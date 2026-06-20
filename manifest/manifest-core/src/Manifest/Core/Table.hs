{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

module Manifest.Core.Table
  ( Serial
  , PrimaryKey
  , Exposed
  , Base
  , Field
  , Nullable
  , FieldMeta(..)
  ) where

import Data.Functor.Identity (Identity)
import Data.Kind (Type)
import Manifest.Core.SqlType (SqlType(..))
import Manifest.Core.Codec (DbType(..), Codec(..))

-- | Marker: an auto-incrementing serial column whose runtime type is @a@.
data Serial a

-- | Marker: a primary-key column wrapping inner marker/type @a@.
data PrimaryKey a

-- | The metadata context. @Field Exposed a = Exposed a@ keeps the marker visible
-- to the deriver, where @Field Identity a@ erases it.
data Exposed a

-- | Strip markers down to the runtime base type.
type family Base (a :: Type) :: Type where
  Base (PrimaryKey a) = Base a
  Base (Serial a)     = a
  Base a              = a

-- | Per-context column type. SP1 instantiates only Identity (runtime value) and
-- Exposed (metadata). The query-expression context is added in SP4.
type family Field (f :: Type -> Type) (a :: Type) :: Type where
  Field Identity a = Base a
  Field Exposed  a = Exposed a

-- | Marker alias for a nullable column.
type Nullable a = Maybe a

-- | Reflect a field's PK/serial flags + SQL type/nullability from its marker
-- structure (used by the deriver).
class FieldMeta a where
  fieldIsPK     :: Bool
  fieldIsSerial :: Bool
  fieldSqlType  :: SqlType
  fieldNullable :: Bool

instance FieldMeta a => FieldMeta (PrimaryKey a) where
  fieldIsPK     = True
  fieldIsSerial = fieldIsSerial @a
  fieldSqlType  = fieldSqlType @a
  fieldNullable = False                      -- a PK is NOT NULL

instance FieldMeta (Serial a) where
  fieldIsPK     = False
  fieldIsSerial = True
  fieldSqlType  = SqlBigSerial
  fieldNullable = False

instance {-# OVERLAPPABLE #-} DbType a => FieldMeta a where
  fieldIsPK     = False
  fieldIsSerial = False
  fieldSqlType  = cSqlType  (dbType @a)
  fieldNullable = cNullable (dbType @a)
