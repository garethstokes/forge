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
  ) where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.Maybe (listToMaybe)
import Manifest.Core.Codec (SqlParam)
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..), pkColumn)
import Manifest.Core.Query (Rel, Cond(..), Op(..))
import Manifest.Core.Relation (HasRelation(..), RelSpec(..))
import Manifest.Core.Sql (renderSelect)
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

-- | The encoded value of column @col@ on @parent@ (looked up by name in tableMeta).
colValueOf :: forall a. Entity a => ByteString -> a -> SqlParam
colValueOf col parent =
  case [v | (c, v) <- zip (tmColumns (tableMeta @a)) (rowEncode parent), cmName c == col] of
    (v : _) -> v
    []      -> error ("Manifest: column " <> show col <> " not found on entity")
