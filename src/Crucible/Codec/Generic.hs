{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
-- | Generic derivation of an autodocodec 'JSONCodec' from GHC.Generics, so
-- @instance HasCodec T where codec = genericCodec@ works for records and
-- nullary-constructor enums. The ONLY module here using GHC.Generics.
module Crucible.Codec.Generic
  ( HasCodec (..)
  , genericCodec
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics
import Autodocodec
  ( JSONCodec, ObjectCodec, HasCodec (codec), requiredFieldWith'
  , stringConstCodec, dimapCodec, (.=) )
import qualified Autodocodec as AC

-- | Build a 'JSONCodec' for any single-record or nullary-sum 'Generic' type.
genericCodec :: forall a. (Generic a, GCodec (Rep a)) => JSONCodec a
genericCodec = dimapCodec to from (gcodec @(Rep a))

class GCodec (f :: * -> *) where
  gcodec :: JSONCodec (f x)

-- datatype wrapper: delegate
instance GCodec f => GCodec (M1 D c f) where
  gcodec = dimapCodec M1 unM1 (gcodec @f)

-- single constructor with named fields = record -> object
instance (Constructor c, GProd f) => GCodec (M1 C c f) where
  gcodec = dimapCodec M1 unM1 (AC.object (conNameT @c) (gprod @f))

-- sum of nullary constructors = enum -> stringConstCodec
instance {-# OVERLAPPING #-} (GNullary (a :+: b)) => GCodec (a :+: b) where
  gcodec = stringConstCodec (gvariants @(a :+: b))

class GProd (f :: * -> *) where
  gprod :: ObjectCodec (f x) (f x)

instance (GProd a, GProd b) => GProd (a :*: b) where
  gprod =
    (:*:)
      <$> (gprod @a .= (\(a :*: _) -> a))
      <*> (gprod @b .= (\(_ :*: b) -> b))

instance (Selector s, HasCodec t) => GProd (M1 S s (K1 r t)) where
  gprod = dimapCodec (M1 . K1) (\(M1 (K1 v)) -> v)
            (requiredFieldWith' (selNameT @s) codec)

class GNullary (f :: * -> *) where
  gvariants :: NonEmpty (f x, Text)
instance (GNullary a, GNullary b) => GNullary (a :+: b) where
  gvariants =
    fmap (\(x,t) -> (L1 x, t)) (gvariants @a)
      <> fmap (\(x,t) -> (R1 x, t)) (gvariants @b)
instance Constructor c => GNullary (M1 C c U1) where
  gvariants = (M1 U1, conNameT @c) :| []

selNameT :: forall s f x. Selector s => Text
selNameT = T.pack (selName (undefined :: M1 S s f x))
conNameT :: forall c f x. Constructor c => Text
conNameT = T.pack (conName (undefined :: M1 C c f x))
