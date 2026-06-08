{-# LANGUAGE OverloadedStrings #-}
module Crucible.SAP (stripToJson, decodeLLM) where

import Data.Text (Text)
import qualified Data.Text as T
import Crucible.Codec (Codec(..))
import qualified Crucible.Json.Decode as D

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

-- | Schema-aligned decode: pull the JSON out of messy text, then decode it
-- through the codec's decoder.
decodeLLM :: Codec a -> Text -> Either D.Error a
decodeLLM c = D.decodeString (codecDecode c) . stripToJson
