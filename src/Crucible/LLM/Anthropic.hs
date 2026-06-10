{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- | The live Anthropic interpreter for the 'LLM' effect (M8).
--
-- Interpreters are named as short verbs meant to be used qualified:
-- @Anthropic.run@, @Anthropic.usage@, @Anthropic.record@, @Anthropic.replay@,
-- and their @Chat@ twins (@Anthropic.runChat@, @Anthropic.usageChat@,
-- @Anthropic.recordChat@, @Anthropic.replayChat@).
--
-- 'run' discharges @LLM@ by calling the real Anthropic Messages API over HTTPS
-- (@POST \/v1\/messages@) via @http-client-tls@. It is the @IOE@-grounded
-- counterpart to the pure @runLLMScripted@: the control loop's
-- @(LLM :> es, Tools :> es)@ type is unchanged; only the interpreter at the
-- edge differs.
--
-- Request/response JSON is built and read with aeson. System messages are
-- hoisted to the top-level @system@ field; the rest map to the API's
-- user\/assistant turns.
module Crucible.LLM.Anthropic
  ( AnthropicConfig (..)
  , defaultAnthropicConfig
  , newAnthropicManager
  , requestJson
  , run
  , record
  , replay
  , AnthropicError (..)
  , isRetryable
  , chatRequestJson
  , turnContentJson
  , parseTurn
  , parseUsage
  , runChat
  , recordChat
  , replayChat
  , usage
  , usageChat
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

import qualified Data.Aeson as A
import Data.Aeson (Value (..), (.=), (.:))
import qualified Data.Aeson.Types as AT
import qualified Data.Vector as V

import qualified Crucible.Chat as Chat
import Crucible.Chat (Block (..), Chat (..), ToolUse (..), Turn (..))
import Crucible.LLM (LLM (..), Message (..), Role (..))
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
  { apiKey          :: Text
  , model           :: Text
  , maxTokens       :: Int
  , timeoutSecs     :: Int  -- ^ request timeout in seconds
  , maxRetries      :: Int  -- ^ retries on transient failures
  , baseDelayMicros :: Int  -- ^ backoff base delay, microseconds
  , streamIdleSecs  :: Int  -- ^ mid-stream per-chunk idle timeout, seconds
  }
  deriving (Eq, Show)

-- | A config with sensible defaults (60s timeout, 3 retries, 0.5s backoff base);
-- supply the API key.
defaultAnthropicConfig :: Text -> AnthropicConfig
defaultAnthropicConfig key =
  AnthropicConfig
    { apiKey = key
    , model = "claude-haiku-4-5-20251001"
    , maxTokens = 1024
    , timeoutSecs = 60
    , maxRetries = 3
    , baseDelayMicros = 500000
    , streamIdleSecs = 60
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
      { managerResponseTimeout = responseTimeoutMicro (cfg.timeoutSecs * 1000000) }

-- | Interpret @LLM@ against the live Anthropic Messages API. One shared TLS
-- manager is created up front; each 'Complete' is one @POST \/v1\/messages@ with
-- timeout + retry. Failures throw 'AnthropicError'.
-- Use as @Anthropic.run@.
run :: (IOE :> es) => AnthropicConfig -> Eff (LLM : es) a -> Eff es a
run cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret (\_ (Complete msgs) -> liftIO (anthropicComplete cfg mgr msgs)) action

-- | Like 'run', but also TEE each reply to a cassette file (one
-- JSON-encoded reply per line, appended in call order). A recorded cassette
-- replays deterministically via 'replay' — the slider between a live
-- eval and a hermetic test. Use as @Anthropic.record@.
record :: (IOE :> es) => FilePath -> AnthropicConfig -> Eff (LLM : es) a -> Eff es a
record path cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Complete msgs) -> liftIO $ do
        reply <- anthropicComplete cfg mgr msgs
        TIO.appendFile path (TE.decodeUtf8 (LBS.toStrict (A.encode (A.String reply))) <> "\n")
        pure reply)
    action

-- | Replay a cassette recorded by 'record': each 'Complete' pops the
-- next recorded reply in order (a file-backed 'runLLMScripted'). Deterministic;
-- no network. Exhausting the cassette yields @""@. Use as @Anthropic.replay@.
replay :: (IOE :> es) => FilePath -> Eff (LLM : es) a -> Eff es a
replay path action = do
  contents <- liftIO (TIO.readFile path)
  let replies =
        [ either (const ln) id $ do
            v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 ln))
            AT.parseEither A.parseJSON v
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
converseOnce :: AnthropicConfig -> Manager -> [(ToolName, Value)] -> [Chat.Message] -> IO (Turn, Usage)
converseOnce cfg mgr specs msgs = do
  body <- postMessages cfg mgr (chatRequestJson cfg specs msgs)
  turn <- either (\_ -> throwIO (AnthropicNoContent body)) pure (parseTurn body)
  pure (turn, parseUsage body)

-- | Interpret 'Chat' against the live Anthropic Messages API with native
-- tool-calling. One shared TLS manager is created up front; each 'Converse'
-- POSTs the conversation + tool specs and parses the assistant's 'Turn'.
-- Failures throw 'AnthropicError'. Use as @Anthropic.runChat@.
runChat :: (IOE :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es a
runChat cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Converse specs msgs) -> liftIO (fst <$> converseOnce cfg mgr specs msgs))
    action

-- | Like 'runChat', but also TEE each assistant 'Turn' to a cassette
-- file (one content-JSON line, appended in call order). Replays via
-- 'replayChat'. Use as @Anthropic.recordChat@.
recordChat :: (IOE :> es) => FilePath -> AnthropicConfig -> Eff (Chat : es) a -> Eff es a
recordChat path cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Converse specs msgs) -> liftIO $ do
        (turn, _u) <- converseOnce cfg mgr specs msgs
        TIO.appendFile path (TE.decodeUtf8 (LBS.toStrict (A.encode (turnContentJson turn))) <> "\n")
        pure turn)
    action

-- | Replay a cassette recorded by 'recordChat': each 'Converse' pops
-- the next recorded 'Turn' in order (a file-backed 'runChatScripted').
-- Deterministic; no network. Exhausting the cassette, or an unparseable line,
-- yields @Turn "" []@. Use as @Anthropic.replayChat@.
replayChat :: (IOE :> es) => FilePath -> Eff (Chat : es) a -> Eff es a
replayChat path action = do
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

-- | Like 'run', but sum the token usage across every 'Complete' and
-- return the total alongside the result. Additive opt-in; the underlying API
-- calls are identical to 'run'. Use as @Anthropic.usage@.
usage :: (IOE :> es) => AnthropicConfig -> Eff (LLM : es) a -> Eff es (a, Usage)
usage cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  reinterpret (runState mempty)
    (\_ (Complete msgs) -> do
        (text, u) <- liftIO (anthropicCompleteUsage cfg mgr msgs)
        modify (<> u)
        pure text)
    action

-- | Like 'runChat', but sum the token usage across every 'Converse'
-- (e.g. each step of a 'runToolAgent' loop) and return the total alongside the
-- result. Additive opt-in. Use as @Anthropic.usageChat@.
usageChat :: (IOE :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es (a, Usage)
usageChat cfg action = do
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
        [ ("x-api-key", TE.encodeUtf8 cfg.apiKey)
        , ("anthropic-version", "2023-06-01")
        , ("content-type", "application/json")
        ]
    , requestBody = RequestBodyLBS (A.encode bodyJson)
    }

-- | Wrap an IO action in the shared retry policy: jittered exponential backoff
-- capped at 'maxBackoffMicros', up to 'maxRetries', retrying 'AnthropicError's
-- for which 'isRetryable' holds.
withAnthropicRetry :: AnthropicConfig -> IO a -> IO a
withAnthropicRetry cfg action =
  recovering
    (capDelay maxBackoffMicros (fullJitterBackoff cfg.baseDelayMicros)
       <> limitRetries cfg.maxRetries)
    [ \_ -> Handler (\(e :: AnthropicError) -> pure (isRetryable e)) ]
    (\_ -> action)

-- | POST a JSON request body to @/v1/messages@ and return the raw 2xx response
-- body, retrying transient failures (network/timeout, 429, 5xx) with jittered
-- exponential backoff up to 'maxRetries'. A non-2xx response throws
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
  txt <- either (\_ -> throwIO (AnthropicNoContent body)) pure (extractText body)
  pure (txt, parseUsage body)

-- | One text round-trip, discarding usage (the original behaviour).
anthropicComplete :: AnthropicConfig -> Manager -> [Message] -> IO Text
anthropicComplete cfg mgr msgs = fst <$> anthropicCompleteUsage cfg mgr msgs

-- | The Anthropic request body. System turns are concatenated into the
-- top-level @system@ field; the remaining turns become the @messages@ array.
requestJson :: AnthropicConfig -> [Message] -> Value
requestJson cfg msgs =
  A.object $
    [ "model" .= cfg.model
    , "max_tokens" .= cfg.maxTokens
    ]
      ++ systemField
      ++ [ "messages" .= A.Array (V.fromList [turn m | m <- conversation]) ]
  where
    (systems, conversation) = partition ((== System) . role) msgs
    systemField = case systems of
      [] -> []
      _  -> ["system" .= T.intercalate "\n\n" (map content systems)]
    turn (Message r c) =
      A.object ["role" .= anthropicRole r, "content" .= c]

-- | Map a 'Role' to an Anthropic message role. System is handled separately; a
-- Tool result is sent as a user turn (the API has no distinct tool role here).
anthropicRole :: Role -> Text
anthropicRole = \case
  Assistant -> "assistant"
  _         -> "user"

-- | Pull @content[0].text@ out of a Messages API response.
extractText :: Text -> Either String Text
extractText t = do
  v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 t))
  AT.parseEither
    (A.withObject "resp" $ \o -> do
        arr <- o .: "content"
        case arr of
          (x : _) -> A.withObject "block" (.: "text") x
          []      -> fail "empty content array")
    v

-- | Build the @/v1/messages@ request body for a chat turn: the model + token
-- cap, the advertised @tools@ (each @{name, input_schema}@), and the
-- conversation @messages@ as content-block arrays.
chatRequestJson :: AnthropicConfig -> [(ToolName, Value)] -> [Chat.Message] -> Value
chatRequestJson cfg specs msgs =
  A.object
    [ "model" .= cfg.model
    , "max_tokens" .= cfg.maxTokens
    , "tools" .= A.Array (V.fromList [ toolSpec n s | (n, s) <- specs ])
    , "messages" .= A.Array (V.fromList (map chatMsgJson msgs))
    ]
  where
    toolSpec n s = A.object ["name" .= A.String n, "input_schema" .= s]

chatMsgJson :: Chat.Message -> Value
chatMsgJson (Chat.Message r blocks) =
  A.object ["role" .= anthropicRole r, "content" .= A.Array (V.fromList (map blockJson blocks))]

-- | Encode a 'Turn' to the Anthropic content shape (reusing 'blockJson'), for
-- recording to a chat cassette. Round-trips: @parseTurn (encode (turnContentJson t)) == Right t@.
turnContentJson :: Turn -> Value
turnContentJson (Turn t uses) =
  A.object ["content" .= A.Array (V.fromList (map blockJson blocks))]
  where
    blocks = [TextBlock t | not (T.null t)] ++ map ToolUseBlock uses

blockJson :: Block -> Value
blockJson (TextBlock t) =
  A.object ["type" .= A.String "text", "text" .= t]
blockJson (ToolUseBlock (ToolUse i n a)) =
  A.object ["type" .= A.String "tool_use", "id" .= i, "name" .= n, "input" .= a]
blockJson (ToolResultBlock i v) =
  A.object
    [ "type" .= A.String "tool_result"
    , "tool_use_id" .= i
    , "content" .= resultText v
    ]
  where
    resultText (String s) = A.String s
    resultText other      = A.String (TE.decodeUtf8 (LBS.toStrict (A.encode other)))

-- | Parse a @/v1/messages@ response body into a 'Turn': concatenated @text@
-- blocks, plus every @tool_use@ block.
parseTurn :: Text -> Either String Turn
parseTurn t = do
  v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 t))
  AT.parseEither
    (A.withObject "resp" $ \o -> do
        blocks <- o .: "content"
        rbs    <- mapM parseRBlock blocks
        pure (Turn (T.concat [tx | RText tx <- rbs]) [u | RUse u <- rbs]))
    v

data RBlock = RText Text | RUse ToolUse | RSkip

parseRBlock :: Value -> AT.Parser RBlock
parseRBlock = A.withObject "block" $ \o -> do
  ty <- o .: "type" :: AT.Parser Text
  case ty of
    "text"     -> RText <$> o .: "text"
    "tool_use" -> do
      i   <- o .: "id"
      n   <- o .: "name"
      inp <- o .: "input"
      pure (RUse (ToolUse i n inp))
    _ -> pure RSkip

-- | Read the @usage@ object from a @\/v1\/messages@ response body. A body without
-- a well-formed @usage@ yields 'mempty' — usage is telemetry, not correctness.
parseUsage :: Text -> Usage
parseUsage t = either (const mempty) id $ do
  v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 t))
  AT.parseEither
    (A.withObject "resp" $ \o -> do
        u <- o .: "usage"
        Usage <$> u .: "input_tokens" <*> u .: "output_tokens")
    v
