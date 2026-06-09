{-# LANGUAGE OverloadedStrings #-}
module Crucible.Schema (Schema(..), renderSchema, schemaToJson) where

import Data.Text (Text)
import qualified Data.Text as T
import Crucible.Json.Value (Value (..))

-- | A structural description of a type, injected into prompts.
data Schema
  = SObj   [(Text, Schema)]
  | SArr   Schema
  | SEnum  [Text]
  | SOneOf [Schema]
  | SStr
  | SNum
  | SBool
  | SOpt   Schema
  | SAny
  deriving (Eq, Show)

-- | Compact, deterministic, single-line rendering (multi-line pretty is a later refinement).
renderSchema :: Schema -> Text
renderSchema SStr        = "string"
renderSchema SNum        = "number"
renderSchema SBool       = "boolean"
renderSchema SAny        = "any"
renderSchema (SOpt s)    = renderSchema s <> " | null"
renderSchema (SArr s)    = "[" <> renderSchema s <> "]"
renderSchema (SEnum xs)  = T.intercalate " | " (map quote xs)
renderSchema (SOneOf ss) = T.intercalate " | " (map renderSchema ss)
renderSchema (SObj fs)   =
  "{" <> T.intercalate ", " [ quote k <> ": " <> renderSchema v | (k, v) <- fs ] <> "}"

quote :: Text -> Text
quote s = "\"" <> s <> "\""

-- | Render a 'Schema' as a JSON-Schema object (for an Anthropic tool's
-- @input_schema@). Optional object fields are omitted from @required@.
schemaToJson :: Schema -> Value
schemaToJson s = case s of
  SStr      -> JObject [("type", JString "string")]
  SNum      -> JObject [("type", JString "number")]
  SBool     -> JObject [("type", JString "boolean")]
  SArr e    -> JObject [("type", JString "array"), ("items", schemaToJson e)]
  SEnum vs  -> JObject [("type", JString "string"), ("enum", JArray (map JString vs))]
  SOneOf ss -> JObject [("anyOf", JArray (map schemaToJson ss))]
  SOpt e    -> schemaToJson e
  SAny      -> JObject []
  SObj kvs  ->
    JObject
      [ ("type", JString "object")
      , ("properties", JObject [(k, schemaToJson v) | (k, v) <- kvs])
      , ("required", JArray [JString k | (k, v) <- kvs, not (isOpt v)])
      ]
  where
    isOpt (SOpt _) = True
    isOpt _        = False
