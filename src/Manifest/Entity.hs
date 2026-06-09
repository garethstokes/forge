{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Manifest.Entity
  ( Entity(..)
  , Table(..)
  , PrimKey
  , GPrimKeyType
  , Key(..)
  , GRowDecode
  , GRowEncode
  , genericRowDecoder
  , genericRowEncode
  , genericPrimKey
  , identityKey
  , pkParam
  , pkIndex
  ) where

import Data.Functor.Identity (Identity)
import Data.Kind (Type)
import Data.List (findIndex)
import Data.Maybe (fromMaybe)
import Type.Reflection (Typeable, SomeTypeRep, someTypeRep)
import Data.Proxy (Proxy(..))
import GHC.Generics
import GHC.TypeLits (Symbol, TypeError, ErrorMessage(..))
import Manifest.Core.Cascade (CascadeRule)
import Manifest.Core.Index (Index)
import Manifest.Core.Rls (Policy)
import Manifest.Core.Codec (DbType(..), Codec(..), RowDecoder, SqlParam, encode, decodeCol)
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..))
import Manifest.Core.Table (Exposed, Base)

-- | The @deriving via@ carrier. @Table name t@ wraps @t Identity@ with the
-- table name carried at the type level, so an entity becomes a one-liner:
-- @deriving via (Table "posts" PostT) instance Entity Post@.
newtype Table (name :: Symbol) (t :: (Type -> Type) -> Type) = Table (t Identity)

-- | The primary-key runtime type of an entity. By convention the PK is the
-- FIRST field; we walk the @t Exposed@ rep to it and take the 'Base' of its
-- marker.
type family PrimKey a where
  PrimKey (Table name t) = GPrimKeyType (Rep (t Exposed))
  PrimKey (t Identity)   = GPrimKeyType (Rep (t Exposed))

-- | The PK is, by convention, the FIRST field. Walk to it and take the Base of
-- its marker.
type family GPrimKeyType (rep :: Type -> Type) :: Type where
  GPrimKeyType (D1 m f) = GPrimKeyType f
  GPrimKeyType (C1 m f) = GPrimKeyType f
  GPrimKeyType ((S1 m (Rec0 (Exposed inner))) :*: rest) = Base inner
  GPrimKeyType (S1 m (Rec0 (Exposed inner)))            = Base inner
  GPrimKeyType other =
    TypeError ('Text "Manifest: an entity must be a single-constructor record with its primary key as the first field")

-- | The class the Unit-of-Work operates over. Every method has a Generics-based
-- default except 'tableMeta' (which needs the table name).
class Typeable a => Entity a where
  tableMeta  :: TableMeta a

  rowDecoder :: RowDecoder a
  default rowDecoder :: (Generic a, GRowDecode (Rep a)) => RowDecoder a
  rowDecoder = genericRowDecoder

  rowEncode  :: a -> [SqlParam]
  default rowEncode :: (Generic a, GRowEncode (Rep a)) => a -> [SqlParam]
  rowEncode = genericRowEncode

  primKey :: a -> PrimKey a
  default primKey :: DbType (PrimKey a) => a -> PrimKey a
  primKey = genericPrimKey

  -- | onDelete cascade rules applied when a value of this type is deleted.
  -- Default: none. Override with the 'cascade' builder.
  cascadeRules :: [CascadeRule]
  cascadeRules = []
  -- | Row-level-security policies for this entity (default: none). Built with the
  -- "Manifest.Rls" DSL; applied by the migration engine.
  rlsPolicies :: [Policy a]
  rlsPolicies = []
  -- | Declarative indexes for this entity (default: none). Built with the
  -- "Manifest.Index" DSL ('Manifest.Index.gin' / 'Manifest.Index.btree');
  -- created (create-if-absent, never dropped) by the migration engine.
  indexes :: [Index a]
  indexes = []

-- | A row's identity: a newtype over its primary-key value.
newtype Key a = Key { unKey :: PrimKey a }

-- Generic row decoder ---------------------------------------------------------

class GRowDecode (rep :: Type -> Type) where
  gRowDecode :: RowDecoder (rep p)

instance GRowDecode f => GRowDecode (D1 m f) where gRowDecode = M1 <$> gRowDecode
instance GRowDecode f => GRowDecode (C1 m f) where gRowDecode = M1 <$> gRowDecode
instance (GRowDecode a, GRowDecode b) => GRowDecode (a :*: b) where
  gRowDecode = (:*:) <$> gRowDecode <*> gRowDecode
instance DbType t => GRowDecode (S1 m (Rec0 t)) where
  gRowDecode = M1 . K1 <$> decodeCol

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
instance DbType t => GRowEncode (S1 m (Rec0 t)) where
  gRowEncode (M1 (K1 x)) = [encode x]

-- | Default 'rowEncode' via Generics. Produces one 'SqlParam' per column, in
-- 'tableMeta' column order.
genericRowEncode :: (Generic a, GRowEncode (Rep a)) => a -> [SqlParam]
genericRowEncode = gRowEncode . from

-- | Default 'primKey': re-encode the row, take the PK column's 'SqlParam', and
-- decode it back to 'PrimKey a'.
genericPrimKey :: forall a. (Entity a, DbType (PrimKey a)) => a -> PrimKey a
genericPrimKey a =
  case cDecode (dbType @(PrimKey a)) (rowEncode a !! pkIndex @a) of
    Right v  -> v
    Left err -> error ("Manifest.genericPrimKey: " <> show err)

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
