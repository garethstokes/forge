{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Manifest.Migrate
  ( ManagedTable(..)
  , managed
  , renderCreateTable
  , renderAddColumn
  , liveColumns
  , tableExists
  , TableDiff(..)
  , diffTable
  , MigrationPlan(..)
  , migrate
  , migrateUp
  , runMigrate
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM_, unless, void)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.Maybe (mapMaybe)
import Data.Proxy (Proxy)
import qualified Data.ByteString.Char8 as BC
import Manifest.Core.Codec (SqlParam)
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..), sqlTypeDDL, sqlTypeLive)
import Manifest.Entity (Entity, tableMeta)
import Manifest.Error (DbError(OtherError), DbException(..))
import Manifest.Postgres (Pool)
import Manifest.Session (Db, execDb, withSession, withTransaction)
import System.IO (hPutStrLn, stderr)

-- | A table the migration engine manages: its name + its columns (with SQL types).
data ManagedTable = ManagedTable
  { mtName    :: ByteString
  , mtColumns :: [ColumnMeta]
  } deriving (Eq, Show)

-- | Reflect an entity's managed schema. @managed (Proxy @User)@.
managed :: forall a. Entity a => Proxy a -> ManagedTable
managed _ = let tm = tableMeta @a in ManagedTable (tmTable tm) (tmColumns tm)

-- | One column's DDL fragment: @name TYPE [NOT NULL]@. A serial PK column is
-- @name BIGSERIAL PRIMARY KEY@; a non-serial PK gets @PRIMARY KEY@ too.
columnDDL :: ColumnMeta -> ByteString
columnDDL c =
  cmName c <> " " <> sqlTypeDDL (cmSqlType c)
    <> (if cmIsPK c then " PRIMARY KEY" else if cmNullable c then "" else " NOT NULL")

-- | @CREATE TABLE name (col1 …, col2 …, …)@ from the managed schema.
renderCreateTable :: ManagedTable -> ByteString
renderCreateTable (ManagedTable name cols) =
  "CREATE TABLE " <> name <> " (" <> BC.intercalate ", " (map columnDDL cols) <> ")"

-- | @ALTER TABLE name ADD COLUMN col …@ (additive). Added columns are never PK.
renderAddColumn :: ByteString -> ColumnMeta -> ByteString
renderAddColumn table c =
  "ALTER TABLE " <> table <> " ADD COLUMN " <> cmName c <> " " <> sqlTypeDDL (cmSqlType c)
    <> (if cmNullable c then "" else " NOT NULL")

-- | A live column as Postgres reports it: (name, data_type, is_nullable).
liveColumns :: ByteString -> Db [(ByteString, ByteString, Bool)]
liveColumns table = do
  rows <- execDb
    "SELECT column_name, data_type, (is_nullable = 'YES') \
    \FROM information_schema.columns \
    \WHERE table_schema = 'public' AND table_name = $1 \
    \ORDER BY ordinal_position"
    [Just table]
  pure (mapMaybe parse rows)
  where
    parse :: [SqlParam] -> Maybe (ByteString, ByteString, Bool)
    parse [Just n, Just t, Just b] = Just (n, t, b == "t")
    parse _ = Nothing

-- | True when the table has at least one column in the @public@ schema.
tableExists :: ByteString -> Db Bool
tableExists table = not . null <$> liveColumns table

-- | The diff between a managed table and the live DB.
data TableDiff
  = CreateTable ManagedTable                     -- table absent → CREATE
  | AlterTable ByteString [ColumnMeta] [String]  -- missing columns to ADD; destructive issues (review only)
  | UpToDate
  deriving (Eq, Show)

diffTable :: ManagedTable -> Db TableDiff
diffTable mt@(ManagedTable name cols) = do
  exists <- tableExists name
  if not exists
    then pure (CreateTable mt)
    else do
      live <- liveColumns name
      let liveNames = [ n | (n, _, _) <- live ]
          missing   = [ c | c <- cols, cmName c `notElem` liveNames ]
          -- destructive: a column present in BOTH but with a different SQL type.
          destructive =
            [ "column " <> BC.unpack (cmName c) <> " type mismatch: record "
                <> BC.unpack (sqlTypeLive (cmSqlType c)) <> " vs live " <> BC.unpack lt
            | c <- cols
            , (n, lt, _) <- live, n == cmName c
            , sqlTypeLive (cmSqlType c) /= lt
            ]
      pure $ if null missing && null destructive then UpToDate else AlterTable name missing destructive

-- | The pending plan across all managed tables: additive DDL to apply, and
-- destructive issues that need human review (NEVER auto-applied).
data MigrationPlan = MigrationPlan
  { planAdditive    :: [ByteString]   -- CREATE TABLE / ADD COLUMN statements, in order
  , planDestructive :: [String]       -- "table.column type mismatch …" — review only
  } deriving (Eq, Show)

-- | Compute the additive plan + destructive issues for the managed tables.
migrate :: [ManagedTable] -> Db MigrationPlan
migrate tables = do
  diffs <- mapM diffTable tables
  let additive = concatMap toAdditive (zip tables diffs)
      destr    = concatMap toDestr diffs
  pure (MigrationPlan additive destr)
  where
    toAdditive (mt, CreateTable _)       = [renderCreateTable mt]
    toAdditive (_,  AlterTable t adds _) = [renderAddColumn t c | c <- adds]
    toAdditive (_,  UpToDate)            = []
    toDestr (AlterTable _ _ d) = d
    toDestr _                  = []

-- | Bootstrap the tracking table.
ensureSchemaMigrations :: Db ()
ensureSchemaMigrations = void $ execDb
  "CREATE TABLE IF NOT EXISTS schema_migrations \
  \( id BIGSERIAL PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now(), statements BIGINT NOT NULL )" []

-- | Apply the additive plan in a transaction; record a row in schema_migrations.
-- Destructive diffs ABORT (never silently applied) — fix them by hand / a future
-- destructive migration. Returns the plan that was (attempted to be) applied.
migrateUp :: [ManagedTable] -> Db MigrationPlan
migrateUp tables = do
  ensureSchemaMigrations
  plan <- migrate tables
  unless (null (planDestructive plan)) $
    liftIO (throwIO (DbException (OtherError
      ("migrate up aborted: destructive changes need review: " <> show (planDestructive plan)))))
  unless (null (planAdditive plan)) $
    withTransaction $ do
      forM_ (planAdditive plan) $ \stmt -> void (execDb stmt [])
      void $ execDb "INSERT INTO schema_migrations (statements) VALUES ($1)"
                    [Just (BC.pack (show (length (planAdditive plan))))]
  pure plan

-- | The CLI dispatcher: @diff@ prints the plan; @up@ applies it. @args@ is argv.
runMigrate :: [ManagedTable] -> Pool -> [String] -> IO ()
runMigrate tables pool args = case args of
  ["diff"] -> do
    plan <- withSession pool (do ensureSchemaMigrations; migrate tables)
    mapM_ BC.putStrLn (planAdditive plan)
    unless (null (planDestructive plan)) $ do
      hPutStrLn stderr "-- destructive (review, not applied):"
      mapM_ (hPutStrLn stderr . ("--   " <>)) (planDestructive plan)
  ["up"] -> do
    plan <- withSession pool (migrateUp tables)
    hPutStrLn stderr ("applied " <> show (length (planAdditive plan)) <> " statement(s)")
  _ -> hPutStrLn stderr "usage: manifest migrate (diff|up)"
