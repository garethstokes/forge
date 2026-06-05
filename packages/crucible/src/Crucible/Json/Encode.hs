{-# LANGUAGE OverloadedStrings #-}
module Crucible.Json.Encode (encode) where

import Data.Text (Text)
import qualified Data.Text as T
import Crucible.Json.Value (Value(..))

encode :: Value -> Text
encode JNull        = "null"
encode (JBool b)    = if b then "true" else "false"
encode (JNumber n)  = T.pack (show n)
encode (JString s)  = quote s
encode (JArray xs)  = "[" <> T.intercalate "," (map encode xs) <> "]"
encode (JObject kv) = "{" <> T.intercalate "," (map pair kv) <> "}"
  where pair (k, v) = quote k <> ":" <> encode v

quote :: Text -> Text
quote s = "\"" <> T.concatMap esc s <> "\""
  where esc '"'  = "\\\""
        esc '\\' = "\\\\"
        esc '\n' = "\\n"
        esc '\t' = "\\t"
        esc '\r' = "\\r"
        esc c    = T.singleton c
