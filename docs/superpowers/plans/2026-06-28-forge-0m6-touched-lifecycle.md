# Generated-on-update lifecycle (`Touched` marker) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `Touched a` HKD field marker for columns the DB generates on insert AND re-stamps with `now()` on every UPDATE (e.g. `updated_at`).

**Architecture:** `Touched` projects identically to the existing `Generated` marker (omitted from Create and Update payloads, visible on Read), so it reuses the snapshot-diff machinery unchanged. The single behavioural difference — auto-stamping on UPDATE — is carried by metadata (`cmTouchedOnUpdate`) and realized in one place: `renderUpdate` appends `<col> = now()` for every touched column, so both `flushSave` and `Command.update`/`patch` stamp for free with zero call-site changes. Stamp-only: no `RETURNING`, no in-memory refresh.

**Tech Stack:** Haskell (GHC 9.12.2), HKD type families, GHC.Generics deriving, custom `Harness` test runner (no hspec), ephemeral Postgres via `withEmptyDb`. Build tool: `zinc` (workspace monorepo).

## Global Constraints

- **manifest-core is a workspace dependency of crucible and manifest-evals.** After changing `manifest-core`, build the WHOLE workspace from the repo root: `zinc build` — not just `manifest:lib`. A green `manifest` build alone can hide downstream breakage.
- **Run the manifest test suite from the REPO ROOT** as `zinc test manifest:spec`. Do NOT `cd manifest` (it is a workspace member; `cd manifest && zinc test` fails). Bare `zinc test manifest` matches the wrong member (`crucible-manifest`).
- The test harness is the project's own `Harness` module: `group`, `test`, `assertEqual`, `assertBool`. There is no hspec. Match the existing spec style exactly.
- `Touched` projections MUST be byte-for-byte identical to `Generated` except for the UPDATE stamp. Do not invent new Create/Update behaviour.
- Stamp-only. Do NOT add `RETURNING` or any in-memory refresh on UPDATE.
- Spec: `docs/superpowers/specs/2026-06-28-forge-0m6-touched-lifecycle-design.md`.

---

### Task 1: `Touched` marker — type, Base, projections, metadata

Add the marker and wire it through the three type families (`Base`, `Field`, `FieldMeta`) in `manifest-core`. This task is type-level only; its deliverable is the compile-time projection proofs in `ProjectionSpec`.

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Table.hs`
- Test: `manifest/test/ProjectionSpec.hs`

**Interfaces:**
- Consumes: existing `Generated` marker as the template; `Omitted`, `Base`, `Field`, `Create`, `Update`, `FieldMeta` (all already in `Table.hs`).
- Produces: `Touched :: Type -> Type` (exported); `Base (Touched a) = Base a`; `Field Create (Touched a) = Omitted`; `Field Update (Touched a) = Omitted`; new `FieldMeta` method `fieldTouchedOnUpdate :: Bool` (class default `False`, `True` only for the `Touched` instance, which also sets `fieldIsGenerated = True`).

- [ ] **Step 1: Write the failing test** — add projection proofs and a touched-specific assertion to `ProjectionSpec.hs`.

Add `Touched` to the import from `Manifest.Core.Table`:

```haskell
import Manifest.Core.Table
  (Field, Create, Update, Omitted, Patch(..),
   PrimaryKey, Serial, Generated, Default, Secret, ReadOnly, Touched)
```

Add these top-level proof bindings (a wrong projection fails to compile):

```haskell
-- Touched projection (identical to Generated: omitted on Create AND Update)
_createOmitsTouched :: Field Create (Touched UTCTime) -> Omitted
_createOmitsTouched = id
_updateOmitsTouched :: Field Update (Touched UTCTime) -> Omitted
_updateOmitsTouched = id
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `zinc test manifest:spec`
Expected: COMPILE FAILURE — `Touched` is not in scope / not exported from `Manifest.Core.Table`.

- [ ] **Step 3: Add the marker, Base clause, Field clauses, and FieldMeta**

In `manifest/manifest-core/src/Manifest/Core/Table.hs`:

3a. Add `Touched` to the module export list, next to `Generated`:

```haskell
  , Generated
  , Touched
  , Default
```

3b. Add the marker declaration after the `Generated` declaration (around line 41):

```haskell
-- | Marker: a server-generated column that is also re-stamped on every UPDATE
-- (e.g. @updated_at TIMESTAMPTZ NOT NULL DEFAULT now()@). Like 'Generated' for
-- Create/Read/Update projections; additionally the deriver flags it so
-- 'Manifest.Core.Sql.renderUpdate' appends @<col> = now()@ to every UPDATE.
data Touched a
```

3c. Add a `Base` clause next to the `Generated` clause (in the `Base` family, ~line 71):

```haskell
  Base (Generated a)  = Base a
  Base (Touched a)    = Base a
```

3d. Add `Field` clauses for both contexts. In the Create block, after the `Generated` clause:

```haskell
  Field Create (Generated a)              = Omitted
  Field Create (Touched a)                = Omitted
```

In the Update block, after the `Generated` clause:

```haskell
  Field Update (Generated a)  = Omitted
  Field Update (Touched a)    = Omitted
```

3e. Add the new method (with a class default) to `FieldMeta`:

```haskell
class FieldMeta a where
  fieldIsPK        :: Bool
  fieldIsSerial    :: Bool
  fieldIsGenerated :: Bool
  fieldSqlType     :: SqlType
  fieldNullable    :: Bool
  -- | True only for 'Touched': the column is re-stamped @= now()@ on every UPDATE.
  fieldTouchedOnUpdate :: Bool
  fieldTouchedOnUpdate = False
```

3f. Add the `Touched` `FieldMeta` instance after the `Generated` instance:

```haskell
instance FieldMeta a => FieldMeta (Touched a) where
  fieldIsPK = False; fieldIsSerial = fieldIsSerial @a; fieldIsGenerated = True
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a
  fieldTouchedOnUpdate = True
```

(Leave every other instance untouched — they inherit the `False` default. `PrimaryKey`/`Generated` etc. need no change.)

- [ ] **Step 4: Run the suite to verify the projections compile and pass**

Run: `zinc test manifest:spec`
Expected: PASS — `ProjectionSpec` compiles (proofs hold) and its runtime tests stay green.

- [ ] **Step 5: Whole-workspace build (manifest-core changed)**

Run: `zinc build`
Expected: SUCCESS across the workspace (crucible, manifest-evals included).

- [ ] **Step 6: Commit**

```bash
git add manifest/manifest-core/src/Manifest/Core/Table.hs manifest/test/ProjectionSpec.hs
git commit -m "feat(manifest-core): add Touched marker (generated + re-stamped on update)"
```

---

### Task 2: `cmTouchedOnUpdate` metadata + populate from `GColumns`

Carry the touched flag into runtime column metadata so the renderer can find touched columns. Adding a `ColumnMeta` field breaks the positional constructors in three test files — this task fixes them in the same commit.

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Meta.hs`
- Modify: `manifest/test/MetaSpec.hs:46-48`
- Modify: `manifest/test/MigrateMetaSpec.hs:14-16`
- Modify: `manifest/test/MigrateSqlSpec.hs:21,25`
- Test: `manifest/test/MetaSpec.hs` (its existing `gColumns` equality assertion is the test)

**Interfaces:**
- Consumes: `fieldTouchedOnUpdate :: Bool` from Task 1.
- Produces: `ColumnMeta` field `cmTouchedOnUpdate :: Bool` (placed immediately after `cmIsGenerated`), populated by `GColumns`. Positional `ColumnMeta` literals gain one `Bool` in the 5th position (after the `cmIsGenerated` bool, before the `SqlType`).

- [ ] **Step 1: Update the failing test** — extend `MetaSpec.hs`'s expected `[ColumnMeta]` to include the new field, so it fails until `GColumns` populates it.

In `manifest/test/MetaSpec.hs`, change the expected columns (lines ~46-48) to insert a `False` after each `cmIsGenerated` bool:

```haskell
[ ColumnMeta "user_id"    True  True  True  False SqlBigSerial False
, ColumnMeta "user_name"  False False False False SqlText      False
, ColumnMeta "user_email" False False False False SqlText      True
]
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `zinc test manifest:spec`
Expected: COMPILE FAILURE — `ColumnMeta` has 6 fields, the literal now supplies 7 (arity mismatch) until Step 3 adds the field.

- [ ] **Step 3: Add the `ColumnMeta` field and populate it in `GColumns`**

In `manifest/manifest-core/src/Manifest/Core/Meta.hs`, add the field after `cmIsGenerated`:

```haskell
data ColumnMeta = ColumnMeta
  { cmName            :: ByteString
  , cmIsPK            :: Bool
  , cmIsSerial        :: Bool
  , cmIsGenerated     :: Bool
  , cmTouchedOnUpdate :: Bool
  , cmSqlType         :: SqlType
  , cmNullable        :: Bool
  } deriving (Eq, Show)
```

Populate it in the `GColumns` `S1` instance (insert after `cmIsGenerated`):

```haskell
        { cmName            = camelToSnake (selName (undefined :: S1 m (Rec0 (Exposed t)) p))
        , cmIsPK            = fieldIsPK @t
        , cmIsSerial        = fieldIsSerial @t
        , cmIsGenerated     = fieldIsGenerated @t
        , cmTouchedOnUpdate = fieldTouchedOnUpdate @t
        , cmSqlType         = fieldSqlType  @t
        , cmNullable        = fieldNullable @t
        }
```

- [ ] **Step 4: Fix the other positional `ColumnMeta` literals**

In `manifest/test/MigrateMetaSpec.hs` (lines ~14-16):

```haskell
[ ColumnMeta "user_id"    True  True  True  False SqlBigSerial False
, ColumnMeta "user_name"  False False False False SqlText      False
, ColumnMeta "user_email" False False False False SqlText      True   -- Maybe Text → nullable
```

In `manifest/test/MigrateSqlSpec.hs` (lines ~21 and ~25):

```haskell
(renderAddColumn "users" (ColumnMeta "nickname" False False False False SqlText True))
```

```haskell
(renderAddColumn "users" (ColumnMeta "age" False False False False SqlBigInt False))
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `zinc test manifest:spec`
Expected: PASS — `MetaSpec`, `MigrateMetaSpec`, `MigrateSqlSpec` all green (the `gColumns` equality now matches, `cmTouchedOnUpdate = False` for every non-touched column).

- [ ] **Step 6: Whole-workspace build**

Run: `zinc build`
Expected: SUCCESS.

- [ ] **Step 7: Commit**

```bash
git add manifest/manifest-core/src/Manifest/Core/Meta.hs manifest/test/MetaSpec.hs manifest/test/MigrateMetaSpec.hs manifest/test/MigrateSqlSpec.hs
git commit -m "feat(manifest-core): carry cmTouchedOnUpdate in ColumnMeta"
```

---

### Task 3: `renderUpdate` auto-appends `<touched col> = now()` + render test

Make `renderUpdate` append a literal `= now()` assignment for every touched column in the table meta. This is the one behavioural change; it gives both UPDATE paths stamping for free.

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Sql.hs:57-63`
- Create: `manifest/test/TouchedSpec.hs`
- Modify: `manifest/test/Spec.hs` (register `TouchedSpec`)

**Interfaces:**
- Consumes: `cmTouchedOnUpdate`, `cmName`, `tmColumns` from Task 2; `Touched` marker from Task 1.
- Produces: `TouchedSpec.tests :: [Test]`. The `renderUpdate` signature is UNCHANGED (`TableMeta a -> [ByteString] -> ByteString -> ByteString`); only its body changes, so existing callers (`Session.flushSave`, `Command.update`) are unaffected at the call site.

- [ ] **Step 1: Write the failing test** — create `manifest/test/TouchedSpec.hs` with a fixture entity carrying a `Touched` column and a pure render assertion.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeApplications #-}

module TouchedSpec (tests) where

import Data.Functor.Identity (Identity)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Manifest.Core.Table (Field, PrimaryKey, Serial, Generated, Touched)
import Manifest.Core.Sql (renderUpdate)
import Manifest.Entity (Entity (..), Table (..))
import Harness

-- A doc with a Generated created_at (insert-only) and a Touched updated_at
-- (insert + re-stamped on every UPDATE).
data DocT f = Doc
  { docId      :: Field f (PrimaryKey (Serial Int))
  , docTitle   :: Field f Text
  , docCreated :: Field f (Generated UTCTime)
  , docUpdated :: Field f (Touched UTCTime)
  } deriving Generic
type Doc = DocT Identity
deriving via (Table "docs" DocT) instance Entity Doc

tests :: [Test]
tests = group "Touched"
  [ test "renderUpdate appends touched columns as `= now()` after the param sets" $
      assertEqual "upd"
        "UPDATE docs SET doc_title = $1, doc_updated = now() WHERE doc_id = $2"
        (renderUpdate (tableMeta @Doc) ["doc_title"] "doc_id")
  , test "touched literal does not consume a placeholder (PK index = #setCols + 1)" $
      assertEqual "pk-index"
        "UPDATE docs SET doc_title = $1, doc_created = $2, doc_updated = now() WHERE doc_id = $3"
        (renderUpdate (tableMeta @Doc) ["doc_title", "doc_created"] "doc_id")
  ]
```

Register it in `manifest/test/Spec.hs`: add `import qualified TouchedSpec` near the other imports, and append `++ TouchedSpec.tests` to the `runTests (...)` chain.

- [ ] **Step 2: Run the suite to verify it fails**

Run: `zinc test manifest:spec`
Expected: FAIL — `renderUpdate` still emits `"UPDATE docs SET doc_title = $1 WHERE doc_id = $2"` (no `doc_updated = now()`), so the `assertEqual` fails.

- [ ] **Step 3: Implement the auto-append in `renderUpdate`**

In `manifest/manifest-core/src/Manifest/Core/Sql.hs`, replace the `renderUpdate` body (lines 56-63):

```haskell
-- | @UPDATE t SET c1 = $1, ..., <touched> = now() WHERE pk = $n@.
-- Touched columns (re-stamped on every update) are appended as literal
-- @= now()@ assignments read from the table meta. They consume no parameter,
-- so the PK placeholder stays at @length setCols + 1@; and they never appear in
-- @setCols@ (the Update projection omits them and the flush diff skips them).
renderUpdate :: TableMeta a -> [ByteString] -> ByteString -> ByteString
renderUpdate tm setCols pkCol =
  let sets    = [ c <> " = " <> placeholder i | (c, i) <- zip setCols [1 ..] ]
      touched = [ cmName c <> " = now()" | c <- tmColumns tm, cmTouchedOnUpdate c ]
      pkPh    = placeholder (length setCols + 1)
  in "UPDATE " <> tmTable tm
       <> " SET " <> bcIntercalate ", " (sets ++ touched)
       <> " WHERE " <> pkCol <> " = " <> pkPh
```

(The `Manifest.Core.Meta` import at the top of `Sql.hs` already brings in `ColumnMeta(..)` and `TableMeta(..)`, so `cmName`, `cmTouchedOnUpdate`, and `tmColumns` are in scope — no import change needed.)

- [ ] **Step 4: Run the suite to verify it passes**

Run: `zinc test manifest:spec`
Expected: PASS — `TouchedSpec` render tests green; `SqlSpec`'s existing `"UPDATE users SET user_name = $1 WHERE user_id = $2"` stays green because `User` has no touched column (`touched = []`).

- [ ] **Step 5: Whole-workspace build**

Run: `zinc build`
Expected: SUCCESS.

- [ ] **Step 6: Commit**

```bash
git add manifest/manifest-core/src/Manifest/Core/Sql.hs manifest/test/TouchedSpec.hs manifest/test/Spec.hs
git commit -m "feat(manifest-core): renderUpdate auto-stamps touched columns with now()"
```

---

### Task 4: Integration — UPDATE stamps `updated_at`, leaves `created_at`

Prove end-to-end (against ephemeral Postgres) that both UPDATE paths — the snapshot-diff `save`/`flush` and the explicit-command `update` (`Command.update`, which `patch` also wraps) — emit `updated_at = now()` and never touch the `Generated` `created_at` column.

**Files:**
- Modify: `manifest/test/TouchedSpec.hs` (add the `Doc` DDL + integration tests)

**Interfaces:**
- Consumes: the `DocT`/`Doc` fixture and `tableMeta @Doc` from Task 3; the `Manifest.Session` API (`withSession`, `add`, `save`, `withTransaction`, `statementLog`), `Manifest.Session.Command (update)`, `Manifest.Core.Query ((=.))`, `Manifest.Entity (Key(..))`, `Fixtures (withEmptyDb)`, `Manifest.Postgres (execText, withConnection)`.
- Produces: nothing consumed downstream.

- [ ] **Step 1: Write the failing integration tests** — extend `manifest/test/TouchedSpec.hs`.

Add `{-# LANGUAGE OverloadedLabels #-}` to the file's pragma block (the `#docTitle` label syntax needs it). Extend the existing imports — the file already imports `Data.Time (UTCTime)`, widen it, and add the session/command/query/db imports:

```haskell
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf, isPrefixOf)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Manifest.Core.Query ((=.))
import Manifest.Session (add, save, get, withSession, withTransaction, statementLog)
import Manifest.Session.Command (update)
import Manifest.Entity (Key (..))
import Manifest.Postgres (execText, withConnection)
import Fixtures (withEmptyDb)
```

(The module already has `import Manifest.Entity (Entity (..))` for `tableMeta`; merge `Key (..)` into it rather than importing `Manifest.Entity` twice. `Data.Time (UTCTime)` is already imported for the fixture — replace that line with the widened one above.)

Two notes on API shape, verified against the codebase:
- The explicit-command path uses **`update`**, NOT `patch`. `Manifest.Session.Command.update :: Key a -> [Assign a] -> Db ()` takes an assignment list (see `manifest/test/CommandSpec.hs`). `patch` takes a `Patch`-projection *record* (`DocT Update`), not an `[Assign a]`, so it cannot take `[ #docTitle =. ... ]`. Both `update` and `patch` route through the same `Command.update` → `renderUpdate`, so testing `update` proves the stamping on the explicit-command path.
- Build `UTCTime` with the explicit constructor (matching `FlushSpec.hs`), not `read`.

Add the DDL and two tests. The `Doc` table mirrors the fixture: a serial PK, a plain title, a `Generated` `created_at` and a `Touched` `updated_at`, both `DEFAULT now()`:

```haskell
docsDDL :: BC.ByteString
docsDDL =
  "CREATE TABLE docs \
  \( doc_id      BIGSERIAL PRIMARY KEY \
  \, doc_title   TEXT NOT NULL \
  \, doc_created TIMESTAMPTZ NOT NULL DEFAULT now() \
  \, doc_updated TIMESTAMPTZ NOT NULL DEFAULT now() )"

t2020 :: UTCTime
t2020 = UTCTime (fromGregorian 2020 1 1) (secondsToDiffTime 0)
```

Append these to the `tests` list (after the render tests):

```haskell
  , test "save (snapshot-diff) stamps updated_at and leaves created_at" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c docsDDL [])
        sqls <- withSession pool $ do
          d <- add (Doc { docId = 0, docTitle = "draft"
                        , docCreated = t2020, docUpdated = t2020 } :: Doc)
          withTransaction $ save (d { docTitle = "final" } :: Doc)
          map (BC.unpack . fst) <$> statementLog
        let upd = filter ("UPDATE" `isPrefixOf`) sqls
        assertBool ("one UPDATE expected; got " <> show sqls) (length upd == 1)
        assertBool "UPDATE sets doc_title"                 (any (isInfixOf "doc_title = $1")     upd)
        assertBool "UPDATE stamps doc_updated = now()"     (any (isInfixOf "doc_updated = now()") upd)
        assertBool "UPDATE does NOT touch doc_created"     (not (any (isInfixOf "doc_created")    upd))
  , test "update (explicit command) stamps updated_at and leaves created_at" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c docsDDL [])
        sqls <- withSession pool $ do
          d <- add (Doc { docId = 0, docTitle = "draft"
                        , docCreated = t2020, docUpdated = t2020 } :: Doc)
          withTransaction $ update @Doc (Key (docId d)) [ #docTitle =. ("renamed" :: Text) ]
          map (BC.unpack . fst) <$> statementLog
        let upd = filter ("UPDATE" `isPrefixOf`) sqls
        assertBool ("one UPDATE expected; got " <> show sqls) (length upd == 1)
        assertBool "UPDATE stamps doc_updated = now()"  (any (isInfixOf "doc_updated = now()") upd)
        assertBool "UPDATE does NOT touch doc_created"  (not (any (isInfixOf "doc_created")    upd))
  ]
```

- [ ] **Step 2: Run the suite to verify behaviour**

Run: `zinc test manifest:spec`
Expected: PASS — both UPDATE paths include `doc_updated = now()` and exclude `doc_created`. (If `add`/`save` does not yet support a `Generated`+`Touched` mix, the failure message will name the missing piece — fix forward; the projections from Tasks 1-3 should make this work without further core changes.)

- [ ] **Step 3: Whole-workspace build**

Run: `zinc build`
Expected: SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add manifest/test/TouchedSpec.hs
git commit -m "test(manifest): Touched stamps updated_at via save and patch, not created_at"
```

---

### Task 5: Close out the bead's deferred items

Record the disposition of all four forge-0m6 items in the bead so the descope/done decisions are durable.

**Files:** none (bead metadata only).

- [ ] **Step 1: Note insert-side RETURNING as already-done and item 3 as descoped**

```bash
bd update forge-0m6 --notes="Item 1+4 (generated-on-update): DONE via Touched marker (renderUpdate auto-stamps now()). Item 2 insert-side RETURNING refresh: already implemented in insertCreate (setBaseline on RETURNING row) — no work. Item 2 update-side: stamp-only via Touched, no RETURNING. Item 3 Secret/Masked entity-JSON wiring: DESCOPED — manifest has no entity-JSON derivation layer to hook into (only Json/Aeson column wrappers + standalone Masked). File a follow-up if that layer is added. Spec: docs/superpowers/specs/2026-06-28-forge-0m6-touched-lifecycle-design.md"
```

- [ ] **Step 2: Close the bead**

```bash
bd close forge-0m6 --reason="Touched marker implemented (Tasks 1-4); insert-side RETURNING already done; Secret/Masked entity-JSON wiring descoped (no derivation layer)."
```

---

## Self-Review

**Spec coverage:**
- Marker + projections (spec §Design "Marker + projections") → Task 1. ✓
- `FieldMeta.fieldTouchedOnUpdate` + class default (spec §Metadata) → Task 1 step 3e/3f. ✓
- `ColumnMeta.cmTouchedOnUpdate` + `GColumns` (spec §Metadata) → Task 2. ✓
- `renderUpdate` auto-append `= now()` (spec §Rendering) → Task 3. ✓
- Stamp-only / both callers benefit (spec §Decision) → Task 3 (one body change) + Task 4 (proves `save` AND `patch`). ✓
- Tests: projection proofs / render / integration (spec §Testing) → Tasks 1, 3, 4. ✓
- Item-2 insert done + item-3 descoped (spec §Scope decision) → Task 5. ✓
- Edge case: `User` has no touched col so `SqlSpec` stays green (spec §Edge cases) → Task 3 step 4. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N" — every code step shows full code. ✓

**Type consistency:** `cmTouchedOnUpdate`, `fieldTouchedOnUpdate`, `Touched`, `renderUpdate` (unchanged signature), `tableMeta @Doc` used identically across Tasks 1-4. The `Doc`/`DocT` fixture is defined once in Task 3 and reused (not redefined) in Task 4. ✓

**Migrate-DDL note:** `columnDDL`/`renderAddColumn` do not emit `DEFAULT now()` for any generated/touched column today (the existing `Generated` marker shares this gap; fixtures hand-write the DDL). Generating `DEFAULT now()` from metadata is out of scope here — same limitation as `Generated`.