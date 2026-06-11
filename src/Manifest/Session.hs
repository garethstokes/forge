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
  , save
  , delete
  ) where

import Control.Monad (void, unless)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Exception (SomeException, throwIO, try)
import Control.Monad.Trans.Reader (ReaderT(..), ask, runReaderT)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Type.Reflection (SomeTypeRep)
import Manifest.Core.Cascade (OnDelete(..), CascadeRule(..))
import Manifest.Core.Codec (SqlParam, DbType, encode, decodeRow)
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..), pkColumn, cmName, cmIsSerial, cmIsPK)
import Manifest.Core.Query (Cond(..), Op(..))
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
      pure a'
    [] -> Db (liftIO (throwIO (DbException (OtherError "add: INSERT returned no row"))))

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
                    , v /= b ]
      if null changed
        then pure ()
        else do
          _ <- execDb (renderUpdate tm (map fst changed) (cmName (pkColumn tm)))
                      (map snd changed ++ [pkParam a])
          setBaseline a

-- | Emit a DELETE for the record, applying onDelete cascades first, and drop it
-- from the identity map. Cascades run in two passes: all 'Restrict' checks first
-- (aborting the whole delete if any child exists, so nothing is partially
-- mutated), then the mutating policies ('Cascade' DELETE / 'SetNull' UPDATE).
flushDelete :: forall a. Entity a => a -> Db ()
flushDelete a = do
  let tm     = tableMeta @a
      parent = pkParam a
      rules  = cascadeRules @a
  -- 1. all Restrict checks first (abort the whole delete if any child exists)
  mapM_ (restrictCheck parent) [r | r <- rules, crPolicy r == Restrict]
  -- 2. then the mutating policies
  mapM_ (applyMutating parent) [r | r <- rules, crPolicy r /= Restrict]
  -- 3. delete the parent (unchanged from SP1)
  _ <- execDb (renderDelete tm (cmName (pkColumn tm))) [parent]
  Db $ do
    sess <- ask
    liftIO $ modifyIORef' (sessIdentity sess) (Map.delete (identityKey a))

-- | A 'Restrict' rule: fail the delete if the child table still has rows
-- referencing the parent.
restrictCheck :: SqlParam -> CascadeRule -> Db ()
restrictCheck parent (CascadeRule childT fk _ _ _) = do
  rows <- execDb ("SELECT 1 FROM " <> childT <> " WHERE " <> fk <> " = $1 LIMIT 1") [parent]
  unless (null rows) $
    liftIO (throwIO (DbException (OtherError ("onDelete Restrict: " <> show childT <> " still has children"))))

-- | Apply a mutating cascade policy ('Cascade' DELETEs children, 'SetNull' NULLs
-- their FK). 'Restrict' is a no-op here (handled by 'restrictCheck').
applyMutating :: SqlParam -> CascadeRule -> Db ()
applyMutating parent (CascadeRule childT fk policy _ _) = case policy of
  Cascade  -> void $ execDb ("DELETE FROM " <> childT <> " WHERE " <> fk <> " = $1") [parent]
  SetNull  -> void $ execDb ("UPDATE " <> childT <> " SET " <> fk <> " = NULL WHERE " <> fk <> " = $1") [parent]
  Restrict -> pure ()  -- handled in restrictCheck

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
