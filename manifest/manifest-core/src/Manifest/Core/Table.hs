{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
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
  , Touched
  , References
  , Default
  , Secret
  , ReadOnly
  , Create
  , Update
  , Patch(..)
  , Table(..)
  , PrimKey
  , GPrimKeyType
  ) where

import Data.Functor.Identity (Identity)
import Data.Kind (Type)
import GHC.Generics (Rep, D1, C1, S1, Rec0, (:*:))
import GHC.TypeLits (Symbol, TypeError, ErrorMessage(..))
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

-- | Marker: a server-generated column that is also re-stamped on every UPDATE
-- (e.g. @updated_at TIMESTAMPTZ NOT NULL DEFAULT now()@). Like 'Generated' for
-- Create/Read/Update projections; additionally the deriver flags it so
-- 'Manifest.Core.Sql.renderUpdate' appends @<col> = now()@ to every UPDATE.
data Touched a

-- | Marker: a column with a server-side DEFAULT that may be omitted on insert.
data Default a

-- | Marker: a column whose value is masked at serialization (JSON/Show/logs) via
-- 'Manifest.Core.Secret.Masked'. NOT a DB-presence policy — a Secret column is read
-- and written to the database normally.
data Secret a

-- | Marker: a column that is read-only (never written by the application).
data ReadOnly a

-- | Marker: a foreign-key column referencing entity @t@. The column's runtime
-- value is @t@'s primary key (@Base (References t) = PrimKey t@); the migration
-- engine emits a @REFERENCES t(pk)@ constraint. Nullable (optional) FKs compose
-- with 'Nullable': @Nullable (References t)@.
data References (t :: Type)

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
  Base (Touched a)    = Base a
  Base (Default a)    = Base a
  Base (Secret a)     = Base a
  Base (ReadOnly a)   = Base a
  Base (References t) = PrimKey t
  Base (Maybe a)      = Maybe (Base a)
  Base a              = a

-- | Per-context column type. Closed family: specific clauses before catch-alls.
type family Field (f :: Type -> Type) (a :: Type) :: Type where
  Field Identity a = Base a
  Field Exposed  a = Exposed a
  -- Create: DB-assigned keys/cols absent; Default optional; app-supplied present
  Field Create (PrimaryKey (Serial a))    = Omitted
  Field Create (PrimaryKey (Generated a)) = Omitted
  Field Create (Generated a)              = Omitted
  Field Create (Touched a)                = Omitted
  Field Create (ReadOnly a)               = Omitted
  Field Create (Default a)                = Maybe (Base a)
  Field Create (PrimaryKey a)             = Base a
  Field Create a                          = Base a
  -- Update: PK is the key (never SET); DB-owned absent; rest -> Patch
  Field Update (PrimaryKey a) = Omitted
  Field Update (Generated a)  = Omitted
  Field Update (Touched a)    = Omitted
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
  -- | True only for 'Touched': the column is re-stamped @= now()@ on every UPDATE.
  fieldTouchedOnUpdate :: Bool
  fieldTouchedOnUpdate = False

instance FieldMeta a => FieldMeta (PrimaryKey a) where
  fieldIsPK = True; fieldIsSerial = fieldIsSerial @a; fieldIsGenerated = fieldIsGenerated @a
  fieldSqlType = fieldSqlType @a; fieldNullable = False

instance FieldMeta (Serial a) where
  fieldIsPK = False; fieldIsSerial = True; fieldIsGenerated = True
  fieldSqlType = SqlBigSerial; fieldNullable = False

instance FieldMeta a => FieldMeta (Generated a) where
  fieldIsPK = False; fieldIsSerial = fieldIsSerial @a; fieldIsGenerated = True
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance FieldMeta a => FieldMeta (Touched a) where
  fieldIsPK = False; fieldIsSerial = fieldIsSerial @a; fieldIsGenerated = True
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a
  fieldTouchedOnUpdate = True

instance FieldMeta a => FieldMeta (Default a) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance FieldMeta a => FieldMeta (Secret a) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance FieldMeta a => FieldMeta (ReadOnly a) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance DbType (PrimKey t) => FieldMeta (References t) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldNullable = False
  fieldSqlType = cSqlType (dbType @(PrimKey t))

instance DbType (PrimKey t) => FieldMeta (Maybe (References t)) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldNullable = True
  fieldSqlType = cSqlType (dbType @(PrimKey t))

instance {-# OVERLAPPABLE #-} DbType a => FieldMeta a where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = cSqlType  (dbType @a); fieldNullable = cNullable (dbType @a)

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
  -- 4+ fields produce a balanced product tree, so the first field sits at the
  -- left spine of a nested @:*:@; recurse left to reach it.
  GPrimKeyType ((l :*: r) :*: rest) = GPrimKeyType (l :*: r)
  GPrimKeyType ((S1 m (Rec0 (Exposed inner))) :*: rest) = Base inner
  GPrimKeyType (S1 m (Rec0 (Exposed inner)))            = Base inner
  GPrimKeyType other =
    TypeError ('Text "Manifest: an entity must be a single-constructor record with its primary key as the first field")
