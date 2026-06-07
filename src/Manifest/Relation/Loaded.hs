{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Manifest.Relation.Loaded
  ( Ent(..)
  , RelMap
  , manage
  , getEnt
  , Strategy
  , selectin
  , Insert
  , with
  , Member
  , rel
  ) where

import Data.Dynamic (Dynamic, fromDynamic, toDyn)
import Data.Kind (Constraint, Type)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Proxy (Proxy(..))
import Data.Typeable (Typeable)
import GHC.TypeError (Unsatisfiable, ErrorMessage(..))
import GHC.TypeLits (CmpSymbol, KnownSymbol, Symbol, symbolVal)
import Manifest.Core.Codec (ToField)
import Manifest.Core.Query (Rel)
import Manifest.Core.Relation (HasRelation(..))
import Manifest.Entity (Entity, Key, PrimKey)
import Manifest.Relation (loadRel)
import Manifest.Session (Db, get)

-- | Loaded relations, type-erased, keyed by relation name.
type RelMap = Map String Dynamic

-- | A value plus a type-level record of which relations have been loaded onto
-- it. The phantom @loaded@ rides on this wrapper ONLY — never on the bare @a@.
data Ent (loaded :: [Symbol]) a = Ent
  { entVal  :: a
  , entRels :: RelMap
  }

-- | Wrap a bare persistent value with an empty load-set.
manage :: a -> Ent '[] a
manage v = Ent v Map.empty

-- | Load by PK into the D path (nothing loaded yet).
getEnt :: (Entity a, ToField (PrimKey a)) => Key a -> Db (Maybe (Ent '[] a))
getEnt k = fmap manage <$> get k

-- | A loading strategy for relation @name@. SP2 core has only @selectin@.
data Strategy (name :: Symbol) = Selectin

-- | The default (and only, in SP2 core) strategy: a separate SELECT.
selectin :: Rel a name -> Strategy name
selectin _ = Selectin

-- | Add @name@ to the load-set (simple prepend; membership is all that matters).
type family Insert (name :: Symbol) (loaded :: [Symbol]) :: [Symbol] where
  Insert name loaded = name ': loaded

-- | Load relation @name@ onto an 'Ent', recording it in the load-set phantom.
with :: forall name a l.
        (HasRelation a name, KnownSymbol name, Typeable (Target a name))
     => Strategy name -> Ent l a -> Db (Ent (Insert name l) a)
with _ (Ent v rels) = do
  t <- loadRel @a @name v
  pure (Ent v (Map.insert (symbolVal (Proxy @name)) (toDyn t) rels))

-- | The custom message shown when reading a relation that isn't loaded.
type NotLoaded (name :: Symbol) (a :: Type) =
  'Text "Relation '" ':<>: 'Text name ':<>: 'Text "' is not loaded on this "
    ':<>: 'ShowType a ':<>: 'Text "."
  ':$$: 'Text "Add `with (selectin #" ':<>: 'Text name ':<>: 'Text ")`, "
    ':<>: 'Text "or call `load #" ':<>: 'Text name ':<>: 'Text " value` for the bare A-path."

-- | Holds iff @name@ is in the load-set; otherwise reduces to a custom
-- 'Unsatisfiable' constraint (membership-only; tracks Symbols, not types).
type Member :: Symbol -> [Symbol] -> Type -> Constraint
type family Member name loaded a where
  Member name '[]       a = Unsatisfiable (NotLoaded name a)
  Member name (x ': xs) a = MemberCmp (CmpSymbol name x) name xs a

type MemberCmp :: Ordering -> Symbol -> [Symbol] -> Type -> Constraint
type family MemberCmp o name xs a where
  MemberCmp 'EQ _    _  _ = ()
  MemberCmp _   name xs a = Member name xs a

-- | Read a loaded relation, totally. Only typechecks when @name@ is in the
-- load-set; the @Member@ constraint is the only user-visible failure surface.
rel :: forall name a loaded.
       ( HasRelation a name
       , Member name loaded a
       , Typeable (Target a name)
       )
    => Rel a name -> Ent loaded a -> Target a name
rel _ (Ent _ rels) =
  case Map.lookup (symbolVal (Proxy @name)) rels >>= fromDynamic of
    Just t  -> t
    Nothing -> error "Manifest: internal invariant — Member held but relation absent in RelMap"
