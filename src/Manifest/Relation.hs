{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Manifest.Relation
  ( load
  , loadRel
  , Path
  , (./)
  , loadNested
  ) where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Maybe (listToMaybe)
import GHC.TypeLits (Symbol)
import Manifest.Core.Codec (SqlParam)
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..), pkColumn)
import Manifest.Core.Query (Rel, Cond(..), Op(..))
import Manifest.Core.Relation (HasRelation(..), RelSpec(..))
import Manifest.Core.Sql (bcIntercalate, renderSelect)
import Manifest.Entity (Entity(..), pkParam)
import Manifest.Error (DbError(OtherError), DbException(..))
import Manifest.Session (Db, decodeRowDb, execDb, setBaseline)

-- | Load relation @name@ off a bare value (the A path). Zero type-level
-- tracking; returns the plain 'Target' ([Post] / Maybe Profile).
load :: forall a name. (HasRelation a name) => Rel a name -> a -> Db (Target a name)
load _ = loadRel @a @name

-- | The strategy execution shared by the A and D paths: run a separate SELECT
-- for the children (the @selectin@ strategy) and wrap by cardinality.
loadRel :: forall a name. (HasRelation a name) => a -> Db (Target a name)
loadRel parent = case relSpec @a @name of
  RelMany childFk -> selectByKey childFk (pkParam parent)
  RelOpt  childFk -> listToMaybe <$> selectByKey childFk (pkParam parent)
  RelOne  selfFk  -> loadOne selfFk parent
  RelOptOne selfFk -> loadOptOne selfFk parent

-- | The forward-FK (belongs-to) loader: SELECT the target whose PK equals the
-- parent's value at the self FK column, returning the single row (throwing if
-- the referenced target is missing). @c@ is the target type, brought into scope
-- as a named type variable from the 'RelOne' GADT match.
loadOne :: forall a c. (Entity a, Entity c) => ByteString -> a -> Db c
loadOne selfFk parent = do
  let targetPkCol = cmName (pkColumn (tableMeta @c))
  one <- selectByKey @c targetPkCol (colValueOf @a selfFk parent)
  case one of
    (x : _) -> pure x
    []      -> liftIO (throwIO (DbException (OtherError "belongs-to: target row missing")))

-- | The forward-FK, nullable (belongs-to-maybe) loader: a NULL self-FK yields
-- 'Nothing'; otherwise SELECT the target by its PK and take the first row (if
-- any). @c@ is the target type, named via the top-level @forall@ so @\@c@ is
-- nameable (the GADT @c@ can't be named inline).
loadOptOne :: forall a c. (Entity a, Entity c) => ByteString -> a -> Db (Maybe c)
loadOptOne selfFk parent =
  case colValueOf @a selfFk parent of
    Nothing -> pure Nothing                                   -- self FK is NULL → no manager
    fkVal   -> listToMaybe <$> selectByKey @c (cmName (pkColumn (tableMeta @c))) fkVal

-- | @SELECT <child cols> FROM <child> WHERE <keyCol> = $1@, decoding each row and
-- registering it in the identity map (so loaded children are managed and flow
-- through snapshot-diff on a later 'Manifest.Session.save'). Shared by every
-- cardinality's selectin loader.
selectByKey :: forall c. Entity c => ByteString -> SqlParam -> Db [c]
selectByKey keyCol keyVal = do
  let tm  = tableMeta @c
      sql = renderSelect tm [Cond keyCol OpEq keyVal]
  rows <- execDb sql [keyVal]
  mapM (\row -> do child <- decodeRowDb @c row; setBaseline child; pure child) rows

-- | A two-level load path: relation @n1@ on @a@, then relation @n2@ on its
-- elements (@mid@). Phantom; carries only the type-level shape.
data Path a (n1 :: Symbol) mid (n2 :: Symbol) = Path

-- | Compose two relation labels into a nested path: @#posts ./ #comments@.
(./) :: Rel a n1 -> Rel mid n2 -> Path a n1 mid n2
_ ./ _ = Path
infixr 5 ./

-- | @SELECT <child cols> FROM <child> WHERE <keyCol> IN ($1,...)@ — one batched
-- query for the children of MANY parents; decodes + registers each (so loaded
-- rows are managed). An empty key list short-circuits to @[]@ (no query).
selectByKeyIn :: forall c. Entity c => ByteString -> [SqlParam] -> Db [c]
selectByKeyIn _ [] = pure []
selectByKeyIn keyCol keyVals = do
  let tm    = tableMeta @c
      cols  = bcIntercalate ", " (map cmName (tmColumns tm))
      phs   = bcIntercalate ", " [BC.pack ('$' : show i) | i <- [1 .. length keyVals]]
      sql   = "SELECT " <> cols <> " FROM " <> tmTable tm <> " WHERE " <> keyCol <> " IN (" <> phs <> ")"
  rows <- execDb sql keyVals
  mapM (\row -> do c <- decodeRowDb @c row; setBaseline c; pure c) rows

-- | One-level nested load (both levels to-many), batched: load the mids via
-- @loadRel \@a \@n1@, then issue a SINGLE @WHERE leafFk IN (…)@ query for all of
-- their leaves, grouping each leaf under its parent mid by matching the leaf's
-- FK to the mid's PK. The @RelMany@ match binds the leaf existential; the result
-- type @[(mid,[leaf])]@ ties it to @leaf@ via @selectByKeyIn@ (no @\@leaf@ needed
-- on the existential). Non-Many leaf relations are rejected at runtime.
loadNested
  :: forall a n1 mid n2 leaf.
     ( HasRelation a n1, Target a n1 ~ [mid], Entity mid
     , HasRelation mid n2, Target mid n2 ~ [leaf], Entity leaf )
  => Path a n1 mid n2 -> a -> Db [(mid, [leaf])]
loadNested _ parent = do
  mids <- loadRel @a @n1 parent                  -- [mid]
  case relSpec @mid @n2 of
    RelMany leafFk -> do
      leaves <- selectByKeyIn leafFk (map pkParam mids)
      pure [ (m, [ l | l <- leaves, colValueOf leafFk l == pkParam m ]) | m <- mids ]
    _ -> liftIO (throwIO (DbException (OtherError "loadNested: leaf relation must be to-many (Many) in this MVP")))

-- | The encoded value of column @col@ on @parent@ (looked up by name in tableMeta).
colValueOf :: forall a. Entity a => ByteString -> a -> SqlParam
colValueOf col parent =
  case [v | (c, v) <- zip (tmColumns (tableMeta @a)) (rowEncode parent), cmName c == col] of
    (v : _) -> v
    []      -> error ("Manifest: column " <> show col <> " not found on entity")
