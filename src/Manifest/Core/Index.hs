module Manifest.Core.Index
  ( IndexMethod(..)
  , methodSql
  , IndexDef(..)
  , Index(..)
  ) where

import Data.ByteString (ByteString)

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
  , idxColumns :: [ByteString]
  } deriving (Eq, Show)

-- | An index attached to entity @a@ (phantom). Carries the method + the
-- column name(s) until 'Manifest.Migrate.managed' names it. Built with the
-- "Manifest.Index" DSL.
newtype Index a = Index { indexSpec :: (IndexMethod, [ByteString]) }
