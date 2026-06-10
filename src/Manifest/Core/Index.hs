{-# LANGUAGE ExistentialQuantification #-}

module Manifest.Core.Index
  ( IndexMethod(..)
  , methodSql
  , IndexDef(..)
  , Index(..)
  , SomeColumn(..)
  ) where

import Data.ByteString (ByteString)
import Manifest.Core.Query (Column(..))

-- | The access method for an index.
data IndexMethod = Gin | Btree deriving (Eq, Show)

-- | The SQL keyword for an index access method.
methodSql :: IndexMethod -> ByteString
methodSql Gin   = "gin"
methodSql Btree = "btree"

-- | An entity-erased index definition. The name is derived later (when the
-- table is known), in 'Manifest.Migrate.managed'.
data IndexDef = IndexDef
  { idxName    :: ByteString
  , idxMethod  :: IndexMethod
  , idxUnique  :: Bool
  , idxColumns :: [ByteString]
  } deriving (Eq, Show)

-- | An index attached to entity @a@ (phantom). Carries the method, a uniqueness
-- flag, and the column name(s) until 'Manifest.Migrate.managed' names it. Built
-- with the "Manifest.Index" DSL.
newtype Index a = Index { indexSpec :: (IndexMethod, Bool, [ByteString]) }

-- | A column of entity @a@ with its value type erased, so a heterogeneous list
-- of columns (e.g. @[#a, #b]@) can be passed to a multi-column index builder.
data SomeColumn a = forall t. SomeColumn (Column a t)
