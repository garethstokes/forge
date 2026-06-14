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
  , Table(..)
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
  , (?.)
  , Label(..)
  , FieldType
  , val
  , (.==), (./=), (.>), (.<), (.&&)
  , Jsonb
  , JsonbExpr
  , (.@>)
  , (.->)
  , (.->>)
  , (.#>)
  , (.#>>)
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
  , RelSpec(..)
  , Card(..)
  , hasMany
  , hasOpt
  , belongsTo
  , belongsToMaybe
    -- * Cascades (onDelete)
  , OnDelete(..)
  , CascadeRule(..)
  , cascade
    -- * Change feed
  , Change(..)
  , listenChanges
    -- * Relationships (D path)
  , Ent(..)
  , manage
  , getEnt
  , with
  , selectin
  , joined
  , rel
  , Member
    -- * Column-type classes (for newtype columns)
  , DbType (..)
  , Codec (..)
  , encode
  , dimap
  , lmap
  , rmap
  , refine
  , nullable
  , DecodeError (..)
  , SqlType (..)
    -- * JSONB columns
  , Json (..)
  , Aeson (..)
  , HasCodec (..)
    -- * Table metadata
  , Serial
  , PrimaryKey
  , Field
  , Pk
  , Nullable
  , TableMeta(..)
  , ColumnMeta(..)
  , genericTableMeta
  , camelToSnake
  , genericRowDecoder
  , genericRowEncode
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
  , renderCreateIndex
  , liveColumns
  , tableExists
    -- * Row-level security
  , Policy
  , PolicyCmd (..)
  , policy
  , using
  , withCheck
  , forCommand
  , Self
  , currentSetting
  , currentSettingOr
  , castText
  , lit
  , withRlsContext
    -- * Declarative indexes
  , IndexMethod (..)
  , Index
  , IndexDef (..)
  , SomeColumn (..)
  , gin
  , btree
  , unique
    -- * Errors
  , DbError(..)
  , DbException(..)
    -- * Testing helpers
  , withEphemeralDb
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
  , withCte, fromCte, CteRef, innerJoin, leftJoin, rightJoin, fullJoin, opt, (^.), (?.), Label(..), FieldType, val
  , (.==), (./=), (.>), (.<), (.&&), Jsonb, JsonbExpr, (.@>), (.->), (.->>), (.#>), (.#>>), where_, having, distinct, orderBy, asc, desc
  , limit, offset, groupBy, countRows, sum_, avg_, min_, max_
  , OrderTerm, Selectable (Result), runQuery, Self, currentSetting, currentSettingOr, castText, lit )
import Manifest.Core.Rls
  ( Policy, PolicyCmd (..) )
import Manifest.Rls
  ( policy, using, withCheck, forCommand )
import Manifest.Core.Index
  ( IndexMethod (..), Index, IndexDef (..), SomeColumn (..) )
import Manifest.Index
  ( gin, btree, unique )
import Manifest.Core.Relation
  ( HasRelation(..)
  , RelSpec(..)
  , Card(..)
  , cascade
  , hasMany
  , hasOpt
  , belongsTo
  , belongsToMaybe
  )
import Manifest.Core.Cascade
  ( OnDelete(..)
  , CascadeRule(..)
  )
import Manifest.Notify
  ( Change (..)
  , listenChanges
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
import Manifest.Core.Codec
  ( DbType (..)
  , Codec (..)
  , encode
  , dimap
  , lmap
  , rmap
  , refine
  , nullable
  )
import Manifest.Json
  ( Json (..)
  , Aeson (..)
  )
import Autodocodec
  ( HasCodec (..)
  )
import Manifest.Core.Table
  ( Serial
  , PrimaryKey
  , Field
  , Pk
  , Nullable
  )
import Manifest.Core.Meta
  ( TableMeta (..)
  , ColumnMeta (..)
  , genericTableMeta
  , camelToSnake
  , SqlType (..)
  )
import Manifest.Entity
  ( Entity(..)
  , Key(..)
  , genericRowDecoder
  , genericRowEncode
  )
import Manifest.Derive
  ( Table(..)
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
  , renderCreateIndex
  , liveColumns
  , tableExists
  )
import Manifest.Error
  ( DbError(..)
  , DbException(..)
  , DecodeError(..)
  )
import Manifest.Session
  ( Db
  , withSession
  , withTransaction
  , withRlsContext
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
import Manifest.Testing
  ( withEphemeralDb
  )
