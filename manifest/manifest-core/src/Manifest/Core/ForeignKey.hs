{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Type-level reflection of an entity's foreign-key columns. Walks the
-- @Rep (t Exposed)@ and, for each 'References'-marked field, reads the target's
-- table + PK column from its 'Entity' dictionary. Lives above 'Entity' so it can
-- consult @tableMeta \@target@.
module Manifest.Core.ForeignKey
  ( GForeignKeys(..)
  , genericForeignKeys
  ) where

import Data.Kind (Type)
import GHC.Generics
import Manifest.Core.Meta (ForeignKey(..), camelToSnake, cmName, pkColumn, tmTable)
import Manifest.Core.Table (Exposed, References)
import Manifest.Entity (Entity, tableMeta)

class GForeignKeys (rep :: Type -> Type) where
  gForeignKeys :: [ForeignKey]

instance GForeignKeys f => GForeignKeys (D1 m f) where gForeignKeys = gForeignKeys @f
instance GForeignKeys f => GForeignKeys (C1 m f) where gForeignKeys = gForeignKeys @f
instance (GForeignKeys a, GForeignKeys b) => GForeignKeys (a :*: b) where
  gForeignKeys = gForeignKeys @a ++ gForeignKeys @b

-- A required FK field: Exposed (References target).
instance (Selector m, Entity target)
    => GForeignKeys (S1 m (Rec0 (Exposed (References target)))) where
  gForeignKeys =
    [ ForeignKey
        { fkColumn      = camelToSnake (selName (undefined :: S1 m (Rec0 (Exposed (References target))) p))
        , fkRefTable    = tmTable (tableMeta @target)
        , fkRefPkColumn = cmName (pkColumn (tableMeta @target))
        } ]

-- A nullable FK field: Exposed (Maybe (References target)).
instance (Selector m, Entity target)
    => GForeignKeys (S1 m (Rec0 (Exposed (Maybe (References target))))) where
  gForeignKeys =
    [ ForeignKey
        { fkColumn      = camelToSnake (selName (undefined :: S1 m (Rec0 (Exposed (Maybe (References target)))) p))
        , fkRefTable    = tmTable (tableMeta @target)
        , fkRefPkColumn = cmName (pkColumn (tableMeta @target))
        } ]

-- Any other field contributes no foreign key.
instance {-# OVERLAPPABLE #-} GForeignKeys (S1 m (Rec0 other)) where
  gForeignKeys = []

-- | An entity's foreign keys from the Generic rep of @t Exposed@.
genericForeignKeys
  :: forall t. (Generic (t Exposed), GForeignKeys (Rep (t Exposed))) => [ForeignKey]
genericForeignKeys = gForeignKeys @(Rep (t Exposed))
