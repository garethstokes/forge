module NotifySpec (tests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC8
import Data.IORef
import Harness
import Manifest.Notify (Change (..), listenChanges)
import Manifest.Postgres (Pool, execText, withConnection)
import Manifest.Testing (withEphemeralDb')

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
  ]
