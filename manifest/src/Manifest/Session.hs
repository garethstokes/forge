{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Manifest.Session
  ( Db
  , unDb
  , Session(..)
  , SessionConfig(..)
  , defaultConfig
  , PendingOp(..)
  , IdentityMap
  , withSession
  , execDb
  , decodeRowDb
  , statementLog
  , setBaseline
  , lookupBaseline
  , get
  , selectWhere
  , withTransaction
  , withRlsContext
  , flush
  , add
  , insertCreate
  , save
  , delete
  , emitChange
  ) where

import Control.Monad (void, unless, when)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Exception (SomeException, throwIO, try)
import Control.Monad.Trans.Reader (ReaderT(..), ask, runReaderT)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Maybe (fromMaybe)
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic, Rep)
import Type.Reflection (SomeTypeRep)
import Manifest.Core.Assign (assignments, GAssignEncode)
import Manifest.Core.Cascade (OnDelete(..), CascadeRule(..))
import Manifest.Core.Codec (SqlParam, DbType, encode, decodeRow)
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..), pkColumn, cmName, cmIsSerial, cmIsPK, cmIsGenerated)
import Manifest.Core.Query (Cond(..), Op(..), Assign(..))
import Manifest.Core.Sql (renderSelect, renderInsert, renderUpdate, renderDelete)
import Manifest.Entity
import Manifest.Error (DbError(..), DbException(..))
import Manifest.Postgres (Connection, Pool, execText, withConnection)

-- | (TypeRep, encoded-PK) → baseline encoded-column vector.
type IdentityMap = Map (SomeTypeRep, SqlParam) [SqlParam]

-- | A deferred write awaiting flush. (Adds are eager — see plan notes.)
data PendingOp where
  OpSave   :: Entity a => a -> PendingOp
  OpDelete :: Entity a => a -> PendingOp

data SessionConfig = SessionConfig
  { cfgAutoflush :: Bool   -- ^ flush pending writes before each query (default on)
  }

defaultConfig :: SessionConfig
defaultConfig = SessionConfig { cfgAutoflush = True }

data Session = Session
  { sessConn     :: Connection
  , sessIdentity :: IORef IdentityMap
  , sessPending  :: IORef [PendingOp]
  , sessLog      :: IORef [(ByteString, [SqlParam])]
  , sessConfig   :: SessionConfig
  }

-- | The session monad: sealed @ReaderT Session IO@.
newtype Db a = Db { unDb :: ReaderT Session IO a }
  deriving (Functor, Applicative, Monad, MonadIO)

-- | Acquire a connection, fresh per-session maps, run, release.
withSession :: Pool -> Db a -> IO a
withSession pool (Db r) =
  withConnection pool $ \conn -> do
    idMap <- newIORef Map.empty
    pend  <- newIORef []
    logr  <- newIORef []
    runReaderT r (Session conn idMap pend logr defaultConfig)

-- | Execute a data statement, appending it to the session statement log.
execDb :: ByteString -> [SqlParam] -> Db [[SqlParam]]
execDb sql params = Db $ do
  sess <- ask
  liftIO $ modifyIORef' (sessLog sess) (++ [(sql, params)])
  liftIO $ execText (sessConn sess) sql params

-- | The statements executed so far this session, in order.
statementLog :: Db [(ByteString, [SqlParam])]
statementLog = Db $ ask >>= liftIO . readIORef . sessLog

-- Identity-map helpers (used here and by flush in Task 10) --------------------

setBaseline :: forall a. Entity a => a -> Db ()
setBaseline a = Db $ do
  sess <- ask
  liftIO $ modifyIORef' (sessIdentity sess) (Map.insert (identityKey a) (rowEncode a))

lookupBaseline :: (SomeTypeRep, SqlParam) -> Db (Maybe [SqlParam])
lookupBaseline k = Db $ do
  sess <- ask
  liftIO $ Map.lookup k <$> readIORef (sessIdentity sess)

-- Read path -------------------------------------------------------------------

decodeRowDb :: forall a. Entity a => [SqlParam] -> Db a
decodeRowDb row = case decodeRow (rowDecoder @a) row of
  Right a  -> pure a
  Left err -> Db (liftIO (throwIO (DbException (DecodeFailure err))))

-- | Emit the change-feed wake-up for an opted-in entity. Goes through
-- 'execDb' so it appears in the statement log; Postgres delivers NOTIFY at
-- COMMIT inside a transaction (and drops it on ROLLBACK), immediately
-- otherwise. The payload is the pk as text, or empty for bulk operations.
--
-- Note on failure: the notify is a statement like any other. If it throws
-- (e.g., connection death between the preceding write and this call), the
-- exception propagates to the caller. In autocommit mode the preceding write
-- may have already committed at that point — the write is durable but the
-- wake-up is lost. Subscribers that cannot afford missed wake-ups should poll
-- as a backstop (consistent with the 'listenChanges' haddock).
emitChange :: forall a. Entity a => SqlParam -> Db ()
emitChange pk =
  when (notifyChanges @a) $
    void $ execDb "SELECT pg_notify($1, $2)"
      [ Just ("manifest_" <> tmTable (tableMeta @a))
      , Just (fromMaybe "" pk) ]

-- | flush hook — flushes pending writes before each query when autoflush is on.
autoflushHook :: Db ()
autoflushHook = do
  on <- Db (cfgAutoflush . sessConfig <$> ask)
  if on then flush else pure ()

-- | Load by primary key; records a baseline snapshot for the loaded entity.
get :: forall a. (Entity a, DbType (PrimKey a)) => Key a -> Db (Maybe a)
get (Key k) = do
  autoflushHook
  let tm  = tableMeta @a
      sql = renderSelect tm [Cond (cmName (pkColumn tm)) OpEq (encode k)]
  rows <- execDb sql [encode k]
  case rows of
    []        -> pure Nothing
    (row : _) -> do
      a <- decodeRowDb @a row
      setBaseline a
      pure (Just a)

-- | Load all rows matching the (ANDed) conditions; each becomes managed.
selectWhere :: forall a. Entity a => [Cond a] -> Db [a]
selectWhere conds = do
  autoflushHook
  let tm  = tableMeta @a
      sql = renderSelect tm conds
      ps  = [ v | Cond _ _ v <- conds ]
  rows <- execDb sql ps
  mapM (\row -> do a <- decodeRowDb @a row; setBaseline a; pure a) rows

-- Write path ------------------------------------------------------------------

-- | Append a deferred op to the session's pending queue.
pushPending :: PendingOp -> Db ()
pushPending op = Db $ do
  sess <- ask
  liftIO $ modifyIORef' (sessPending sess) (++ [op])

-- | Queue a save (UPDATE on flush, snapshot-diffed against the baseline).
save :: Entity a => a -> Db ()
save a = pushPending (OpSave a)

-- | Queue a delete (DELETE on flush).
delete :: Entity a => a -> Db ()
delete a = pushPending (OpDelete a)

-- | Insert a new row EAGERLY (documented SP1 choice): issues the INSERT
-- immediately, decodes the RETURNING row into the persistent record (PK
-- filled), records its baseline, and returns it.
add :: forall a. Entity a => a -> Db a
add a = do
  let tm      = tableMeta @a
      insCols = filter (not . cmIsSerial) (tmColumns tm)
      vals    = [ v | (c, v) <- zip (tmColumns tm) (rowEncode a), not (cmIsSerial c) ]
      sql     = renderInsert tm insCols
  rows <- execDb sql vals
  case rows of
    (row : _) -> do
      a' <- decodeRowDb @a row
      setBaseline a'
      emitChange @a (pkParam a')
      pure a'
    [] -> Db (liftIO (throwIO (DbException (OtherError "add: INSERT returned no row"))))

-- | Insert a new row from a Create-projection record (omitting DB-assigned serial
-- PK columns, which contribute nothing to 'assignments'). Decodes the RETURNING
-- row into the persistent entity (PK filled by the DB), records its baseline,
-- and returns it.
insertCreate :: forall a c. (Entity a, Generic c, GAssignEncode (Rep c)) => c -> Db a
insertCreate c = do
  let tm    = tableMeta @a
      asgs  = assignments c :: [Assign a]
      names = [ n | Assign n _ <- asgs ]
      vals  = [ v | Assign _ v <- asgs ]
      -- ColumnMeta for each assigned column, in the SAME order as names/vals:
      cols  = [ m | n <- names, m <- tmColumns tm, cmName m == n ]
      sql   = renderInsert tm cols
  rows <- execDb sql vals
  case rows of
    (row : _) -> do
      a' <- decodeRowDb @a row
      setBaseline a'
      emitChange @a (pkParam a')
      pure a'
    [] -> Db (liftIO (throwIO (DbException (OtherError "insertCreate: INSERT returned no row"))))

-- | Flush all pending writes: take & clear the queue, run all saves then deletes.
flush :: Db ()
flush = do
  ops <- Db $ do
    sess <- ask
    liftIO $ atomicModifyIORef' (sessPending sess) (\os -> ([], os))
  mapM_ (\op -> case op of OpSave a -> flushSave a; _ -> pure ()) ops
  mapM_ (\op -> case op of OpDelete a -> flushDelete a; _ -> pure ()) ops

-- | Emit a MINIMAL UPDATE: diff the record against its baseline column-by-column
-- and update only the changed (non-PK) columns. No baseline → 'UnmanagedSave'.
flushSave :: forall a. Entity a => a -> Db ()
flushSave a = do
  let tm = tableMeta @a
  mb <- lookupBaseline (identityKey a)
  case mb of
    Nothing -> Db (liftIO (throwIO (DbException (UnmanagedSave (BC.unpack (tmTable tm))))))
    Just baseline -> do
      let changed = [ (cmName c, v)
                    | (c, v, b) <- zip3 (tmColumns tm) (rowEncode a) baseline
                    , not (cmIsPK c)
                    , not (cmIsGenerated c)
                    , v /= b ]
      if null changed
        then pure ()
        else do
          _ <- execDb (renderUpdate tm (map fst changed) (cmName (pkColumn tm)))
                      (map snd changed ++ [pkParam a])
          setBaseline a
          emitChange @a (pkParam a)

-- | Emit a DELETE for the record, applying onDelete cascades first, and drop it
-- from the identity map. Cascades run in two passes over the WHOLE rule tree:
-- all reachable 'Restrict' checks first (aborting the delete if any child
-- exists anywhere in the tree, so nothing is partially mutated), then the
-- mutating policies, deepest-first ('Cascade' DELETE / 'SetNull' UPDATE).
flushDelete :: forall a. Entity a => a -> Db ()
flushDelete a = do
  let tm     = tableMeta @a
      parent = pkParam a
      rules  = cascadeRules @a
      path   = [tmTable tm]
  -- 1. all Restrict checks first (abort the whole delete if any child exists)
  restrictPass parent path Nothing rules
  -- 2. then the mutating policies, deepest-first
  mutatePass parent path Nothing rules
  -- 3. delete the parent
  -- Note: cascade-deleted children deliberately do NOT notify — only the root deletion is reported.
  _ <- execDb (renderDelete tm (cmName (pkColumn tm))) [parent]
  emitChange @a parent
  Db $ do
    sess <- ask
    liftIO $ modifyIORef' (sessIdentity sess) (Map.delete (identityKey a))

-- | The walk's scope: Nothing at the root (the rule's FK matches the deleted
-- PK, @$1@, directly); deeper, the enclosing rule's (table, pk, condition) —
-- the child FK must be IN the enclosing rule's selected rows.
type Enclosing = Maybe (ByteString, ByteString, ByteString)

-- | The WHERE condition selecting a rule's in-scope child rows.
ruleCond :: CascadeRule -> Enclosing -> ByteString
ruleCond r Nothing = crFkColumn r <> " = $1"
ruleCond r (Just (pTable, pPk, pCond)) =
  crFkColumn r <> " IN (SELECT " <> pPk <> " FROM " <> pTable <> " WHERE " <> pCond <> ")"

-- | Descend into a Cascade rule's children unless its table is already on the
-- path (cycle guard: one level per declared self/mutual edge). Rows deleted at
-- a cut level have NONE of their own rules applied — grandchildren through the
-- cycle are orphaned and even their 'Restrict' rules are bypassed.
descend :: SqlParam -> [ByteString] -> Enclosing -> CascadeRule
        -> (SqlParam -> [ByteString] -> Enclosing -> [CascadeRule] -> Db ()) -> Db ()
descend parent path enclosing r walk =
  unless (crChildTable r `elem` path) $
    walk parent (crChildTable r : path)
         (Just (crChildTable r, crChildPk r, ruleCond r enclosing))
         (crChildRules r)

-- | Pass 1: every 'Restrict' rule reachable through 'Cascade' edges, checked
-- before anything mutates. A hit aborts the whole delete.
restrictPass :: SqlParam -> [ByteString] -> Enclosing -> [CascadeRule] -> Db ()
restrictPass parent path enclosing = mapM_ check
  where
    check r = case crPolicy r of
      Restrict -> do
        rows <- execDb ("SELECT 1 FROM " <> crChildTable r <> " WHERE "
                          <> ruleCond r enclosing <> " LIMIT 1") [parent]
        unless (null rows) $
          liftIO (throwIO (DbException (OtherError
            ("onDelete Restrict: " <> show (crChildTable r) <> " still has children"))))
      Cascade  -> descend parent path enclosing r restrictPass
      SetNull  -> pure ()

-- | Pass 2: mutations, deepest-first. 'Cascade' recurses into the child's own
-- rules before deleting the child rows; 'SetNull' applies at its depth and
-- does not descend (those rows survive).
mutatePass :: SqlParam -> [ByteString] -> Enclosing -> [CascadeRule] -> Db ()
mutatePass parent path enclosing = mapM_ apply
  where
    apply r = case crPolicy r of
      Restrict -> pure ()  -- handled in restrictPass
      SetNull  -> void $ execDb ("UPDATE " <> crChildTable r <> " SET " <> crFkColumn r
                                   <> " = NULL WHERE " <> ruleCond r enclosing) [parent]
      Cascade  -> do
        descend parent path enclosing r mutatePass
        void $ execDb ("DELETE FROM " <> crChildTable r <> " WHERE "
                         <> ruleCond r enclosing) [parent]

-- | Set GUC variables for the enclosing transaction (LOCAL-scoped via set_config,
-- so they auto-clear at COMMIT/ROLLBACK and never leak to the next pool checkout).
-- Use inside 'withTransaction'. RLS policies read these with @current_setting(...)@.
withRlsContext :: [(Text, Text)] -> Db a -> Db a
withRlsContext settings body = do
  mapM_ setLocal settings
  body
  where
    setLocal (k, v) =
      void $ execDb "SELECT set_config($1, $2, true)"
                    [Just (TE.encodeUtf8 k), Just (TE.encodeUtf8 v)]

-- | Run a block inside a database transaction. BEGIN/COMMIT/ROLLBACK are issued
-- raw (NOT logged) so the statement log shows only data statements. On exception
-- the transaction is rolled back and the exception re-thrown.
withTransaction :: Db a -> Db a
withTransaction (Db body) = Db $ do
  sess <- ask
  let conn = sessConn sess
  _ <- liftIO $ execText conn "BEGIN" []
  r <- liftIO (try (runReaderT (body >>= \x -> unDb flush >> pure x) sess))
  case r of
    Left (e :: SomeException) -> do
      _ <- liftIO $ execText conn "ROLLBACK" []
      liftIO (throwIO e)
    Right a -> do
      _ <- liftIO $ execText conn "COMMIT" []
      pure a
