{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE GADTs              #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators      #-}

-- | SSE streaming for the live Anthropic path: a pure event core
-- ('splitFrames' / 'parseEvent' / 'stepAcc') plus thin streaming interpreters.
module Crucible.LLM.Anthropic.Stream
  ( splitFrames
  , StreamEvent (..)
  , parseEvent
  , StreamAcc (..)
  , PartialTool (..)
  , emptyAcc
  , stepAcc
  , runLLMAnthropicStream
  , runChatAnthropicStream
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Data.Maybe (fromMaybe)
import Data.Word (Word8)
import qualified Data.ByteString.Lazy as LBS

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.Exception (bracket)
import Effectful.State.Static.Local (modify, runState)

import Control.Exception (handle, throwIO)
import Control.Monad.Catch (Handler (Handler))
import Control.Retry (capDelay, fullJitterBackoff, limitRetries, recovering)
import Network.HTTP.Client
  ( BodyReader, HttpException, Manager, RequestBody (RequestBodyLBS), Response
  , brRead, method, parseRequest, requestBody, requestHeaders, responseBody
  , responseClose, responseOpen, responseStatus )
import Network.HTTP.Types.Status (statusCode)

import Crucible.Chat (Chat (..), ToolUse (..), ToolUseId, Turn (..))
import Crucible.Emit (Emit, emit)
import Crucible.Json.Decode (Decoder, at, decodeValue, field, int, string)
import Crucible.Json.Encode (encode)
import Crucible.Json.Parse (parse)
import Crucible.Json.Value (Value (JBool, JObject))
import Crucible.LLM (LLM (..))
import Crucible.LLM.Anthropic
  ( AnthropicConfig (..), AnthropicError (..), chatRequestJson, isRetryable
  , newAnthropicManager, requestJson )
import Crucible.Tool (ToolName)
import Crucible.Usage (Usage (..))

-- | Split complete SSE frames (blank-line @\\n\\n@-delimited) off the buffer,
-- returning the frames and the unconsumed remainder. With no blank line yet the
-- whole buffer is the remainder. Empty frames (e.g. from a trailing @\\n\\n@,
-- which every well-formed SSE body has) are omitted, so returned frames are
-- always non-empty. (Anthropic SSE uses bare LF; CRLF is not normalised.)
splitFrames :: ByteString -> ([ByteString], ByteString)
splitFrames = go []
  where
    go acc buf =
      let (before, rest) = BS.breakSubstring "\n\n" buf
      in if BS.null rest
           then (reverse acc, buf)
           else if BS.null before
                  then go acc (BS.drop 2 rest)
                  else go (before : acc) (BS.drop 2 rest)

-- | A single parsed SSE event, reduced to what the accumulator needs.
data StreamEvent
  = EvText      Text                    -- text_delta
  | EvToolStart Int ToolUseId ToolName  -- tool_use block opened at index
  | EvToolJson  Int Text                -- input_json_delta fragment for index
  | EvBlockStop Int
  | EvUsageIn   Int
  | EvUsageOut  Int
  | EvOther
  deriving (Eq, Show)

-- | Parse one frame's @data:@ payload into a 'StreamEvent'. A frame with no
-- usable @data:@ JSON, or an unrecognised shape, is 'EvOther'.
parseEvent :: ByteString -> StreamEvent
parseEvent frame = case dataPayload frame of
  Nothing  -> EvOther
  Just txt -> case parse txt of
    Left _  -> EvOther
    Right v -> classify v

-- | Extract the (stripped, UTF-8-decoded) text after the first @data:@ line.
dataPayload :: ByteString -> Maybe Text
dataPayload frame = case filter ("data:" `BS.isPrefixOf`) (BC.lines frame) of
  (ln : _) -> Just (T.strip (TE.decodeUtf8Lenient (BS.drop 5 ln)))
  []       -> Nothing

classify :: Value -> StreamEvent
classify v = case dv (field "type" string) of
  Just "content_block_delta" -> case dv (at ["delta", "type"] string) of
    Just "text_delta"       -> maybe EvOther EvText            (dv (at ["delta", "text"] string))
    Just "input_json_delta" -> maybe EvOther (EvToolJson idx)  (dv (at ["delta", "partial_json"] string))
    _                       -> EvOther
  Just "content_block_start" -> case dv (at ["content_block", "type"] string) of
    Just "tool_use" -> case ( dv (at ["content_block", "id"] string)
                            , dv (at ["content_block", "name"] string) ) of
      (Just i, Just n) -> EvToolStart idx i n
      _                -> EvOther
    _ -> EvOther
  Just "content_block_stop" -> maybe EvOther EvBlockStop (dv (field "index" int))
  Just "message_start"      -> maybe EvOther EvUsageIn   (dv (at ["message", "usage", "input_tokens"] int))
  Just "message_delta"      -> maybe EvOther EvUsageOut  (dv (at ["usage", "output_tokens"] int))
  _                         -> EvOther
  where
    idx = fromMaybe 0 (dv (field "index" int))
    dv :: Decoder a -> Maybe a
    dv d = either (const Nothing) Just (decodeValue d v)

-- | An in-progress tool_use block: id, name, and accumulated argument JSON.
data PartialTool = PartialTool ToolUseId ToolName Text
  deriving (Eq, Show)

-- | Running accumulation across one streamed response.
data StreamAcc = StreamAcc
  { saText    :: Text                 -- concatenated text deltas
  , saPartial :: [(Int, PartialTool)] -- in-progress tool_use blocks, by index
  , saTools   :: [ToolUse]            -- completed tool_uses, in completion order
  , saUsage   :: Usage
  }
  deriving (Eq, Show)

emptyAcc :: StreamAcc
emptyAcc = StreamAcc "" [] [] mempty

-- | Fold one event into the accumulator (and the IO loop 'emit's text deltas).
stepAcc :: StreamAcc -> StreamEvent -> StreamAcc
stepAcc acc = \case
  EvText t            -> acc { saText = saText acc <> t }
  EvToolStart i tid n -> acc { saPartial = (i, PartialTool tid n "") : saPartial acc }
  EvToolJson i frag   -> acc { saPartial = map (bump i frag) (saPartial acc) }
  EvBlockStop i       -> case lookup i (saPartial acc) of
    Nothing                       -> acc  -- non-tool block stop (e.g. text); ignore
    Just (PartialTool tid n js) -> acc
      { saPartial = filter ((/= i) . fst) (saPartial acc)
      , saTools   = saTools acc ++ [ToolUse tid n (parseArgs js)]
      }
  EvUsageIn n  -> acc { saUsage = (saUsage acc) { usInputTokens  = n } }
  EvUsageOut n -> acc { saUsage = (saUsage acc) { usOutputTokens = n } }
  EvOther      -> acc
  where
    bump i frag (j, pt@(PartialTool tid n js))
      | i == j    = (j, PartialTool tid n (js <> frag))
      | otherwise = (j, pt)
    parseArgs js = either (const (JObject [])) id (parse js)

-- | Upper bound on a single backoff delay (30s). Mirrors the constant in
-- "Crucible.LLM.Anthropic"; kept local so this module is self-contained.
maxBackoffMicros :: Int
maxBackoffMicros = 30000000

-- | Add @"stream": true@ to a request body object.
addStream :: Value -> Value
addStream (JObject kvs) = JObject (kvs ++ [("stream", JBool True)])
addStream v             = v

-- | Open a @stream:true@ POST, retrying transient PRE-stream failures
-- (network/timeout, 429, 5xx) with the same policy as the non-streaming path.
-- Returns the live 2xx response (the caller streams and closes it); a non-2xx
-- response is drained, closed, and thrown as a retryable 'AnthropicStatusError'.
-- Nothing is emitted before this returns, so retrying is safe.
openStream :: AnthropicConfig -> Manager -> Value -> IO (Response BodyReader)
openStream cfg mgr bodyJson =
  recovering
    (capDelay maxBackoffMicros (fullJitterBackoff (acBaseDelayMicros cfg))
       <> limitRetries (acMaxRetries cfg))
    [ \_ -> Handler (\(e :: AnthropicError) -> pure (isRetryable e)) ]
    (\_ -> doOpen)
  where
    doOpen = handle (\(e :: HttpException) -> throwIO (AnthropicHttpError e)) $ do
      base <- parseRequest "https://api.anthropic.com/v1/messages"
      let req = base
            { method = "POST"
            , requestHeaders =
                [ ("x-api-key", TE.encodeUtf8 (acApiKey cfg))
                , ("anthropic-version", "2023-06-01")
                , ("content-type", "application/json")
                , ("accept", "text/event-stream")
                ]
            , requestBody = RequestBodyLBS (LBS.fromStrict (TE.encodeUtf8 (encode bodyJson)))
            }
      resp <- responseOpen req mgr
      let code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then pure resp
        else do
          errBody <- drainBody (responseBody resp)
          responseClose resp
          throwIO (AnthropicStatusError code (TE.decodeUtf8Lenient errBody))

-- | Read a BodyReader to exhaustion into one strict ByteString.
drainBody :: BodyReader -> IO ByteString
drainBody br = go []
  where
    go acc = do
      chunk <- brRead br
      if BS.null chunk then pure (BS.concat (reverse acc)) else go (chunk : acc)

-- | Stream an open response: read chunks, split frames, 'emit' text deltas live,
-- and fold the whole stream into a 'StreamAcc'.
streamLoop :: (IOE :> es, Emit :> es) => Response BodyReader -> Eff es StreamAcc
streamLoop resp = go emptyAcc BS.empty
  where
    br = responseBody resp
    go acc buf = do
      chunk <- liftIO (brRead br)
      if BS.null chunk
        then if BS.all isWs buf then pure acc else emitFrames acc [buf]
        else do
          let (frames, rest) = splitFrames (buf <> chunk)
          acc' <- emitFrames acc frames
          go acc' rest
    emitFrames acc []       = pure acc
    emitFrames acc (f : fs) = do
      let ev = parseEvent f
      case ev of
        EvText t -> emit t
        _        -> pure ()
      emitFrames (stepAcc acc ev) fs
    isWs :: Word8 -> Bool
    isWs c = c == 32 || c == 10 || c == 13 || c == 9

-- | Stream the text path: interpret 'LLM' against Anthropic SSE, 'emit'ting each
-- text delta and returning the assembled reply plus summed 'Usage'.
runLLMAnthropicStream
  :: (IOE :> es, Emit :> es)
  => AnthropicConfig -> Eff (LLM : es) a -> Eff es (a, Usage)
runLLMAnthropicStream cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  reinterpret (runState mempty)
    (\_ (Complete msgs) -> do
        acc <- bracket
                 (liftIO (openStream cfg mgr (addStream (requestJson cfg msgs))))
                 (liftIO . responseClose)
                 streamLoop
        modify (<> saUsage acc)
        pure (saText acc))
    action

-- | Stream the chat path: interpret 'Chat' against Anthropic SSE, 'emit'ting each
-- text delta, reassembling tool_use blocks, and returning the assembled 'Turn'
-- plus summed 'Usage'.
runChatAnthropicStream
  :: (IOE :> es, Emit :> es)
  => AnthropicConfig -> Eff (Chat : es) a -> Eff es (a, Usage)
runChatAnthropicStream cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  reinterpret (runState mempty)
    (\_ (Converse specs msgs) -> do
        acc <- bracket
                 (liftIO (openStream cfg mgr (addStream (chatRequestJson cfg specs msgs))))
                 (liftIO . responseClose)
                 streamLoop
        modify (<> saUsage acc)
        pure (Turn (saText acc) (saTools acc)))
    action
