{-# LANGUAGE OverloadedStrings #-}
module Crucible.Schema (Schema(..), renderSchema) where

import Data.Text (Text)
import qualified Data.Text as T

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
  deriving (Eq, Show)

-- | Compact, deterministic, single-line rendering (multi-line pretty is a later refinement).
renderSchema :: Schema -> Text
renderSchema SStr        = "string"
renderSchema SNum        = "number"
renderSchema SBool       = "boolean"
renderSchema (SOpt s)    = renderSchema s <> " | null"
renderSchema (SArr s)    = "[" <> renderSchema s <> "]"
renderSchema (SEnum xs)  = T.intercalate " | " (map quote xs)
renderSchema (SOneOf ss) = T.intercalate " | " (map renderSchema ss)
renderSchema (SObj fs)   =
  "{" <> T.intercalate ", " [ quote k <> ": " <> renderSchema v | (k, v) <- fs ] <> "}"

quote :: Text -> Text
quote s = "\"" <> s <> "\""
