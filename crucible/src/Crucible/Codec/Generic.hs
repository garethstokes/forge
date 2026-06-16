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

import Control.Applicative ((<|>))
import Data.Scientific (fromFloatDigits)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics
import Autodocodec
  ( JSONCodec, ObjectCodec, HasCodec (codec), requiredFieldWith'
  , optionalFieldOrNullWith'
  , textCodec, scientificCodec, bimapCodec, dimapCodec, lmapCodec )
import qualified Autodocodec as AC

-- | autodocodec has no @HasCodec Double@ (only @Scientific@/@Int@/@Integer@);
-- supply one so 'Double' record fields derive. Orphan by necessity.
instance {-# OVERLAPPING #-} HasCodec Double where
  codec = dimapCodec realToFrac fromFloatDigits scientificCodec

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

-- sum of nullary constructors = enum. Encoded by constructor name (no 'Eq' on
-- the Rep needed — name-based, via 'bimapCodec' over 'textCodec').
instance {-# OVERLAPPING #-} (GSum (a :+: b)) => GCodec (a :+: b) where
  gcodec = bimapCodec dec gsEncode textCodec
    where
      dec t = maybe (Left ("unknown variant: " <> T.unpack t)) Right (gsDecode t)

class GProd (f :: * -> *) where
  gprod :: ObjectCodec (f x) (f x)

instance (GProd a, GProd b) => GProd (a :*: b) where
  gprod = (:*:) <$> lmapCodec prjL gprod <*> lmapCodec prjR gprod
    where
      prjL (l :*: _) = l
      prjR (_ :*: r) = r

instance (Selector s, HasCodec t) => GProd (M1 S s (K1 r t)) where
  gprod =
    dimapCodec (M1 . K1) (\(M1 (K1 v)) -> v)
      (requiredFieldWith' (selNameT @s) codec)

-- A 'Maybe' field is optional on the wire: dropped from the schema's
-- @required@ list, omitted when 'Nothing', and tolerant of both an absent
-- key and an explicit @null@ on decode.
instance {-# OVERLAPPING #-} (Selector s, HasCodec t) => GProd (M1 S s (K1 r (Maybe t))) where
  gprod =
    dimapCodec (M1 . K1) (\(M1 (K1 v)) -> v)
      (optionalFieldOrNullWith' (selNameT @s) codec)

class GSum (f :: * -> *) where
  gsDecode :: Text -> Maybe (f x)
  gsEncode :: f x -> Text

instance (GSum a, GSum b) => GSum (a :+: b) where
  gsDecode n = (L1 <$> gsDecode n) <|> (R1 <$> gsDecode n)
  gsEncode (L1 x) = gsEncode x
  gsEncode (R1 x) = gsEncode x

instance Constructor c => GSum (M1 C c U1) where
  gsDecode n = if n == conNameT @c then Just (M1 U1) else Nothing
  gsEncode _ = conNameT @c

selNameT :: forall (s :: Meta). Selector s => Text
selNameT = T.pack (selName (undefined :: M1 S s f a))

conNameT :: forall (c :: Meta). Constructor c => Text
conNameT = T.pack (conName (undefined :: M1 C c f a))
