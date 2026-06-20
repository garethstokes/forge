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
  , Create
  , Update
  , Patch(..)
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

-- | HKD context tag: the payload used when creating a new row.
data Create a

-- | HKD context tag: the payload used when updating an existing row.
data Update a

-- | Represents an optional field update: keep the current value or set a new one.
data Patch a = Keep | Set a deriving (Eq, Show)

-- | Strip markers down to the runtime base type.
type family Base (a :: Type) :: Type where
  Base (PrimaryKey a) = Base a
  Base (Serial a)     = a
  Base (Generated a)  = Base a
  Base (Default a)    = Base a
  Base (Secret a)     = Base a
  Base (ReadOnly a)   = Base a
  Base a              = a

-- | Per-context column type. Closed family: specific clauses before catch-alls.
type family Field (f :: Type -> Type) (a :: Type) :: Type where
  Field Identity a = Base a
  Field Exposed  a = Exposed a
  -- Create: DB-assigned keys/cols absent; Default optional; app-supplied present
  Field Create (PrimaryKey (Serial a))    = Omitted
  Field Create (PrimaryKey (Generated a)) = Omitted
  Field Create (Generated a)              = Omitted
  Field Create (ReadOnly a)               = Omitted
  Field Create (Default a)                = Maybe (Base a)
  Field Create (PrimaryKey a)             = Base a
  Field Create a                          = Base a
  -- Update: PK is the key (never SET); DB-owned absent; rest -> Patch
  Field Update (PrimaryKey a) = Omitted
  Field Update (Generated a)  = Omitted
  Field Update (ReadOnly a)   = Omitted
  Field Update a              = Patch (Base a)

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
