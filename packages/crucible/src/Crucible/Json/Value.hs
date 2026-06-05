module Crucible.Json.Value (Value(..)) where

import Data.Text (Text)

data Value
  = JNull
  | JBool   Bool
  | JNumber Double
  | JString Text
  | JArray  [Value]
  | JObject [(Text, Value)]
  deriving (Eq, Show)
