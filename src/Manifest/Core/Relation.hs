{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Manifest.Core.Relation
  ( Card(..)
  , HasRelation(..)
  , RelSpec(..)
  , belongsTo
  , belongsToMaybe
  , cascade
  , hasMany
  , hasOpt
  ) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Proxy (Proxy(..))
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Manifest.Core.Cascade (CascadeRule(..), OnDelete)
import Manifest.Core.Meta (camelToSnake, cmName, pkColumn, tmTable)
import Manifest.Entity (Entity, cascadeRules, tableMeta)

-- | Relationship cardinality (promoted to a kind via DataKinds).
data Card = Many | One | Opt
  deriving (Eq, Show)

-- | A relationship named @name@ on entity @a@. SP2 core supports the
-- \"FK on the child references the parent's PK\" shape (Many and Opt).
class (Entity a, KnownSymbol name) => HasRelation a (name :: Symbol) where
  type Related     a name :: Type   -- ^ [Post] / Maybe Profile
  type Cardinality a name :: Card   -- ^ 'Many / 'Opt
  relSpec :: RelSpec (Related a name)

-- | A relationship's runtime spec, indexed by its target type so the loader
-- is type-safe. Each carries the child's 'Entity' dictionary and the child
-- column (the FK) that holds the parent's PK value.
data RelSpec t where
  RelMany :: Entity c => ByteString -> RelSpec [c]
  RelOpt  :: Entity c => ByteString -> RelSpec (Maybe c)
  RelOne  :: Entity c => ByteString -> RelSpec c   -- forward FK: target.pk = self.<fk>
  RelOptOne :: Entity c => ByteString -> RelSpec (Maybe c)   -- forward FK, nullable target

-- | @hasMany #childFk@ — a to-many relationship whose child rows are those
-- with @child_fk = parent_pk@. The child type comes from the 'Related'.
hasMany :: forall c fk. (Entity c, KnownSymbol fk) => Proxy fk -> RelSpec [c]
hasMany _ = RelMany (camelToSnake (symbolVal (Proxy @fk)))

-- | @hasOpt #childFk@ — an optional to-one whose child (if any) has
-- @child_fk = parent_pk@.
hasOpt :: forall c fk. (Entity c, KnownSymbol fk) => Proxy fk -> RelSpec (Maybe c)
hasOpt _ = RelOpt (camelToSnake (symbolVal (Proxy @fk)))

-- | @belongsTo #selfFk@ — a to-one whose target is the row with
-- @target.pk = self.<selfFk>@ (a forward foreign key on the owning entity).
belongsTo :: forall c fk. (Entity c, KnownSymbol fk) => Proxy fk -> RelSpec c
belongsTo _ = RelOne (camelToSnake (symbolVal (Proxy @fk)))

-- | A nullable to-one via a forward FK: the target (if the self FK is set and
-- the row exists) is the one with @target.pk = self.<selfFk>@; otherwise 'Nothing'.
belongsToMaybe :: forall c fk. (Entity c, KnownSymbol fk) => Proxy fk -> RelSpec (Maybe c)
belongsToMaybe _ = RelOptOne (camelToSnake (symbolVal (Proxy @fk)))

-- | Declare a cascade rule for a reverse-FK relation: the @Child@ rows whose
-- @selfFk@ column references this entity's PK get @policy@ on delete. Derives
-- the child table + PK from @Entity Child@, the FK column name from the label,
-- and captures the child's own rules (lazily) so deletes recurse.
cascade :: forall c fk. (Entity c, KnownSymbol fk)
        => Proxy c -> Proxy fk -> OnDelete -> CascadeRule
cascade _ _ policy = CascadeRule
  { crChildTable = tmTable tm
  , crFkColumn   = camelToSnake (symbolVal (Proxy @fk))
  , crPolicy     = policy
  , crChildPk    = cmName (pkColumn tm)
  , crChildRules = cascadeRules @c
  }
  where tm = tableMeta @c
