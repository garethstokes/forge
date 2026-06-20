{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module NotifySpec (tests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC8
import Data.Functor.Identity (Identity)
import Data.IORef
import GHC.Generics (Generic)
import Harness
import Manifest.Core.Meta (genericTableMeta)
import Manifest.Core.Query (Cond, (=.), (==.))
import Manifest.Core.Table (Field, PrimaryKey, Serial)
import Manifest.Derive ()
import Manifest.Entity (Entity (..), Key (..), Table (..))
import Manifest.Notify (Change (..), listenChanges)
import Manifest.Postgres (Pool, execText, withConnection)
import Manifest.Session
import Manifest.Session.Command
import Manifest.Testing (withEphemeralDb')

-- ---------------------------------------------------------------------------
-- Fixture entities (local to this spec)
-- ---------------------------------------------------------------------------

data PingT f = Ping
  { pingId  :: Field f (PrimaryKey (Serial Int))
  , pingMsg :: Field f String
  } deriving Generic

type Ping = PingT Identity

instance Entity Ping where
  tableMeta     = genericTableMeta @PingT "pings"
  notifyChanges = True

-- Pong: same shape, also opted in, used for dispatch test.
data PongT f = Pong
  { pongId  :: Field f (PrimaryKey (Serial Int))
  , pongMsg :: Field f String
  } deriving Generic

type Pong = PongT Identity

instance Entity Pong where
  tableMeta     = genericTableMeta @PongT "pongs"
  notifyChanges = True

-- Quiet: opted OUT (default notifyChanges = False).
data QuietT f = Quiet
  { quietId  :: Field f (PrimaryKey (Serial Int))
  , quietMsg :: Field f String
  } deriving Generic

type Quiet = QuietT Identity

deriving via (Table "quiets" QuietT) instance Entity Quiet

-- ---------------------------------------------------------------------------
-- DDL helper
-- ---------------------------------------------------------------------------

createFixtureTables :: Pool -> IO ()
createFixtureTables pool =
  withConnection pool $ \conn -> mapM_ (\sql -> execText conn sql [])
    [ "CREATE TABLE pings  (ping_id  BIGSERIAL PRIMARY KEY, ping_msg  TEXT NOT NULL)"
    , "CREATE TABLE pongs  (pong_id  BIGSERIAL PRIMARY KEY, pong_msg  TEXT NOT NULL)"
    , "CREATE TABLE quiets (quiet_id BIGSERIAL PRIMARY KEY, quiet_msg TEXT NOT NULL)"
    ]

-- ---------------------------------------------------------------------------
-- Helpers (unchanged from Task 1)
-- ---------------------------------------------------------------------------

-- | Fork a 'listenChanges' listener; on exception, append a poisoned sentinel
-- so tests fail loudly instead of hanging.
startListener :: ByteString -> [ByteString] -> IO (IORef [Change])
startListener conninfo tables = do
  ref <- newIORef []
  _ <- forkIO $ do
    r <- try (listenChanges conninfo tables (\c -> atomicModifyIORef' ref (\cs -> (cs ++ [c], ()))))
          :: IO (Either SomeException ())
    case r of
      Right () -> pure ()
      Left e   -> atomicModifyIORef' ref (\cs -> (cs ++ [Change (BC8.pack "LISTENER-DIED") (Just (BC8.pack (show e)))], ()))
  pure ref

-- | Poll every 10 ms, up to 5 s, until at least @n@ changes have arrived;
-- return whatever is in the ref at that point.
awaitChanges :: IORef [Change] -> Int -> IO [Change]
awaitChanges ref n = go (500 :: Int)
  where
    go 0   = readIORef ref
    go ticks = do
      cs <- readIORef ref
      if length cs >= n
        then pure cs
        else threadDelay 10_000 >> go (ticks - 1)

-- | Wait for the LISTEN registration to be in place before the first real
-- notify.  Sends 'manifest_pings' warmup pings and loops until one arrives,
-- then waits until the ref length is stable across two consecutive 50 ms ticks
-- (no new warmup arrivals in flight) before returning.  Up to ~100 × 50 ms =
-- 5 s overall.
awaitWarmup :: Pool -> IORef [Change] -> IO ()
awaitWarmup pool ref = go (100 :: Int)
  where
    go 0 = ioError (userError "awaitWarmup: listener never became ready")
    go n = do
      withConnection pool $ \conn ->
        execText conn "SELECT pg_notify('manifest_pings', 'warmup')" []
      threadDelay 50_000
      cs <- readIORef ref
      if null cs
        then go (n - 1)
        else stabilize (length cs)

    -- Keep ticking until the ref length stops growing across two consecutive
    -- 50 ms windows; this drains any straggler warmup notifications.
    stabilize prev = do
      threadDelay 50_000
      cur <- length <$> readIORef ref
      if cur == prev
        then pure ()
        else stabilize cur

tests :: [Test]
tests = group "Notify"
  [ test "listener receives raw pg_notify on a watched channel, strips the prefix" $
      withEphemeralDb' $ \conninfo pool -> do
        ref <- startListener conninfo ["pings"]
        awaitWarmup pool ref
        n0  <- length <$> readIORef ref
        withConnection pool $ \conn ->
          execText conn "SELECT pg_notify('manifest_pings', '42')" []
        cs  <- awaitChanges ref (n0 + 1)
        assertEqual "last change" (Change (BC8.pack "pings") (Just (BC8.pack "42"))) (last cs)

  , test "empty payload becomes Nothing; unwatched channels are not delivered" $
      withEphemeralDb' $ \conninfo pool -> do
        ref <- startListener conninfo ["pings"]
        awaitWarmup pool ref
        n0  <- length <$> readIORef ref
        withConnection pool $ \conn -> do
          -- unwatched channel first
          execText conn "SELECT pg_notify('manifest_quiets', 'x')" []
          -- watched channel with empty payload
          execText conn "SELECT pg_notify('manifest_pings', '')" []
        cs  <- awaitChanges ref (n0 + 1)
        let newTail = drop n0 cs
        assertEqual "tail length" 1 (length newTail)
        assertEqual "empty payload is Nothing"
          (Change (BC8.pack "pings") Nothing)
          (head newTail)

  , test "two watched tables dispatch with the right table field" $
      withEphemeralDb' $ \conninfo pool -> do
        ref <- startListener conninfo ["pings", "pongs"]
        awaitWarmup pool ref
        n0  <- length <$> readIORef ref
        withConnection pool $ \conn ->
          execText conn "SELECT pg_notify('manifest_pongs', '7')" []
        cs  <- awaitChanges ref (n0 + 1)
        assertEqual "last change"
          (Change (BC8.pack "pongs") (Just (BC8.pack "7")))
          (last cs)

  -- -------------------------------------------------------------------------
  -- New emission tests (Task 2)
  -- -------------------------------------------------------------------------

  , test "add/save/delete each notify with the pk" $
      withEphemeralDb' $ \conninfo pool -> do
        createFixtureTables pool
        ref <- startListener conninfo ["pings"]
        awaitWarmup pool ref
        n0 <- length <$> readIORef ref

        -- All three operations in one session so the baseline is always present.
        -- add emits immediately; save and delete are flushed inside withTransaction.
        p <- withSession pool $ do
          p <- add (Ping { pingId = 0, pingMsg = "a" } :: Ping)
          withTransaction $ do
            save (p { pingMsg = "b" } :: Ping)  -- queued; flushed by withTransaction
          withTransaction $ delete p
          pure p
        let pingPk = BC8.pack (show (pingId p))

        -- 3 notifications: add, save, delete
        cs <- awaitChanges ref (n0 + 3)
        let tail3 = drop n0 cs
        assertEqual "3 notifications" 3 (length tail3)
        -- All must reference table "pings"
        assertBool "all on pings" (all (\c -> table c == BC8.pack "pings") tail3)
        -- All three notifications must carry exactly the pk of the inserted row
        assertEqual "add key is pk"    (Just pingPk) (key (head tail3))
        assertEqual "save key is pk"   (Just pingPk) (key (tail3 !! 1))
        assertEqual "delete key is pk" (Just pingPk) (key (tail3 !! 2))

  , test "unchanged save is silent" $
      withEphemeralDb' $ \conninfo pool -> do
        createFixtureTables pool
        ref <- startListener conninfo ["pings"]
        awaitWarmup pool ref
        nWarmup <- length <$> readIORef ref

        -- Deterministic assertion: the unchanged save must produce NO pg_notify
        -- statement. Capture the log length after the add (which does emit),
        -- then verify no new pg_notify appears after the save.
        stmts <- withSession pool $ do
          p <- add (Ping { pingId = 0, pingMsg = "x" } :: Ping)
          afterAdd <- statementLog
          withTransaction (save p)  -- no field changed → silent
          afterSave <- statementLog
          -- return only the statements added by the save (and its flush)
          pure (drop (length afterAdd) afterSave)
        let notifyStmts = filter (BC8.isInfixOf (BC8.pack "pg_notify") . fst) stmts
        assertEqual "no pg_notify statement for unchanged save" [] notifyStmts

        -- Delivery-timing assertion (sentinel-bounded): the unchanged save must
        -- NOT add a second notification after the add's notification lands.
        csAdd <- awaitChanges ref (nWarmup + 1)
        let n0 = length csAdd

        -- sentinel: add a second row to get a guaranteed notification
        p2 <- withSession pool (add (Ping { pingId = 0, pingMsg = "sentinel" } :: Ping))
        let sentinelPk = BC8.pack (show (pingId p2))
        cs <- awaitChanges ref (n0 + 1)
        let newTail = drop n0 cs
        assertEqual "exactly one new change (sentinel only)" 1 (length newTail)
        assertEqual "sentinel pk" (Change (BC8.pack "pings") (Just sentinelPk)) (head newTail)

  , test "transaction gating: commit delivers, rollback suppresses" $
      withEphemeralDb' $ \conninfo pool -> do
        createFixtureTables pool
        ref <- startListener conninfo ["pings"]
        awaitWarmup pool ref
        n0 <- length <$> readIORef ref

        -- committed transaction: two adds should deliver two notifications
        withSession pool $ withTransaction $ do
          _ <- add (Ping { pingId = 0, pingMsg = "c1" } :: Ping)
          _ <- add (Ping { pingId = 0, pingMsg = "c2" } :: Ping)
          pure ()
        cs1 <- awaitChanges ref (n0 + 2)
        assertEqual "committed: 2 new" 2 (length cs1 - n0)

        n1 <- length <$> readIORef ref

        -- rolled-back transaction: notifications must NOT be delivered
        _ <- (try :: IO a -> IO (Either SomeException a)) $
               withSession pool $ withTransaction $ do
                 _ <- add (Ping { pingId = 0, pingMsg = "r1" } :: Ping)
                 _ <- liftIO (ioError (userError "force rollback"))
                 pure ()

        -- sentinel add to prove the channel is still live
        p3 <- withSession pool (add (Ping { pingId = 0, pingMsg = "sentinel" } :: Ping))
        let sentinelPk = BC8.pack (show (pingId p3))
        cs2 <- awaitChanges ref (n1 + 1)
        let newTail = drop n1 cs2
        assertEqual "rollback+sentinel: exactly 1 new" 1 (length newTail)
        assertEqual "only sentinel arrived" (Change (BC8.pack "pings") (Just sentinelPk)) (head newTail)

  , test "command path: update emits pk, deleteWhere emits Nothing" $
      withEphemeralDb' $ \conninfo pool -> do
        createFixtureTables pool
        ref <- startListener conninfo ["pings"]
        awaitWarmup pool ref
        nWarmup <- length <$> readIORef ref

        p <- withSession pool (add (Ping { pingId = 0, pingMsg = "cmd" } :: Ping))
        let pk = BC8.pack (show (pingId p))

        -- wait for the add notification to arrive
        csAdd <- awaitChanges ref (nWarmup + 1)
        assertEqual "add emits pk" (Change (BC8.pack "pings") (Just pk)) (last csAdd)
        let n0 = length csAdd

        -- update by key
        withSession pool (update @Ping (Key (pingId p)) [#pingMsg =. ("updated" :: String)])
        cs1 <- awaitChanges ref (n0 + 1)
        assertEqual "update emits pk" (Change (BC8.pack "pings") (Just pk)) (last cs1)

        -- deleteWhere
        withSession pool (deleteWhere @Ping [#pingMsg ==. ("updated" :: String)])
        cs2 <- awaitChanges ref (n0 + 2)
        assertEqual "deleteWhere emits Nothing" (Change (BC8.pack "pings") Nothing) (last cs2)

  , test "non-opted entity is silent" $
      withEphemeralDb' $ \conninfo pool -> do
        createFixtureTables pool
        ref <- startListener conninfo ["pings", "quiets"]
        awaitWarmup pool ref
        n0 <- length <$> readIORef ref

        -- add a Quiet row — should produce no notification on "quiets"
        _ <- withSession pool (add (Quiet { quietId = 0, quietMsg = "shh" } :: Quiet))

        -- sentinel on pings to prove listener is live
        p <- withSession pool (add (Ping { pingId = 0, pingMsg = "sentinel" } :: Ping))
        let sentinelPk = BC8.pack (show (pingId p))
        cs <- awaitChanges ref (n0 + 1)
        let newTail = drop n0 cs
        assertEqual "only sentinel (Quiet is silent)" 1 (length newTail)
        assertEqual "sentinel is the only change"
          (Change (BC8.pack "pings") (Just sentinelPk)) (head newTail)

  , test "dispatch: Pong notifies on pongs channel" $
      withEphemeralDb' $ \conninfo pool -> do
        createFixtureTables pool
        ref <- startListener conninfo ["pings", "pongs"]
        awaitWarmup pool ref
        n0 <- length <$> readIORef ref

        pong <- withSession pool (add (Pong { pongId = 0, pongMsg = "hello" } :: Pong))
        let pk = BC8.pack (show (pongId pong))
        cs <- awaitChanges ref (n0 + 1)
        assertEqual "pong dispatches on pongs"
          (Change (BC8.pack "pongs") (Just pk)) (last cs)
  ]
