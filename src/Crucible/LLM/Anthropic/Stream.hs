{-# LANGUAGE OverloadedStrings #-}

-- | SSE streaming for the live Anthropic path: a pure event core
-- ('splitFrames' / 'parseEvent' / 'stepAcc') plus thin streaming interpreters.
module Crucible.LLM.Anthropic.Stream
  ( splitFrames
  , StreamEvent (..)
  , parseEvent
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Data.Maybe (fromMaybe)
import Crucible.Json.Decode (Decoder, at, decodeValue, field, int, string)
import Crucible.Json.Parse (parse)
import Crucible.Json.Value (Value)
import Crucible.Tool (ToolName)

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

-- Anthropic's tool_use id is a JSON string.
type ToolUseId = Text

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
