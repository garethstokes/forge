{-# LANGUAGE OverloadedStrings #-}
module Crucible.Json.Encode (encode) where

import Data.Text (Text)
import qualified Data.Text as T
import Crucible.Json.Value (Value(..))

encode :: Value -> Text
encode JNull        = "null"
encode (JBool b)    = if b then "true" else "false"
encode (JNumber n)  = number n
encode (JString s)  = quote s
encode (JArray xs)  = "[" <> T.intercalate "," (map encode xs) <> "]"
encode (JObject kv) = "{" <> T.intercalate "," (map pair kv) <> "}"
  where pair (k, v) = quote k <> ":" <> encode v

-- | Render a JSON number. A whole-valued Double is emitted without a trailing
-- @.0@ (JSON has no float/int distinction, but APIs that expect an integer —
-- e.g. Anthropic's @max_tokens@ — reject @1024.0@). Values still round-trip:
-- @parse "1024"@ yields @JNumber 1024.0@.
number :: Double -> Text
number n
  | isNaN n || isInfinite n        = "null"
  | n == fromIntegral i            = T.pack (show i)
  | otherwise                      = T.pack (show n)
  where i = round n :: Integer

quote :: Text -> Text
quote s = "\"" <> T.concatMap esc s <> "\""
  where esc '"'  = "\\\""
        esc '\\' = "\\\\"
        esc '\n' = "\\n"
        esc '\t' = "\\t"
        esc '\r' = "\\r"
        esc c    = T.singleton c
