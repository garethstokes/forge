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
  , renderCreatePolicy
  , renderDropPolicy
  , rlsPlan
  , renderCreateIndex
  , liveIndexes
  , indexesForTable
  , indexPlan
  ) where

import Control.Exception (throwIO)
import Control.Monad (forM_, unless, void)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.Maybe (mapMaybe)
import Data.Proxy (Proxy)
import qualified Data.ByteString.Char8 as BC
import Manifest.Core.Codec (SqlParam)
import Manifest.Core.Meta (ColumnMeta(..), ForeignKey(..), TableMeta(..), sqlTypeDDL, sqlTypeLive)
import Manifest.Core.Index (Index (..), IndexDef (..), IndexMethod (..), methodSql)
import Manifest.Core.Rls (PolicyDef (..), PolicyCmd (..), policyDef)
import Manifest.Entity (Entity, tableMeta, rlsPolicies, indexes, foreignKeys)
import Manifest.Error (DbError(OtherError), DbException(..))
import Manifest.Postgres (Pool)
import Manifest.Session (Db, execDb, withSession, withTransaction)
import System.IO (hPutStrLn, stderr)

-- | A table the migration engine manages: its name, its columns (with SQL
-- types), and its declared RLS policies.
data ManagedTable = ManagedTable
  { mtName        :: ByteString
  , mtColumns     :: [ColumnMeta]
  , mtPolicies    :: [PolicyDef]
  , mtIndexes     :: [IndexDef]
  , mtForeignKeys :: [ForeignKey]
  } deriving (Eq, Show)

-- | Reflect an entity's managed schema. @managed (Proxy @User)@.
managed :: forall a. Entity a => Proxy a -> ManagedTable
managed _ = ManagedTable (tmTable tm) (tmColumns tm)
                         (map policyDef (rlsPolicies @a))
                         (mkIndexes (tmTable tm) (indexes @a))
                         (foreignKeys @a)
  where tm = tableMeta @a

-- | Name each declared index from the table it lives on, so the name is
-- schema-unique: @\<table>_\<col1>[_\<col2>...]_\<method>_idx@.
mkIndexes :: ByteString -> [Index a] -> [IndexDef]
mkIndexes table = map $ \(Index (m, uniq, cols)) ->
  let suffix = if uniq then "unique" else methodSql m
      name   = table <> "_" <> BC.intercalate "_" cols <> "_" <> suffix <> "_idx"
  in IndexDef name m uniq cols

-- | One column's DDL fragment: @name TYPE [NOT NULL]@. A serial PK column is
-- @name BIGSERIAL PRIMARY KEY@; a non-serial PK gets @PRIMARY KEY@ too.
columnDDL :: ColumnMeta -> ByteString
columnDDL c =
  cmName c <> " " <> sqlTypeDDL (cmSqlType c)
    <> (if cmIsPK c then " PRIMARY KEY" else if cmNullable c then "" else " NOT NULL")

-- | One FK's table-level constraint clause.
fkDDL :: ForeignKey -> ByteString
fkDDL fk =
  "FOREIGN KEY (" <> fkColumn fk <> ") REFERENCES "
    <> fkRefTable fk <> "(" <> fkRefPkColumn fk <> ")"

-- | @CREATE TABLE name (col1 …, col2 …, …)@ from the managed schema.
renderCreateTable :: ManagedTable -> ByteString
renderCreateTable (ManagedTable name cols _ _ fks) =
  "CREATE TABLE " <> name <> " ("
    <> BC.intercalate ", " (map columnDDL cols ++ map fkDDL fks)
    <> ")"

-- | @ALTER TABLE name ADD COLUMN col …@ (additive). Added columns are never PK.
-- The FK list is consulted to append an inline @REFERENCES@ clause if the column
-- is marked as a foreign key.
renderAddColumn :: ByteString -> [ForeignKey] -> ColumnMeta -> ByteString
renderAddColumn table fks c =
  "ALTER TABLE " <> table <> " ADD COLUMN " <> cmName c <> " " <> sqlTypeDDL (cmSqlType c)
    <> (if cmNullable c then "" else " NOT NULL")
    <> maybe "" (\fk -> " REFERENCES " <> fkRefTable fk <> "(" <> fkRefPkColumn fk <> ")")
             (lookupFk (cmName c) fks)
  where
    lookupFk :: ByteString -> [ForeignKey] -> Maybe ForeignKey
    lookupFk col = foldr (\fk acc -> if fkColumn fk == col then Just fk else acc) Nothing

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
diffTable mt@(ManagedTable name cols _ _ _) = do
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

-- RLS DDL ---------------------------------------------------------------------

-- | The SQL keyword for a policy's command scope.
cmdSql :: PolicyCmd -> ByteString
cmdSql CmdAll    = "ALL"
cmdSql CmdSelect = "SELECT"
cmdSql CmdInsert = "INSERT"
cmdSql CmdUpdate = "UPDATE"
cmdSql CmdDelete = "DELETE"

-- | @CREATE POLICY name ON table [FOR cmd] [USING (…)] [WITH CHECK (…)]@.
renderCreatePolicy :: ByteString -> PolicyDef -> ByteString
renderCreatePolicy table pd =
  "CREATE POLICY " <> pdName pd <> " ON " <> table
    <> (if pdCmd pd == CmdAll then "" else " FOR " <> cmdSql (pdCmd pd))
    <> maybe "" (\u -> " USING (" <> u <> ")") (pdUsing pd)
    <> maybe "" (\c -> " WITH CHECK (" <> c <> ")") (pdCheck pd)

-- | @DROP POLICY name ON table@.
renderDropPolicy :: ByteString -> ByteString -> ByteString
renderDropPolicy table name = "DROP POLICY " <> name <> " ON " <> table

-- | The policy names live on a table (in the @public@ schema).
livePolicies :: ByteString -> Db [ByteString]
livePolicies table = do
  rows <- execDb "SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=$1" [Just table]
  pure [ n | [Just n] <- rows ]

-- | A table's live (rowsecurity, forcerowsecurity) flags.
liveRlsFlags :: ByteString -> Db (Bool, Bool)
liveRlsFlags table = do
  rows <- execDb "SELECT relrowsecurity, relforcerowsecurity FROM pg_class \
                 \WHERE oid = ('public.' || $1)::regclass" [Just table]
  pure $ case rows of
    ([Just a, Just b] : _) -> (a == "t", b == "t")
    _                      -> (False, False)

-- | DDL to make one table's live RLS match its declarations. Empty if the table
-- has no policies or does not exist yet (it will be reconciled after creation).
rlsForTable :: ManagedTable -> Db [ByteString]
rlsForTable (ManagedTable name _ pols _ _)
  | null pols = pure []
  | otherwise = do
      exists <- tableExists name
      if not exists then pure [] else do
        (rls, frc) <- liveRlsFlags name
        live       <- livePolicies name
        let declNames = map pdName pols
            enable = [ "ALTER TABLE " <> name <> " ENABLE ROW LEVEL SECURITY" | not rls ]
            force  = [ "ALTER TABLE " <> name <> " FORCE ROW LEVEL SECURITY"  | not frc ]
            create = [ renderCreatePolicy name pd | pd <- pols, pdName pd `notElem` live ]
            drop_  = [ renderDropPolicy name n    | n  <- live, n `notElem` declNames ]
        pure (enable ++ force ++ drop_ ++ create)

-- | The RLS reconciliation DDL across all managed tables.
rlsPlan :: [ManagedTable] -> Db [ByteString]
rlsPlan = fmap concat . mapM rlsForTable

-- Index DDL -------------------------------------------------------------------

-- | @CREATE INDEX name ON table USING method (col1, col2, …)@.
renderCreateIndex :: ByteString -> IndexDef -> ByteString
renderCreateIndex table (IndexDef n method uniq cols) =
  "CREATE " <> (if uniq then "UNIQUE " else "") <> "INDEX " <> n <> " ON " <> table
    <> (case method of Gin -> " USING gin"; Btree -> "")
    <> " (" <> BC.intercalate ", " cols <> ")"

-- | The index names live on a table (in the @public@ schema).
liveIndexes :: ByteString -> Db [ByteString]
liveIndexes table = do
  rows <- execDb "SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename=$1" [Just table]
  pure [ n | [Just n] <- rows ]

-- | DDL to create one table's declared indexes that are not already live.
-- Empty if the table has no declared indexes or does not exist yet (it will be
-- reconciled after creation). Unlike RLS, this is CREATE-ONLY — it NEVER drops:
-- Postgres auto-creates the @\<table>_pkey@ index and users may add their own,
-- so dropping "unmanaged" indexes would risk dropping the PK index.
indexesForTable :: ManagedTable -> Db [ByteString]
indexesForTable mt
  | null (mtIndexes mt) = pure []
  | otherwise = do
      exists <- tableExists (mtName mt)
      if not exists then pure [] else do
        live <- liveIndexes (mtName mt)
        pure [ renderCreateIndex (mtName mt) idx | idx <- mtIndexes mt, idxName idx `notElem` live ]

-- | The index reconciliation DDL across all managed tables.
indexPlan :: [ManagedTable] -> Db [ByteString]
indexPlan = fmap concat . mapM indexesForTable

-- | The pending plan across all managed tables: additive DDL to apply,
-- destructive issues that need human review (NEVER auto-applied), and the RLS
-- reconciliation DDL.
data MigrationPlan = MigrationPlan
  { planAdditive    :: [ByteString]   -- CREATE TABLE / ADD COLUMN statements, in order
  , planDestructive :: [String]       -- "table.column type mismatch …" — review only
  , planRls         :: [ByteString]   -- ENABLE/FORCE RLS + CREATE/DROP POLICY, reconciled
  , planIndexes     :: [ByteString]   -- CREATE INDEX (create-if-absent only), reconciled
  } deriving (Eq, Show)

-- | Compute the additive plan + destructive issues for the managed tables.
migrate :: [ManagedTable] -> Db MigrationPlan
migrate tables = do
  diffs <- mapM diffTable tables
  let additive = concatMap toAdditive (zip tables diffs)
      destr    = concatMap toDestr diffs
  rls  <- rlsPlan tables
  idxs <- indexPlan tables
  pure (MigrationPlan additive destr rls idxs)
  where
    toAdditive (mt, CreateTable _)       = [renderCreateTable mt]
    toAdditive (mt, AlterTable t adds _) = [renderAddColumn t (mtForeignKeys mt) c | c <- adds]
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
  let additive = planAdditive plan
  rls0  <- rlsPlan tables                          -- for the empty-work guard (tables that already exist)
  idxs0 <- indexPlan tables                        -- ditto for indexes
  unless (null additive && null rls0 && null idxs0) $
    withTransaction $ do
      forM_ additive $ \s -> void (execDb s [])
      rls <- rlsPlan tables                        -- recompute: any just-created table now exists
      forM_ rls $ \s -> void (execDb s [])
      idxs <- indexPlan tables                     -- recompute: index a just-created table
      forM_ idxs $ \s -> void (execDb s [])
      void $ execDb "INSERT INTO schema_migrations (statements) VALUES ($1)"
                    [Just (BC.pack (show (length additive + length rls + length idxs)))]
  pure plan

-- | The CLI dispatcher: @diff@ prints the plan; @up@ applies it. @args@ is argv.
runMigrate :: [ManagedTable] -> Pool -> [String] -> IO ()
runMigrate tables pool args = case args of
  ["diff"] -> do
    plan <- withSession pool (do ensureSchemaMigrations; migrate tables)
    mapM_ BC.putStrLn (planAdditive plan)
    unless (null (planRls plan)) $ do
      BC.putStrLn "-- rls:"
      mapM_ BC.putStrLn (planRls plan)
    unless (null (planIndexes plan)) $ do
      BC.putStrLn "-- indexes:"
      mapM_ BC.putStrLn (planIndexes plan)
    unless (null (planDestructive plan)) $ do
      hPutStrLn stderr "-- destructive (review, not applied):"
      mapM_ (hPutStrLn stderr . ("--   " <>)) (planDestructive plan)
  ["up"] -> do
    plan <- withSession pool (migrateUp tables)
    hPutStrLn stderr ("applied " <> show (length (planAdditive plan)) <> " statement(s)")
  _ -> hPutStrLn stderr "usage: manifest migrate (diff|up)"
