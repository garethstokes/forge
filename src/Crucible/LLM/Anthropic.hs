{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | The live Anthropic interpreter for the 'LLM' effect (M8).
--
-- @runLLMAnthropic@ discharges @LLM@ by calling the real Anthropic Messages
-- API over HTTPS (@POST \/v1\/messages@) via @http-client-tls@. It is the
-- @IOE@-grounded counterpart to the pure @runLLMScripted@: the control loop's
-- @(LLM :> es, Tools :> es)@ type is unchanged; only the interpreter at the
-- edge differs.
--
-- Request/response JSON is built and read with the in-repo hand-rolled codecs
-- (@Crucible.Json.*@) — no aeson. System messages are hoisted to the top-level
-- @system@ field; the rest map to the API's user\/assistant turns.
module Crucible.LLM.Anthropic
  ( AnthropicConfig (..)
  , defaultAnthropicConfig
  , runLLMAnthropic
  , recordLLMAnthropic
  , runLLMCassette
  , AnthropicError (..)
  , isRetryable
  ) where

import Data.List (partition)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO

import qualified Data.ByteString.Lazy as LBS

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret)
import Effectful.State.Static.Local (evalState, get, put)

import Control.Exception (Exception)
import Network.HTTP.Client
  ( HttpException
  , RequestBody (RequestBodyLBS)
  , httpLbs
  , method
  , parseRequest
  , requestBody
  , requestHeaders
  , responseBody
  )
import Network.HTTP.Client.TLS (newTlsManager)

import Crucible.Json.Encode (encode)
import Crucible.Json.Value (Value (..))
import qualified Crucible.Json.Decode as D
import Crucible.LLM (LLM (..), Message (..), Role (..))

-- | A typed live-path failure. Network/timeout errors are wrapped as
-- 'AnthropicHttpError'; a non-2xx response is 'AnthropicStatusError'; a 2xx body
-- with no text content block is 'AnthropicNoContent'. Thrown by the live
-- interpreter (the 'LLM' effect still returns 'Text'); callers 'try' it in IO.
data AnthropicError
  = AnthropicHttpError   HttpException
  | AnthropicStatusError Int Text
  | AnthropicNoContent   Text
  deriving (Show)

instance Exception AnthropicError

-- | Whether a failure is worth retrying: network/timeout errors and HTTP 429 /
-- 5xx are transient; other 4xx and a content-shape failure are permanent.
isRetryable :: AnthropicError -> Bool
isRetryable (AnthropicHttpError _)     = True
isRetryable (AnthropicStatusError s _) = s == 429 || s >= 500
isRetryable (AnthropicNoContent _)     = False

-- | What the live interpreter needs: an API key, a model id, and a token cap.
data AnthropicConfig = AnthropicConfig
  { acApiKey    :: Text
  , acModel     :: Text
  , acMaxTokens :: Int
  }
  deriving (Eq, Show)

-- | A config with a sensible default model + token cap; supply the API key.
defaultAnthropicConfig :: Text -> AnthropicConfig
defaultAnthropicConfig key =
  AnthropicConfig
    { acApiKey = key
    , acModel = "claude-haiku-4-5-20251001"
    , acMaxTokens = 1024
    }

-- | Interpret @LLM@ against the live Anthropic Messages API. Each 'Complete'
-- becomes one @POST \/v1\/messages@; the reply is the first text content block.
runLLMAnthropic :: (IOE :> es) => AnthropicConfig -> Eff (LLM : es) a -> Eff es a
runLLMAnthropic cfg = interpret $ \_ -> \case
  Complete msgs -> liftIO (anthropicComplete cfg msgs)

-- | Like 'runLLMAnthropic', but also TEE each reply to a cassette file (one
-- JSON-encoded reply per line, appended in call order). A recorded cassette
-- replays deterministically via 'runLLMCassette' — the slider between a live
-- eval and a hermetic test.
recordLLMAnthropic :: (IOE :> es) => FilePath -> AnthropicConfig -> Eff (LLM : es) a -> Eff es a
recordLLMAnthropic path cfg = interpret $ \_ -> \case
  Complete msgs -> liftIO $ do
    reply <- anthropicComplete cfg msgs
    TIO.appendFile path (encode (JString reply) <> "\n")
    pure reply

-- | Replay a cassette recorded by 'recordLLMAnthropic': each 'Complete' pops the
-- next recorded reply in order (a file-backed 'runLLMScripted'). Deterministic;
-- no network. Exhausting the cassette yields @""@.
runLLMCassette :: (IOE :> es) => FilePath -> Eff (LLM : es) a -> Eff es a
runLLMCassette path action = do
  contents <- liftIO (TIO.readFile path)
  let replies =
        [ either (const ln) id (D.decodeString D.string ln)
        | ln <- T.lines contents
        , not (T.null ln)
        ]
  reinterpret (evalState replies) (\_ -> \case
    Complete _ -> do
      rs <- get
      case rs of
        (x : xs) -> put xs >> pure x
        []       -> pure "")
    action

-- | One live round-trip: encode the messages, POST them, return the reply text.
-- A non-JSON or shape-unexpected response degrades to the raw body so failures
-- surface legibly rather than as an empty string.
anthropicComplete :: AnthropicConfig -> [Message] -> IO Text
anthropicComplete cfg msgs = do
  mgr <- newTlsManager
  base <- parseRequest "https://api.anthropic.com/v1/messages"
  let req =
        base
          { method = "POST"
          , requestHeaders =
              [ ("x-api-key", TE.encodeUtf8 (acApiKey cfg))
              , ("anthropic-version", "2023-06-01")
              , ("content-type", "application/json")
              ]
          , requestBody =
              RequestBodyLBS (LBS.fromStrict (TE.encodeUtf8 (encode (requestJson cfg msgs))))
          }
  resp <- httpLbs req mgr
  let body = TE.decodeUtf8 (LBS.toStrict (responseBody resp))
  pure (either (const body) id (extractText body))

-- | The Anthropic request body. System turns are concatenated into the
-- top-level @system@ field; the remaining turns become the @messages@ array.
requestJson :: AnthropicConfig -> [Message] -> Value
requestJson cfg msgs =
  JObject $
    [ ("model", JString (acModel cfg))
    , ("max_tokens", JNumber (fromIntegral (acMaxTokens cfg)))
    ]
      ++ systemField
      ++ [ ("messages", JArray [turn m | m <- conversation]) ]
  where
    (systems, conversation) = partition ((== System) . role) msgs
    systemField = case systems of
      [] -> []
      _  -> [("system", JString (T.intercalate "\n\n" (map content systems)))]
    turn (Message r c) =
      JObject [("role", JString (anthropicRole r)), ("content", JString c)]

-- | Map a 'Role' to an Anthropic message role. System is handled separately; a
-- Tool result is sent as a user turn (the API has no distinct tool role here).
anthropicRole :: Role -> Text
anthropicRole = \case
  Assistant -> "assistant"
  _         -> "user"

-- | Pull @content[0].text@ out of a Messages API response.
extractText :: Text -> Either D.Error Text
extractText = D.decodeString (D.field "content" (D.index 0 (D.field "text" D.string)))
