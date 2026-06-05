{-# LANGUAGE OverloadedStrings #-}
module Crucible.Codec
  ( Codec(..)
  , str, int, bool, float
  , list', nullable', enum
  , ObjectCodec(..), field, object
  , Variant(..), oneOfC
  ) where

import Data.Text (Text)
import Crucible.Schema (Schema(..))
import Crucible.Json.Value (Value(..))
import qualified Crucible.Json.Decode as D
import Crucible.Json.Decode (Decoder)

-- | Bidirectional: schema (for prompts) + decoder + encoder, in one value.
data Codec a = Codec
  { codecSchema :: Schema
  , codecDecode :: Decoder a
  , codecEncode :: a -> Value
  }

str :: Codec Text
str = Codec SStr D.string JString

int :: Codec Int
int = Codec SNum D.int (JNumber . fromIntegral)

bool :: Codec Bool
bool = Codec SBool D.bool JBool

float :: Codec Double
float = Codec SNum D.float JNumber

list' :: Codec a -> Codec [a]
list' (Codec s d e) = Codec (SArr s) (D.list d) (JArray . map e)

nullable' :: Codec a -> Codec (Maybe a)
nullable' (Codec s d e) = Codec (SOpt s) (D.nullable d) (maybe JNull e)

-- | An enum over a finite tagged set. Needs Eq for the encode-side reverse lookup.
enum :: Eq a => [(Text, a)] -> Codec a
enum pairs = Codec (SEnum (map fst pairs)) dec enc
  where
    dec = D.andThen (\t -> case lookup t pairs of
            Just a  -> D.succeed a
            Nothing -> D.failD ("unknown variant: " ++ show t)) D.string
    enc a = case [ k | (k, v) <- pairs, v == a ] of
              (k:_) -> JString k
              []    -> JNull   -- unreachable for a total enum table

-- | Builds an object's field-schemas and decoder covariantly, and its encoder
-- contravariantly (o is the type being encoded; a the type decoded; they unify at `object`).
data ObjectCodec o a = ObjectCodec
  { ocFields :: [(Text, Schema)]
  , ocDecode :: Decoder a
  , ocEncode :: o -> [(Text, Value)]
  }

instance Functor (ObjectCodec o) where
  fmap f (ObjectCodec fs d e) = ObjectCodec fs (fmap f d) e

instance Applicative (ObjectCodec o) where
  pure x = ObjectCodec [] (pure x) (const [])
  ObjectCodec f1 d1 e1 <*> ObjectCodec f2 d2 e2 =
    ObjectCodec (f1 ++ f2) (d1 <*> d2) (\o -> e1 o ++ e2 o)

-- | A single object field. The getter (o -> f) supplies the encode direction.
field :: Text -> (o -> f) -> Codec f -> ObjectCodec o f
field name getter (Codec s d e) =
  ObjectCodec [(name, s)] (D.field name d) (\o -> [(name, e (getter o))])

-- | Close an object: o and a unify to the record type.
object :: ObjectCodec a a -> Codec a
object (ObjectCodec fs d e) = Codec (SObj fs) d (\a -> JObject (e a))

-- | One arm of a sum: its schema, its decoder, and a partial encoder
-- (Nothing = "not my constructor").
data Variant a = Variant Schema (Decoder a) (a -> Maybe Value)

-- | A tagged/structural union. Decode tries each arm in order; encode uses the
-- first arm whose matcher fires.
oneOfC :: [Variant a] -> Codec a
oneOfC vs =
  Codec (SOneOf [ s | Variant s _ _ <- vs ])
        (D.oneOf  [ d | Variant _ d _ <- vs ])
        (\a -> case [ v | Variant _ _ enc <- vs, Just v <- [enc a] ] of
                 (v:_) -> v
                 []    -> JNull)   -- unreachable if the variant set is total
