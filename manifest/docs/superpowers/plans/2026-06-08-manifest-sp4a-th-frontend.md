# Manifest SP4a — Template Haskell front-end (`mkEntity`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `mkEntity` Template Haskell macro that, from a terse one-block declaration, generates the full hand-written entity boilerplate — the HKD `WidgetT f` record, `deriving Generic`, the `type Widget = WidgetT Identity` synonym, and the `Entity Widget` instance — restoring Lune's `@derive(Table)` ergonomics.

**Architecture:** A new pure-codegen module `Manifest.Derive.TH` exporting `mkEntity :: String -> String -> [(String, Q Type)] -> Q [Dec]` (plus a tiny `field` helper). It generates code *byte-for-byte equivalent* to the hand-written entities in `test/Fixtures.hs` (e.g. `UserT`), so it inherits all existing generic machinery (`genericTableMeta`/`genericRowDecoder`/`genericRowEncode`) with zero new runtime code. Field names are the lowercased entity name + capitalised short name (`"Widget"` + `"id"` → `widgetId`), matching the existing `userId`/`userName` convention. The single `PrimaryKey` field is detected structurally to wire `primKey` and `type PrimKey`.

**Tech Stack:** GHC 9.10.1 via zinc; `template-haskell` 2.22 (a GHC boot library — no pin). Template Haskell is already verified to run under zinc (a scratch splice compiled and ran). The existing custom `test/Harness.hs` (no hspec) and the `readProcessWithExitCode "ghc" …` golden-compile-failure pattern from `test/RelationErrorSpec.hs`.

**Scope note:** This is SP4a, the first half of SP4. The macro generates the *core* entity (record + `Generic` + `Entity` instance). Relationships (`HasRelation` instances) and `cascadeRules` remain declared separately by hand, exactly as today — they are not part of this macro. SP4b (Core joins/aggregates) is a separate plan. A terser quasi-quoter front-end (`[entity| … |]`) is a possible follow-up; this plan deliberately uses the `[t| … |]`-list API to avoid hand-writing a parser.

---

## Background: the exact target

A hand-written entity in this codebase (from `test/Fixtures.hs:48-62`) looks like:

```haskell
data UserT f = User
  { userId    :: Col f (PrimaryKey (Serial Int))
  , userName  :: Col f Text
  , userEmail :: Col f (Maybe Text)
  } deriving Generic

type User = UserT Identity

instance Entity User where
  type PrimKey User = Int
  tableMeta  = genericTableMeta @UserT "users"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = userId
```

The macro call `mkEntity "Widget" "widgets" [field "id" [t| PrimaryKey (Serial Int) |], field "name" [t| Text |], field "size" [t| Maybe Int |]]` must generate the identical shape for `Widget`. Key facts the macro relies on (verified against the live source):

- `Col` / `Base` / `Serial` / `PrimaryKey` live in `Manifest.Core.Table`. `Base (PrimaryKey (Serial Int))` reduces to `Int`, so emitting `type PrimKey Widget = Base (PrimaryKey (Serial Int))` is definitionally `= Int` and needs no arithmetic.
- `genericTableMeta @WidgetT name :: TableMeta (WidgetT Identity)` (`Manifest.Core.Meta`); it takes a `ByteString` table name. The hand-written code relies on `OverloadedStrings`; the macro instead emits `fromString "widgets"` so the splice site does **not** need `OverloadedStrings`.
- `genericRowDecoder` / `genericRowEncode` come from `Manifest.Entity`.
- Column names are `camelToSnake` of the record selector (`userId` → `user_id`), with no prefix stripping (`Manifest.Core.Meta:54`).
- `add` is **eager**: it INSERTs immediately with `RETURNING` and returns the entity with the real serial PK filled (see `test/EndToEndSpec.hs:20-24`).

**Required pragmas at every splice site** (the macro cannot enable extensions for the user). A module that calls `mkEntity` must enable:

```haskell
{-# LANGUAGE TemplateHaskell #-}   -- the $( ) splice
{-# LANGUAGE TypeFamilies #-}      -- the `type PrimKey …` associated-type instance + `Col`
{-# LANGUAGE TypeApplications #-}  -- the generated `genericTableMeta @WidgetT`
{-# LANGUAGE DeriveGeneric #-}     -- the generated `deriving Generic`
{-# LANGUAGE FlexibleInstances #-} -- `instance Entity (WidgetT Identity)` (concrete arg)
```

(The test target's `ghc-options` already enable `TypeApplications`/`ScopedTypeVariables`/`OverloadedStrings`, but `TemplateHaskell`/`TypeFamilies`/`DeriveGeneric`/`FlexibleInstances` are not global, so each splice-site module declares them itself.)

---

## File Structure

- **Create `src/Manifest/Derive/TH.hs`** — the `mkEntity` + `field` macro. One responsibility: entity codegen. ~70 lines.
- **Modify `zinc.toml`** — add `template-haskell` to `[build.lib].depends`.
- **Create `test/THSpec.hs`** — splices a `Widget` entity; pure metadata assertions (Task 1) + a DB round-trip (Task 2) + a golden "missing PK fails to compile" test (Task 3).
- **Modify `test/Spec.hs`** — import `THSpec` and append `THSpec.tests`.
- **Modify `src/Manifest.hs`** — re-export `mkEntity`/`field` (Task 3).
- **Modify `docs/entities.md`** — document the now-built TH front-end (Task 3).

---

### Task 1: The `mkEntity` macro + pure metadata test

**Files:**
- Create: `src/Manifest/Derive/TH.hs`
- Modify: `zinc.toml` (add `template-haskell` to `[build.lib].depends`, line ~27)
- Create: `test/THSpec.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: Write the failing test (pure metadata assertion)**

Create `test/THSpec.hs`. The splice defines `Widget`; the test asserts the generated `tableMeta` is exactly right (table name, column names, PK/serial flags, SQL types, nullability). This is a DB-free unit test of the macro's output.

```haskell
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}

module THSpec (tests) where

import Data.Text (Text)
import Manifest (Key (..), Entity (..), withSession, add, get)
import Manifest.Core.Meta (ColumnMeta (..), SqlType (..), tmTable, tmColumns)
import Manifest.Core.Table (PrimaryKey, Serial)
import Manifest.Postgres (execText, withConnection)
import Manifest.Derive.TH (field, mkEntity)
import Fixtures (withEmptyDb)
import Harness

-- The terse declaration under test. One block generates WidgetT, Widget, and
-- the Entity Widget instance — equivalent to the hand-written UserT in Fixtures.
$(mkEntity "Widget" "widgets"
    [ field "id"   [t| PrimaryKey (Serial Int) |]
    , field "name" [t| Text |]
    , field "size" [t| Maybe Int |]
    ])

tests :: [Test]
tests = group "TH"
  [ test "mkEntity generates correct table metadata" $ do
      let tm = tableMeta @Widget
      assertEqual "table name" "widgets" (tmTable tm)
      assertEqual "columns"
        [ ColumnMeta "widget_id"   True  True  SqlBigSerial False
        , ColumnMeta "widget_name" False False SqlText      False
        , ColumnMeta "widget_size" False False SqlBigInt    True
        ]
        (tmColumns tm)
  , test "mkEntity wires primKey to the PrimaryKey field" $
      assertEqual "primKey selects widget_id" 7
        (primKey (Widget { widgetId = 7, widgetName = "x", widgetSize = Nothing } :: Widget))
  ]
```

Wire it into the aggregator — `test/Spec.hs`, add the import alongside the others (after line 22) and append `THSpec.tests` to the concatenation in `main`:

```haskell
import qualified THSpec
```
```haskell
main = runTests (CodecSpec.tests ++ … ++ NestedSpec.tests ++ THSpec.tests)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix develop -c zinc test 2>&1 | tail -20`
Expected: compile failure — `Variable not in scope: mkEntity` / `field` (and `Widget`/`tableMeta @Widget` undefined). The module can't compile because the macro doesn't exist yet.

- [ ] **Step 3: Add the `template-haskell` dependency**

In `zinc.toml`, add `"template-haskell"` to `[build.lib].depends` (the list ending at line 28):

```toml
depends = [
  "base",
  "bytestring",
  "containers",
  "stm",
  "text",
  "time",
  "transformers",
  "postgresql-libpq",
  "template-haskell",
]
```

- [ ] **Step 4: Implement `Manifest.Derive.TH`**

Create `src/Manifest/Derive/TH.hs`. The macro resolves each field's `Q Type`, locates the single `PrimaryKey` field, then emits three top-level declarations: the record, the type synonym, and the `Entity` instance. It references generated symbols by captured Names (`'genericTableMeta`, `''Generic`, …) so the splice site needn't import them; only the field-type names the *user* writes (`PrimaryKey`, `Serial`, `Text`) must be in scope at the call.

```haskell
{-# LANGUAGE TemplateHaskell #-}

-- | A Template Haskell front-end for declaring entities. @mkEntity@ generates
-- the HKD record + @deriving Generic@ + the @type E = ET Identity@ synonym +
-- the @Entity@ instance from a terse field list — the same code one would write
-- by hand (see @test/Fixtures.hs@), with none of the boilerplate.
--
-- Required pragmas at the splice site: TemplateHaskell, TypeFamilies,
-- TypeApplications, DeriveGeneric, FlexibleInstances.
module Manifest.Derive.TH
  ( mkEntity
  , field
  ) where

import Data.Char (toLower, toUpper)
import Data.Functor.Identity (Identity)
import Data.String (fromString)
import GHC.Generics (Generic)
import Language.Haskell.TH
import Manifest.Core.Meta (genericTableMeta)
import Manifest.Core.Table (Base, Col, PrimaryKey)
import Manifest.Entity (Entity (..), genericRowDecoder, genericRowEncode)

-- | One field in a terse entity declaration: a short name (the record selector
-- without the entity-name prefix) and its marker/runtime type. @field = (,)@; it
-- exists for readability and forward-compatibility.
field :: String -> Q Type -> (String, Q Type)
field = (,)

-- | Generate an entity. @mkEntity "Widget" "widgets" [field "id" …, …]@ emits
-- @data WidgetT f = Widget { widgetId :: Col f …, … } deriving Generic@,
-- @type Widget = WidgetT Identity@, and @instance Entity Widget@.
--
-- Exactly one field must have type @PrimaryKey …@; it becomes @primKey@ and
-- determines @type PrimKey@.
mkEntity :: String -> String -> [(String, Q Type)] -> Q [Dec]
mkEntity ename table fields = do
  let tyName  = mkName (ename ++ "T")           -- WidgetT
      conName = mkName ename                     -- Widget (constructor)
      synName = mkName ename                     -- Widget (type synonym)
      prefix  = lower1 ename                      -- "widget"
      selName short = mkName (prefix ++ upper1 short)
  f <- newName "f"
  resolved <- mapM (\(s, qt) -> fmap ((,) s) qt) fields   -- [(String, Type)]
  pkShort <- case [ s | (s, t) <- resolved, isPrimaryKey t ] of
    [s] -> pure s
    []  -> fail ("mkEntity: entity " ++ ename ++ " has no PrimaryKey field")
    _   -> fail ("mkEntity: entity " ++ ename ++ " has multiple PrimaryKey fields")
  pkType <- maybe (fail "mkEntity: internal: PK type lost") pure (lookup pkShort resolved)

  -- data WidgetT f = Widget { widgetId :: Col f <ty>, … } deriving Generic
  let recFields =
        [ varBangType (selName s)
            (bangType (bang noSourceUnpackedness noSourceStrictness)
                      [t| Col $(varT f) $(pure t) |])
        | (s, t) <- resolved
        ]
  dataDec <- dataD (pure []) tyName [plainTV f] Nothing
               [ recC conName recFields ]
               [ derivClause Nothing [ conT ''Generic ] ]

  -- type Widget = WidgetT Identity
  synDec <- tySynD synName [] [t| $(conT tyName) Identity |]

  -- instance Entity Widget where
  --   type PrimKey Widget = Base (<pkType>)
  --   tableMeta  = genericTableMeta @WidgetT (fromString "widgets")
  --   rowDecoder = genericRowDecoder
  --   rowEncode  = genericRowEncode
  --   primKey    = widgetId
  let tableMetaE =
        appE (appTypeE (varE 'genericTableMeta) (conT tyName))
             (appE (varE 'fromString) (litE (stringL table)))
  instDec <- instanceD (pure []) [t| Entity $(conT synName) |]
    [ tySynInstD (tySynEqn Nothing [t| PrimKey $(conT synName) |] [t| Base $(pure pkType) |])
    , funD 'tableMeta  [clause [] (normalB tableMetaE) []]
    , funD 'rowDecoder [clause [] (normalB (varE 'genericRowDecoder)) []]
    , funD 'rowEncode  [clause [] (normalB (varE 'genericRowEncode)) []]
    , funD 'primKey    [clause [] (normalB (varE (selName pkShort))) []]
    ]

  pure [dataDec, synDec, instDec]

-- | Structurally: is a resolved type @PrimaryKey …@ ? Peels application,
-- parens and kind signatures down to the head constructor.
isPrimaryKey :: Type -> Bool
isPrimaryKey = go
  where
    go (AppT a _)  = go a
    go (ParensT a) = go a
    go (SigT a _)  = go a
    go (ConT n)    = n == ''PrimaryKey
    go _           = False

lower1, upper1 :: String -> String
lower1 []     = []
lower1 (c:cs) = toLower c : cs
upper1 []     = []
upper1 (c:cs) = toUpper c : cs
```

> **Implementer note (single known version touch-point):** `template-haskell` 2.22 (GHC 9.10) uses `TyVarBndr BndrVis` for `dataD`/`tySynD` binders. The library helper `plainTV` is internally version-matched to `dataD`, so `[plainTV f]` should compile as written. If the compiler reports a binder-flag mismatch, use the `plainTV`/`plainTVFlag` variant the error names — the structure is unchanged. Compile iteratively; this is the only API spot that may differ by version.

- [ ] **Step 5: Run the test to verify it passes**

Run: `nix develop -c zinc test 2>&1 | tail -20`
Expected: build succeeds; among the summary, the two `TH —` tests pass and the overall count increases by 2 from the previous green baseline. If the splice fails to compile, read the GHC error at the `$(mkEntity …)` line and fix `Manifest.Derive.TH` (most likely the `plainTV` note above, or a missing import in the TH module).

- [ ] **Step 6: Verify `-Wall` cleanliness of the new module**

zinc's `[build.lib]` already passes `-Wall`. Confirm the new module produced no warnings by rebuilding the library alone:

Run: `nix develop -c zinc build 2>&1 | grep -i "warning\|Manifest/Derive" | tail -20`
Expected: no warnings referencing `Manifest/Derive/TH.hs`. (Unused imports are the usual culprit; remove any the compiler flags.)

- [ ] **Step 7: Commit**

```bash
git add src/Manifest/Derive/TH.hs zinc.toml test/THSpec.hs test/Spec.hs
git commit -m "feat(th): mkEntity macro generates HKD record + Entity instance"
```

---

### Task 2: The generated entity round-trips through the Unit-of-Work

Proves the generated `rowEncode`/`rowDecoder`/`primKey` are correct against real Postgres — `add` (eager INSERT … RETURNING) then `get` in a **fresh session** so the read decodes from the DB, not the identity map.

**Files:**
- Modify: `test/THSpec.hs`

- [ ] **Step 1: Add the failing round-trip test**

Append to the `tests` list in `test/THSpec.hs` (and add the `widgetsDDL` binding below the splice). The DDL column order/types match what Task 1 already asserted for `tableMeta`.

```haskell
-- add to the imports already present; withEmptyDb/execText/withConnection are imported in Task 1
widgetsDDL :: Data.ByteString.ByteString
widgetsDDL =
  "CREATE TABLE widgets \
  \( widget_id   BIGSERIAL PRIMARY KEY \
  \, widget_name TEXT NOT NULL \
  \, widget_size BIGINT )"
```

New test case (append inside the `group "TH" [ … ]` list):

```haskell
  , test "generated entity round-trips: add (eager, RETURNING) then get decodes from the DB" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c widgetsDDL [])
        w0 <- withSession pool $
          add (Widget { widgetId = 0, widgetName = "gizmo", widgetSize = Just 7 } :: Widget)
        assertBool "add filled the serial PK" (widgetId w0 > 0)
        got <- withSession pool $ get @Widget (Key (widgetId w0))
        assertEqual "name decodes" (Just "gizmo")       (fmap widgetName got)
        assertEqual "size decodes" (Just (Just 7))      (fmap widgetSize got)
        assertEqual "pk decodes"   (Just (widgetId w0)) (fmap widgetId got)
```

Add the `bytestring` import to the module header (used by `widgetsDDL`):

```haskell
import qualified Data.ByteString
```

- [ ] **Step 2: Run to verify it fails first**

Before implementing anything, confirm the test is real by temporarily breaking the expectation — change `"gizmo"` in the assertion to `"WRONG"`, run, see it FAIL, then change it back. (There is no new production code in this task; the macro from Task 1 should already make the corrected test pass. This deliberate-break step proves the DB round-trip actually exercises encode/decode rather than vacuously passing.)

Run: `nix develop -c zinc test 2>&1 | grep -A2 "round-trips"`
Expected with `"WRONG"`: FAIL `name decodes: expected (Just "WRONG") but got (Just "gizmo")`. Restore `"gizmo"`.

- [ ] **Step 3: Run to verify it passes**

Run: `nix develop -c zinc test 2>&1 | tail -5`
Expected: all green; total count is now +1 over Task 1's baseline.

- [ ] **Step 4: Commit**

```bash
git add test/THSpec.hs
git commit -m "test(th): generated entity round-trips through the UoW"
```

---

### Task 3: Negative golden (missing PK), umbrella export, and honest docs

**Files:**
- Modify: `test/THSpec.hs` (golden compile-failure test)
- Modify: `src/Manifest.hs` (re-export)
- Modify: `docs/entities.md` (document the built feature)

- [ ] **Step 1: Write the failing golden test for the "no PrimaryKey" error**

`mkEntity` calls `fail` when no field has type `PrimaryKey …`. Assert that compiling such a splice fails with our message, reusing the `readProcessWithExitCode "ghc"` mechanism from `test/RelationErrorSpec.hs:43-70`. Add to `test/THSpec.hs`:

Imports to add:
```haskell
import Data.List (isInfixOf)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)
```

A standalone source that splices an entity with no PK field, kept as a string so it is only compiled by the test:
```haskell
noPkSource :: String
noPkSource = unlines
  [ "{-# LANGUAGE TemplateHaskell #-}"
  , "{-# LANGUAGE TypeFamilies #-}"
  , "{-# LANGUAGE TypeApplications #-}"
  , "{-# LANGUAGE DeriveGeneric #-}"
  , "{-# LANGUAGE FlexibleInstances #-}"
  , "module NoPkGolden where"
  , "import Data.Text (Text)"
  , "import Manifest.Derive.TH (field, mkEntity)"
  , "$(mkEntity \"Bad\" \"bads\" [ field \"name\" [t| Text |] ])"
  ]
```

New test case (append to the `group "TH"` list):
```haskell
  , test "mkEntity without a PrimaryKey field is a compile error naming the problem" $ do
      tmp <- getTemporaryDirectory
      (path, h) <- openTempFile tmp "NoPkGolden.hs"
      hClose h
      writeFile path noPkSource
      (_code, _out, err) <-
        readProcessWithExitCode "ghc"
          [ "-fforce-recomp", "-outputdir", tmp
          , "-package-db", ".zinc/pkgdb"
          , "-i.zinc/lib", "-itest"
          , "-XTemplateHaskell", "-XTypeFamilies", "-XTypeApplications"
          , "-XDeriveGeneric", "-XFlexibleInstances"
          , path
          ]
          ""
      removeFile path
      let msg = unwords (words err)
      assertBool ("names the missing PrimaryKey; output was:\n" <> err)
        ("has no PrimaryKey field" `isInfixOf` msg)
  ]
```

> Uses `-outputdir tmp` (not `-fno-code`): the splice must actually run to hit `fail`, and `-fno-code` can interfere with TH evaluation. The compile aborts at the splice with our message, which we assert appears in stderr.

- [ ] **Step 2: Run to verify the golden passes**

Run: `nix develop -c zinc test 2>&1 | grep -A1 "no PrimaryKey\|without a PrimaryKey"`
Expected: PASS. (If it FAILs because `ghc` couldn't find the package, check the `-package-db .zinc/pkgdb -i.zinc/lib` paths exist after a build — they're produced by `zinc build`.)

- [ ] **Step 3: Re-export `mkEntity`/`field` from the umbrella**

In `src/Manifest.hs`, add an export section after the metadata exports (`genericRowEncode`, ~line 62) and the matching import. Export list addition:

```haskell
    -- * Template Haskell front-end
  , mkEntity
  , field
```

Import addition (alongside the other `import Manifest.* (…)` blocks):

```haskell
import Manifest.Derive.TH
  ( mkEntity
  , field
  )
```

- [ ] **Step 4: Verify the umbrella still builds**

Run: `nix develop -c zinc build 2>&1 | tail -5`
Expected: builds clean, no warnings. (`Manifest.hs` is `-Wall`; an unused re-export is not a warning, so this just confirms the names resolve.)

- [ ] **Step 5: Document the built feature in `docs/entities.md`**

Add a section to `docs/entities.md` (the entities page) titled "Deriving entities with Template Haskell". It must be honest: the macro generates the *core* entity; relationships and cascades are still declared separately. Append:

````markdown
## Deriving entities with Template Haskell

Writing the HKD record, the `type` synonym, and the `Entity` instance by hand is
mechanical. The `mkEntity` macro generates all three from one block:

```haskell
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}

import Manifest (mkEntity, field)
import Manifest.Core.Table (PrimaryKey, Serial)
import Data.Text (Text)

mkEntity "Widget" "widgets"
  [ field "id"   [t| PrimaryKey (Serial Int) |]
  , field "name" [t| Text |]
  , field "size" [t| Maybe Int |]
  ]
```

This is exactly equivalent to writing `data WidgetT f = Widget { widgetId :: …, … }
deriving Generic`, `type Widget = WidgetT Identity`, and the `Entity Widget`
instance by hand. Field selectors are the lowercased entity name plus the
capitalised short name (`widgetId`, `widgetName`), and column names are their
`snake_case` form (`widget_id`). Exactly one field must be a `PrimaryKey`; it
becomes `primKey`.

> **Scope:** `mkEntity` generates the core entity only. Relationships
> (`HasRelation` instances) and `onDelete` cascade rules are declared separately,
> the same way as for a hand-written entity.
````

If the page carried a "Planned" callout for TH sugar, change it to reflect that the core macro now exists (relations-in-the-macro remain future work).

- [ ] **Step 6: Final full-suite run**

Run: `nix develop -c zinc test 2>&1 | tail -3`
Expected: every test green, total count = previous baseline + 4 (two metadata/primKey, one round-trip, one golden).

- [ ] **Step 7: Commit**

```bash
git add test/THSpec.hs src/Manifest.hs docs/entities.md
git commit -m "feat(th): export mkEntity from umbrella; golden + docs"
```

---

## Self-Review

**1. Spec coverage** (against the SP4 design intent "a TH macro takes a terse declaration and generates the `UserT f` record + `Generic` + relationship stubs"):
- HKD record + `Generic` → Task 1 (`dataDec`). ✓
- `type E = ET Identity` synonym → Task 1 (`synDec`). ✓
- `Entity` instance (`tableMeta`/`rowDecoder`/`rowEncode`/`primKey`/`PrimKey`) → Task 1 (`instDec`). ✓
- Terse one-block declaration → the `mkEntity`/`field` API. ✓
- *"relationship stubs"* — intentionally **out of scope** for SP4a (documented in Scope note + `entities.md`); relations stay hand-written. This is a deliberate, stated narrowing, not a gap.
- Correctness proven three ways: pure metadata equality (Task 1), DB round-trip (Task 2), negative golden (Task 3).

**2. Placeholder scan:** No TBD/TODO/"add error handling"/"similar to" — every step has complete code or an exact command + expected output. ✓

**3. Type consistency:**
- `mkEntity :: String -> String -> [(String, Q Type)] -> Q [Dec]` and `field :: String -> Q Type -> (String, Q Type)` — used consistently in `Manifest.Derive.TH`, `THSpec`, the golden source, and the umbrella re-export. ✓
- Generated selectors `widgetId`/`widgetName`/`widgetSize` — used identically in the metadata test, the round-trip (`Widget { widgetId = …, … }`), and asserted column names `widget_id`/`widget_name`/`widget_size`. ✓
- `ColumnMeta` positional fields `cmName cmIsPK cmIsSerial cmSqlType cmNullable` match `Manifest.Core.Meta:33-39`; `SqlBigSerial`/`SqlText`/`SqlBigInt` match the `FieldMeta`/`ScalarMeta` instances (`Manifest.Core.Table:50-75`). ✓
- `add :: Entity a => a -> Db a` (eager) and `get :: (Entity a, ToField (PrimKey a)) => Key a -> Db (Maybe a)` — used as in `EndToEndSpec`. ✓

**Open risk carried into execution:** the `template-haskell` 2.22 binder-flag (`plainTV`) signature — flagged inline at Task 1 Step 4 with the fix. TDD compile feedback resolves it in one iteration.
