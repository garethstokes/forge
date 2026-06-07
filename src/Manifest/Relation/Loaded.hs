{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Manifest.Relation.Loaded
  ( Ent(..)
  , RelMap
  , manage
  , getEnt
  , Strategy
  , selectin
  , Insert
  , with
  ) where

import Data.Dynamic (Dynamic, toDyn)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Proxy (Proxy(..))
import Data.Typeable (Typeable)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
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
