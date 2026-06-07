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
  , Col
  , FieldMeta(..)
  ) where

import Data.Functor.Identity (Identity)
import Data.Kind (Type)

-- | Marker: an auto-incrementing serial column whose runtime type is @a@.
data Serial a

-- | Marker: a primary-key column wrapping inner marker/type @a@.
data PrimaryKey a

-- | The metadata context. @Col Exposed a = Exposed a@ keeps the marker visible
-- to the deriver, where @Col Identity a@ erases it.
data Exposed a

-- | Strip markers down to the runtime base type.
type family Base (a :: Type) :: Type where
  Base (PrimaryKey a) = Base a
  Base (Serial a)     = a
  Base a              = a

-- | Per-context column type. SP1 instantiates only Identity (runtime value) and
-- Exposed (metadata). The query-expression context is added in SP4.
type family Col (f :: Type -> Type) (a :: Type) :: Type where
  Col Identity a = Base a
  Col Exposed  a = Exposed a

-- | Reflect a field's PK/serial flags from its marker structure (used by the deriver).
class FieldMeta a where
  fieldIsPK     :: Bool
  fieldIsSerial :: Bool

instance FieldMeta a => FieldMeta (PrimaryKey a) where
  fieldIsPK     = True
  fieldIsSerial = fieldIsSerial @a

instance FieldMeta (Serial a) where
  fieldIsPK     = False
  fieldIsSerial = True

instance {-# OVERLAPPABLE #-} FieldMeta a where
  fieldIsPK     = False
  fieldIsSerial = False
