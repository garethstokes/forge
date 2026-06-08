{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
-- | Opt-in GHC.Generics derive layer for codecs.
--
-- This is the ONLY module that uses GHC.Generics; the core stays Generics-free.
-- A 'HasCodec' instance gives a type its canonical 'Codec'; the default method
-- 'genericCodec' derives schema + decoder + encoder together from the type's
-- 'Rep', so leaf records and nullary-sum enums derive with no hand-written
-- getters.
module Crucible.Codec.Generic
  ( HasCodec(..)
  , genericCodec
  , GCodec    -- exported so the `default` signature + deriving works
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Control.Applicative ((<|>))
import GHC.Generics
import Crucible.Schema (Schema(..))
import Crucible.Json.Value (Value(..))
import qualified Crucible.Codec as C
import Crucible.Codec (Codec(..))
import qualified Crucible.Json.Decode as D

-- | The canonical codec for a type. Used by the generic deriver to resolve
-- nested fields by type. Provide instances by hand OR via 'genericCodec'
-- (the default method).
class HasCodec a where
  codec :: Codec a
  default codec :: (Generic a, GCodec (Rep a)) => Codec a
  codec = genericCodec

instance HasCodec Text   where codec = C.str
instance HasCodec Int    where codec = C.int
instance HasCodec Bool   where codec = C.bool
instance HasCodec Double where codec = C.float
instance HasCodec a => HasCodec [a]       where codec = C.list' (codec @a)
instance HasCodec a => HasCodec (Maybe a) where codec = C.nullable' (codec @a)

-- | Build schema + decoder + encoder from a type's Generic 'Rep'.
genericCodec :: forall a. (Generic a, GCodec (Rep a)) => Codec a
genericCodec = Codec (gschema @(Rep a))
                     (to <$> gdecode)
                     (gencode . from)

class GCodec (f :: * -> *) where
  gschema :: Schema
  gdecode :: D.Decoder (f x)
  gencode :: f x -> Value

-- Datatype wrapper: descend.
instance GCodec f => GCodec (M1 D c f) where
  gschema = gschema @f
  gdecode = M1 <$> gdecode
  gencode (M1 x) = gencode x

-- Single constructor = record: an object built from its product of selectors.
instance GProd f => GCodec (M1 C c f) where
  gschema = SObj (gpFields @f)
  gdecode = M1 <$> gpDecode
  gencode (M1 x) = JObject (gpEncode x)

-- Sum of constructors = enum (of nullary constructors).
instance (GSum a, GSum b) => GCodec (a :+: b) where
  gschema = SEnum (gsNames @(a :+: b))
  gdecode = D.andThen
              (\n -> case gsDecode n of
                       Just v  -> D.succeed v
                       Nothing -> D.failD ("unknown variant: " ++ show n))
              D.string
  gencode = JString . gsEncode

-- Products of named selectors.
class GProd (f :: * -> *) where
  gpFields :: [(Text, Schema)]
  gpDecode :: D.Decoder (f x)
  gpEncode :: f x -> [(Text, Value)]

instance (GProd a, GProd b) => GProd (a :*: b) where
  gpFields = gpFields @a ++ gpFields @b
  gpDecode = (:*:) <$> gpDecode <*> gpDecode
  gpEncode (a :*: b) = gpEncode a ++ gpEncode b

instance (Selector s, HasCodec t) => GProd (M1 S s (K1 r t)) where
  gpFields = [ (sel, codecSchema (codec @t)) ]
    where sel = selNameT @s
  gpDecode = M1 . K1 <$> D.field (selNameT @s) (codecDecode (codec @t))
  gpEncode (M1 (K1 v)) = [ (selNameT @s, codecEncode (codec @t) v) ]

-- Sum of constructors.
class GSum (f :: * -> *) where
  gsNames  :: [Text]
  gsDecode :: Text -> Maybe (f x)   -- Just if a constructor name matches
  gsEncode :: f x -> Text

instance (GSum a, GSum b) => GSum (a :+: b) where
  gsNames = gsNames @a ++ gsNames @b
  gsDecode n = (L1 <$> gsDecode n) <|> (R1 <$> gsDecode n)
  gsEncode (L1 x) = gsEncode x
  gsEncode (R1 x) = gsEncode x

instance Constructor c => GSum (M1 C c U1) where
  gsNames    = [ conNameT @c ]
  gsDecode n = if n == conNameT @c then Just (M1 U1) else Nothing
  gsEncode _ = conNameT @c

-- | Read a selector's record-field name as 'Text'.
selNameT :: forall (s :: Meta). Selector s => Text
selNameT = T.pack (selName (undefined :: M1 S s Maybe ()))

-- | Read a constructor's name as 'Text'.
conNameT :: forall (c :: Meta). Constructor c => Text
conNameT = T.pack (conName (undefined :: M1 C c Maybe ()))
