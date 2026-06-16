{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Crucible.Codec
  ( JSONCodec, ObjectCodec
  , str, int, bool, float, list', nullable', enum
  , object, field, optField, anyValue
  , bimapCodec, dimapCodec
  , schemaValue, schemaText, encodeText
  , refine, checked, Checked (..), allPassed, describe
  ) where

import Data.Aeson (Value)
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LB
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Scientific (fromFloatDigits)
import Autodocodec
  ( JSONCodec, ObjectCodec, codec, textCodec, boolCodec, valueCodec
  , scientificCodec, dimapCodec, bimapCodec
  , listCodec, maybeCodec, stringConstCodec, requiredFieldWith', optionalFieldWith', (.=)
  , (<?>) , toJSONVia )
import qualified Autodocodec as AC
import Autodocodec.Schema (jsonSchemaVia)

str :: JSONCodec Text
str = textCodec
bool :: JSONCodec Bool
bool = boolCodec
int :: JSONCodec Int
int = codec
float :: JSONCodec Double
float = dimapCodec realToFrac fromFloatDigits scientificCodec
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

-- | An optional object field (crucible's optional field), on autodocodec.
optField :: Text -> (o -> Maybe f) -> JSONCodec f -> ObjectCodec o (Maybe f)
optField k getter c = optionalFieldWith' k c .= getter

-- | Close an applicative object codec (crucible's old @object@).
object :: ObjectCodec a a -> JSONCodec a
object = AC.object "object"

-- | The JSON-Schema document for a codec, as an aeson Value (tool input_schema).
schemaValue :: JSONCodec a -> Value
schemaValue = A.toJSON . jsonSchemaVia

-- | The schema rendered as compact JSON text (for prompt injection).
schemaText :: JSONCodec a -> Text
schemaText = TE.decodeUtf8 . LB.toStrict . A.encode . schemaValue

-- | Encode a value to compact JSON text through its codec (the encode
-- companion to 'schemaText' / 'Crucible.Decode.decodeLLM').
encodeText :: JSONCodec a -> a -> Text
encodeText c = TE.decodeUtf8 . LB.toStrict . A.encode . toJSONVia c

-- | Attach a human description to a codec's schema (renders as the
-- JSON-schema "description"). Re-exports autodocodec's '<?>'.
describe :: JSONCodec a -> Text -> JSONCodec a
describe = (<?>)

-- | A hard refinement. Decoding fails when the predicate does not hold,
-- carrying @message@ so 'Crucible.Skill.call's retry loop feeds the
-- violation back to the model. The message is also surfaced as the schema
-- description, so the model sees the constraint upfront. The JSON type is
-- unchanged: a refinement is human guidance, not a wire-format change.
refine :: Text -> (a -> Bool) -> JSONCodec a -> JSONCodec a
refine msg ok c = bimapCodec check id c `describe` msg
  where check a = if ok a then Right a else Left (T.unpack msg)

-- | A value plus the result of each soft check, by name and in order.
data Checked a = Checked { value :: a, checks :: [(Text, Bool)] }
  deriving (Eq, Show)

-- | True when every check passed.
allPassed :: Checked a -> Bool
allPassed cv = all snd cv.checks

-- | A soft refinement. Decoding always succeeds; the value comes back
-- wrapped with each named check's pass/fail, so a caller branches on
-- quality without losing the data. The wire shape and schema are the inner
-- value's; 'Checked' is transparent on the wire.
checked :: [(Text, a -> Bool)] -> JSONCodec a -> JSONCodec (Checked a)
checked specs c = dimapCodec attach (.value) c
  where attach a = Checked a [(nm, p a) | (nm, p) <- specs]
