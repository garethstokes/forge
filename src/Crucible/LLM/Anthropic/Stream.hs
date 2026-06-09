{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

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
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Data.Maybe (fromMaybe)
import Crucible.Chat (ToolUse (..), ToolUseId)
import Crucible.Json.Decode (Decoder, at, decodeValue, field, int, string)
import Crucible.Json.Parse (parse)
import Crucible.Json.Value (Value (JObject))
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
