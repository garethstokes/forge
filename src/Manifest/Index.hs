{-# LANGUAGE ScopedTypeVariables #-}

module Manifest.Index
  ( gin
  , btree
  ) where

import Manifest.Core.Index (Index(..), IndexMethod(..))
import Manifest.Core.Query (Column(..))

-- | A GIN index on a column (e.g. a @jsonb@ column, so @\@>@ containment uses
-- an index).
gin :: Column a t -> Index a
gin (Column c) = Index (Gin, [c])

-- | An ordinary B-tree index on a column.
btree :: Column a t -> Index a
btree (Column c) = Index (Btree, [c])
