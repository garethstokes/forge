{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Tolerant decoding of LLM replies: strip markdown fences / surrounding
-- prose, extract the first balanced JSON bracket group, parse it, and decode
-- through an autodocodec 'JSONCodec'.
module Crucible.Decode (stripToJson, decodeLLM, DecodeError (..)) where

import Data.Aeson (Value)
import qualified Data.Aeson as A
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as LB
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Autodocodec (JSONCodec, parseJSONVia)

-- | A structured parse failure carrying both the error message and the
-- original (un-stripped) LLM reply text.
data DecodeError = DecodeError { message :: Text, raw :: Text }
  deriving (Eq, Show)

-- | Best-effort extraction of a JSON value from LLM output that may be wrapped
-- in markdown code fences and/or surrounding prose. Finds the first '{' or '['
-- and returns the balanced group ending at the matching close, respecting
-- string literals (so braces inside strings don't confuse the depth count).
-- Falls back to the trimmed input if no bracket group is found.
stripToJson :: Text -> Text
stripToJson t = case findStart t of
  Nothing    -> T.strip t
  Just start ->
    let s = T.drop start t
    in case scanBalanced s of
         Just n  -> T.take n s
         Nothing -> T.strip s

findStart :: Text -> Maybe Int
findStart = T.findIndex (\c -> c == '{' || c == '[')

-- | Length of the balanced bracket prefix of s (which begins at '{' or '[').
scanBalanced :: Text -> Maybe Int
scanBalanced = go 0 (0 :: Int) False False
  where
    go i depth inStr esc t = case T.uncons t of
      Nothing -> Nothing
      Just (c, rest)
        | inStr ->
            if esc then go (i + 1) depth True  False rest
            else case c of
                   '"'  -> go (i + 1) depth False False rest
                   '\\' -> go (i + 1) depth True  True  rest
                   _    -> go (i + 1) depth True  False rest
        | otherwise -> case c of
            '"' -> go (i + 1) depth       True  False rest
            '{' -> go (i + 1) (depth + 1) False False rest
            '[' -> go (i + 1) (depth + 1) False False rest
            '}' -> close i depth rest
            ']' -> close i depth rest
            _   -> go (i + 1) depth       False False rest
      where
        close j d r = let d' = d - 1
                      in if d' == 0 then Just (j + 1) else go (j + 1) d' False False r

-- | Strip JSON out of LLM prose, parse it, and decode through the codec.
-- On any failure returns a 'DecodeError' whose 'raw' field carries the
-- original un-stripped input.
decodeLLM :: JSONCodec a -> Text -> Either DecodeError a
decodeLLM c t =
  case A.eitherDecode (LB.fromStrict (TE.encodeUtf8 (stripToJson t))) of
    Left err -> Left (DecodeError (T.pack err) t)
    Right v  -> case parseEither (parseJSONVia c) (v :: Value) of
      Left err -> Left (DecodeError (T.pack err) t)
      Right a  -> Right a
