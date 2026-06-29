# `References` FK markers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `References T` HKD field marker that types an FK column as the target's PK and makes the migration engine emit a real `FOREIGN KEY … REFERENCES target(pk)` constraint.

**Architecture:** `References T` projects via `Base (References T) = PrimKey T`, so the existing catch-all `Field` clauses make it a readwrite scalar with zero new projection clauses. DDL needs the target's table + PK names, which only exist as runtime values in `Entity target`'s `tableMeta`; a type-level walk (`GForeignKeys`) over `Rep (t Exposed)` resolves them, wired into each entity as a new defaulted `Entity` method (`foreignKeys`) the deriving-via carrier fills in. `PrimKey` is relocated down so `Base` can reference it.

**Tech Stack:** Haskell (GHC 9.12.2), HKD type families, GHC.Generics, custom `Harness` test runner (no hspec), ephemeral Postgres via `withEmptyDb`. Build tool: `zinc` (workspace monorepo).

## Global Constraints

- **manifest-core is a dependency of crucible and manifest-evals.** After changing it, build the WHOLE workspace from the repo root: `zinc build` — not just one member.
- **Run the manifest suite from the REPO ROOT** as `zinc test manifest:spec`. Do NOT `cd manifest` (it is a workspace member; that fails). Bare `zinc test manifest` matches the wrong member.
- The test harness is the project's own `Harness` module (`group`/`test`/`assertEqual`/`assertBool`); there is no hspec. Match existing spec style.
- New test modules under `manifest/test/` are auto-discovered once imported by `manifest/test/Spec.hs` — there is no cabal module list to edit. Register a new spec by adding an import + `++ XSpec.tests` to the `runTests (...)` chain in `Spec.hs`.
- `References` projections must make the FK a plain readwrite scalar of the target's PK type. No `ON DELETE` policy in this bead (deferred to a follow-up); emit `REFERENCES target(pk)` with no `ON DELETE` clause.
- Existing app-level cascade machinery (`Manifest.Core.Cascade`, `cascadeRules`, `flushDelete`) is UNCHANGED.
- Spec: `docs/superpowers/specs/2026-06-29-forge-u0w-references-fk-markers-design.md`.

---

### Task 1: Relocate `Table` newtype + `PrimKey`/`GPrimKeyType` into `Core.Table`

Pure refactor with no behavioural change: move the three type-level definitions down so `Base` can reference `PrimKey` in Task 2. `Manifest.Entity` re-exports them so every existing import keeps working. The deliverable's test is the unchanged whole suite + workspace build.

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Table.hs` (receive the moved defs)
- Modify: `manifest/manifest-core/src/Manifest/Entity.hs` (remove the defs; re-export from `Core.Table`)

**Interfaces:**
- Consumes: `Base`, `Exposed` (already in `Core.Table`).
- Produces (now exported from `Manifest.Core.Table`, and re-exported by `Manifest.Entity`): `newtype Table (name :: Symbol) (t :: (Type -> Type) -> Type) = Table (t Identity)`; `type family PrimKey a`; `type family GPrimKeyType (rep :: Type -> Type) :: Type`.

- [ ] **Step 1: Read both files** to capture the exact current text.

Read `manifest/manifest-core/src/Manifest/Entity.hs` and locate three definitions to move verbatim: the `newtype Table …`, the `type family PrimKey a where …`, and the `type family GPrimKeyType (rep …) where …` blocks (currently around lines 49–72). Read `manifest/manifest-core/src/Manifest/Core/Table.hs` to see its current imports/exports.

- [ ] **Step 2: Add the moved definitions to `Core.Table`**

In `Manifest/Core/Table.hs`:
- Add to the language pragma block (if not already present): `{-# LANGUAGE TypeOperators #-}`.
- Add imports: `import GHC.TypeLits (Symbol, TypeError, ErrorMessage(..))` and `import GHC.Generics (Rep)`. (`Data.Functor.Identity (Identity)` and `Data.Kind (Type)` are already imported.)
- Add to the module export list: `Table(..)`, `PrimKey`, `GPrimKeyType`.
- Paste the three blocks verbatim (the `newtype Table …`, `type family PrimKey …`, `type family GPrimKeyType …`) at the end of the module.

- [ ] **Step 3: Remove the definitions from `Entity.hs` and re-export them**

In `Manifest/Entity.hs`:
- Delete the three moved blocks (`newtype Table`, `type family PrimKey`, `type family GPrimKeyType`).
- Add `import Manifest.Core.Table (… , Table(..), PrimKey, GPrimKeyType)` (merge into the existing `Manifest.Core.Table` import line, which currently imports `Exposed, Base`).
- Keep `Table(..)`, `PrimKey`, `GPrimKeyType` in `Entity.hs`'s module export list (they are now re-exports) so `Manifest.Entity (Table(..), PrimKey, …)` importers are unaffected.

- [ ] **Step 4: Build the whole workspace**

Run: `zinc build`
Expected: SUCCESS across the workspace. (If `Core.Table` reports an unused-import or a missing extension, fix the pragma/imports. A failure naming `Table`/`PrimKey` not in scope means an export/import was missed.)

- [ ] **Step 5: Run the manifest suite (no behaviour should change)**

Run: `zinc test manifest:spec`
Expected: PASS — identical to before the refactor.

- [ ] **Step 6: Commit**

```bash
git add manifest/manifest-core/src/Manifest/Core/Table.hs manifest/manifest-core/src/Manifest/Entity.hs
git commit -m "refactor(manifest-core): relocate Table/PrimKey/GPrimKeyType into Core.Table"
```

---

### Task 2: `References` marker + projections + `FieldMeta`

Add the marker and its type-level behaviour. Deliverable: compile-time projection proofs.

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Table.hs`
- Create: `manifest/test/ReferencesSpec.hs`
- Modify: `manifest/test/Spec.hs` (register the new spec)

**Interfaces:**
- Consumes: `PrimKey` (now in `Core.Table` from Task 1); `Base`, `Field`, `FieldMeta`, `DbType`.
- Produces: `References :: Type -> Type` (exported); `Base (References t) = PrimKey t`; `Base (Maybe a) = Maybe (Base a)`; `FieldMeta (References t)` and `FieldMeta (Maybe (References t))` instances (requiring `DbType (PrimKey t)`).

- [ ] **Step 1: Write the failing projection proofs** — create `manifest/test/ReferencesSpec.hs`.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
module ReferencesSpec (tests) where

import Data.Functor.Identity (Identity)
import Manifest.Core.Table (Field, Create, Update, Patch(..), Nullable, References)
import Fixtures (User)
import Harness

-- Projection proofs: an FK column is a readwrite scalar of the target's PK type.
_createFkScalar :: Field Create (References User) -> Int
_createFkScalar = id
_identityFkScalar :: Field Identity (References User) -> Int
_identityFkScalar = id
_updateFkPatch :: Field Update (References User) -> Patch Int
_updateFkPatch = id
_createNullableFk :: Field Create (Nullable (References User)) -> Maybe Int
_createNullableFk = id

tests :: [Test]
tests = group "References"
  [ test "FK projection proofs compile" $ assertBool "ok" True ]
```

Register it in `manifest/test/Spec.hs`: add `import qualified ReferencesSpec` near the other imports and append `++ ReferencesSpec.tests` to the `runTests (...)` chain.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `zinc test manifest:spec`
Expected: COMPILE FAILURE — `References` not exported from `Manifest.Core.Table`.

- [ ] **Step 3: Add the marker, Base clauses, and FieldMeta instances** in `Manifest/Core/Table.hs`.

3a. Export `References` (add to the module export list near `Generated`/`Touched`):
```haskell
  , References
```

3b. Add the marker declaration (near the other markers):
```haskell
-- | Marker: a foreign-key column referencing entity @t@. The column's runtime
-- value is @t@'s primary key (@Base (References t) = PrimKey t@); the migration
-- engine emits a @REFERENCES t(pk)@ constraint. Nullable (optional) FKs compose
-- with 'Nullable': @Nullable (References t)@.
data References (t :: Type)
```

3c. Add `Base` clauses (in the `Base` family, before the catch-all `Base a = a`):
```haskell
  Base (References t) = PrimKey t
  Base (Maybe a)      = Maybe (Base a)
```

3d. Add `FieldMeta` instances (after the existing instances). They need `DbType` and `PrimKey` — both in scope in `Core.Table`:
```haskell
instance DbType (PrimKey t) => FieldMeta (References t) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldNullable = False
  fieldSqlType = cSqlType (dbType @(PrimKey t))

instance DbType (PrimKey t) => FieldMeta (Maybe (References t)) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldNullable = True
  fieldSqlType = cSqlType (dbType @(PrimKey t))
```

- [ ] **Step 4: Run the suite to verify the proofs compile and pass**

Run: `zinc test manifest:spec`
Expected: PASS — `ReferencesSpec` compiles (projections hold), the whole suite stays green (the `Base (Maybe a)` clause is backward-compatible: `Base (Maybe Text) = Maybe Text` as before).

- [ ] **Step 5: Whole-workspace build**

Run: `zinc build`
Expected: SUCCESS.

- [ ] **Step 6: Commit**

```bash
git add manifest/manifest-core/src/Manifest/Core/Table.hs manifest/test/ReferencesSpec.hs manifest/test/Spec.hs
git commit -m "feat(manifest-core): add References FK marker (projects to target PrimKey)"
```

---

### Task 3: FK reflection — `ForeignKey`, `GForeignKeys`, `Entity.foreignKeys`

Resolve each entity's FK targets (table + PK names) at the type level and surface them as a defaulted `Entity` method. Deliverable: a pure (no-DB) unit test of the reflection on a fixture.

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Meta.hs` (add the `ForeignKey` type)
- Modify: `manifest/manifest-core/src/Manifest/Entity.hs` (add the `foreignKeys` method, default `[]`)
- Create: `manifest/manifest-core/src/Manifest/Core/ForeignKey.hs` (`GForeignKeys`, `genericForeignKeys`)
- Modify: `manifest/manifest-core/src/Manifest/Derive.hs` (wire the carrier)
- Add to: `manifest/test/ReferencesSpec.hs` (reflection unit test)

**Interfaces:**
- Consumes: `References` marker (Task 2); `Entity`, `tableMeta`, `pkColumn`, `tmTable`, `cmName`, `camelToSnake`, `Exposed`.
- Produces:
  - `data ForeignKey = ForeignKey { fkColumn :: ByteString, fkRefTable :: ByteString, fkRefPkColumn :: ByteString } deriving (Eq, Show)` (in `Manifest.Core.Meta`).
  - `class GForeignKeys (rep :: Type -> Type) where gForeignKeys :: [ForeignKey]` and `genericForeignKeys :: forall t. (Generic (t Exposed), GForeignKeys (Rep (t Exposed))) => [ForeignKey]` (in `Manifest.Core.ForeignKey`).
  - `Entity` method `foreignKeys :: [ForeignKey]` (default `[]`).

- [ ] **Step 1: Add the `ForeignKey` type to `Meta.hs`**

In `manifest/manifest-core/src/Manifest/Core/Meta.hs`, add to the export list `ForeignKey(..)` and define:
```haskell
-- | A resolved foreign key: the local FK column, and the target table + PK column
-- it references. Drives the @REFERENCES@ DDL clause.
data ForeignKey = ForeignKey
  { fkColumn      :: ByteString
  , fkRefTable    :: ByteString
  , fkRefPkColumn :: ByteString
  } deriving (Eq, Show)
```

- [ ] **Step 2: Add the `foreignKeys` method to `Entity` (default `[]`)**

In `manifest/manifest-core/src/Manifest/Entity.hs`:
- Import the type: add `ForeignKey` to the existing `import Manifest.Core.Meta (...)` list.
- In the `Entity` class body, add (next to `cascadeRules`):
```haskell
  -- | Foreign-key constraints for this entity's columns, for DDL. Default: none.
  -- The deriving-via carrier ('Manifest.Derive') fills this with
  -- 'genericForeignKeys'; manual instances with FK columns opt in the same way.
  foreignKeys :: [ForeignKey]
  foreignKeys = []
```

- [ ] **Step 3: Create the reflection module** `manifest/manifest-core/src/Manifest/Core/ForeignKey.hs`

```haskell
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Type-level reflection of an entity's foreign-key columns. Walks the
-- @Rep (t Exposed)@ and, for each 'References'-marked field, reads the target's
-- table + PK column from its 'Entity' dictionary. Lives above 'Entity' so it can
-- consult @tableMeta \@target@.
module Manifest.Core.ForeignKey
  ( GForeignKeys(..)
  , genericForeignKeys
  ) where

import Data.Kind (Type)
import GHC.Generics
import Manifest.Core.Meta (ForeignKey(..), camelToSnake, cmName, pkColumn, tmTable)
import Manifest.Core.Table (Exposed, References)
import Manifest.Entity (Entity, tableMeta)

class GForeignKeys (rep :: Type -> Type) where
  gForeignKeys :: [ForeignKey]

instance GForeignKeys f => GForeignKeys (D1 m f) where gForeignKeys = gForeignKeys @f
instance GForeignKeys f => GForeignKeys (C1 m f) where gForeignKeys = gForeignKeys @f
instance (GForeignKeys a, GForeignKeys b) => GForeignKeys (a :*: b) where
  gForeignKeys = gForeignKeys @a ++ gForeignKeys @b

-- A required FK field: Exposed (References target).
instance (Selector m, Entity target)
    => GForeignKeys (S1 m (Rec0 (Exposed (References target)))) where
  gForeignKeys =
    [ ForeignKey
        { fkColumn      = camelToSnake (selName (undefined :: S1 m (Rec0 (Exposed (References target))) p))
        , fkRefTable    = tmTable (tableMeta @target)
        , fkRefPkColumn = cmName (pkColumn (tableMeta @target))
        } ]

-- A nullable FK field: Exposed (Maybe (References target)).
instance (Selector m, Entity target)
    => GForeignKeys (S1 m (Rec0 (Exposed (Maybe (References target))))) where
  gForeignKeys =
    [ ForeignKey
        { fkColumn      = camelToSnake (selName (undefined :: S1 m (Rec0 (Exposed (Maybe (References target))) ) p))
        , fkRefTable    = tmTable (tableMeta @target)
        , fkRefPkColumn = cmName (pkColumn (tableMeta @target))
        } ]

-- Any other field contributes no foreign key.
instance {-# OVERLAPPABLE #-} GForeignKeys (S1 m (Rec0 other)) where
  gForeignKeys = []

-- | An entity's foreign keys from the Generic rep of @t Exposed@.
genericForeignKeys
  :: forall t. (Generic (t Exposed), GForeignKeys (Rep (t Exposed))) => [ForeignKey]
genericForeignKeys = gForeignKeys @(Rep (t Exposed))
```

Note for the implementer: confirm `camelToSnake`, `cmName`, `pkColumn`, `tmTable` are exported from `Manifest.Core.Meta` (they are used by `Manifest.Core.Relation` already — check that module's import line). If `pkColumn` or `tmTable` is not exported, add it to `Meta.hs`'s export list as part of this task.

- [ ] **Step 4: Register the new module for the build**

`Manifest.Core.ForeignKey` must be a member of the `manifest-core` library. Read `manifest/manifest-core/zinc.toml`; if it lists library modules explicitly, add `Manifest.Core.ForeignKey`. If modules are auto-discovered from a source dir, no change is needed. (The other `Manifest.Core.*` modules are the reference — match how they are declared.)

- [ ] **Step 5: Wire the deriving-via carrier** in `manifest/manifest-core/src/Manifest/Derive.hs`

- Add imports: `import GHC.Generics (Rep)` is already present; add `import Manifest.Core.ForeignKey (GForeignKeys, genericForeignKeys)`.
- Add `GForeignKeys (Rep (t Exposed))` to the instance context (next to `GColumns (Rep (t Exposed))`).
- Add the method body: `foreignKeys = genericForeignKeys @t`.

- [ ] **Step 6: Add the reflection unit test** to `manifest/test/ReferencesSpec.hs`

Add a fixture entity with a required and a nullable FK to `User`, and assert its reflected foreign keys. Add these imports to `ReferencesSpec.hs`:
```haskell
import Data.Text (Text)
import GHC.Generics (Generic)
import Manifest.Core.Table (Field, PrimaryKey, Serial)
import Manifest.Core.Meta (ForeignKey(..))
import Manifest.Entity (Entity(..), Table(..))
import Fixtures (User, UserT)
```
Define the fixture and test:
```haskell
data DocT f = Doc
  { docId     :: Field f (PrimaryKey (Serial Int))
  , docAuthor :: Field f (References User)            -- required FK
  , docEditor :: Field f (Nullable (References User))  -- nullable FK
  } deriving Generic
type Doc = DocT Identity
deriving via (Table "docs" DocT) instance Entity Doc

-- add to the `tests` list:
  , test "genericForeignKeys reflects required + nullable FK targets" $
      assertEqual "fks"
        [ ForeignKey "doc_author" "users" "user_id"
        , ForeignKey "doc_editor" "users" "user_id" ]
        (foreignKeys @Doc)
```
(`Doc`/`DocT` is reused by Task 5; define it cleanly here.)

- [ ] **Step 7: Run the suite to verify it passes**

Run: `zinc test manifest:spec`
Expected: PASS — `foreignKeys @Doc` returns the two reflected FKs; existing entities (no marker) reflect `[]` and stay green.

- [ ] **Step 8: Whole-workspace build**

Run: `zinc build`
Expected: SUCCESS.

- [ ] **Step 9: Commit**

```bash
git add manifest/manifest-core/src/Manifest/Core/Meta.hs manifest/manifest-core/src/Manifest/Entity.hs manifest/manifest-core/src/Manifest/Core/ForeignKey.hs manifest/manifest-core/src/Manifest/Derive.hs manifest/manifest-core/zinc.toml manifest/test/ReferencesSpec.hs
git commit -m "feat(manifest-core): reflect entity foreign keys (GForeignKeys + Entity.foreignKeys)"
```

---

### Task 4: Emit FK constraints in migration DDL

Carry the reflected FKs into `ManagedTable` and emit `FOREIGN KEY … REFERENCES …` in CREATE TABLE and inline in ADD COLUMN. Deliverable: DDL render tests.

**Files:**
- Modify: `manifest/src/Manifest/Migrate.hs`
- Add to: `manifest/test/ReferencesSpec.hs` (DDL render tests)

**Interfaces:**
- Consumes: `foreignKeys @a` (Task 3); `ForeignKey(..)`; `managed`, `ManagedTable`, `renderCreateTable`, `renderAddColumn`.
- Produces: `ManagedTable` field `mtForeignKeys :: [ForeignKey]`; FK clauses in `renderCreateTable` (table-level) and `renderAddColumn` (inline).

- [ ] **Step 1: Write the failing DDL render tests** — add to `manifest/test/ReferencesSpec.hs`.

Add imports:
```haskell
import Data.Proxy (Proxy(..))
import Manifest.Migrate (ManagedTable(..), managed, renderCreateTable, renderAddColumn)
import Manifest.Core.Meta (ColumnMeta(..), SqlType(..))
```
Add tests (reusing the `Doc` fixture from Task 3):
```haskell
  , test "renderCreateTable appends FK constraints (required + nullable)" $
      assertEqual "create"
        "CREATE TABLE docs (doc_id BIGSERIAL PRIMARY KEY, doc_author BIGINT NOT NULL, \
        \doc_editor BIGINT, FOREIGN KEY (doc_author) REFERENCES users(user_id), \
        \FOREIGN KEY (doc_editor) REFERENCES users(user_id))"
        (renderCreateTable (managed (Proxy @Doc)))
  , test "renderAddColumn emits the FK inline for a marked column" $
      assertEqual "add"
        "ALTER TABLE docs ADD COLUMN doc_author BIGINT NOT NULL REFERENCES users(user_id)"
        (renderAddColumn' (managed (Proxy @Doc)) "docs"
           (ColumnMeta "doc_author" False False False False SqlBigInt False))
```

Note on the second test's helper: `renderAddColumn` currently has signature `ByteString -> ColumnMeta -> ByteString` and does not know the table's FKs. This task changes it to also take the FK list (see Step 3). Use whatever final signature Step 3 produces; the test above calls a `renderAddColumn'` that takes the `ManagedTable` — adjust the call to match the real signature you implement (the key assertion is the emitted string). If you keep `renderAddColumn :: ByteString -> [ForeignKey] -> ColumnMeta -> ByteString`, call it `renderAddColumn "docs" (mtForeignKeys (managed (Proxy @Doc))) (ColumnMeta …)`.

(The `ColumnMeta` literal has 7 fields — `name isPK isSerial isGenerated touchedOnUpdate sqlType nullable` — matching the current record; confirm against `Meta.hs`.)

- [ ] **Step 2: Run the suite to verify it fails**

Run: `zinc test manifest:spec`
Expected: COMPILE FAILURE / assertion failure — `mtForeignKeys` does not exist and the DDL lacks `FOREIGN KEY`.

- [ ] **Step 3: Add `mtForeignKeys` and emit the clauses** in `manifest/src/Manifest/Migrate.hs`.

3a. Import: add `ForeignKey(..)` to the `import Manifest.Core.Meta (...)` line, and `foreignKeys` to the `import Manifest.Entity (...)` line.

3b. Add the field to `ManagedTable`:
```haskell
data ManagedTable = ManagedTable
  { mtName        :: ByteString
  , mtColumns     :: [ColumnMeta]
  , mtPolicies    :: [PolicyDef]
  , mtIndexes     :: [IndexDef]
  , mtForeignKeys :: [ForeignKey]
  } deriving (Eq, Show)
```

3c. Populate it in `managed` (it has `Entity a` in scope):
```haskell
managed :: forall a. Entity a => Proxy a -> ManagedTable
managed _ = ManagedTable (tmTable tm) (tmColumns tm)
                         (map policyDef (rlsPolicies @a))
                         (mkIndexes (tmTable tm) (indexes @a))
                         (foreignKeys @a)
  where tm = tableMeta @a
```

3d. Render the FK clause and append table-level constraints in `renderCreateTable`:
```haskell
-- | One FK's table-level constraint clause.
fkDDL :: ForeignKey -> ByteString
fkDDL fk =
  "FOREIGN KEY (" <> fkColumn fk <> ") REFERENCES "
    <> fkRefTable fk <> "(" <> fkRefPkColumn fk <> ")"

renderCreateTable :: ManagedTable -> ByteString
renderCreateTable (ManagedTable name cols _ _ fks) =
  "CREATE TABLE " <> name <> " ("
    <> BC.intercalate ", " (map columnDDL cols ++ map fkDDL fks)
    <> ")"
```

3e. Emit the FK inline in `renderAddColumn` (look the column up in the table's FK list):
```haskell
renderAddColumn :: ByteString -> [ForeignKey] -> ColumnMeta -> ByteString
renderAddColumn table fks c =
  "ALTER TABLE " <> table <> " ADD COLUMN " <> cmName c <> " " <> sqlTypeDDL (cmSqlType c)
    <> (if cmNullable c then "" else " NOT NULL")
    <> maybe "" (\fk -> " REFERENCES " <> fkRefTable fk <> "(" <> fkRefPkColumn fk <> ")")
             (lookupFk (cmName c) fks)
  where
    lookupFk :: ByteString -> [ForeignKey] -> Maybe ForeignKey
    lookupFk col = foldr (\fk acc -> if fkColumn fk == col then Just fk else acc) Nothing
```

3f. Update `renderAddColumn`'s caller in `migrate`'s `toAdditive` to thread the FK list (the `mt` is available in the `zip tables diffs` pair):
```haskell
    toAdditive (mt, CreateTable _)       = [renderCreateTable mt]
    toAdditive (mt, AlterTable t adds _) = [renderAddColumn t (mtForeignKeys mt) c | c <- adds]
    toAdditive (_,  UpToDate)            = []
```

3g. Fix the other `ManagedTable` pattern-matches for the new 5th field. `diffTable` matches `mt@(ManagedTable name cols _ _)` and `rlsForTable` matches `(ManagedTable name _ pols _)` — add the extra `_` so they become `…(ManagedTable name cols _ _ _)` and `…(ManagedTable name _ pols _ _)`. (Search the file for `ManagedTable ` patterns and `ManagedTable {` constructions; the only constructor call is in `managed`, fixed in 3c.)

- [ ] **Step 4: Run the suite to verify it passes**

Run: `zinc test manifest:spec`
Expected: PASS — the DDL render tests match; existing migration tests (`MigrateSqlSpec`, `MigrateSpec`, `MigrateMetaSpec`) stay green because entities without markers have `mtForeignKeys = []`, so `renderCreateTable` output is unchanged for them.

- [ ] **Step 5: Whole-workspace build**

Run: `zinc build`
Expected: SUCCESS.

- [ ] **Step 6: Commit**

```bash
git add manifest/src/Manifest/Migrate.hs manifest/test/ReferencesSpec.hs
git commit -m "feat(manifest): emit FOREIGN KEY constraints from References markers"
```

---

### Task 5: Integration — DB enforcement + cascade compatibility

Prove against ephemeral Postgres that the constraint is real and that it composes with the existing app-level cascades. Deliverable: integration tests.

**Files:**
- Add to: `manifest/test/ReferencesSpec.hs`

**Interfaces:**
- Consumes: `managed`, `migrateUp` (or direct DDL via `renderCreateTable`), the `Doc`/`User` fixtures, the session API (`withSession`, `add`, `delete`, `withTransaction`), `Fixtures (withEmptyDb)`, `Manifest.Postgres (execText, withConnection)`.
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing integration tests** — add to `manifest/test/ReferencesSpec.hs`.

Add imports:
```haskell
import Control.Exception (try, SomeException)
import Manifest.Session (withSession, withTransaction, add, delete)
import Manifest.Entity (Key(..))
import Manifest.Postgres (execText, withConnection)
import Fixtures (withEmptyDb, usersDDL)
import qualified Data.ByteString.Char8 as BC
```

Create the `docs` table from the managed schema (so the test exercises the real generated DDL), then:

```haskell
  , test "DB rejects an FK-violating insert" $
      withEmptyDb $ \pool -> do
        withConnection pool $ \c -> do
          execText c usersDDL []
          execText c (renderCreateTable (managed (Proxy @Doc))) []
        r <- try $ withSession pool $
               add (Doc { docId = 0, docAuthor = 999, docEditor = Nothing } :: Doc)
        case (r :: Either SomeException Doc) of
          Left _  -> assertBool "insert rejected" True
          Right _ -> assertBool "expected FK violation for author=999" False
```

Note for the implementer: confirm `usersDDL` is exported from `Fixtures` (it is — see `manifest/test/Fixtures.hs`). The `Doc` fixture from Task 3 references `users(user_id)`, so the `users` table must exist first. If `add` requires a `HasRelation`/cascade instance that the fixture lacks, it does not — `Doc` only needs its `Entity` instance (already derived in Task 3).

- [ ] **Step 2: Run the suite to verify the enforcement test passes**

Run: `zinc test manifest:spec`
Expected: PASS — the bad insert raises an FK violation. (If the DDL the test creates is malformed, the failure message shows the rejected statement — fix `fkDDL`/`renderCreateTable` from Task 4.)

- [ ] **Step 3: Add the cascade-compatibility test with a self-contained `Owner`/`Item` fixture**

This proves a plain `NO ACTION` FK does not break the existing app-level cascade: the parent declares a `Cascade` rule, so `flushDelete` removes the child rows *before* the parent `DELETE`, which the `NO ACTION` constraint tolerates. Use a dedicated parent/child pair so no shared fixture is mutated.

Add imports to `ReferencesSpec.hs`:
```haskell
import Manifest.Core.Meta (genericTableMeta)
import Manifest.Core.Cascade (OnDelete(..))
import Manifest.Core.Relation (cascade)
import Manifest.Core.Query (Cond)
import Manifest.Session (selectWhere)
```
Define the mutually-referencing fixtures (the parent's `cascadeRules` points at the child; the child's FK points at the parent — Haskell resolves the mutual `Entity` instances fine):
```haskell
data OwnerT f = Owner
  { ownerId :: Field f (PrimaryKey (Serial Int)) } deriving Generic
type Owner = OwnerT Identity
instance Entity Owner where
  tableMeta    = genericTableMeta @OwnerT "owners"
  cascadeRules = [ cascade (Proxy @Item) (Proxy @"itemOwner") Cascade ]

data ItemT f = Item
  { itemId    :: Field f (PrimaryKey (Serial Int))
  , itemOwner :: Field f (References Owner) } deriving Generic
type Item = ItemT Identity
deriving via (Table "items" ItemT) instance Entity Item
```
Add the test (create `owners` before `items` so the FK target exists):
```haskell
  , test "app cascade composes with a NO ACTION FK (parent delete succeeds, child cascaded)" $
      withEmptyDb $ \pool -> do
        withConnection pool $ \c -> do
          execText c (renderCreateTable (managed (Proxy @Owner))) []
          execText c (renderCreateTable (managed (Proxy @Item)))  []
        childGone <- withSession pool $ do
          o <- add (Owner { ownerId = 0 } :: Owner)
          _ <- add (Item { itemId = 0, itemOwner = ownerId o } :: Item)
          withTransaction $ delete o     -- app cascade deletes items first, then the owner
          items <- selectWhere ([] :: [Cond Item])
          pure (null items)
        assertBool "child cascaded and parent delete succeeded despite NO ACTION FK" childGone
```

Why this is a real test: if `flushDelete` did *not* delete children first, the owner `DELETE` would hit the `NO ACTION` FK and raise — failing the test. Passing proves the ordering composes with the DB constraint.

- [ ] **Step 4: Run the suite**

Run: `zinc test manifest:spec`
Expected: PASS — both integration tests green.

- [ ] **Step 5: Whole-workspace build**

Run: `zinc build`
Expected: SUCCESS.

- [ ] **Step 6: Regression check — existing fixtures unchanged**

Confirm the existing migration specs still pass (they ran in Step 4 as part of the suite). The existing `usersDDL`/`postsDDL` fixtures use plain `Int` FK columns (no marker), so `managed`/`renderCreateTable` for them emit no `FOREIGN KEY` clause — byte-identical to before.

- [ ] **Step 7: Commit**

```bash
git add manifest/test/ReferencesSpec.hs
git commit -m "test(manifest): References FK enforced by DB and composes with app cascades"
```

---

## Self-Review

**Spec coverage:**
- `References` marker + `Base (References t) = PrimKey t` + `Base (Maybe a)` (spec §Design) → Task 2. ✓
- No new `Field` clauses; projections via catch-all (spec §Field projections) → Task 2 proofs. ✓
- `FieldMeta` required + nullable instances (spec §FieldMeta) → Task 2. ✓
- `PrimKey` relocation (spec §Module-layering) → Task 1. ✓
- FK target resolution in a type-level walk consulting `Entity target` (spec §FK reflection) → Task 3. ✓
- `ManagedTable.mtForeignKeys` + `renderCreateTable`/`renderAddColumn` clauses (spec §FK reflection + DDL) → Task 4. ✓
- Tests: type proofs, DDL render, DB enforcement, cascade compatibility, regression (spec §Testing) → Tasks 2, 4, 5. ✓
- Out of scope (no `ON DELETE`, app cascades unchanged) → honoured: `fkDDL` emits no `ON DELETE`; no change to `Manifest.Core.Cascade`/`flushDelete`. ✓

**Placeholder scan:** clean — every code step shows complete code, including the Task 5 cascade test (self-contained `Owner`/`Item` fixture).

**Type consistency:** `ForeignKey`/`fkColumn`/`fkRefTable`/`fkRefPkColumn`, `mtForeignKeys`, `foreignKeys`, `genericForeignKeys`, `GForeignKeys`, `renderAddColumn`'s new `[ForeignKey]` parameter are used consistently across Tasks 3–5. The `Doc`/`DocT` fixture is defined once (Task 3) and reused (Tasks 4–5).

**Note on a known risk:** Task 1 (relocating `Table`/`PrimKey`/`GPrimKeyType`) is the largest regression surface — it touches the entity layer that the whole workspace builds on. Its only deliverable is "the suite + `zinc build` are unchanged"; treat any failure there as an export/import omission, not a logic error.
