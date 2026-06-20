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
  , Omitted(..)
  , Generated
  , Default
  , Secret
  , ReadOnly
  ) where

import Data.Functor.Identity (Identity)
import Data.Kind (Type)
import Manifest.Core.SqlType (SqlType(..))
import Manifest.Core.Codec (DbType(..), Codec(..))

-- | Marker: an auto-incrementing serial column whose runtime type is @a@.
data Serial a

-- | Marker: a primary-key column wrapping inner marker/type @a@.
data PrimaryKey a

-- | Filler for omitted fields in partial HKD payloads.
data Omitted = Omitted deriving (Eq, Show)

-- | Marker: a server-generated column (e.g. @DEFAULT gen_random_uuid()@).
data Generated a

-- | Marker: a column with a server-side DEFAULT that may be omitted on insert.
data Default a

-- | Marker: a column that should not be included in query results by default.
data Secret a

-- | Marker: a column that is read-only (never written by the application).
data ReadOnly a

-- | The metadata context. @Field Exposed a = Exposed a@ keeps the marker visible
-- to the deriver, where @Field Identity a@ erases it.
data Exposed a

-- | Strip markers down to the runtime base type.
type family Base (a :: Type) :: Type where
  Base (PrimaryKey a) = Base a
  Base (Serial a)     = a
  Base (Generated a)  = Base a
  Base (Default a)    = Base a
  Base (Secret a)     = Base a
  Base (ReadOnly a)   = Base a
  Base a              = a

-- | Per-context column type. SP1 instantiates only Identity (runtime value) and
-- Exposed (metadata). The query-expression context is added in SP4.
type family Field (f :: Type -> Type) (a :: Type) :: Type where
  Field Identity a = Base a
  Field Exposed  a = Exposed a

-- | Marker alias for a nullable column.
type Nullable a = Maybe a

-- | Reflect a field's PK/serial/generated flags + SQL type/nullability from its
-- marker structure (used by the deriver).
class FieldMeta a where
  fieldIsPK        :: Bool
  fieldIsSerial    :: Bool
  fieldIsGenerated :: Bool
  fieldSqlType     :: SqlType
  fieldNullable    :: Bool

instance FieldMeta a => FieldMeta (PrimaryKey a) where
  fieldIsPK = True; fieldIsSerial = fieldIsSerial @a; fieldIsGenerated = fieldIsGenerated @a
  fieldSqlType = fieldSqlType @a; fieldNullable = False

instance FieldMeta (Serial a) where
  fieldIsPK = False; fieldIsSerial = True; fieldIsGenerated = True
  fieldSqlType = SqlBigSerial; fieldNullable = False

instance FieldMeta a => FieldMeta (Generated a) where
  fieldIsPK = False; fieldIsSerial = fieldIsSerial @a; fieldIsGenerated = True
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance FieldMeta a => FieldMeta (Default a) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance FieldMeta a => FieldMeta (Secret a) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance FieldMeta a => FieldMeta (ReadOnly a) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance {-# OVERLAPPABLE #-} DbType a => FieldMeta a where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = cSqlType  (dbType @a); fieldNullable = cNullable (dbType @a)
