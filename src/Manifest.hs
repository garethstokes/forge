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
    -- * Query builder (table-handle)
  , QueryM
  , Handle
  , OptHandle
  , Projectable
  , Expr
  , from
  , withCte
  , fromCte
  , CteRef
  , innerJoin
  , leftJoin
  , rightJoin
  , fullJoin
  , opt
  , (^.)
  , val
  , (.==), (./=), (.>), (.<), (.&&)
  , where_
  , having
  , distinct
  , orderBy
  , asc
  , desc
  , limit
  , offset
  , groupBy
  , countRows
  , sum_
  , avg_
  , min_
  , max_
  , OrderTerm
  , Selectable (Result)
  , runQuery
    -- * Relationships (A path)
  , load
  , loadNested
  , (./)
  , Path
  , HasRelation(..)
  , Card(..)
    -- * Cascades (onDelete)
  , OnDelete(..)
  , CascadeRule(..)
  , cascade
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
  , genericTableMeta
  , genericRowDecoder
  , genericRowEncode
    -- * Template Haskell front-end
  , mkEntity
  , field
    -- * Connection pool
  , newPool
  , closePool
    -- * Migrations
  , ManagedTable(..)
  , managed
  , migrate
  , migrateUp
  , runMigrate
  , MigrationPlan(..)
  , TableDiff(..)
  , diffTable
  , renderCreateTable
  , renderAddColumn
  , liveColumns
  , tableExists
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
import Manifest.Query
  ( QueryM, Handle, OptHandle, Projectable, Expr, from
  , withCte, fromCte, CteRef, innerJoin, leftJoin, rightJoin, fullJoin, opt, (^.), val
  , (.==), (./=), (.>), (.<), (.&&), where_, having, distinct, orderBy, asc, desc
  , limit, offset, groupBy, countRows, sum_, avg_, min_, max_
  , OrderTerm, Selectable (Result), runQuery )
import Manifest.Core.Relation
  ( HasRelation(..)
  , Card(..)
  , cascade
  )
import Manifest.Core.Cascade
  ( OnDelete(..)
  , CascadeRule(..)
  )
import Manifest.Relation
  ( load
  , loadNested
  , (./)
  , Path
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
import Manifest.Core.Meta
  ( genericTableMeta
  )
import Manifest.Entity
  ( Entity(..)
  , Key(..)
  , genericRowDecoder
  , genericRowEncode
  )
import Manifest.Derive.TH
  ( mkEntity
  , field
  )
import Manifest.Postgres
  ( newPool
  , closePool
  )
import Manifest.Migrate
  ( ManagedTable(..)
  , managed
  , migrate
  , migrateUp
  , runMigrate
  , MigrationPlan(..)
  , TableDiff(..)
  , diffTable
  , renderCreateTable
  , renderAddColumn
  , liveColumns
  , tableExists
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
