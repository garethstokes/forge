{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Crucible.Codec
  ( JSONCodec, ObjectCodec
  , str, int, bool, float, list', nullable', enum
  , object, field, anyValue
  , schemaValue, schemaText
  ) where

import Data.Aeson (Value)
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LB
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Autodocodec
  ( JSONCodec, ObjectCodec, codec, textCodec, boolCodec, valueCodec
  , scientificCodec, dimapCodec
  , listCodec, maybeCodec, stringConstCodec, requiredFieldWith', (.=) )
import qualified Autodocodec as AC
import Autodocodec.Schema (jsonSchemaVia)

str :: JSONCodec Text
str = textCodec
bool :: JSONCodec Bool
bool = boolCodec
int :: JSONCodec Int
int = codec
float :: JSONCodec Double
float = dimapCodec realToFrac realToFrac scientificCodec
anyValue :: JSONCodec Value
anyValue = valueCodec

list' :: JSONCodec a -> JSONCodec [a]
list' = listCodec
nullable' :: JSONCodec a -> JSONCodec (Maybe a)
nullable' = maybeCodec

-- | crucible's old @enum [(tag, value)]@, on autodocodec.
enum :: Eq a => [(Text, a)] -> JSONCodec a
enum pairs = stringConstCodec (NE.fromList [ (a, t) | (t, a) <- pairs ])

-- | A single object field bundling its getter (crucible's old @field@).
field :: Text -> (o -> f) -> JSONCodec f -> ObjectCodec o f
field k getter c = requiredFieldWith' k c .= getter

-- | Close an applicative object codec (crucible's old @object@).
object :: ObjectCodec a a -> JSONCodec a
object = AC.object "object"

-- | The JSON-Schema document for a codec, as an aeson Value (tool input_schema).
schemaValue :: JSONCodec a -> Value
schemaValue = A.toJSON . jsonSchemaVia

-- | The schema rendered as compact JSON text (for prompt injection).
schemaText :: JSONCodec a -> Text
schemaText = TE.decodeUtf8 . LB.toStrict . A.encode . schemaValue
