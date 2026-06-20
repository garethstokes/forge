{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE KindSignatures #-}
module Manifest.Core.Skeleton (GNeutral(..), neutral) where

import Data.Kind (Type)
import GHC.Generics
import Manifest.Core.Table (Omitted(..), Patch(..))

class GNeutral (rep :: Type -> Type) where gNeutral :: rep p
instance GNeutral f => GNeutral (D1 m f) where gNeutral = M1 gNeutral
instance GNeutral f => GNeutral (C1 m f) where gNeutral = M1 gNeutral
instance (GNeutral a, GNeutral b) => GNeutral (a :*: b) where gNeutral = gNeutral :*: gNeutral
instance GNeutral (S1 m (Rec0 Omitted))   where gNeutral = M1 (K1 Omitted)
instance GNeutral (S1 m (Rec0 (Maybe t))) where gNeutral = M1 (K1 Nothing)
instance GNeutral (S1 m (Rec0 (Patch t))) where gNeutral = M1 (K1 Keep)

neutral :: (Generic a, GNeutral (Rep a)) => a
neutral = to gNeutral
