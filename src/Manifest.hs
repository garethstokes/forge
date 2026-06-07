-- | Manifest — the Unit-of-Work layer Haskell never had.
--
-- This is the public umbrella module. It re-exports the curated public
-- surface from the underlying @Manifest.*@ modules so that downstream code
-- (and the end-to-end worked example) only needs to @import Manifest@.
module Manifest
  ( -- * Session & transactions
    Db
  , withSession
  , withTransaction
  , flush
  , statementLog
    -- * Reads
  , get
  , selectWhere
    -- * Snapshot-diff path
  , add
  , save
  , delete
    -- * Command path
  , update
  , deleteWhere
    -- * Entities & keys
  , Entity(..)
  , Key(..)
    -- * Query DSL
  , Column(..)
  , Rel(..)
  , Cond(..)
  , Assign(..)
  , (==.)
  , (/=.)
  , (>.)
  , (<.)
  , (=.)
    -- * Relationships (A path)
  , load
  , HasRelation(..)
  , Card(..)
    -- * Relationships (D path)
  , Ent(..)
  , manage
  , getEnt
  , with
  , selectin
  , joined
  , rel
  , Member
    -- * Table metadata
  , Serial
  , PrimaryKey
  , Col
    -- * Errors
  , DbError(..)
  , DbException(..)
  ) where

import Manifest.Core.Query
  ( Column(..)
  , Rel(..)
  , Cond(..)
  , Assign(..)
  , (==.)
  , (/=.)
  , (>.)
  , (<.)
  , (=.)
  )
import Manifest.Core.Relation
  ( HasRelation(..)
  , Card(..)
  )
import Manifest.Relation
  ( load
  )
import Manifest.Relation.Loaded
  ( Ent(..)
  , manage
  , getEnt
  , with
  , selectin
  , joined
  , rel
  , Member
  )
import Manifest.Core.Table
  ( Serial
  , PrimaryKey
  , Col
  )
import Manifest.Entity
  ( Entity(..)
  , Key(..)
  )
import Manifest.Error
  ( DbError(..)
  , DbException(..)
  )
import Manifest.Session
  ( Db
  , withSession
  , withTransaction
  , flush
  , statementLog
  , get
  , selectWhere
  , add
  , save
  , delete
  )
import Manifest.Session.Command
  ( update
  , deleteWhere
  )
