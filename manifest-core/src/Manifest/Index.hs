{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Manifest.Index
  ( gin
  , btree
  , unique
  ) where

import Data.Proxy (Proxy(..))
import GHC.OverloadedLabels (IsLabel(..))
import GHC.TypeLits (KnownSymbol, symbolVal)
import Manifest.Core.Index (Index(..), IndexMethod(..), SomeColumn(..))
import Manifest.Core.Meta (camelToSnake)
import Manifest.Core.Query (Column(..))

-- | A GIN index on a column (e.g. a @jsonb@ column, so @\@>@ containment uses
-- an index).
gin :: Column a t -> Index a
gin (Column c) = Index (Gin, False, [c])

-- | An ordinary B-tree index on a column.
btree :: Column a t -> Index a
btree (Column c) = Index (Btree, False, [c])

-- | A @#label@ used as a type-erased column, so a multi-column index builder can
-- take a heterogeneous list @[#a, #b]@.
instance KnownSymbol name => IsLabel name (SomeColumn a) where
  fromLabel = SomeColumn (Column (camelToSnake (symbolVal (Proxy @name))))

-- | A UNIQUE composite B-tree index over the given columns:
-- @unique [#a, #b]@ → @CREATE UNIQUE INDEX … (a, b)@.
unique :: [SomeColumn a] -> Index a
unique cols = Index (Btree, True, [ c | SomeColumn (Column c) <- cols ])
