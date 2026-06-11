module Manifest.Core.Cascade
  ( OnDelete(..)
  , CascadeRule(..)
  ) where

import Data.ByteString (ByteString)

-- | What happens to a relation's children when the parent is deleted.
data OnDelete = Cascade | SetNull | Restrict
  deriving (Eq, Show)

-- | A resolved cascade: the child table, the child FK column that references
-- the parent's PK, and the policy — plus what the recursive walk needs: the
-- child's own PK column (for scope subqueries) and the child's OWN cascade
-- rules, captured lazily. Built by 'Manifest.Core.Relation.cascade'.
--
-- 'crChildRules' is potentially INFINITE for self-referential or mutually
-- recursive entities — never force it whole. 'Eq'/'Show' are hand-written
-- over the finite fields for the same reason.
data CascadeRule = CascadeRule
  { crChildTable :: ByteString
  , crFkColumn   :: ByteString
  , crPolicy     :: OnDelete
  , crChildPk    :: ByteString
  , crChildRules :: [CascadeRule]
  }

instance Eq CascadeRule where
  a == b =
    (crChildTable a, crFkColumn a, crPolicy a, crChildPk a)
      == (crChildTable b, crFkColumn b, crPolicy b, crChildPk b)

instance Show CascadeRule where
  show r =
    "CascadeRule " <> show (crChildTable r) <> " " <> show (crFkColumn r)
      <> " " <> show (crPolicy r) <> " " <> show (crChildPk r) <> " <child rules>"
