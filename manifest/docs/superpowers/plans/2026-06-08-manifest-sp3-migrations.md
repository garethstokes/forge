# Manifest Sub-project 3 — Migrations (records as the schema source of truth)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Records are the schema source of truth. Derive each entity's expected schema (column SQL types + nullability + PK/serial), introspect the live Postgres schema, compute the **additive** delta (CREATE TABLE / ADD COLUMN), surface **destructive** diffs (type changes, etc.) for review *without ever applying them*, apply the additive plan in a transaction tracked in a `schema_migrations` table, and expose it all behind a `manifest migrate diff` / `manifest migrate up` CLI.

**Architecture:** A new `SqlType` + the SP1-deferred SQL-type metadata: `ScalarMeta` maps base scalars (`Int`→bigint, `Text`→text, `Bool`→boolean, `Maybe a`→nullable) and `FieldMeta` gains `fieldSqlType`/`fieldNullable` (markers: `Serial`→bigserial, `PrimaryKey`→not-null PK). `ColumnMeta` carries `cmSqlType`/`cmNullable`, populated by the existing Generics deriver. A `Manifest.Migrate` module turns a `ManagedTable` (table name + its `ColumnMeta`s, built by `managed (Proxy @Entity)`) into DDL (`renderCreateTable`/`renderAddColumn`), introspects `information_schema.columns`, diffs (`diffTable`: Create / Add columns / Destructive-flagged), and runs `migrate`/`migrateUp` (additive-only, in a transaction, recorded in `schema_migrations`). `runMigrate :: [ManagedTable] -> Pool -> [String] -> IO ()` is the CLI dispatcher (`diff`/`up`); a thin `app/Main.hs` exe wires a built-in example schema + a `MANIFEST_DATABASE_URL` conninfo.

**Tech Stack:** GHC 9.10.1 · zinc · the hand-rolled `test/Harness.hs`. No new external deps. Alembic-style file migrations + renames/drops/type-change auto-application are explicit non-goals (follow-up).

---

## EXECUTION NOTES (carry over — apply everywhere)

1. **Build/test:** `nix develop -c zinc build` / `nix develop -c zinc test` (wrap in `nix develop -c`; Bash `timeout: 600000`). **Always `zinc test` before `.zinc/build/spec`** (staleness). `.zinc/build/spec` runs green only INSIDE `nix develop`.
2. **Tests use `test/Harness.hs`** (`group`/`test`/`assertBool`/`assertEqual` msg-expected-actual), NOT hspec. Spec modules export `tests :: [Test]`; `test/Spec.hs` aggregates with `++`.
3. **Test DB:** the thin `initdb`/`pg_ctl` harness (`test/Fixtures.hs withTestDb`). Migration tests run against a fresh ephemeral DB. Note: `withTestDb` currently pre-creates the example tables — migration tests need an EMPTY DB; see Task 3 for the `withEmptyDb` variant.
4. **`-Wall`** via direct GHC against built interfaces WITH lib extensions: `nix develop -c bash -lc 'cd "$PWD" && ghc -fno-code -Wall -fforce-recomp -package-db .zinc/pkgdb -i.zinc/lib -XOverloadedStrings -XScopedTypeVariables -XTypeApplications -XLambdaCase -XTupleSections <module.hs>'` (plus the module's own pragmas).
5. **GADT existential gotcha:** a `c` bound by `case … of` is not nameable as `@c`; hoist into a `forall a c` helper. `managed`/`scalarType @a` name their type via `Proxy`/explicit application, avoiding this.
6. HKD literals need `:: User`/etc.; `Db` has no `MonadFail`; column names camelCase→snake_case (no prefix strip).

Baseline: `main` at `6a3c737`, SP2.7 complete, 65/65 green on GHC 9.10.1. Existing metadata: `ColumnMeta{cmName,cmIsPK,cmIsSerial}`, `TableMeta{tmTable,tmColumns}` (`Core/Meta.hs`); `FieldMeta{fieldIsPK,fieldIsSerial}` + markers `Serial`/`PrimaryKey` (`Core/Table.hs`); the Generics deriver `GColumns`/`genericTableMeta` (`Core/Meta.hs`). Postgres exec via `Manifest.Session.execDb`; `Manifest.Postgres` for raw `Pool`/`withConnection`/`execText`.

---

## File Structure

| File | Change |
|---|---|
| `src/Manifest/Core/Table.hs` | add `ScalarMeta` (base→SqlType+nullable); extend `FieldMeta` with `fieldSqlType`/`fieldNullable`. |
| `src/Manifest/Core/Meta.hs` | add `SqlType(..)` + `sqlTypeDDL`/`sqlTypeLive`; `ColumnMeta` gains `cmSqlType`/`cmNullable`; the `GColumns` `S1` instance populates them. |
| `src/Manifest/Migrate.hs` | NEW — `ManagedTable`/`managed`; `renderCreateTable`/`renderAddColumn`; `liveColumns`/`tableExists`; `TableDiff`/`diffTable`; `MigrationPlan`/`migrate`/`migrateUp` (+ `schema_migrations`); `runMigrate` (CLI dispatcher). |
| `src/Manifest.hs` | re-export the migration surface. |
| `app/Main.hs` | NEW — the `manifest migrate diff/up` exe: example schema + `MANIFEST_DATABASE_URL`. |
| `zinc.toml` | add `[build.exe.manifest-migrate]` (links `-lpq`). |
| `test/Fixtures.hs` | add `withEmptyDb` (ephemeral cluster, NO tables created) for migration tests. |
| `test/MigrateMetaSpec.hs` | NEW — derived SQL-type metadata (pure). |
| `test/MigrateSqlSpec.hs` | NEW — `renderCreateTable`/`renderAddColumn` (pure). |
| `test/MigrateSpec.hs` | NEW — introspect + diff + migrate/migrateUp + schema_migrations (integration). |

---

### Task 1: SQL types in the metadata layer

The SP1-deferred SQL-type derivation. Every column gets a `SqlType` + nullability.

**Files:** Modify `src/Manifest/Core/Table.hs`, `src/Manifest/Core/Meta.hs`; create `test/MigrateMetaSpec.hs`.

- [ ] **Step 1: `SqlType` + renderers** (`src/Manifest/Core/Meta.hs`)

Add (near the top, exported):
```haskell
-- | The subset of Postgres column types SP3 derives from Haskell field types.
data SqlType = SqlBigInt | SqlText | SqlBool | SqlBigSerial
  deriving (Eq, Show)

-- | The DDL spelling (for CREATE TABLE / ADD COLUMN).
sqlTypeDDL :: SqlType -> ByteString
sqlTypeDDL SqlBigInt    = "BIGINT"
sqlTypeDDL SqlText      = "TEXT"
sqlTypeDDL SqlBool      = "BOOLEAN"
sqlTypeDDL SqlBigSerial = "BIGSERIAL"

-- | The normalized type name as @information_schema.columns.data_type@ reports it
-- (a BIGSERIAL column IS @bigint@ in the catalog, with a sequence default), used
-- for diffing the live DB against the records.
sqlTypeLive :: SqlType -> ByteString
sqlTypeLive SqlBigInt    = "bigint"
sqlTypeLive SqlText      = "text"
sqlTypeLive SqlBool      = "boolean"
sqlTypeLive SqlBigSerial = "bigint"
```

- [ ] **Step 2: `ScalarMeta` + extend `FieldMeta`** (`src/Manifest/Core/Table.hs`)

Add `SqlType`/`ScalarMeta` machinery. First import `SqlType(..)` — but `SqlType` lives in `Core.Meta`, which imports `Core.Table` (`FieldMeta`)… **avoid the cycle:** put `SqlType(..)`/`sqlTypeDDL`/`sqlTypeLive` in a NEW tiny module `src/Manifest/Core/SqlType.hs` (no deps) that BOTH `Core.Table` and `Core.Meta` import. (Adjust Step 1 to create `Core/SqlType.hs` instead of putting `SqlType` in `Core.Meta`; `Core.Meta` re-exports it for convenience.)

```haskell
-- Core/Table.hs additions:
import Manifest.Core.SqlType (SqlType(..))

-- | Map a base scalar to its column type + nullability.
class ScalarMeta a where
  scalarType     :: SqlType
  scalarNullable :: Bool

instance ScalarMeta Int  where { scalarType = SqlBigInt; scalarNullable = False }
instance ScalarMeta Text where { scalarType = SqlText;   scalarNullable = False }
instance ScalarMeta Bool where { scalarType = SqlBool;   scalarNullable = False }
instance ScalarMeta a => ScalarMeta (Maybe a) where
  scalarType     = scalarType @a
  scalarNullable = True
```
(import `Data.Text (Text)`.) Then extend the `FieldMeta` class with two methods and update all three instances:
```haskell
class FieldMeta a where
  fieldIsPK     :: Bool
  fieldIsSerial :: Bool
  fieldSqlType  :: SqlType
  fieldNullable :: Bool

instance FieldMeta a => FieldMeta (PrimaryKey a) where
  fieldIsPK     = True
  fieldIsSerial = fieldIsSerial @a
  fieldSqlType  = fieldSqlType @a
  fieldNullable = False                      -- a PK is NOT NULL

instance FieldMeta (Serial a) where
  fieldIsPK     = False
  fieldIsSerial = True
  fieldSqlType  = SqlBigSerial
  fieldNullable = False

instance {-# OVERLAPPABLE #-} ScalarMeta a => FieldMeta a where
  fieldIsPK     = False
  fieldIsSerial = False
  fieldSqlType  = scalarType @a
  fieldNullable = scalarNullable @a
```
Export `ScalarMeta(..)` and the new `FieldMeta` methods.

- [ ] **Step 3: `ColumnMeta` gains the type + nullability** (`src/Manifest/Core/Meta.hs`)

`import Manifest.Core.SqlType (SqlType(..), sqlTypeDDL, sqlTypeLive)` and re-export them. Extend `ColumnMeta`:
```haskell
data ColumnMeta = ColumnMeta
  { cmName     :: ByteString
  , cmIsPK     :: Bool
  , cmIsSerial :: Bool
  , cmSqlType  :: SqlType
  , cmNullable :: Bool
  } deriving (Eq, Show)
```
Update the `GColumns (S1 m (Rec0 (Exposed t)))` instance to populate the two new fields from `FieldMeta`:
```haskell
        , cmSqlType  = fieldSqlType  @t
        , cmNullable = fieldNullable @t
```
(import `fieldSqlType`/`fieldNullable` from `Core.Table`.)

- [ ] **Step 4: pure test** (`test/MigrateMetaSpec.hs`)

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module MigrateMetaSpec (tests) where

import Fixtures (UserT)
import Manifest.Core.Meta (ColumnMeta (..), SqlType (..), TableMeta (..), genericTableMeta)
import Harness

tests :: [Test]
tests = group "MigrateMeta"
  [ test "genericTableMeta derives SqlType + nullability for UserT" $
      assertEqual "columns"
        [ ColumnMeta "user_id"    True  True  SqlBigSerial False
        , ColumnMeta "user_name"  False False SqlText      False
        , ColumnMeta "user_email" False False SqlText      True   -- Maybe Text → nullable
        ]
        (tmColumns (genericTableMeta @UserT "users"))
  ]
```
Wire into `test/Spec.hs`. NOTE: this changes `ColumnMeta`'s shape, so the SP1 `MetaSpec` test that asserts `ColumnMeta "user_id" True True` (3 fields) WILL break — update those literals in `test/MetaSpec.hs` to the 5-field form (`ColumnMeta "user_id" True True SqlBigSerial False`, etc.). Find them via `grep -n "ColumnMeta " test/*.hs`.

- [ ] **Step 5: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `66/66 tests passed` (the new test; the updated MetaSpec literals keep their count). `-Wall`-clean on `Core/SqlType.hs`, `Core/Table.hs`, `Core/Meta.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp3): SQL types + nullability in the metadata layer (ScalarMeta, FieldMeta)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: DDL generation — `ManagedTable`, `renderCreateTable`, `renderAddColumn`

**Files:** Create `src/Manifest/Migrate.hs` (the rendering half); create `test/MigrateSqlSpec.hs`.

- [ ] **Step 1: `Manifest/Migrate.hs` — managed tables + DDL rendering**

```haskell
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Manifest.Migrate
  ( ManagedTable(..)
  , managed
  , renderCreateTable
  , renderAddColumn
  ) where

import Data.ByteString (ByteString)
import Data.Proxy (Proxy)
import qualified Data.ByteString.Char8 as BC
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..), sqlTypeDDL)
import Manifest.Entity (Entity, tableMeta)

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
```

> Note the PK rendering: for `user_id` (serial PK) → `user_id BIGSERIAL PRIMARY KEY` (matches the SP1 hand-written `usersDDL`). A nullable column omits `NOT NULL`. An added column that's NOT NULL on a table with existing rows would fail in real Postgres without a default — but SP3's MVP adds columns to freshly-created/empty tables; document this limitation.

- [ ] **Step 2: pure tests** (`test/MigrateSqlSpec.hs`)

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module MigrateSqlSpec (tests) where

import Data.Proxy (Proxy (..))
import Fixtures (User)
import Manifest.Core.Meta (ColumnMeta (..), SqlType (..))
import Manifest.Migrate (managed, mtColumns, renderAddColumn, renderCreateTable)
import Harness

tests :: [Test]
tests = group "MigrateSql"
  [ test "renderCreateTable matches the hand-written users DDL" $
      assertEqual "create"
        "CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL, user_email TEXT)"
        (renderCreateTable (managed (Proxy @User)))
  , test "renderAddColumn for a nullable text column" $
      assertEqual "add"
        "ALTER TABLE users ADD COLUMN nickname TEXT"
        (renderAddColumn "users" (ColumnMeta "nickname" False False SqlText True))
  , test "renderAddColumn for a NOT NULL bigint column" $
      assertEqual "add"
        "ALTER TABLE users ADD COLUMN age BIGINT NOT NULL"
        (renderAddColumn "users" (ColumnMeta "age" False False SqlBigInt False))
  ]
```
Wire into `test/Spec.hs`.

- [ ] **Step 3: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `69/69 tests passed`. `-Wall`-clean on `Migrate.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp3): ManagedTable + renderCreateTable/renderAddColumn (DDL from records)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: introspection + diff

**Files:** Modify `src/Manifest/Migrate.hs`, `test/Fixtures.hs`; create `test/MigrateSpec.hs`.

- [ ] **Step 1: `withEmptyDb` harness** (`test/Fixtures.hs`)

`withTestDb` pre-creates the example tables; migration tests need an EMPTY DB. Add a sibling that spins the same ephemeral cluster but creates NO tables:
```haskell
withEmptyDb :: (Pool -> IO a) -> IO a
```
Implement it like `withTestDb` but with an empty DDL list (just the cluster + pool, no `CREATE TABLE`s). Factor the common cluster setup if convenient. Export `withEmptyDb`.

- [ ] **Step 2: introspection + diff** (`src/Manifest/Migrate.hs`)

Add to the exports `liveColumns`, `tableExists`, `TableDiff(..)`, `diffTable`. Add imports `Manifest.Core.Meta (sqlTypeLive)`, `Manifest.Core.Codec (SqlParam)`, `Manifest.Session (Db, execDb)`, `Data.Maybe (mapMaybe)`.
```haskell
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
    parse [Just n, Just t, Just b] = Just (n, t, b == "t")
    parse _ = Nothing

tableExists :: ByteString -> Db Bool
tableExists table = not . null <$> liveColumns table

-- | The diff between a managed table and the live DB.
data TableDiff
  = CreateTable ManagedTable                 -- table absent → CREATE
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
```

- [ ] **Step 3: integration tests** (`test/MigrateSpec.hs`)

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module MigrateSpec (tests) where

import Data.Proxy (Proxy (..))
import Fixtures (User, withEmptyDb, withTestDb)
import Manifest.Migrate
import Manifest.Postgres (execText, withConnection)
import Manifest.Session (withSession)
import Harness

tests :: [Test]
tests = group "Migrate"
  [ test "diffTable on an empty DB says CreateTable" $
      withEmptyDb $ \pool -> do
        d <- withSession pool (diffTable (managed (Proxy @User)))
        case d of
          CreateTable mt -> assertEqual "name" "users" (mtName mt)
          _              -> assertBool "expected CreateTable" False
  , test "diffTable detects a missing column (additive)" $
      withEmptyDb $ \pool -> do
        withConnection pool $ \c ->
          mapM_ (\s -> execText c s [])
            ["CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL)"]
        d <- withSession pool (diffTable (managed (Proxy @User)))
        case d of
          AlterTable t adds destr -> do
            assertEqual "table" "users" t
            assertEqual "adds" ["user_email"] (map cmName adds)
            assertEqual "no destructive" [] destr
          _ -> assertBool "expected AlterTable" False
  , test "diffTable flags a type mismatch as destructive (NOT applied)" $
      withEmptyDb $ \pool -> do
        withConnection pool $ \c ->
          mapM_ (\s -> execText c s [])
            ["CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, user_name BIGINT NOT NULL, user_email TEXT)"]
        d <- withSession pool (diffTable (managed (Proxy @User)))
        case d of
          AlterTable _ adds destr -> do
            assertEqual "no adds" [] (map cmName adds)
            assertBool "user_name flagged" (any (\s -> "user_name" `elem` words s) destr)
          _ -> assertBool "expected AlterTable with destructive" False
  ]
```
Wire into `test/Spec.hs`.

- [ ] **Step 4: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `72/72 tests passed`. `-Wall`-clean on `Migrate.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp3): information_schema introspection + diffTable (additive vs destructive)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `migrate` / `migrateUp` + `schema_migrations` + `runMigrate`

**Files:** Modify `src/Manifest/Migrate.hs`, `test/MigrateSpec.hs`.

- [ ] **Step 1: the engine** (`src/Manifest/Migrate.hs`)

Add to exports `MigrationPlan(..)`, `migrate`, `migrateUp`, `runMigrate`. Add imports `Manifest.Session (withSession, withTransaction)` and `Control.Monad (forM_, unless, when, void)`, `Control.Exception (throwIO)`, `Manifest.Error (DbError(OtherError), DbException(..))`, `Control.Monad.IO.Class (liftIO)`, `Manifest.Postgres (Pool)`, `System.IO (hPutStrLn, stderr)`.
```haskell
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
    mapM_ (BC.putStrLn) (planAdditive plan)
    unless (null (planDestructive plan)) $ do
      hPutStrLn stderr "-- destructive (review, not applied):"
      mapM_ (hPutStrLn stderr . ("--   " <>)) (planDestructive plan)
  ["up"] -> do
    plan <- withSession pool (migrateUp tables)
    hPutStrLn stderr ("applied " <> show (length (planAdditive plan)) <> " statement(s)")
  _ -> hPutStrLn stderr "usage: manifest migrate (diff|up)"
```
(Add `BC.putStrLn` via `Data.ByteString.Char8`.)

- [ ] **Step 2: integration tests** (append to `test/MigrateSpec.hs`)

```haskell
  , test "migrateUp on an empty DB creates the managed tables; re-run is a no-op" $
      withEmptyDb $ \pool -> do
        let tbls = [managed (Proxy @User)]
        p1 <- withSession pool (migrateUp tbls)
        p2 <- withSession pool (migrateUp tbls)            -- idempotent
        existsUsers <- withSession pool (tableExists "users")
        assertBool  "users created" existsUsers
        assertEqual "first run had additive" 1 (length (planAdditive p1))
        assertEqual "second run is a no-op"  0 (length (planAdditive p2))
  , test "migrateUp applies a missing column" $
      withEmptyDb $ \pool -> do
        withConnection pool $ \c ->
          mapM_ (\s -> execText c s [])
            ["CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL)"]
        _ <- withSession pool (migrateUp [managed (Proxy @User)])
        d <- withSession pool (diffTable (managed (Proxy @User)))
        assertEqual "now up to date" UpToDate d
  , test "migrateUp aborts on a destructive diff (no DDL applied)" $
      withEmptyDb $ \pool -> do
        withConnection pool $ \c ->
          mapM_ (\s -> execText c s [])
            ["CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, user_name BIGINT NOT NULL, user_email TEXT)"]
        res <- (Harness.tryIO :: IO a -> IO (Either String a))
                 (withSession pool (migrateUp [managed (Proxy @User)]))
        assertBool "aborted" (either (const True) (const False) res)
  ]
```
(Import `Manifest.Postgres (execText, withConnection)` if not already; `tableExists` from `Manifest.Migrate`. For the abort test, use `Control.Exception (try, SomeException)` directly: `res <- (try :: IO a -> IO (Either SomeException a)) (...)` rather than a `Harness.tryIO` if that helper doesn't exist — adjust to what's available and assert the migrateUp threw.)

- [ ] **Step 3: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `75/75 tests passed`. `-Wall`-clean on `Migrate.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp3): migrate/migrateUp engine + schema_migrations + runMigrate CLI dispatcher

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: the `manifest migrate` executable + umbrella + e2e

**Files:** Create `app/Main.hs`; modify `zinc.toml`, `src/Manifest.hs`, `test/MigrateSpec.hs`.

- [ ] **Step 1: the exe** (`app/Main.hs`)

A thin CLI that defines a built-in example schema and dispatches via `runMigrate`. It reads the DB conninfo from `MANIFEST_DATABASE_URL`.
```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Main (main) where

import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import GHC.Generics (Generic)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Manifest

-- An example managed schema (the exe migrates this).
data NoteT f = Note
  { noteId    :: Col f (PrimaryKey (Serial Int))
  , noteTitle :: Col f Text
  , noteBody  :: Col f (Maybe Text)
  } deriving Generic
type Note = NoteT Identity

instance Entity Note where
  type PrimKey Note = Int
  tableMeta  = genericTableMeta @NoteT "notes"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = noteId

schema :: [ManagedTable]
schema = [ managed (Proxy @Note) ]

main :: IO ()
main = do
  args <- getArgs
  mUrl <- lookupEnv "MANIFEST_DATABASE_URL"
  case mUrl of
    Nothing  -> hPutStrLn stderr "set MANIFEST_DATABASE_URL" >> exitFailure
    Just url -> do
      pool <- newPool (BC.pack url) 1
      runMigrate schema pool args
      closePool pool
```
(This needs `Col`, `PrimaryKey`, `Serial`, `Entity(..)`, `genericTableMeta`, `genericRowDecoder`, `genericRowEncode`, `ManagedTable`, `managed`, `runMigrate`, `newPool`, `closePool` exported from `Manifest` — add any missing to the umbrella in Step 3.)

- [ ] **Step 2: the exe target** (`zinc.toml`)

Add:
```toml
[build.exe.manifest-migrate]
source-dirs = ["app"]
main = "Main.hs"
ghc-options = ["-lpq"]
depends = [
  "base", "bytestring", "text", "manifest"
]
```

- [ ] **Step 3: umbrella exports** (`src/Manifest.hs`)

Re-export the migration surface from `Manifest.Migrate`: `ManagedTable(..)`, `managed`, `migrate`, `migrateUp`, `runMigrate`, `MigrationPlan(..)`, `TableDiff(..)`, `diffTable`, `renderCreateTable`, `renderAddColumn`, `liveColumns`, `tableExists`. Also ensure the HKD/Entity/derive names `app/Main.hs` needs are exported (`Col`, `genericTableMeta`, `genericRowDecoder`, `genericRowEncode` — `genericTableMeta` is in `Core.Meta`, the generic codecs in `Manifest.Entity`; add them to the umbrella) and the pool helpers `newPool`/`closePool` (from `Manifest.Postgres`).

- [ ] **Step 4: build the exe + an e2e** (`test/MigrateSpec.hs`)

First confirm the exe BUILDS: `nix develop -c zinc build` should compile the `manifest-migrate` exe target (it links `-lpq`). Then add a library-level e2e (drives the same `runMigrate`/`migrate` path the exe uses, against an ephemeral DB):
```haskell
  , test "end-to-end: migrate empty DB up, then everything is UpToDate" $
      withEmptyDb $ \pool -> do
        let tbls = [managed (Proxy @User)]
        _ <- withSession pool (migrateUp tbls)
        d <- withSession pool (diffTable (managed (Proxy @User)))
        assertEqual "up to date after migrate up" UpToDate d
  ]
```

- [ ] **Step 5: Run → fail → implement → pass → commit**

`nix develop -c zinc build` builds the exe (no errors); `nix develop -c .zinc/build/spec` → `76/76 tests passed`. `-Wall`-clean library + `app/Main.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp3): manifest-migrate CLI exe + umbrella migration exports + e2e

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Spec coverage check (self-review)

| Design § | Requirement | Where covered |
|---|---|---|
| §6.4 | records are the schema source of truth | Tasks 1–2 (`SqlType` metadata → `renderCreateTable`) |
| §6.4 | `migrate diff` — introspect DB, compute delta vs records | Tasks 3–4 (`liveColumns`/`diffTable`/`migrate`; `runMigrate ["diff"]`) |
| §6.4 | `migrate up` — apply pending, tracked in `schema_migrations` | Task 4 (`migrateUp` + `ensureSchemaMigrations`) |
| §6.4 | CREATE TABLE from records + additive diffs (new table/column) | Tasks 2–4 |
| §6.4 | destructive ops surfaced for review, NEVER silently executed | Task 4 (`migrateUp` aborts on `planDestructive`; `diff` prints them to stderr) |
| §6.4 | CLI (`manifest migrate …`) | Task 5 (`app/Main.hs` exe + `[build.exe.manifest-migrate]`) |

**Deferred (explicit non-goals):** Alembic-style file-based up/down migrations (the user confirmed CLI-only for this slice); renames; type-change/drop AUTO-application (detected + surfaced only); defaults for `NOT NULL` ADD COLUMN on non-empty tables; multi-column PKs / FK constraints in generated DDL; an entity auto-registry (the exe hard-codes its schema list); richer `SqlType`s (only BigInt/Text/Bool/BigSerial — extend `ScalarMeta` for more).

**Type-consistency notes:** `SqlType` lives in `Manifest.Core.SqlType` (imported by both `Core.Table` and `Core.Meta` to avoid a cycle; re-exported from `Core.Meta`). `ColumnMeta` is now 5-fold (`cmName`/`cmIsPK`/`cmIsSerial`/`cmSqlType`/`cmNullable`) — every `ColumnMeta` literal in tests updated. `ManagedTable{mtName,mtColumns}`; `managed :: Entity a => Proxy a -> ManagedTable`. `diffTable :: ManagedTable -> Db TableDiff` (`CreateTable`/`AlterTable name adds destr`/`UpToDate`). `migrate :: [ManagedTable] -> Db MigrationPlan`; `migrateUp :: [ManagedTable] -> Db MigrationPlan` (aborts on destructive); `runMigrate :: [ManagedTable] -> Pool -> [String] -> IO ()`.
