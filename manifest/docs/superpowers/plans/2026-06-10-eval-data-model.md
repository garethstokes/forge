# Eval Orchestrator — Data Model (sub-project A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Manifest schema for an LLM-eval orchestrator — datasets/versions/examples, targets/versions, graders/versions, and the run/output/score graph — as a new `examples/manifest-evals/` package depending on the local `manifest`, plus the small Manifest library extensions it needs.

**Architecture:** Two layers. **Layer 1** adds to the `manifest` library the column types and index/testing support the schema needs (timestamps, `Double`, unique indexes, an ephemeral-DB test helper). **Layer 2** is a new zinc workspace package `examples/manifest-evals/` that defines the 12 entities (record-dot style, typed IDs, `Aeson Value` jsonb), relationships, cascades, indexes, a migration, and tests against ephemeral Postgres.

**Tech Stack:** GHC 9.10.1 via zinc (NOT cabal). `manifest` (local), `aeson`, `time` (already in the dep closure). Record-dot extensions `DuplicateRecordFields`/`NoFieldSelectors`/`OverloadedRecordDot`.

**Spec:** `docs/superpowers/specs/2026-06-10-eval-orchestrator-data-model-design.md` (entity declarations are verbatim in spec §2; transcribe them exactly).

**Baseline:** `main` is at **135/135**. Confirm: `nix develop -c zinc test` then `nix develop -c .zinc/build/spec`.

**Build/test commands:**
- `nix develop -c zinc build` — build the default (library) target.
- `nix develop -c zinc build manifest-evals` — build the eval package.
- `nix develop -c zinc test` — rebuild + run the manifest test suite.
- `nix develop -c .zinc/build/spec` — re-run the manifest test binary (`N/N tests passed`).
- `nix develop -c zinc test manifest-evals` (or the member's test target name) — run the eval package's tests. IMPORTANT: read counts INSIDE `nix develop` (the compile-error shell-out tests need `ghc` on PATH).

**Pre-verified during planning (do not re-derive):**
- A zinc workspace member at `examples/manifest-evals/` depending on `manifest` builds and uses cross-package generic derivation + the record-dot extensions.
- Postgres `timestamptz`: accepts ISO8601-with-`Z` on insert; returns `YYYY-MM-DD HH:MM:SS[.ffffff]±HH` (space separator, `±HH` offset — e.g. `2026-06-10 10:53:21.123456+10`). The decoder must normalize the trailing offset to `±HHMM` before parsing with `%z`.
- `TableMeta` is NOT re-exported from the `Manifest` umbrella (it is in `Manifest.Core.Meta`); Task 5 adds it + the other umbrella exports the eval package needs.

---

## File Structure

**Layer 1 (manifest library):**
- `src/Manifest/Core/SqlType.hs` — add `SqlDouble`, `SqlTimestamptz`.
- `src/Manifest/Core/Codec.hs` — add `DbType Double`, `DbType UTCTime` + the pg-timestamp parser.
- `src/Manifest/Core/Index.hs`, `src/Manifest/Index.hs`, `src/Manifest/Migrate.hs` — add the `unique` (multi-column) index builder.
- `src/Manifest/Testing.hs` (NEW) — `withEphemeralDb` (extract the spinup from `test/Fixtures.hs`).
- `src/Manifest.hs` — re-export the new names + the gaps (`TableMeta`, `managed`, `migrateUp`, `ManagedTable`, `Index`/`gin`/`btree`/`unique`).
- `test/CodecSpec.hs` / `test/IndexSpec.hs` — unit tests for the new instances/builder.

**Layer 2 (eval package, all under `examples/manifest-evals/`):**
- `zinc.toml` (member) — package + lib + test targets, `depends = [..., "manifest"]`.
- `src/Evals/Ids.hs` — the typed-id newtypes.
- `src/Evals/Schema.hs` — the 12 entity records + `deriving via Table` instances + relationships + cascades + indexes.
- `src/Evals/Migrate.hs` — the `schema :: [ManagedTable]` list + a `migrateAll` helper.
- `test/Spec.hs`, `test/SchemaSpec.hs` — the package's tests.
- Root `zinc.toml` — add `examples/manifest-evals` to `[workspace] members`.

---

### Task 1: `DbType Double` + `SqlDouble` (manifest library)

**Files:** Modify `src/Manifest/Core/SqlType.hs`, `src/Manifest/Core/Codec.hs`, `src/Manifest.hs`, `test/CodecSpec.hs`.

- [ ] **Step 1: Failing unit test** — append to the `group "Codec"` in `test/CodecSpec.hs`:
```haskell
  , test "Double column round-trips and is double precision" $ do
      assertEqual "sqltype" SqlDouble (cSqlType (dbType @Double))
      assertEqual "encode"  (Just (BC.pack "1.5")) (encode (1.5 :: Double))
      assertEqual "decode"  (Right (1.5 :: Double)) (cDecode (dbType @Double) (Just (BC.pack "1.5")))
```
`nix develop -c zinc test 2>&1 | tail` → fails (`SqlDouble`/`DbType Double` undefined).

- [ ] **Step 2: `SqlDouble`** in `src/Manifest/Core/SqlType.hs`: add `SqlDouble` to the `SqlType` constructor list; `sqlTypeDDL SqlDouble = "DOUBLE PRECISION"`; `sqlTypeLive SqlDouble = "double precision"`.

- [ ] **Step 3: `DbType Double`** in `src/Manifest/Core/Codec.hs` (near the other scalar instances; `readMaybe`/`BC` already imported):
```haskell
instance DbType Double where
  dbType = Codec (Just . BC.pack . show)
                 (\p -> case p of
                          Just bs -> maybe (Left (DecodeError ("expected Double, got " <> show (BC.unpack bs)))) Right (readMaybe (BC.unpack bs))
                          Nothing -> Left (DecodeError "expected Double, got NULL"))
                 SqlDouble False
```

- [ ] **Step 4: Run** `nix develop -c zinc test 2>&1 | tail` then `.zinc/build/spec 2>&1 | tail -3` → **136/136**.

- [ ] **Step 5: Commit**
```bash
git add src/Manifest/Core/SqlType.hs src/Manifest/Core/Codec.hs test/CodecSpec.hs
git commit -m "feat(core): DbType Double + SqlDouble"
```

---

### Task 2: `DbType UTCTime` + `SqlTimestamptz` (manifest library)

**Files:** Modify `src/Manifest/Core/SqlType.hs`, `src/Manifest/Core/Codec.hs`, `test/CodecSpec.hs`, and add a DB round-trip in `test/MigrateSpec.hs` (or an existing DB spec).

- [ ] **Step 1: Failing unit test** (value-level round-trip) — append to `test/CodecSpec.hs` (add `import Data.Time (UTCTime); import Data.Time.Format (parseTimeM, defaultTimeLocale)` or build a UTCTime literal via `read`):
```haskell
  , test "UTCTime decodes the Postgres timestamptz text format" $ do
      assertEqual "sqltype" SqlTimestamptz (cSqlType (dbType @UTCTime))
      -- Postgres returns "YYYY-MM-DD HH:MM:SS[.ffffff]±HH"; decoder must handle the ±HH offset
      let bs = Just (BC.pack "2026-06-10 10:53:21.123456+10")
      assertEqual "decode +10 offset to UTC"
        (Right (read "2026-06-10 00:53:21.123456 UTC" :: UTCTime))
        (cDecode (dbType @UTCTime) bs)
```
Fails (undefined).

- [ ] **Step 2: `SqlTimestamptz`** in `SqlType.hs`: add constructor; `sqlTypeDDL SqlTimestamptz = "TIMESTAMPTZ"`; `sqlTypeLive SqlTimestamptz = "timestamp with time zone"`.

- [ ] **Step 3: `DbType UTCTime`** in `Codec.hs`. Add imports `import Data.Time (UTCTime); import Data.Time.Format (formatTime, parseTimeM, defaultTimeLocale); import Data.Char (isDigit)`.
```haskell
instance DbType UTCTime where
  dbType = Codec
    (\t -> Just (BC.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" t)))   -- ISO8601 UTC; Postgres accepts it
    (\p -> case p of
        Just bs -> maybe (Left (DecodeError ("expected timestamptz, got " <> show (BC.unpack bs)))) Right
                         (parsePgTimestamptz (BC.unpack bs))
        Nothing -> Left (DecodeError "expected timestamptz, got NULL"))
    SqlTimestamptz False

-- Parse Postgres ISO timestamptz "YYYY-MM-DD HH:MM:SS[.ffffff]±HH[:MM[:SS]]".
-- The time library's %z wants ±HHMM, so normalize the trailing offset first.
parsePgTimestamptz :: String -> Maybe UTCTime
parsePgTimestamptz s = parseTimeM True defaultTimeLocale "%Y-%m-%d %H:%M:%S%Q%z" (normalizeOffset s)
  where
    normalizeOffset str =
      case [ i | (i, c) <- zip [0 :: Int ..] str, c == '+' || c == '-', i > 10 ] of   -- last sign past the date
        [] -> str
        is -> let (ts, sign : off) = splitAt (last is) str
                  digs = take 4 (filter isDigit off ++ "0000")                          -- ±HH/±HH:MM/±HH:MM:SS -> ±HHMM
              in ts ++ sign : digs
```

- [ ] **Step 4: Run unit test** `nix develop -c .zinc/build/spec 2>&1 | tail -3` → **137/137**. If the decode assertion fails, print the parsed value and adjust `normalizeOffset`/format to match the empirically-confirmed Postgres output (`2026-06-10 10:53:21.123456+10`).

- [ ] **Step 5: DB round-trip test.** Read `test/MigrateSpec.hs` (or another DB spec) for the harness. Add a test that creates a table with a `timestamptz` column, inserts a `UTCTime` via `encode`, selects it back via `decodeCol`/the codec, and asserts equality — proving the insert format Postgres accepts and the decode format round-trip end to end against real Postgres. (Use `withEmptyDb` + `execText`.) Run → **138/138**.

- [ ] **Step 6: Commit**
```bash
git add src/Manifest/Core/SqlType.hs src/Manifest/Core/Codec.hs test/CodecSpec.hs test/MigrateSpec.hs
git commit -m "feat(core): DbType UTCTime + SqlTimestamptz (pg timestamptz round-trip)"
```

---

### Task 3: `unique` multi-column index builder (manifest library)

**Files:** Modify `src/Manifest/Core/Index.hs`, `src/Manifest/Index.hs`, `src/Manifest/Migrate.hs`, `src/Manifest.hs`, `test/IndexSpec.hs`. Read all three source files first.

- [ ] **Step 1: Failing test** — append to `test/IndexSpec.hs` a test that an entity with `indexes = [ unique [#a, #b] ]` produces a `CREATE UNIQUE INDEX … (a, b)` in the plan and the live index exists after `migrateUp`. (Mirror the existing gin/btree index tests in this file.)

- [ ] **Step 2: Extend `Core/Index.hs`.** Add a `unique` flag and a multi-column existential column:
```haskell
data IndexDef = IndexDef
  { idxName    :: ByteString
  , idxMethod  :: IndexMethod
  , idxUnique  :: Bool
  , idxColumns :: [ByteString]
  } deriving (Eq, Show)

newtype Index a = Index { indexSpec :: (IndexMethod, Bool, [ByteString]) }   -- (method, unique, column names)

data SomeColumn a = forall t. SomeColumn (Column a t)   -- needs ExistentialQuantification; import Column from Manifest.Core.Query
```
(Add the import of `Column(..)` from `Manifest.Core.Query`. Update `gin`/`btree` to the new triple shape: `Index (Gin, False, [c])` / `Index (Btree, False, [c])`.)

- [ ] **Step 3: `unique` builder in `src/Manifest/Index.hs`** + an `IsLabel` instance so `#col :: SomeColumn a`:
```haskell
import GHC.OverloadedLabels (IsLabel(..))
import GHC.TypeLits (KnownSymbol, symbolVal)
import Data.Proxy (Proxy(..))
import Manifest.Core.Meta (camelToSnake)
import Manifest.Core.Query (Column(..))

instance KnownSymbol name => IsLabel name (SomeColumn a) where
  fromLabel = SomeColumn (Column (camelToSnake (symbolVal (Proxy @name))))

unique :: [SomeColumn a] -> Index a
unique cols = Index (Btree, True, [ c | SomeColumn (Column c) <- cols ])
```
(Confirm `Column(..)` is exported from `Manifest.Core.Query`; if not, export it. `camelToSnake :: String -> ByteString` is in `Manifest.Core.Meta`.)

- [ ] **Step 4: Update `Migrate.hs`.** `mkIndexes` names a unique index `<table>_<cols>_unique_idx` (else `<table>_<cols>_<method>_idx`). `renderCreateIndex`:
```haskell
renderCreateIndex table (IndexDef n method uniq cols) =
  "CREATE " <> (if uniq then "UNIQUE " else "") <> "INDEX " <> n <> " ON " <> table
    <> (case method of Gin -> " USING gin"; Btree -> "") <> " (" <> BC.intercalate ", " cols <> ")"
```
Update `mkIndexes` to read the new `(method, unique, cols)` triple and set `idxUnique`. The create-only reconciliation in `indexesForTable` is unchanged.

- [ ] **Step 5: Umbrella** — export `unique`, `SomeColumn(..)` from `src/Manifest.hs` (alongside `gin`/`btree`).

- [ ] **Step 6: Run** `nix develop -c zinc test 2>&1 | tail` then `.zinc/build/spec 2>&1 | tail -3` → **139/139** (existing gin/btree index tests still green — the triple change is internal). 

- [ ] **Step 7: Commit**
```bash
git add src/Manifest/Core/Index.hs src/Manifest/Index.hs src/Manifest/Migrate.hs src/Manifest.hs test/IndexSpec.hs
git commit -m "feat(migrate): unique multi-column index builder"
```

---

### Task 4: `Manifest.Testing.withEphemeralDb` (manifest library)

Expose the ephemeral-Postgres spinup so consumer packages can test. Extract it from `test/Fixtures.hs`.

**Files:** Create `src/Manifest/Testing.hs`; Modify `src/Manifest.hs` (optional re-export), `zinc.toml` (the lib already depends on `process`/`directory`/`filepath`? — check; the spinup uses `callProcess`/`readProcess` from `process`, and temp dirs from `directory`/`temporary`. Add the deps the spinup needs to `[build.lib].depends`), and optionally refactor `test/Fixtures.hs` to reuse it.

- [ ] **Step 1: Read** `test/Fixtures.hs` lines around `withCluster`/`withEmptyDb` (≈195–227) — the `initdb`/`pg_ctl`/`Pool` setup.

- [ ] **Step 2: Create `src/Manifest/Testing.hs`** exporting `withEphemeralDb :: (Pool -> IO a) -> IO a` (the `withCluster []` behaviour: spin up an isolated cluster with NO tables, hand a `Pool`, tear down). Copy the `withCluster` body, importing `Pool`/pool-creation from the appropriate Manifest module (`Manifest.Postgres`/`Manifest.Session`). Add to `[build.lib].depends` whatever the spinup uses (`process`, `directory`, `filepath`, `temporary` if used) — check what `test/Fixtures.hs` imports.

- [ ] **Step 3: DRY (optional but preferred)** — change `test/Fixtures.hs`'s `withEmptyDb` to `withEmptyDb = withEphemeralDb` (re-exported), removing the duplicated spinup. Keep `withTestDb` (it pre-creates the fixture tables).

- [ ] **Step 4: Run** `nix develop -c zinc test 2>&1 | tail` → **139/139** unchanged (the harness still works).

- [ ] **Step 5: Commit**
```bash
git add src/Manifest/Testing.hs src/Manifest.hs zinc.toml test/Fixtures.hs
git commit -m "feat(testing): expose Manifest.Testing.withEphemeralDb for consumers"
```

---

### Task 5: Umbrella exports for the eval package (manifest library)

The eval package imports `Manifest` alone; make sure everything it needs is re-exported.

**Files:** Modify `src/Manifest.hs`.

- [ ] **Step 1:** Ensure the umbrella exports (add any missing): `TableMeta(..)` (from `Manifest.Core.Meta`), `managed`, `migrateUp`, `migrate`, `ManagedTable(..)`, `MigrationPlan(..)` (from `Manifest.Migrate`), `gin`, `btree`, `unique`, `Index`, `SomeColumn(..)` (from `Manifest.Index`/`Core.Index`), `UTCTime` re-export convenience is unnecessary (users import `Data.Time`). Add the corresponding `import` lines.

- [ ] **Step 2: Verify** `nix develop -c zinc build 2>&1 | tail -3` (clean) and `.zinc/build/spec 2>&1 | tail -3` → **139/139**.

- [ ] **Step 3: Commit**
```bash
git add src/Manifest.hs
git commit -m "feat(core): re-export TableMeta/managed/migrateUp/index builders from the umbrella"
```

---

### Task 6: Scaffold the `examples/manifest-evals/` workspace package

**Files:** Create `examples/manifest-evals/zinc.toml`, `examples/manifest-evals/src/Evals/Ids.hs` (stub), `examples/manifest-evals/test/Spec.hs` (stub); Modify root `zinc.toml`.

- [ ] **Step 1: Root workspace** — in `zinc.toml`, change `[workspace] members = ["."]` to `members = [".", "examples/manifest-evals"]`.

- [ ] **Step 2: Member `examples/manifest-evals/zinc.toml`:**
```toml
[package]
name = "manifest-evals"
version = "0.1.0.0"

[build.lib]
source-dirs = ["src"]
ghc-options = ["-Wall", "-XOverloadedStrings"]
depends = ["base", "text", "time", "bytestring", "aeson", "manifest"]

[build.test.spec]
source-dirs = ["test"]
main = "Spec.hs"
ghc-options = ["-XOverloadedStrings", "-lpq"]
depends = ["base", "text", "time", "bytestring", "aeson", "containers", "manifest", "manifest-evals"]
```

- [ ] **Step 3: Stub modules** so the package builds:
`examples/manifest-evals/src/Evals/Ids.hs`:
```haskell
module Evals.Ids () where
```
`examples/manifest-evals/test/Spec.hs`:
```haskell
module Main where
main :: IO ()
main = putStrLn "manifest-evals tests (none yet)"
```

- [ ] **Step 4: Build** `nix develop -c zinc build manifest-evals 2>&1 | tail -6` → builds (resolves `manifest` as a workspace member, per the planning verification).

- [ ] **Step 5: Commit**
```bash
git add zinc.toml examples/manifest-evals/
git commit -m "feat(evals): scaffold examples/manifest-evals workspace package"
```

---

### Task 7: Typed IDs + the 12 entities (eval package)

**Files:** Modify `examples/manifest-evals/src/Evals/Ids.hs`; Create `examples/manifest-evals/src/Evals/Schema.hs`.

- [ ] **Step 1: Typed IDs** — `Evals/Ids.hs` (transcribe spec §1 verbatim):
```haskell
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Evals.Ids where
import Manifest (DbType)
newtype OrgId            = OrgId Int            deriving newtype DbType
newtype DatasetId        = DatasetId Int        deriving newtype DbType
newtype DatasetVersionId = DatasetVersionId Int deriving newtype DbType
newtype ExampleId        = ExampleId Int        deriving newtype DbType
newtype TargetId         = TargetId Int         deriving newtype DbType
newtype TargetVersionId  = TargetVersionId Int  deriving newtype DbType
newtype GraderId         = GraderId Int         deriving newtype DbType
newtype GraderVersionId  = GraderVersionId Int  deriving newtype DbType
newtype RunId            = RunId Int            deriving newtype DbType
newtype OutputId         = OutputId Int         deriving newtype DbType
newtype ScoreId          = ScoreId Int          deriving newtype DbType
newtype RunMetricId      = RunMetricId Int      deriving newtype DbType
```

- [ ] **Step 2: `Evals/Schema.hs`** header + the 12 entities. Module pragmas:
```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
module Evals.Schema where
import Data.Aeson (Value)
import Data.Functor.Identity (Identity)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Manifest
import Evals.Ids
```
Transcribe the **12 entity declarations from spec §2 verbatim** (bare-name, record-dot style), each followed by its `type X = XT Identity` and `deriving via (Table "table_name" XT) instance Entity X`. The first is the pattern for all:
```haskell
data DatasetT f = Dataset
  { id        :: Field f (Pk DatasetId)
  , org       :: Field f OrgId
  , name      :: Field f Text
  , slug      :: Field f Text
  , createdAt :: Field f UTCTime
  } deriving Generic
type Dataset = DatasetT Identity
deriving via (Table "datasets" DatasetT) instance Entity Dataset
```
(`Run`, `Target`, `Grader` keep the `cascadeRules`/`indexes` explicit-instance form — Task 8/9 — so for now derive them plain via `Table`; the explicit instances replace the `deriving via` line in those tasks. The flexible jsonb payloads are `Aeson Value`.)

- [ ] **Step 3: Build** `nix develop -c zinc build manifest-evals 2>&1 | tail -8` → compiles. This exercises the full HKD + record-dot + typed-id + jsonb + UTCTime stack across the package boundary.

- [ ] **Step 4: Commit**
```bash
git add examples/manifest-evals/src/Evals/Ids.hs examples/manifest-evals/src/Evals/Schema.hs
git commit -m "feat(evals): typed ids + 12 entities (record-dot style)"
```

---

### Task 8: Relationships + cascades (eval package)

**Files:** Modify `examples/manifest-evals/src/Evals/Schema.hs`.

- [ ] **Step 1: Relationships** — add the `HasRelation` instances from spec §3 (each names `Target`, `Cardinality`, `relSpec`). Example:
```haskell
instance HasRelation Dataset "versions" where
  type Target      Dataset "versions" = [DatasetVersion]
  type Cardinality Dataset "versions" = 'Many
  relSpec = hasMany (Proxy @"dataset")           -- FK column on DatasetVersion

instance HasRelation Run "outputs" where
  type Target      Run "outputs" = [Output]
  type Cardinality Run "outputs" = 'Many
  relSpec = hasMany (Proxy @"run")
```
Add the full set per spec §3 (Dataset→versions, DatasetVersion→examples, Target→versions, Grader→versions, Run→outputs, Run→metrics, Output→scores, and the `belongsTo` reverse directions used by tests).

- [ ] **Step 2: Cascades** — replace the plain `deriving via` for the cascade-bearing entities with explicit instances carrying `cascadeRules` (Cascade for ownership, Restrict for referenced versions), per spec §3:
```haskell
instance Entity Dataset where
  tableMeta    = genericTableMeta @DatasetT "datasets"
  cascadeRules = [ cascade (Proxy @DatasetVersion) (Proxy @"dataset") Cascade ]

instance Entity DatasetVersion where
  tableMeta    = genericTableMeta @DatasetVersionT "dataset_versions"
  cascadeRules = [ cascade (Proxy @Example) (Proxy @"datasetVersion") Cascade
                 , cascade (Proxy @Run)     (Proxy @"datasetVersion") Restrict ]   -- protect a referenced version

instance Entity Run where
  tableMeta    = genericTableMeta @RunT "runs"
  cascadeRules = [ cascade (Proxy @Output)    (Proxy @"run") Cascade
                 , cascade (Proxy @RunMetric) (Proxy @"run") Cascade ]
-- ...Target, Grader, TargetVersion, GraderVersion, Output per spec §3
```
(Remove the `deriving via (Table …) instance Entity X` line for each entity that now has an explicit instance.)

- [ ] **Step 3: Build** `nix develop -c zinc build manifest-evals 2>&1 | tail -8` → compiles.

- [ ] **Step 4: Commit**
```bash
git add examples/manifest-evals/src/Evals/Schema.hs
git commit -m "feat(evals): relationships + cascade/restrict rules"
```

---

### Task 9: Indexes + migration wiring (eval package)

**Files:** Modify `examples/manifest-evals/src/Evals/Schema.hs`; Create `examples/manifest-evals/src/Evals/Migrate.hs`.

- [ ] **Step 1: Indexes** — add `indexes` to the relevant entity instances (spec §4): `gin` on queried jsonb (`Example.input`, `Output.response`, `Run.meta`), `btree` on hot FKs (`Output.run`, `Score.output`, `Example.datasetVersion`, `Run.datasetVersion`, `Run.targetVersion`), `unique` on `(dataset, version)` / `(target, version)` / `(grader, version)`:
```haskell
instance Entity DatasetVersion where
  tableMeta    = genericTableMeta @DatasetVersionT "dataset_versions"
  cascadeRules = [ … ]
  indexes      = [ unique [#dataset, #version] ]

instance Entity Example where
  tableMeta = genericTableMeta @ExampleT "examples"
  indexes   = [ gin #input, btree #datasetVersion ]
-- ...Output (gin #response, btree #run), Run (gin #meta, btree #datasetVersion, btree #targetVersion), Score (btree #output), Target/GraderVersion unique ...
```

- [ ] **Step 2: `Evals/Migrate.hs`** — the managed schema list + a helper:
```haskell
module Evals.Migrate (schema, migrateAll) where
import Data.Proxy (Proxy(..))
import Manifest
import Evals.Schema

schema :: [ManagedTable]
schema =
  [ managed (Proxy @Dataset), managed (Proxy @DatasetVersion), managed (Proxy @Example)
  , managed (Proxy @Target),  managed (Proxy @TargetVersion)
  , managed (Proxy @Grader),  managed (Proxy @GraderVersion)
  , managed (Proxy @Run),     managed (Proxy @Output), managed (Proxy @Score), managed (Proxy @RunMetric) ]

migrateAll :: Db MigrationPlan
migrateAll = migrateUp schema
```

- [ ] **Step 3: Build** `nix develop -c zinc build manifest-evals 2>&1 | tail -8` → compiles.

- [ ] **Step 4: Commit**
```bash
git add examples/manifest-evals/src/Evals/Schema.hs examples/manifest-evals/src/Evals/Migrate.hs
git commit -m "feat(evals): indexes + managed schema/migrate helper"
```

---

### Task 10: Tests — migrate idempotent + full round-trip (eval package)

**Files:** Create `examples/manifest-evals/test/SchemaSpec.hs`; Modify `examples/manifest-evals/test/Spec.hs`.

- [ ] **Step 1: Test harness** — `Spec.hs` runs the spec(s). Use `Manifest.Testing.withEphemeralDb` for the DB. Write a minimal assertion helper (or reuse a tiny `assertEqual` of your own, since the eval package does not depend on manifest's `test/Harness.hs`). `Spec.hs`:
```haskell
module Main where
import qualified SchemaSpec
main :: IO ()
main = SchemaSpec.main
```

- [ ] **Step 2: `SchemaSpec.hs`** — migration idempotency + a full round-trip. Use `withEphemeralDb` + `withSession` + `migrateAll` + `add`/`get`. Concretely:
```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module SchemaSpec (main) where
import Control.Monad (unless)
import Data.Aeson (Value, object, (.=))
import Data.Time (getCurrentTime)
import Manifest
import Manifest.Testing (withEphemeralDb)
import Evals.Schema
import Evals.Migrate (migrateAll)

main :: IO ()
main = withEphemeralDb $ \pool -> do
  -- migrate twice; second run is a no-op (empty additive plan)
  p1 <- withSession pool migrateAll
  p2 <- withSession pool migrateAll
  expect "second migrate is a no-op" (null (planAdditive p2))
  now <- getCurrentTime
  out <- withSession pool $ do
    d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "demo", slug = "demo", createdAt = now })
    v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now })
    _  <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c1", input = Aeson (object ["q" .= ("2+2"::Text)]), expected = Just (Aeson (object ["a" .= (4::Int)])), meta = Nothing })
    got <- get @Dataset (Key d.id)
    pure (fmap (.name) got)
  expect "dataset round-trips by typed Key" (out == Just "demo")
  putStrLn "manifest-evals SchemaSpec: OK"
  where
    expect msg ok = unless ok (ioError (userError msg))
```
(Adjust `Aeson`/`object` imports; `Aeson` is the column wrapper from `Manifest`, `object`/`.=` from `Data.Aeson`. This exercises typed IDs, `.field` dot access, jsonb (`Aeson Value`), `UTCTime`, the migration, and `get` by typed `Key`.)

- [ ] **Step 3: Run** `nix develop -c zinc test manifest-evals 2>&1 | tail -15` (or build the test exe and run it inside `nix develop`). Expected: prints `OK`, exit 0. If `zinc test` does not target the member, run `nix develop -c .zinc/build/<member-spec>` — confirm the exact path from the build output.

- [ ] **Step 4: Commit**
```bash
git add examples/manifest-evals/test/
git commit -m "test(evals): migrate idempotency + full round-trip"
```

---

### Task 11: Tests — cascade + restrict behaviour (eval package)

**Files:** Modify `examples/manifest-evals/test/SchemaSpec.hs`.

- [ ] **Step 1:** Add two checks in `SchemaSpec.main`:
  - **Cascade:** create a `Run` with an `Output` and a `Score`; `delete` the run (or `deleteWhere @Run [...]`); assert the run's outputs and scores are gone (`selectWhere`/a count query returns empty).
  - **Restrict:** create a `DatasetVersion` referenced by a `Run`; attempt to delete that `DatasetVersion`; assert it is **rejected** (the operation throws / the row remains). Catch the expected exception (`try`/`catch` on the `DbException`) and assert the version still exists.
  Use concrete `add`/`delete`/`selectWhere` calls and `expect` assertions as in Task 10.

- [ ] **Step 2: Run** → prints OK. Deliberately break one assertion, confirm failure, restore.

- [ ] **Step 3: Commit**
```bash
git add examples/manifest-evals/test/SchemaSpec.hs
git commit -m "test(evals): cascade + restrict behaviour"
```

---

### Task 12: Tests — aggregate + compare-runs queries (eval package)

**Files:** Modify `examples/manifest-evals/test/SchemaSpec.hs`.

- [ ] **Step 1:** Seed two runs over the same dataset version with scores, then:
  - **Aggregate:** the query from spec §4 (`avg_`/`countRows` over `Score⨝Output` grouped by grader version) returns the correct mean + count for a run.
  - **Compare:** join the two runs' outputs by `Example.key` and assert the per-example score pairs line up.
  Use `runQuery`, `from @Output`, `innerJoin @Score`, `?.` projections, `avg_`, `groupBy`, `val` per the spec §4 example. Assert exact numbers against the seeded scores.

- [ ] **Step 2: Run** → OK (with a deliberate-failure check).

- [ ] **Step 3: Commit**
```bash
git add examples/manifest-evals/test/SchemaSpec.hs
git commit -m "test(evals): aggregate + compare-runs queries"
```

---

## Self-Review

**1. Spec coverage:**
- §1 typed IDs → Task 7. §2 entities (bare-name) → Task 7 (verbatim from spec). §3 relationships + Cascade/Restrict → Task 8. §4 indexes (gin/btree/unique) + aggregate/compare queries → Tasks 9, 12. §5 Manifest extensions (UTCTime, Double, unique index) → Tasks 1-3; the testing helper (consumer needs ephemeral DB) → Task 4. §6 RLS-ready `org` column, no policies → present in the Task 7 entities, no `rlsPolicies`. §7 immutability (Restrict + unique index + finalizedAt) → Tasks 3, 8, 9. §8 testing (migrate idempotent, round-trip incl. timestamp/Double/jsonb, cascade/restrict, aggregate/compare) → Tasks 10-12. Housing (examples/ workspace member) → Task 6. Record-dot style → Tasks 6-7. ✓ No gaps.

**2. Placeholder scan:** Library-extension tasks (1-5) carry full code. The eval-package entity transcription (Task 7) references spec §2, which contains the 12 declarations verbatim — that is a stable committed artifact, not a "similar to Task N" dodge; the pattern + first entity are shown in full. Relationships/cascades/indexes (Tasks 8-9) show the pattern + the full set to add per spec §3/§4. The one genuinely environment-dependent spot (the member test target's exact run command) is called out in Task 10 Step 3 to confirm from build output. No TBD/TODO.

**3. Type consistency:** `DbType Double`/`SqlDouble`, `DbType UTCTime`/`SqlTimestamptz`/`parsePgTimestamptz`, `unique`/`SomeColumn`/`IndexDef{idxUnique}`, `withEphemeralDb`, `schema`/`migrateAll`/`MigrationPlan{planAdditive}` are used identically across tasks. Entity/field names match spec §2 (bare-name: `Dataset.id`, `DatasetVersion.dataset`, `Example.datasetVersion`, `Run.run`/`Output.run`, `Score.output`/`Score.graderVersion`, `Score.value`). The `Aeson Value` jsonb wrapper and `Key d.id` typed-key usage match the library. Manifest-suite counts thread 135 → 136 (T1) → 138 (T2) → 139 (T3) → held (T4-5); the eval package has its own test target.
