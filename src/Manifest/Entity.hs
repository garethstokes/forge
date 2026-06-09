{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Manifest.Entity
  ( Entity(..)
  , Key(..)
  , genericRowDecoder
  , genericRowEncode
  , identityKey
  , pkParam
  , pkIndex
  ) where

import Data.Kind (Type)
import Data.List (findIndex)
import Data.Maybe (fromMaybe)
import Type.Reflection (Typeable, SomeTypeRep, someTypeRep)
import Data.Proxy (Proxy(..))
import GHC.Generics
import Manifest.Core.Cascade (CascadeRule)
import Manifest.Core.Rls (Policy)
import Manifest.Core.Codec (FromField, RowDecoder, SqlParam, ToField(..), field)
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..))

-- | The class the Unit-of-Work operates over. SP1 derives every method
-- generically except 'primKey' (the PK selector) and 'tableMeta' (the table name).
class Typeable a => Entity a where
  type PrimKey a
  tableMeta  :: TableMeta a
  rowDecoder :: RowDecoder a
  rowEncode  :: a -> [SqlParam]
  primKey    :: a -> PrimKey a
  -- | onDelete cascade rules applied when a value of this type is deleted.
  -- Default: none. Override with the 'cascade' builder.
  cascadeRules :: [CascadeRule]
  cascadeRules = []
  -- | Row-level-security policies for this entity (default: none). Built with the
  -- "Manifest.Rls" DSL; applied by the migration engine.
  rlsPolicies :: [Policy a]
  rlsPolicies = []

-- | A row's identity: a newtype over its primary-key value.
newtype Key a = Key { unKey :: PrimKey a }

-- Generic row decoder ---------------------------------------------------------

class GRowDecode (rep :: Type -> Type) where
  gRowDecode :: RowDecoder (rep p)

instance GRowDecode f => GRowDecode (D1 m f) where gRowDecode = M1 <$> gRowDecode
instance GRowDecode f => GRowDecode (C1 m f) where gRowDecode = M1 <$> gRowDecode
instance (GRowDecode a, GRowDecode b) => GRowDecode (a :*: b) where
  gRowDecode = (:*:) <$> gRowDecode <*> gRowDecode
instance FromField t => GRowDecode (S1 m (Rec0 t)) where
  gRowDecode = M1 . K1 <$> field

-- | Default 'rowDecoder' via Generics.
genericRowDecoder :: (Generic a, GRowDecode (Rep a)) => RowDecoder a
genericRowDecoder = to <$> gRowDecode

-- Generic row encoder ---------------------------------------------------------

class GRowEncode (rep :: Type -> Type) where
  gRowEncode :: rep p -> [SqlParam]

instance GRowEncode f => GRowEncode (D1 m f) where gRowEncode (M1 x) = gRowEncode x
instance GRowEncode f => GRowEncode (C1 m f) where gRowEncode (M1 x) = gRowEncode x
instance (GRowEncode a, GRowEncode b) => GRowEncode (a :*: b) where
  gRowEncode (a :*: b) = gRowEncode a ++ gRowEncode b
instance ToField t => GRowEncode (S1 m (Rec0 t)) where
  gRowEncode (M1 (K1 x)) = [toField x]

-- | Default 'rowEncode' via Generics. Produces one 'SqlParam' per column, in
-- 'tableMeta' column order.
genericRowEncode :: (Generic a, GRowEncode (Rep a)) => a -> [SqlParam]
genericRowEncode = gRowEncode . from

-- Identity helpers ------------------------------------------------------------

-- | Index of the primary-key column within 'tableMeta'/'rowEncode'.
pkIndex :: forall a. Entity a => Int
pkIndex = fromMaybe (error "Manifest: no primary key column")
                    (findIndex cmIsPK (tmColumns (tableMeta @a)))

-- | The encoded primary-key value of a record (its bytes in the identity map).
pkParam :: forall a. Entity a => a -> SqlParam
pkParam a = rowEncode a !! pkIndex @a

-- | The heterogeneous identity-map key for a record.
identityKey :: forall a. Entity a => a -> (SomeTypeRep, SqlParam)
identityKey a = (someTypeRep (Proxy @a), pkParam a)
