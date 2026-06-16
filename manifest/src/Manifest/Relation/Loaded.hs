{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
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
  , joined
  , Insert
  , with
  , Member
  , rel
  ) where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.Dynamic (Dynamic, fromDynamic, toDyn)
import Data.Kind (Constraint, Type)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (listToMaybe)
import Data.Proxy (Proxy(..))
import Data.Typeable (Typeable)
import GHC.TypeError (Unsatisfiable, ErrorMessage(..))
import GHC.TypeLits (CmpSymbol, KnownSymbol, Symbol, symbolVal)
import Manifest.Core.Codec (SqlParam, DbType)
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..), pkColumn)
import Manifest.Core.Query (Rel)
import Manifest.Core.Relation (HasRelation(..), RelSpec(..))
import Manifest.Core.Sql (renderJoined)
import Manifest.Entity (Entity, Key, PrimKey, pkIndex, pkParam, tableMeta)
import Manifest.Error (DbError(OtherError), DbException(..))
import Manifest.Relation (loadRel)
import Manifest.Session (Db, decodeRowDb, execDb, get, setBaseline)

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
getEnt :: (Entity a, DbType (PrimKey a)) => Key a -> Db (Maybe (Ent '[] a))
getEnt k = fmap manage <$> get k

-- | A loading strategy for relation @name@.
data Strategy (name :: Symbol) = Selectin | Joined

-- | The default strategy: a separate SELECT per relation.
selectin :: Rel a name -> Strategy name
selectin _ = Selectin

-- | The @joined@ strategy: a single LEFT JOIN, decoded NULL-aware.
joined :: Rel a name -> Strategy name
joined _ = Joined

-- | Add @name@ to the load-set (simple prepend; membership is all that matters).
type family Insert (name :: Symbol) (loaded :: [Symbol]) :: [Symbol] where
  Insert name loaded = name ': loaded

-- | Load relation @name@ onto an 'Ent', recording it in the load-set phantom.
with :: forall name a l.
        (HasRelation a name, KnownSymbol name, Typeable (Related a name))
     => Strategy name -> Ent l a -> Db (Ent (Insert name l) a)
with strat (Ent v rels) = do
  t <- case strat of
         Selectin -> loadRel    @a @name v
         Joined   -> joinedLoad @a @name v
  pure (Ent v (Map.insert (symbolVal (Proxy @name)) (toDyn t) rels))

-- | The @joined@ strategy execution: load relation @name@ via a single LEFT
-- JOIN that pins the owning row by its PK, then decode the child/target portion
-- of each row (skipping LEFT-JOIN misses), wrapping by cardinality.
joinedLoad :: forall a name. (HasRelation a name) => a -> Db (Related a name)
joinedLoad parent = case relSpec @a @name of
  RelMany childFk -> joinReverse childFk parent
  RelOpt  childFk -> listToMaybe <$> joinReverse childFk parent
  RelOne  selfFk  -> do
    rs <- joinForward selfFk parent
    case rs of
      (x : _) -> pure x
      []      -> liftIO (throwIO (DbException (OtherError "belongs-to (joined): target row missing")))
  RelOptOne selfFk -> listToMaybe <$> joinForward selfFk parent

-- | Reverse FK (has-many / has-opt): @SELECT child cols FROM self LEFT JOIN
-- child ON child.<fk> = self.<pk> WHERE self.<pk> = $1@, decoded NULL-aware.
joinReverse :: forall a c. (Entity a, Entity c) => ByteString -> a -> Db [c]
joinReverse childFk parent = do
  let selfTm  = tableMeta @a
      childTm = tableMeta @c
      sql = renderJoined (tmTable selfTm) (cmName (pkColumn selfTm))
                         (tmTable childTm) (map cmName (tmColumns childTm))
                         childFk (cmName (pkColumn selfTm))
  rows <- execDb sql [pkParam parent]
  decodeJoinRows @c rows

-- | Forward FK (belongs-to): @SELECT target cols FROM self LEFT JOIN target ON
-- target.<pk> = self.<fk> WHERE self.<pk> = $1@, decoded NULL-aware.
joinForward :: forall a c. (Entity a, Entity c) => ByteString -> a -> Db [c]
joinForward selfFk parent = do
  let selfTm = tableMeta @a
      tgtTm  = tableMeta @c
      sql = renderJoined (tmTable selfTm) (cmName (pkColumn selfTm))
                         (tmTable tgtTm) (map cmName (tmColumns tgtTm))
                         (cmName (pkColumn tgtTm)) selfFk
  rows <- execDb sql [pkParam parent]
  decodeJoinRows @c rows

-- | Decode child rows from a LEFT JOIN, skipping misses (child PK column is
-- @NULL@), and register each surviving child so joined-loaded children are
-- managed (consistent with selectin).
decodeJoinRows :: forall c. Entity c => [[SqlParam]] -> Db [c]
decodeJoinRows rows = do
  let pkIx = pkIndex @c
  fmap concat $ mapM (\row ->
    if (row !! pkIx) == Nothing
      then pure []
      else do child <- decodeRowDb @c row; setBaseline child; pure [child]) rows

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
       , Typeable (Related a name)
       )
    => Rel a name -> Ent loaded a -> Related a name
rel _ (Ent _ rels) =
  case Map.lookup (symbolVal (Proxy @name)) rels >>= fromDynamic of
    Just t  -> t
    Nothing -> error "Manifest: internal invariant — Member held but relation absent in RelMap"
