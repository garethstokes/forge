{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
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
  , newAnthropicManager
  , requestJson
  , runLLMAnthropic
  , recordLLMAnthropic
  , runLLMCassette
  , AnthropicError (..)
  , isRetryable
  , chatRequestJson
  , turnContentJson
  , parseTurn
  , parseUsage
  , runChatAnthropic
  , recordChatAnthropic
  , runChatCassette
  , runLLMAnthropicUsage
  , runChatAnthropicUsage
  , messagesRequest
  , withAnthropicRetry
  ) where

import Data.List (partition)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO

import qualified Data.ByteString.Lazy as LBS

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret)
import Effectful.State.Static.Local (evalState, get, modify, put, runState)

import Control.Exception (Exception, handle, throwIO)
import Control.Monad.Catch (Handler (Handler))
import Control.Retry (capDelay, fullJitterBackoff, limitRetries, recovering)
import Network.HTTP.Client
  ( HttpException
  , Manager
  , ManagerSettings (managerResponseTimeout)
  , Request
  , RequestBody (RequestBodyLBS)
  , httpLbs
  , method
  , newManager
  , parseRequest
  , requestBody
  , requestHeaders
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

import Crucible.Chat (Block (..), Chat (..), ChatMsg (..), ToolUse (..), Turn (..))
import Crucible.Json.Encode (encode)
import Crucible.Json.Value (Value (..))
import qualified Crucible.Json.Decode as D
import Crucible.LLM (LLM (..), Message (..), Role (..))
import Crucible.Schema (Schema, schemaToJson)
import Crucible.Tool (ToolName)
import Crucible.Usage (Usage (..))

-- | A typed live-path failure. Network/timeout errors are wrapped as
-- 'AnthropicHttpError'; a non-2xx response is 'AnthropicStatusError'; a 2xx body
-- with no text content block is 'AnthropicNoContent'. Thrown by the live
-- interpreter (the 'LLM' effect still returns 'Text'); callers 'try' it in IO.
data AnthropicError
  = AnthropicHttpError    HttpException
  | AnthropicStatusError  Int Text
  | AnthropicNoContent    Text
  | AnthropicStreamTimeout Int  -- ^ no chunk within the idle window (microseconds)
  deriving (Show)

instance Exception AnthropicError

-- | Whether a failure is worth retrying: network/timeout errors and HTTP 429 /
-- 5xx are transient; other 4xx and a content-shape failure are permanent.
isRetryable :: AnthropicError -> Bool
isRetryable (AnthropicHttpError _)      = True
isRetryable (AnthropicStatusError s _)  = s == 429 || s >= 500
isRetryable (AnthropicNoContent _)      = False
isRetryable (AnthropicStreamTimeout _)  = False

-- | What the live interpreter needs: an API key, a model id, a token cap,
-- and knobs for timeout + retry behaviour.
data AnthropicConfig = AnthropicConfig
  { acApiKey          :: Text
  , acModel           :: Text
  , acMaxTokens       :: Int
  , acTimeoutSecs     :: Int  -- ^ request timeout in seconds
  , acMaxRetries      :: Int  -- ^ retries on transient failures
  , acBaseDelayMicros :: Int  -- ^ backoff base delay, microseconds
  , acStreamIdleSecs  :: Int  -- ^ mid-stream per-chunk idle timeout, seconds
  }
  deriving (Eq, Show)

-- | A config with sensible defaults (60s timeout, 3 retries, 0.5s backoff base);
-- supply the API key.
defaultAnthropicConfig :: Text -> AnthropicConfig
defaultAnthropicConfig key =
  AnthropicConfig
    { acApiKey = key
    , acModel = "claude-haiku-4-5-20251001"
    , acMaxTokens = 1024
    , acTimeoutSecs = 60
    , acMaxRetries = 3
    , acBaseDelayMicros = 500000
    , acStreamIdleSecs = 60
    }

-- | Upper bound on a single backoff delay (30s), so exponential growth is capped.
maxBackoffMicros :: Int
maxBackoffMicros = 30000000

-- | One TLS 'Manager' configured with the request timeout, shared across all
-- 'Complete's of a single interpreter invocation.
newAnthropicManager :: AnthropicConfig -> IO Manager
newAnthropicManager cfg =
  newManager
    tlsManagerSettings
      { managerResponseTimeout = responseTimeoutMicro (acTimeoutSecs cfg * 1000000) }

-- | Interpret @LLM@ against the live Anthropic Messages API. One shared TLS
-- manager is created up front; each 'Complete' is one @POST \/v1\/messages@ with
-- timeout + retry. Failures throw 'AnthropicError'.
runLLMAnthropic :: (IOE :> es) => AnthropicConfig -> Eff (LLM : es) a -> Eff es a
runLLMAnthropic cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret (\_ (Complete msgs) -> liftIO (anthropicComplete cfg mgr msgs)) action

-- | Like 'runLLMAnthropic', but also TEE each reply to a cassette file (one
-- JSON-encoded reply per line, appended in call order). A recorded cassette
-- replays deterministically via 'runLLMCassette' — the slider between a live
-- eval and a hermetic test.
recordLLMAnthropic :: (IOE :> es) => FilePath -> AnthropicConfig -> Eff (LLM : es) a -> Eff es a
recordLLMAnthropic path cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Complete msgs) -> liftIO $ do
        reply <- anthropicComplete cfg mgr msgs
        TIO.appendFile path (encode (JString reply) <> "\n")
        pure reply)
    action

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

-- | One chat round-trip, with usage: POST the conversation + tool specs, parse
-- the assistant 'Turn' (throwing 'AnthropicNoContent' if malformed), and read
-- the usage from the same body.
converseOnce :: AnthropicConfig -> Manager -> [(ToolName, Schema)] -> [ChatMsg] -> IO (Turn, Usage)
converseOnce cfg mgr specs msgs = do
  body <- postMessages cfg mgr (chatRequestJson cfg specs msgs)
  turn <- either (\_ -> throwIO (AnthropicNoContent body)) pure (parseTurn body)
  pure (turn, parseUsage body)

-- | Interpret 'Chat' against the live Anthropic Messages API with native
-- tool-calling. One shared TLS manager is created up front; each 'Converse'
-- POSTs the conversation + tool specs and parses the assistant's 'Turn'.
-- Failures throw 'AnthropicError'.
runChatAnthropic :: (IOE :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es a
runChatAnthropic cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Converse specs msgs) -> liftIO (fst <$> converseOnce cfg mgr specs msgs))
    action

-- | Like 'runChatAnthropic', but also TEE each assistant 'Turn' to a cassette
-- file (one content-JSON line, appended in call order). Replays via
-- 'runChatCassette'.
recordChatAnthropic :: (IOE :> es) => FilePath -> AnthropicConfig -> Eff (Chat : es) a -> Eff es a
recordChatAnthropic path cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Converse specs msgs) -> liftIO $ do
        (turn, _u) <- converseOnce cfg mgr specs msgs
        TIO.appendFile path (encode (turnContentJson turn) <> "\n")
        pure turn)
    action

-- | Replay a cassette recorded by 'recordChatAnthropic': each 'Converse' pops
-- the next recorded 'Turn' in order (a file-backed 'runChatScripted').
-- Deterministic; no network. Exhausting the cassette yields @Turn "" []@.
runChatCassette :: (IOE :> es) => FilePath -> Eff (Chat : es) a -> Eff es a
runChatCassette path action = do
  contents <- liftIO (TIO.readFile path)
  let turns =
        [ either (const (Turn "" [])) id (parseTurn ln)
        | ln <- T.lines contents
        , not (T.null ln)
        ]
  reinterpret (evalState turns) (\_ -> \case
    Converse _ _ -> do
      ts <- get
      case ts of
        (t : rest) -> put rest >> pure t
        []         -> pure (Turn "" []))
    action

-- | Like 'runLLMAnthropic', but sum the token usage across every 'Complete' and
-- return the total alongside the result. Additive opt-in; the underlying API
-- calls are identical to 'runLLMAnthropic'.
runLLMAnthropicUsage :: (IOE :> es) => AnthropicConfig -> Eff (LLM : es) a -> Eff es (a, Usage)
runLLMAnthropicUsage cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  reinterpret (runState mempty)
    (\_ (Complete msgs) -> do
        (text, u) <- liftIO (anthropicCompleteUsage cfg mgr msgs)
        modify (<> u)
        pure text)
    action

-- | Like 'runChatAnthropic', but sum the token usage across every 'Converse'
-- (e.g. each step of a 'runToolAgent' loop) and return the total alongside the
-- result. Additive opt-in.
runChatAnthropicUsage :: (IOE :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es (a, Usage)
runChatAnthropicUsage cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  reinterpret (runState mempty)
    (\_ (Converse specs msgs) -> do
        (turn, u) <- liftIO (converseOnce cfg mgr specs msgs)
        modify (<> u)
        pure turn)
    action

-- | Build the @POST \/v1\/messages@ request for a JSON body, with the shared
-- Anthropic headers. (The streaming path adds an @Accept@ header on top.)
messagesRequest :: AnthropicConfig -> Value -> IO Request
messagesRequest cfg bodyJson = do
  base <- parseRequest "https://api.anthropic.com/v1/messages"
  pure base
    { method = "POST"
    , requestHeaders =
        [ ("x-api-key", TE.encodeUtf8 (acApiKey cfg))
        , ("anthropic-version", "2023-06-01")
        , ("content-type", "application/json")
        ]
    , requestBody = RequestBodyLBS (LBS.fromStrict (TE.encodeUtf8 (encode bodyJson)))
    }

-- | Wrap an IO action in the shared retry policy: jittered exponential backoff
-- capped at 'maxBackoffMicros', up to 'acMaxRetries', retrying 'AnthropicError's
-- for which 'isRetryable' holds.
withAnthropicRetry :: AnthropicConfig -> IO a -> IO a
withAnthropicRetry cfg action =
  recovering
    (capDelay maxBackoffMicros (fullJitterBackoff (acBaseDelayMicros cfg))
       <> limitRetries (acMaxRetries cfg))
    [ \_ -> Handler (\(e :: AnthropicError) -> pure (isRetryable e)) ]
    (\_ -> action)

-- | POST a JSON request body to @/v1/messages@ and return the raw 2xx response
-- body, retrying transient failures (network/timeout, 429, 5xx) with jittered
-- exponential backoff up to 'acMaxRetries'. A non-2xx response throws
-- 'AnthropicStatusError'; a network/timeout failure throws 'AnthropicHttpError'.
-- Shared by the text completion and the chat interpreter.
postMessages :: AnthropicConfig -> Manager -> Value -> IO Text
postMessages cfg mgr bodyJson =
  withAnthropicRetry cfg $
    handle (\(e :: HttpException) -> throwIO (AnthropicHttpError e)) $ do
      req <- messagesRequest cfg bodyJson
      resp <- httpLbs req mgr
      let body = TE.decodeUtf8Lenient (LBS.toStrict (responseBody resp))
          code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then pure body
        else throwIO (AnthropicStatusError code body)

-- | One text round-trip, with usage: POST the messages, extract
-- @content[0].text@ (throwing 'AnthropicNoContent' if absent), and read the
-- usage from the same body.
anthropicCompleteUsage :: AnthropicConfig -> Manager -> [Message] -> IO (Text, Usage)
anthropicCompleteUsage cfg mgr msgs = do
  body <- postMessages cfg mgr (requestJson cfg msgs)
  text <- either (\_ -> throwIO (AnthropicNoContent body)) pure (extractText body)
  pure (text, parseUsage body)

-- | One text round-trip, discarding usage (the original behaviour).
anthropicComplete :: AnthropicConfig -> Manager -> [Message] -> IO Text
anthropicComplete cfg mgr msgs = fst <$> anthropicCompleteUsage cfg mgr msgs

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

-- | Build the @/v1/messages@ request body for a chat turn: the model + token
-- cap, the advertised @tools@ (each @{name, input_schema}@), and the
-- conversation @messages@ as content-block arrays.
chatRequestJson :: AnthropicConfig -> [(ToolName, Schema)] -> [ChatMsg] -> Value
chatRequestJson cfg specs msgs =
  JObject
    [ ("model", JString (acModel cfg))
    , ("max_tokens", JNumber (fromIntegral (acMaxTokens cfg)))
    , ("tools", JArray [ toolSpec n s | (n, s) <- specs ])
    , ("messages", JArray (map chatMsgJson msgs))
    ]
  where
    toolSpec n s = JObject [("name", JString n), ("input_schema", schemaToJson s)]

chatMsgJson :: ChatMsg -> Value
chatMsgJson (ChatMsg r blocks) =
  JObject [("role", JString (anthropicRole r)), ("content", JArray (map blockJson blocks))]

-- | Encode a 'Turn' to the Anthropic content shape (reusing 'blockJson'), for
-- recording to a chat cassette. Round-trips: @parseTurn (encode (turnContentJson t)) == Right t@.
turnContentJson :: Turn -> Value
turnContentJson (Turn t uses) =
  JObject [("content", JArray (map blockJson blocks))]
  where
    blocks = [TextBlock t | not (T.null t)] ++ map ToolUseBlock uses

blockJson :: Block -> Value
blockJson (TextBlock t) =
  JObject [("type", JString "text"), ("text", JString t)]
blockJson (ToolUseBlock (ToolUse i n a)) =
  JObject [("type", JString "tool_use"), ("id", JString i), ("name", JString n), ("input", a)]
blockJson (ToolResultBlock i v) =
  JObject
    [ ("type", JString "tool_result")
    , ("tool_use_id", JString i)
    , ("content", resultText v)
    ]
  where
    resultText (JString s) = JString s
    resultText other       = JString (encode other)

-- | Parse a @/v1/messages@ response body into a 'Turn': concatenated @text@
-- blocks, plus every @tool_use@ block.
parseTurn :: Text -> Either D.Error Turn
parseTurn = D.decodeString (D.field "content" (toTurn <$> D.list rblock))
  where
    toTurn bs = Turn (T.concat [t | RText t <- bs]) [u | RUse u <- bs]

data RBlock = RText Text | RUse ToolUse | RSkip

rblock :: D.Decoder RBlock
rblock = D.field "type" D.string >>= \ty -> case ty of
  "text"     -> RText <$> D.field "text" D.string
  "tool_use" ->
    (\i n inp -> RUse (ToolUse i n inp))
      <$> D.field "id" D.string
      <*> D.field "name" D.string
      <*> D.field "input" D.value
  _ -> D.succeed RSkip

-- | Read the @usage@ object from a @\/v1\/messages@ response body. A body without
-- a well-formed @usage@ yields 'mempty' — usage is telemetry, not correctness.
parseUsage :: Text -> Usage
parseUsage =
  either (const mempty) id
    . D.decodeString
        (D.field "usage"
          (Usage <$> D.field "input_tokens"  D.int
                 <*> D.field "output_tokens" D.int))
