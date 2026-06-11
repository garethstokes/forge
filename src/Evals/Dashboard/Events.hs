{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The live half of the dashboard: a broadcast hub fed by manifest's change
-- feed, fanned out to browsers as Server-Sent Events. Wake-up-only semantics
-- end to end: an event is a hint to refetch, never data.
module Evals.Dashboard.Events
  ( EventHub
  , newEventHub
  , publish
  , runListener
  , sseResponse
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TChan, atomically, dupTChan, newBroadcastTChanIO, readTChan, writeTChan)
import Control.Exception (SomeException, try)
import Control.Monad (forever)
import Data.Aeson (encode)
import Data.ByteString (ByteString)
import Data.ByteString.Builder (byteString, lazyByteString)
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types (status200)
import Network.Wai (Response, responseStream)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)

import qualified Manifest.Notify as Notify
import Evals.Api (ChangeDto (..))

-- | One broadcast channel; every SSE client holds a 'dupTChan' view.
newtype EventHub = EventHub (TChan ChangeDto)

newEventHub :: IO EventHub
newEventHub = EventHub <$> newBroadcastTChanIO

publish :: EventHub -> ChangeDto -> IO ()
publish (EventHub ch) = atomically . writeTChan ch

-- | The change-feed tables the dashboard watches.
watchedTables :: [ByteString]
watchedTables = ["runs", "outputs", "scores", "run_metrics"]

-- | The listener supervisor: 'Manifest.Notify.listenChanges' throws on
-- connection loss by contract (the caller owns retry) — this is that caller.
-- Log and reconnect with a 1s backoff, forever. Run on its own thread.
runListener :: ByteString -> EventHub -> IO ()
runListener conninfo hub = forever $ do
  r <- try (Notify.listenChanges conninfo watchedTables (publish hub . toDto))
  case r of
    Left (e :: SomeException) ->
      hPutStrLn stderr ("evals-dashboard: change-feed listener died: " <> show e <> "; reconnecting in 1s")
    Right () -> pure ()
  threadDelay 1000000
  where
    toDto c = ChangeDto
      { table = TE.decodeUtf8Lenient (Notify.table c)
      , key   = TE.decodeUtf8Lenient <$> Notify.key c
      }

-- | The SSE stream for one client: a fresh dup of the hub, then alternate
-- between forwarding events and 25s keepalive comments (which also surface
-- dead clients as write failures, ending this handler's thread).
sseResponse :: EventHub -> Response
sseResponse (EventHub ch) =
  responseStream status200
    [ ("Content-Type", "text/event-stream")
    , ("Cache-Control", "no-cache") ]
    $ \write flush -> do
        myChan <- atomically (dupTChan ch)
        write (byteString ": connected\n\n") >> flush
        forever $ do
          mc <- timeout 25000000 (atomically (readTChan myChan))
          case mc of
            Just c  -> write (lazyByteString ("data: " <> encode c <> "\n\n")) >> flush
            Nothing -> write (byteString ": keepalive\n\n") >> flush
