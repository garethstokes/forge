{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE GADTs              #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE NoFieldSelectors   #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators      #-}

-- | SSE streaming for the live OpenAI path: a pure event core ('parseEvents' /
-- 'stepAcc' / 'finishAcc') plus thin streaming interpreters, mirroring
-- "Crucible.LLM.Anthropic.Stream". Use qualified under the same alias as the
-- parent module: @OpenAI.stream@, @OpenAI.streamChat@.
--
-- Wire-format notes (where OpenAI chunks differ from Anthropic events):
--
--   * One chunk's @delta@ can carry text and several @tool_calls@ entries, so
--     a frame parses to a /list/ of events ('parseEvents').
--   * A tool call's @id@ and @function.name@ arrive only on its first
--     fragment; later fragments carry @function.arguments@ pieces, keyed by
--     @index@. There is no per-tool stop event; tools finalize at end of
--     stream ('finishAcc').
--   * Usage arrives in one final chunk (with an empty @choices@) only when
--     the request sets @stream_options.include_usage@; 'addStream' does.
--   * The stream ends with a literal @data: [DONE]@ sentinel.
module Crucible.LLM.OpenAI.Stream
  ( StreamEvent (..)
  , parseEvents
  , StreamAcc (..)
  , PartialCall (..)
  , emptyAcc
  , stepAcc
  , finishAcc
  , stream
  , streamChat
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.Exception (bracket)
import Effectful.State.Static.Local (modify, runState)

import Control.Exception (handle, throwIO)
import System.Timeout (timeout)
import Network.HTTP.Client
  ( BodyReader, HttpException, Manager, Response
  , brRead, responseBody
  , responseClose, responseOpen, responseStatus )
import Network.HTTP.Types.Status (statusCode)

import qualified Data.Aeson as A
import Data.Aeson (Value (..), (.:), (.:?))
import qualified Data.Aeson.Types as AT
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LB

import Crucible.Chat (Chat (..), ToolUse (..), ToolUseId, Turn (..))
import Crucible.Emit (Emit, emit)
import Crucible.LLM (LLM (..))
import Crucible.LLM.Anthropic.Stream (splitFrames)
import Crucible.LLM.OpenAI
  ( OpenAIConfig (..), OpenAIError (..), chatRequestJson
  , completionsRequest, newOpenAIManager, requestJson, withOpenAIRetry )
import Crucible.Tool (ToolName)
import Crucible.Usage (Usage (..))

-- | A single parsed stream event, reduced to what the accumulator needs.
data StreamEvent
  = EvText Text
    -- ^ a @delta.content@ fragment
  | EvToolDelta Int (Maybe ToolUseId) (Maybe ToolName) Text
    -- ^ one @delta.tool_calls@ entry: index, id\/name (first fragment only),
    -- and an @arguments@ fragment
  | EvUsage Int Int
    -- ^ the final usage chunk: prompt tokens, completion tokens
  | EvDone
    -- ^ the @[DONE]@ sentinel
  | EvOther
  deriving (Eq, Show)

-- | Parse one SSE frame's @data:@ payload into events. A frame with no
-- usable payload yields @[]@; an unrecognised JSON shape yields @[EvOther]@.
parseEvents :: ByteString -> [StreamEvent]
parseEvents frame = case dataPayload frame of
  Nothing -> []
  Just bs
    | BC.strip bs == "[DONE]" -> [EvDone]
    | otherwise -> case A.eitherDecode (LB.fromStrict bs) of
        Left _  -> [EvOther]
        Right v -> classify v

-- | Extract the raw bytes after the first @data:@ line (leading whitespace stripped).
dataPayload :: ByteString -> Maybe ByteString
dataPayload frame = case filter ("data:" `BS.isPrefixOf`) (BC.lines frame) of
  (ln : _) -> Just (BC.dropWhile (== ' ') (BS.drop 5 ln))
  []       -> Nothing

classify :: Value -> [StreamEvent]
classify v = fromMaybe [EvOther] (AT.parseMaybe parser v)
  where
    parser = A.withObject "chunk" $ \o -> do
      choices <- o .:? "choices" AT..!= ([] :: [Value])
      musage  <- o .:? "usage"
      deltaEvs <- case choices of
        (c : _) -> flip (A.withObject "choice") c $ \co -> do
          mdelta <- co .:? "delta"
          case mdelta of
            Nothing -> pure []
            Just d  -> flip (A.withObject "delta") d $ \do_ -> do
              mtext  <- do_ .:? "content"
              mcalls <- do_ .:? "tool_calls"
              calls  <- mapM toolDelta (maybe [] Prelude.id mcalls)
              pure ([EvText t | Just (String t) <- [mtext]] ++ calls)
        [] -> pure []
      usageEvs <- case musage of
        Just u@(Object _) ->
          flip (A.withObject "usage") u $ \uo ->
            (\i c -> [EvUsage i c]) <$> uo .: "prompt_tokens" <*> uo .: "completion_tokens"
        _ -> pure []
      pure (deltaEvs ++ usageEvs)

    toolDelta = A.withObject "tool_call" $ \c -> do
      i   <- c .: "index"
      mid <- c .:? "id"
      fn  <- c .:? "function"
      (mn, frag) <- case fn of
        Nothing -> pure (Nothing, "")
        Just f  -> flip (A.withObject "function") f $ \fo ->
          (,) <$> fo .:? "name" <*> (fo .:? "arguments" AT..!= "")
      pure (EvToolDelta i mid mn frag)

-- | An in-progress tool call: id, name, and accumulated argument JSON text.
-- Id and name are filled by the first fragment that carries them.
data PartialCall = PartialCall ToolUseId ToolName Text
  deriving (Eq, Show)

-- | Running accumulation across one streamed response.
data StreamAcc = StreamAcc
  { text    :: Text                 -- concatenated content deltas
  , partial :: [(Int, PartialCall)] -- in-progress tool calls, by index
  , usage   :: Usage
  }
  deriving (Eq, Show)

emptyAcc :: StreamAcc
emptyAcc = StreamAcc "" [] mempty

-- | Fold one event into the accumulator (the IO loop 'emit's text deltas).
stepAcc :: StreamAcc -> StreamEvent -> StreamAcc
stepAcc acc = \case
  EvText t -> acc { text = acc.text <> t }
  EvToolDelta i mid mn frag -> case lookup i acc.partial of
    Nothing ->
      acc { partial = (i, PartialCall (fromMaybe "" mid) (fromMaybe "" mn) frag) : acc.partial }
    Just (PartialCall tid n js) ->
      acc { partial = (i, PartialCall (orElse tid mid) (orElse n mn) (js <> frag))
                        : filter ((/= i) . fst) acc.partial }
  EvUsage inp out -> acc { usage = Usage inp out }
  EvDone  -> acc
  EvOther -> acc
  where
    orElse old Nothing  = old
    orElse old (Just new) | T.null old = new
                          | otherwise  = old

-- | Finalize the accumulated tool calls (index order). An empty arguments
-- string decodes to @{}@; an undecodable one passes through as a JSON string
-- so the tool sees the raw text (matching 'Crucible.LLM.OpenAI.parseTurn').
finishAcc :: StreamAcc -> [ToolUse]
finishAcc acc =
  [ ToolUse tid n (parseArgs js)
  | (_, PartialCall tid n js) <- sortOn fst acc.partial
  ]
  where
    parseArgs js
      | T.null (T.strip js) = A.object []
      | otherwise =
          either (const (A.String js)) Prelude.id
            (A.eitherDecode (LB.fromStrict (TE.encodeUtf8 js)))

-- | Add @"stream": true@ and @"stream_options": {"include_usage": true}@
-- (usage is only sent when asked for) to a request body object.
addStream :: Value -> Value
addStream (Object o) =
  Object
    ( KM.insert (K.fromString "stream") (Bool True)
        (KM.insert (K.fromString "stream_options")
          (A.object [("include_usage", Bool True)]) o) )
addStream v = v

-- | Open a @stream:true@ POST, retrying transient PRE-stream failures with the
-- same policy as the non-streaming path. Returns the live 2xx response (the
-- caller streams and closes it); a non-2xx response is drained, closed, and
-- thrown as 'OpenAIStatusError'. Nothing is emitted before this returns, so
-- retrying is safe.
openStream :: OpenAIConfig -> Manager -> Value -> IO (Response BodyReader)
openStream cfg mgr bodyJson =
  withOpenAIRetry cfg $
    handle (\(e :: HttpException) -> throwIO (OpenAIHttpError e)) $ do
      req <- completionsRequest cfg bodyJson
      resp <- responseOpen req mgr
      let code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then pure resp
        else do
          errBody <- drainBody (responseBody resp)
          responseClose resp
          throwIO (OpenAIStatusError code (TE.decodeUtf8Lenient errBody))

-- | Read a BodyReader to exhaustion into one strict ByteString.
drainBody :: BodyReader -> IO ByteString
drainBody br = go []
  where
    go acc = do
      chunk <- brRead br
      if BS.null chunk then pure (BS.concat (reverse acc)) else go (chunk : acc)

-- | Read one chunk, bounding the wait by @micros@. A non-positive @micros@
-- disables the guard. On timeout, throw 'OpenAIStreamTimeout'.
timedRead :: Int -> IO ByteString -> IO ByteString
timedRead micros readChunk
  | micros <= 0 = readChunk
  | otherwise   =
      timeout micros readChunk >>= maybe (throwIO (OpenAIStreamTimeout micros)) pure

-- | Stream an open response: read chunks, split frames, 'emit' text deltas
-- live, and fold the whole stream into a 'StreamAcc'.
streamLoop :: (IOE :> es, Emit :> es) => Int -> Response BodyReader -> Eff es StreamAcc
streamLoop idleMicros resp = go emptyAcc BS.empty
  where
    br = responseBody resp
    go acc buf = do
      chunk <- liftIO (timedRead idleMicros (brRead br))
      if BS.null chunk
        then if BS.all isWs buf then pure acc else emitFrames acc [buf]
        else do
          let (frames, rest) = splitFrames (buf <> chunk)
          acc' <- emitFrames acc frames
          go acc' rest
    emitFrames acc []       = pure acc
    emitFrames acc (f : fs) = do
      let evs = parseEvents f
      mapM_ (\case EvText t -> emit t; _ -> pure ()) evs
      emitFrames (foldl stepAcc acc evs) fs
    isWs :: Word8 -> Bool
    isWs c = c == 32 || c == 10 || c == 13 || c == 9

-- | Stream the text path: interpret 'LLM' against OpenAI SSE, 'emit'ting each
-- content delta and returning the assembled reply plus summed 'Usage'.
-- Use as @OpenAI.stream@.
stream
  :: (IOE :> es, Emit :> es)
  => OpenAIConfig -> Eff (LLM : es) a -> Eff es (a, Usage)
stream cfg action = do
  mgr <- liftIO (newOpenAIManager cfg)
  reinterpret (runState mempty)
    (\_ (Complete msgs) -> do
        acc <- bracket
                 (liftIO (openStream cfg mgr (addStream (requestJson cfg msgs))))
                 (liftIO . responseClose)
                 (streamLoop (cfg.streamIdleSecs * 1000000))
        modify (<> acc.usage)
        pure acc.text)
    action

-- | Stream the chat path: interpret 'Chat' against OpenAI SSE, 'emit'ting each
-- content delta, reassembling tool calls, and returning the assembled 'Turn'
-- plus summed 'Usage'. Use as @OpenAI.streamChat@.
streamChat
  :: (IOE :> es, Emit :> es)
  => OpenAIConfig -> Eff (Chat : es) a -> Eff es (a, Usage)
streamChat cfg action = do
  mgr <- liftIO (newOpenAIManager cfg)
  reinterpret (runState mempty)
    (\_ (Converse specs msgs) -> do
        acc <- bracket
                 (liftIO (openStream cfg mgr (addStream (chatRequestJson cfg specs msgs))))
                 (liftIO . responseClose)
                 (streamLoop (cfg.streamIdleSecs * 1000000))
        modify (<> acc.usage)
        pure (Turn acc.text (finishAcc acc)))
    action
