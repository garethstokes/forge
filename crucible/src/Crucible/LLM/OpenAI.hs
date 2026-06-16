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

-- | The live OpenAI interpreter for the 'LLM' and 'Chat' effects.
--
-- Interpreters are named as short verbs meant to be used qualified:
-- @OpenAI.run@, @OpenAI.usage@, and their @Chat@ twins (@OpenAI.runChat@,
-- @OpenAI.usageChat@). The qualified grammar mirrors "Crucible.LLM.Anthropic";
-- swapping providers is a one-line change at the @runEff@ edge.
--
-- 'run' discharges @LLM@ by calling the OpenAI Chat Completions API over HTTPS
-- (@POST \/v1\/chat\/completions@) via @http-client-tls@.
--
-- Wire-format notes (where OpenAI differs from Anthropic):
--
--   * System messages are sent natively as @role: system@ turns (no hoisting).
--   * Tool arguments arrive as a JSON-encoded /string/ in
--     @tool_calls[].function.arguments@; 'parseTurn' decodes it to a 'Value'.
--   * Tool results are sent as separate @role: tool@ messages, one per
--     @tool_call_id@, not as content blocks inside a user turn.
--   * An assistant turn that requested tools must be replayed back with its
--     @tool_calls@ field intact; 'chatMessagesJson' re-encodes the arguments
--     'Value' to a string.
module Crucible.LLM.OpenAI
  ( OpenAIConfig (..)
  , defaultOpenAIConfig
  , newOpenAIManager
  , provider
  , OpenAIError (..)
  , isRetryable
  , requestJson
  , extractText
  , chatRequestJson
  , chatMessagesJson
  , parseTurn
  , parseUsage
  , run
  , runChat
  , usage
  , usageChat
  , record
  , replay
  , recordChat
  , replayChat
  , completionsRequest
  , withOpenAIRetry
  , runEmbed
  , embedRequestJson
  , extractEmbedding
  ) where

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
import Data.Aeson (Value (..), (.=), (.:), (.:?))
import qualified Data.Aeson.Types as AT
import qualified Data.Vector as V

import qualified Crucible.Chat as Chat
import Crucible.Chat (Block (..), Chat (..), ToolUse (..), Turn (..))
import Crucible.Embed (Embed (..))
import Crucible.LLM (LLM (..), Message (..), Role (..))
import Crucible.LLM.Provider (Provider (..))
import Crucible.Media (Media (..))
import Crucible.Tool (ToolName)
import Crucible.Usage (Usage (..))

-- | A typed live-path failure. Network/timeout errors are wrapped as
-- 'OpenAIHttpError'; a non-2xx response is 'OpenAIStatusError'; a 2xx body
-- without usable assistant content is 'OpenAINoContent'. Thrown by the live
-- interpreters; callers 'try' it in IO.
data OpenAIError
  = OpenAIHttpError   HttpException
  | OpenAIStatusError Int Text
  | OpenAINoContent   Text
  | OpenAIStreamTimeout Int  -- ^ no chunk within the idle window (microseconds)
  deriving (Show)

instance Exception OpenAIError

-- | Whether a failure is worth retrying: network/timeout errors and HTTP 429 /
-- 5xx are transient; other 4xx and a content-shape failure are permanent.
isRetryable :: OpenAIError -> Bool
isRetryable (OpenAIHttpError _)      = True
isRetryable (OpenAIStatusError s _)  = s == 429 || s >= 500
isRetryable (OpenAINoContent _)      = False
isRetryable (OpenAIStreamTimeout _)  = False

-- | What the live interpreter needs: an API key, a model id, a token cap,
-- and knobs for timeout + retry behaviour.
data OpenAIConfig = OpenAIConfig
  { apiKey          :: Text
  , model           :: Text
  , embedModel      :: Text  -- ^ model used for @\/v1\/embeddings@ calls
  , maxTokens       :: Int  -- ^ sent as @max_completion_tokens@
  , timeoutSecs     :: Int  -- ^ request timeout in seconds
  , maxRetries      :: Int  -- ^ retries on transient failures
  , baseDelayMicros :: Int  -- ^ backoff base delay, microseconds
  , streamIdleSecs  :: Int  -- ^ mid-stream per-chunk idle timeout, seconds
  }
  deriving (Eq, Show)

-- | A config with sensible defaults (60s timeout, 3 retries, 0.5s backoff base);
-- supply the API key.
defaultOpenAIConfig :: Text -> OpenAIConfig
defaultOpenAIConfig key =
  OpenAIConfig
    { apiKey = key
    , model = "gpt-4o-mini"
    , embedModel = "text-embedding-3-small"
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
-- calls of a single interpreter invocation.
newOpenAIManager :: OpenAIConfig -> IO Manager
newOpenAIManager cfg =
  newManager
    tlsManagerSettings
      { managerResponseTimeout = responseTimeoutMicro (cfg.timeoutSecs * 1000000) }

-- | Interpret @LLM@ against the live OpenAI Chat Completions API. One shared
-- TLS manager is created up front; each 'Complete' is one
-- @POST \/v1\/chat\/completions@ with timeout + retry. Failures throw
-- 'OpenAIError'. Use as @OpenAI.run@.
run :: (IOE :> es) => OpenAIConfig -> Eff (LLM : es) a -> Eff es a
run cfg action = do
  mgr <- liftIO (newOpenAIManager cfg)
  interpret (\_ (Complete msgs) -> liftIO (openaiComplete cfg mgr msgs)) action

-- | Like 'run', but sum the token usage across every 'Complete' and return the
-- total alongside the result. Use as @OpenAI.usage@.
usage :: (IOE :> es) => OpenAIConfig -> Eff (LLM : es) a -> Eff es (a, Usage)
usage cfg action = do
  mgr <- liftIO (newOpenAIManager cfg)
  reinterpret (runState mempty)
    (\_ (Complete msgs) -> do
        (txt, u) <- liftIO (openaiCompleteUsage cfg mgr msgs)
        modify (<> u)
        pure txt)
    action

-- | Interpret 'Chat' against the live OpenAI Chat Completions API with native
-- tool-calling. Failures throw 'OpenAIError'. Use as @OpenAI.runChat@.
runChat :: (IOE :> es) => OpenAIConfig -> Eff (Chat : es) a -> Eff es a
runChat cfg action = do
  mgr <- liftIO (newOpenAIManager cfg)
  interpret
    (\_ (Converse specs msgs) -> liftIO (fst <$> converseOnce cfg mgr specs msgs))
    action

-- | Like 'runChat', but sum the token usage across every 'Converse' (e.g. each
-- step of a 'Crucible.Chat.runToolAgent' loop) and return the total alongside
-- the result. Use as @OpenAI.usageChat@.
usageChat :: (IOE :> es) => OpenAIConfig -> Eff (Chat : es) a -> Eff es (a, Usage)
usageChat cfg action = do
  mgr <- liftIO (newOpenAIManager cfg)
  reinterpret (runState mempty)
    (\_ (Converse specs msgs) -> do
        (turn, u) <- liftIO (converseOnce cfg mgr specs msgs)
        modify (<> u)
        pure turn)
    action

-- | Like 'run', but also TEE each reply to a cassette file (one JSON-encoded
-- reply per line, appended in call order). Replays via 'replay'. The cassette
-- format is provider-neutral; a cassette recorded here also replays under
-- @Anthropic.replay@ and vice versa. Use as @OpenAI.record@.
record :: (IOE :> es) => FilePath -> OpenAIConfig -> Eff (LLM : es) a -> Eff es a
record path cfg action = do
  mgr <- liftIO (newOpenAIManager cfg)
  interpret
    (\_ (Complete msgs) -> liftIO $ do
        reply <- openaiComplete cfg mgr msgs
        TIO.appendFile path (encodeText (A.String reply) <> "\n")
        pure reply)
    action

-- | Replay a cassette recorded by 'record': each 'Complete' pops the next
-- recorded reply in order. Deterministic; no network. Exhausting the cassette
-- yields @""@. Use as @OpenAI.replay@.
replay :: (IOE :> es) => FilePath -> Eff (LLM : es) a -> Eff es a
replay path action = do
  contents <- liftIO (TIO.readFile path)
  let replies =
        [ either (const ln) Prelude.id $ do
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

-- | Like 'runChat', but also TEE each assistant 'Turn' to a cassette file
-- (one content-JSON line, in crucible's provider-neutral turn format).
-- Replays via 'replayChat'. Use as @OpenAI.recordChat@.
recordChat :: (IOE :> es) => FilePath -> OpenAIConfig -> Eff (Chat : es) a -> Eff es a
recordChat path cfg action = do
  mgr <- liftIO (newOpenAIManager cfg)
  interpret
    (\_ (Converse specs msgs) -> liftIO $ do
        (turn, _u) <- converseOnce cfg mgr specs msgs
        TIO.appendFile path (encodeText (Chat.turnContentJson turn) <> "\n")
        pure turn)
    action

-- | Replay a cassette recorded by 'recordChat' (or @Anthropic.recordChat@;
-- the format is shared): each 'Converse' pops the next recorded 'Turn'.
-- Deterministic; no network. Exhausting the cassette, or an unparseable line,
-- yields @Turn "" []@. Use as @OpenAI.replayChat@.
replayChat :: (IOE :> es) => FilePath -> Eff (Chat : es) a -> Eff es a
replayChat path action = do
  contents <- liftIO (TIO.readFile path)
  let turns =
        [ either (const (Turn "" [])) Prelude.id (Chat.parseTurn ln)
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

-- | One chat round-trip, with usage: POST the conversation + tool specs, parse
-- the assistant 'Turn' (throwing 'OpenAINoContent' if malformed), and read the
-- usage from the same body.
converseOnce :: OpenAIConfig -> Manager -> [(ToolName, Value)] -> [Chat.Message] -> IO (Turn, Usage)
converseOnce cfg mgr specs msgs = do
  body <- postCompletions cfg mgr (chatRequestJson cfg specs msgs)
  turn <- either (\_ -> throwIO (OpenAINoContent body)) pure (parseTurn body)
  pure (turn, parseUsage body)

-- | One text round-trip, with usage: POST the messages, extract
-- @choices[0].message.content@ (throwing 'OpenAINoContent' if absent), and
-- read the usage from the same body.
openaiCompleteUsage :: OpenAIConfig -> Manager -> [Message] -> IO (Text, Usage)
openaiCompleteUsage cfg mgr msgs = do
  body <- postCompletions cfg mgr (requestJson cfg msgs)
  txt <- either (\_ -> throwIO (OpenAINoContent body)) pure (extractText body)
  pure (txt, parseUsage body)

-- | One text round-trip, discarding usage.
openaiComplete :: OpenAIConfig -> Manager -> [Message] -> IO Text
openaiComplete cfg mgr msgs = fst <$> openaiCompleteUsage cfg mgr msgs

-- | Build the @POST \/v1\/chat\/completions@ request for a JSON body, with the
-- shared OpenAI headers.
completionsRequest :: OpenAIConfig -> Value -> IO Request
completionsRequest cfg bodyJson = do
  base <- parseRequest "https://api.openai.com/v1/chat/completions"
  pure base
    { method = "POST"
    , requestHeaders =
        [ ("authorization", "Bearer " <> TE.encodeUtf8 cfg.apiKey)
        , ("content-type", "application/json")
        ]
    , requestBody = RequestBodyLBS (A.encode bodyJson)
    }

-- | Wrap an IO action in the shared retry policy: jittered exponential backoff
-- capped at 'maxBackoffMicros', up to 'maxRetries', retrying 'OpenAIError's
-- for which 'isRetryable' holds.
withOpenAIRetry :: OpenAIConfig -> IO a -> IO a
withOpenAIRetry cfg action =
  recovering
    (capDelay maxBackoffMicros (fullJitterBackoff cfg.baseDelayMicros)
       <> limitRetries cfg.maxRetries)
    [ \_ -> Handler (\(e :: OpenAIError) -> pure (isRetryable e)) ]
    (\_ -> action)

-- | POST a JSON request body to @\/v1\/chat\/completions@ and return the raw
-- 2xx response body, retrying transient failures with jittered exponential
-- backoff up to 'maxRetries'. A non-2xx response throws 'OpenAIStatusError';
-- a network/timeout failure throws 'OpenAIHttpError'.
postCompletions :: OpenAIConfig -> Manager -> Value -> IO Text
postCompletions cfg mgr bodyJson =
  withOpenAIRetry cfg $
    handle (\(e :: HttpException) -> throwIO (OpenAIHttpError e)) $ do
      req <- completionsRequest cfg bodyJson
      resp <- httpLbs req mgr
      let body = TE.decodeUtf8Lenient (LBS.toStrict (responseBody resp))
          code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then pure body
        else throwIO (OpenAIStatusError code body)

-- | The Chat Completions request body for the text path. Every 'Message' maps
-- to one wire message; OpenAI accepts system turns natively.
requestJson :: OpenAIConfig -> [Message] -> Value
requestJson cfg msgs =
  A.object
    [ "model" .= cfg.model
    , "max_completion_tokens" .= cfg.maxTokens
    , "messages" .= A.Array (V.fromList [turn m | m <- msgs])
    ]
  where
    turn (Message r c) = A.object ["role" .= openaiRole r, "content" .= c]

-- | Map a 'Role' to a Chat Completions role. A flat-text 'Tool' message is
-- sent as a user turn (the @tool@ role requires a @tool_call_id@, which the
-- text path does not carry).
openaiRole :: Role -> Text
openaiRole = \case
  System    -> "system"
  Assistant -> "assistant"
  _         -> "user"

-- | Pull @choices[0].message.content@ out of a Chat Completions response.
extractText :: Text -> Either String Text
extractText t = do
  v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 t))
  AT.parseEither
    (A.withObject "resp" $ \o -> do
        choices <- o .: "choices"
        case choices of
          (x : _) -> A.withObject "choice"
            (\c -> c .: "message" >>= A.withObject "message" (.: "content")) x
          []      -> fail "empty choices array")
    v

-- | Build the @\/v1\/chat\/completions@ request body for a chat turn: the
-- model + token cap, the advertised @tools@ (each wrapped as
-- @{type: function, function: {name, parameters}}@), and the flattened
-- conversation messages.
chatRequestJson :: OpenAIConfig -> [(ToolName, Value)] -> [Chat.Message] -> Value
chatRequestJson cfg specs msgs =
  A.object
    [ "model" .= cfg.model
    , "max_completion_tokens" .= cfg.maxTokens
    , "tools" .= A.Array (V.fromList [ toolSpec n s | (n, s) <- specs ])
    , "messages" .= A.Array (V.fromList (concatMap chatMessagesJson msgs))
    ]
  where
    toolSpec n s =
      A.object
        [ "type" .= A.String "function"
        , "function" .= A.object ["name" .= A.String n, "parameters" .= s]
        ]

-- | Flatten one block-based 'Chat.Message' into Chat Completions wire
-- messages. An assistant turn becomes a single message carrying its text and
-- any @tool_calls@ (arguments re-encoded as a JSON string). A user turn's tool
-- results each become their own @role: tool@ message (emitted first, so they
-- directly follow the assistant's @tool_calls@), and its text, if any, becomes
-- a @role: user@ message.
chatMessagesJson :: Chat.Message -> [Value]
chatMessagesJson (Chat.Message Assistant blocks) =
  [ A.object $
      [ "role" .= A.String "assistant"
      , "content" .= contentValue
      ]
        ++ [ "tool_calls" .= A.Array (V.fromList (map toolCallJson uses))
           | not (null uses)
           ]
  ]
  where
    txt  = T.concat [s | TextBlock s <- blocks]
    uses = [u | ToolUseBlock u <- blocks]
    contentValue = if T.null txt then A.Null else A.String txt
    toolCallJson u =
      A.object
        [ "id" .= u.id
        , "type" .= A.String "function"
        , "function" .= A.object ["name" .= u.name, "arguments" .= encodeText u.args]
        ]
chatMessagesJson (Chat.Message r blocks) =
  [ A.object
      [ "role" .= A.String "tool"
      , "tool_call_id" .= i
      , "content" .= resultText v
      ]
  | ToolResultBlock i v <- blocks
  ]
    ++ userMsgs
  where
    resultText (String s) = A.String s
    resultText other      = A.String (encodeText other)

    txt    = T.concat [s | TextBlock s <- blocks]
    images = [m | ImageBlock m <- blocks]
    docs   = [m | DocumentBlock m <- blocks]

    userMsgs
      | not (null images && null docs) =
          [ A.object ["role" .= openaiRole r, "content" .= A.Array (V.fromList parts)] ]
      | not (T.null txt) =
          [ A.object ["role" .= openaiRole r, "content" .= txt] ]
      | otherwise = []

    parts =
      [ A.object ["type" .= A.String "text", "text" .= txt] | not (T.null txt) ]
        ++ [ imagePart m | m <- images ]
        ++ [ docPart m   | m <- docs ]

    imagePart m =
      A.object
        [ "type" .= A.String "image_url"
        , "image_url" .= A.object ["url" .= dataUri m]
        ]
    docPart m =
      A.object
        [ "type" .= A.String "file"
        , "file" .= A.object
            [ "filename" .= maybe "document.pdf" Prelude.id m.filename
            , "file_data" .= dataUri m
            ]
        ]
    dataUri m = "data:" <> m.mediaType <> ";base64," <> m.dataB64

-- | Encode a 'Value' to compact JSON text (OpenAI's @arguments@ and tool
-- result contents are strings on the wire).
encodeText :: Value -> Text
encodeText = TE.decodeUtf8 . LBS.toStrict . A.encode

-- | Parse a Chat Completions response body into a 'Turn': the assistant
-- message's @content@ (absent or @null@ maps to @""@), plus every entry of
-- @tool_calls@. Each call's @function.arguments@ string is decoded to a
-- 'Value'; an undecodable arguments string is passed through as a JSON string
-- so the tool sees the raw text.
parseTurn :: Text -> Either String Turn
parseTurn t = do
  v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 t))
  AT.parseEither
    (A.withObject "resp" $ \o -> do
        choices <- o .: "choices"
        msg <- case choices of
          (x : _) -> A.withObject "choice" (.: "message") x
          []      -> fail "empty choices array"
        flip (A.withObject "message") msg $ \m -> do
          mtext <- m .:? "content"
          mcalls <- m .:? "tool_calls"
          uses <- mapM parseCall (maybe [] V.toList mcalls)
          pure (Turn (maybe "" txtOrEmpty mtext) uses))
    v
  where
    txtOrEmpty A.Null       = ""
    txtOrEmpty (A.String s) = s
    txtOrEmpty _            = ""

    parseCall = A.withObject "tool_call" $ \c -> do
      i <- c .: "id"
      fn <- c .: "function"
      flip (A.withObject "function") fn $ \f -> do
        n <- f .: "name"
        rawArgs <- f .: "arguments" :: AT.Parser Text
        let argsVal =
              either (const (A.String rawArgs)) Prelude.id
                (A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 rawArgs)))
        pure (ToolUse i n argsVal)

-- | Read the @usage@ object from a Chat Completions response body
-- (@prompt_tokens@ \/ @completion_tokens@). A body without a well-formed
-- @usage@ yields 'mempty'; usage is telemetry, not correctness.
parseUsage :: Text -> Usage
parseUsage t = either (const mempty) Prelude.id $ do
  v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 t))
  AT.parseEither
    (A.withObject "resp" $ \o -> do
        u <- o .: "usage"
        Usage <$> u .: "prompt_tokens" <*> u .: "completion_tokens")
    v

-- | Package this provider for 'Crucible.LLM.Fallback' chains: one shared
-- TLS manager, per-call functions carrying the full retry policy.
provider :: OpenAIConfig -> IO Provider
provider cfg = do
  mgr <- newOpenAIManager cfg
  pure Provider
    { name     = "openai"
    , model    = cfg.model
    , complete = openaiCompleteUsage cfg mgr
    , converse = converseOnce cfg mgr
    }

-- | The embeddings request body: the configured embedding model and one
-- input text.
embedRequestJson :: OpenAIConfig -> Text -> Value
embedRequestJson cfg input =
  A.object ["model" .= cfg.embedModel, "input" .= input]

-- | Pull @data[0].embedding@ out of an embeddings response.
extractEmbedding :: Text -> Either String [Double]
extractEmbedding t = do
  v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 t))
  AT.parseEither
    (A.withObject "resp" $ \o -> do
        ds <- o .: "data"
        case ds of
          (x : _) -> A.withObject "datum" (.: "embedding") x
          []      -> fail "empty data array")
    v

-- | POST a JSON body to @\/v1\/embeddings@ with the shared headers and
-- retry policy (mirrors 'postCompletions').
postEmbeddings :: OpenAIConfig -> Manager -> Value -> IO Text
postEmbeddings cfg mgr bodyJson =
  withOpenAIRetry cfg $
    handle (\(e :: HttpException) -> throwIO (OpenAIHttpError e)) $ do
      base <- parseRequest "https://api.openai.com/v1/embeddings"
      let req = base
            { method = "POST"
            , requestHeaders =
                [ ("authorization", "Bearer " <> TE.encodeUtf8 cfg.apiKey)
                , ("content-type", "application/json")
                ]
            , requestBody = RequestBodyLBS (A.encode bodyJson)
            }
      resp <- httpLbs req mgr
      let body = TE.decodeUtf8Lenient (LBS.toStrict (responseBody resp))
          code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then pure body
        else throwIO (OpenAIStatusError code body)

-- | Interpret 'Embed' against the live OpenAI embeddings API. One shared
-- TLS manager; each 'EmbedText' is one @POST \/v1\/embeddings@ with
-- timeout + retry. Failures throw 'OpenAIError'. Use as @OpenAI.runEmbed@.
runEmbed :: (IOE :> es) => OpenAIConfig -> Eff (Embed : es) a -> Eff es a
runEmbed cfg action = do
  mgr <- liftIO (newOpenAIManager cfg)
  interpret
    (\_ (EmbedText t) -> liftIO $ do
        body <- postEmbeddings cfg mgr (embedRequestJson cfg t)
        either (\_ -> throwIO (OpenAINoContent body)) pure (extractEmbedding body))
    action
