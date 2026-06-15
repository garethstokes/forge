{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The SPA's IO edges: reading\/writing @window.location.hash@ (via miso's
-- JS DSL) and same-origin JSON fetches.
--
-- miso 1.11 ships 'Miso.Fetch.getJSON', but it decodes with miso's own
-- @Miso.JSON.FromJSON@ — our DTOs ("Evals.Api") carry aeson instances shared
-- with the server, so we fetch text and decode with aeson instead.
module Evals.Ui.Fetch
  ( getHash
  , getOrgPrefix
  , setHash
  , setTimeout
  , fetchJson
  ) where

import Data.Aeson (FromJSON, eitherDecodeStrictText)
import Data.Text (Text)
import qualified Data.Text as T
import Data.IORef (newIORef, readIORef, writeIORef)
import Miso.DSL (Function (..), JSVal, asyncCallback, freeFunction, fromJSValUnchecked, jsg, setField, (!), (#))
import Miso.Effect (Effect, withSink)
import Miso.Fetch (Response (..), accept, textPlain)
import Miso.FFI.Internal (fetch, CONTENT_TYPE (..))
import Miso.String (MisoString, fromMisoString, ms)

-- | Current @window.location.hash@ (leading @#@ included, empty when unset).
getHash :: IO MisoString
getHash = fromJSValUnchecked =<< jsg "window" ! "location" ! "hash"

-- | The org path prefix from @window.location.pathname@'s first segment:
-- @"\/acme\/..."@ -> @"\/acme"@; @"\/"@ or @""@ -> @""@. The dashboard is served
-- under @\/<orgSlug>\/@, so all API calls are made relative to that prefix.
getOrgPrefix :: IO MisoString
getOrgPrefix = do
  p <- fromJSValUnchecked =<< jsg "window" ! "location" ! "pathname"
  let segs = filter (not . T.null) (T.splitOn "/" (fromMisoString (p :: MisoString)))
  pure $ case segs of
    (s : _) -> ms ("/" <> s)
    []      -> ""

-- | Assign @window.location.hash@; the browser then raises @hashchange@,
-- which our subscription turns into 'Evals.Ui.Model.HashChanged'.
setHash :: MisoString -> IO ()
setHash h = do
  loc <- jsg "window" ! "location"
  setField loc "hash" h

-- | Run an action after @delayMs@ milliseconds via @window.setTimeout@.
-- NOT 'Control.Concurrent.threadDelay': on the wasm reactor that would park
-- the JS event loop; setTimeout schedules on it instead.
--
-- The JS callback frees itself after firing to avoid a permanent GC reference:
-- we stash the 'Function' handle in an 'IORef' so the callback body can read
-- it back and call 'freeFunction' once the action has run.
setTimeout :: Int -> IO () -> IO ()
setTimeout delayMs action = do
  ref <- newIORef Nothing
  cb  <- asyncCallback $ do
    action
    readIORef ref >>= mapM_ freeFunction
  writeIORef ref (Just (Function cb))
  _ <- jsg "window" # "setTimeout" $ (cb, delayMs)
  pure ()

-- | GET @url@ and aeson-decode the response body, delivering the result
-- (or a human-readable error) as a single action.
fetchJson
  :: forall a action parent props model
   . FromJSON a
  => MisoString
  -> (Either MisoString a -> action)
  -> Effect parent props model action
fetchJson url k = withSink $ \sink -> do
  prefix <- getOrgPrefix
  fetch (prefix <> url) "GET" Nothing [(accept, textPlain)] (sink . ok) (sink . err) TEXT
  where
    ok :: Response MisoString -> action
    ok resp =
      case eitherDecodeStrictText (fromMisoString resp.body :: Text) of
        Left e -> k (Left (url <> ": decode error: " <> ms e))
        Right a -> k (Right a)
    -- miso 1.11 fetchCore nulls errorMessage on async failures and throws
    -- before reading the response body, so the server's ApiError JSON on 4xx
    -- is unreachable here — the HTTP status line is all we get.
    -- non-2xx and network failures land here; the body is a JS Error, so
    -- report the status code rather than poking at it
    err :: Response JSVal -> action
    err resp =
      k . Left $ mconcat
        [ url
        , ": request failed"
        , maybe "" (\s -> " (HTTP " <> msShow s <> ")") resp.status
        , maybe "" (": " <>) resp.errorMessage
        ]
    msShow = ms . show
