{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module Manifest.Core.Assign (GAssignEncode(..), assignments) where

import Data.Kind (Type)
import GHC.Generics
import Manifest.Core.Codec (DbType, encode)
import Manifest.Core.Meta (camelToSnake)
import Manifest.Core.Query (Assign(..))
import Manifest.Core.Table (Omitted, Patch(..))

class GAssignEncode (rep :: Type -> Type) where
  gAssignEncode :: rep p -> [Assign a]

instance GAssignEncode f => GAssignEncode (D1 m f) where gAssignEncode (M1 x) = gAssignEncode x
instance GAssignEncode f => GAssignEncode (C1 m f) where gAssignEncode (M1 x) = gAssignEncode x
instance (GAssignEncode a, GAssignEncode b) => GAssignEncode (a :*: b) where
  gAssignEncode (a :*: b) = gAssignEncode a ++ gAssignEncode b

instance GAssignEncode (S1 m (Rec0 Omitted)) where
  gAssignEncode _ = []

instance (Selector m, DbType t) => GAssignEncode (S1 m (Rec0 (Patch t))) where
  gAssignEncode s@(M1 (K1 p)) = case p of
    Keep  -> []
    Set x -> [Assign (camelToSnake (selName s)) (encode x)]

instance (Selector m, DbType t) => GAssignEncode (S1 m (Rec0 (Maybe t))) where
  gAssignEncode s@(M1 (K1 m')) = case m' of
    Nothing -> []
    Just x  -> [Assign (camelToSnake (selName s)) (encode (Just x))]

instance {-# OVERLAPPABLE #-} (Selector m, DbType t) => GAssignEncode (S1 m (Rec0 t)) where
  gAssignEncode s@(M1 (K1 x)) = [Assign (camelToSnake (selName s)) (encode x)]

assignments :: (Generic u, GAssignEncode (Rep u)) => u -> [Assign a]
assignments = gAssignEncode . from
