module Manifest.Core.Cascade
  ( OnDelete(..)
  , CascadeRule(..)
  ) where

import Data.ByteString (ByteString)

-- | What happens to a relation's children when the parent is deleted.
data OnDelete = Cascade | SetNull | Restrict
  deriving (Eq, Show)

-- | A resolved cascade: the child table, the child FK column that references
-- the parent's PK, and the policy. Built by 'Manifest.Core.Relation.cascade'.
data CascadeRule = CascadeRule
  { crChildTable :: ByteString
  , crFkColumn   :: ByteString
  , crPolicy     :: OnDelete
  } deriving (Eq, Show)
