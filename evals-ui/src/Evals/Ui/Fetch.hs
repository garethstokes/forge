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
  , setHash
  , setTimeout
  , fetchJson
  ) where

import Data.Aeson (FromJSON, eitherDecodeStrictText)
import Data.Text (Text)
import Miso.DSL (JSVal, asyncCallback, fromJSValUnchecked, jsg, setField, (!), (#))
import Miso.Effect (Effect)
import Miso.Fetch (Response (..), getText)
import Miso.String (MisoString, fromMisoString, ms)

-- | Current @window.location.hash@ (leading @#@ included, empty when unset).
getHash :: IO MisoString
getHash = fromJSValUnchecked =<< jsg "window" ! "location" ! "hash"

-- | Assign @window.location.hash@; the browser then raises @hashchange@,
-- which our subscription turns into 'Evals.Ui.Model.HashChanged'.
setHash :: MisoString -> IO ()
setHash h = do
  loc <- jsg "window" ! "location"
  setField loc "hash" h

-- | Run an action after @delayMs@ milliseconds via @window.setTimeout@.
-- NOT 'Control.Concurrent.threadDelay': on the wasm reactor that would park
-- the JS event loop; setTimeout schedules on it instead.
setTimeout :: Int -> IO () -> IO ()
setTimeout delayMs action = do
  cb <- asyncCallback action
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
fetchJson url k = getText url [] ok err
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
