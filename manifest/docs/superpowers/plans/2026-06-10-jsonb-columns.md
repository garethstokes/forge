# JSONB Columns (autodocodec) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A column can store a structured Haskell value as Postgres `jsonb` (serialized via an autodocodec `HasCodec`), and queries can filter/extract on the document with `@>`, `->`, `->>`.

**Architecture:** A `Json a` newtype gets a `DbType (Json a)` instance (built on slice 1's `Codec`/`DbType`) that encodes/decodes through autodocodec; it slots into the existing HKD engine because `Base (Json a) = Json a` and `FieldMeta` reads `cSqlType = SqlJsonb`. The jsonb query operators are thin `Expr` renderers in the query builder.

**Tech Stack:** GHC 9.10.1 via zinc (NOT cabal). New dependency `autodocodec` (resolved+compiled under zinc during planning; pulls aeson/vector/scientific etc.). Existing: `Manifest.Core.Codec` (`Codec(..)`/`DbType(..)`/`encode`), `Manifest.Core.SqlType`, `Manifest.Query` (`Expr`/`quoteLit`/`runQuery`), custom `test/Harness.hs`.

**Spec:** `docs/superpowers/specs/2026-06-10-jsonb-columns-design.md`.

**Baseline:** `main` is at **122/122**. Confirm with `nix develop -c zinc test` then `nix develop -c .zinc/build/spec`.

**Build/test commands:**
- `nix develop -c zinc build` — build library (does NOT rebuild tests).
- `nix develop -c zinc test` — rebuild + run tests (summary `N/N tests passed`).
- `nix develop -c .zinc/build/spec` — re-run the built test binary.

**Pre-verified during planning (do not re-derive):**
- `zinc add autodocodec` resolves the full closure via git (46 packages incl. aeson/vector/scientific) and **compiles** under GHC 9.10.1 (~77s first build). `autodocodec-aeson` does NOT exist as a separate package; the aeson functions live in `autodocodec` core.
- The API: `import Autodocodec` provides `HasCodec(..)` (method `codec`), the object-codec combinators `object`/`requiredField`/`.=`, and the round-trip functions `encodeJSONViaCodec :: HasCodec a => a -> LB.ByteString` and `eitherDecodeJSONViaCodec :: HasCodec a => LB.ByteString -> Either String a`. A sample `HasCodec` instance + round-trip compiled cleanly.

---

## File Structure

- **`zinc.toml`** — `[dependencies.autodocodec]` (via `zinc add`) + `"autodocodec"` in `[build.lib].depends` and `[build.test.spec].depends`. `zinc.lock` frozen by `zinc add`.
- **`src/Manifest/Core/SqlType.hs`** — add `SqlJsonb` + its two spellings.
- **`src/Manifest/Json.hs`** (NEW) — `Json a` newtype + `DbType (Json a)` via autodocodec.
- **`src/Manifest/Query.hs`** — `Jsonb` marker, `JsonbExpr` class, `.@>`/`.->`/`.->>` operators.
- **`src/Manifest.hs`** — re-export `Json(..)`, `Jsonb`, `JsonbExpr`, the operators, and `HasCodec`.
- **`test/JsonSpec.hs`** (NEW) — unit + DB round-trip + operator tests; registered in `test/Spec.hs`.
- **`docs/entities.md`** — a "JSONB columns" section.

---

### Task 1: Add the `autodocodec` dependency and `SqlJsonb`

**Files:** Modify `zinc.toml`, `src/Manifest/Core/SqlType.hs`, `test/CodecSpec.hs` (or a small unit assertion); `zinc.lock` (auto).

- [ ] **Step 1: Add the dependency via zinc and confirm it builds**

```bash
nix develop -c zinc add autodocodec
```
This resolves the closure via git and freezes `zinc.lock`. It does NOT edit `depends`. Then add `"autodocodec",` to BOTH `[build.lib].depends` and `[build.test.spec].depends` in `zinc.toml` (the test target defines a `HasCodec` instance, so it needs the package too). Then:
```bash
nix develop -c zinc build 2>&1 | tail -8
```
Expected: builds (first time compiles ~33 packages, ~80s; cached after). If `zinc add autodocodec` fails to resolve, STOP and report — this is the gating dependency (it was verified to work during planning, so a failure here is environmental).

- [ ] **Step 2: Add `SqlJsonb` to `src/Manifest/Core/SqlType.hs`**

```haskell
data SqlType = SqlBigInt | SqlText | SqlBool | SqlBigSerial | SqlJsonb
  deriving (Eq, Show)

sqlTypeDDL SqlJsonb = "JSONB"      -- add this equation
sqlTypeLive SqlJsonb = "jsonb"     -- add this equation
```
Add the two equations to the existing `sqlTypeDDL`/`sqlTypeLive` functions (keep the others).

- [ ] **Step 3: Unit test the new SqlType spellings**

Add to `test/CodecSpec.hs` (it already imports the codec module; add `Manifest.Core.SqlType` import for `sqlTypeDDL`/`sqlTypeLive`/`SqlType(..)`):
```haskell
  , test "SqlJsonb DDL and live spellings" $ do
      assertEqual "ddl"  "JSONB" (sqlTypeDDL SqlJsonb)
      assertEqual "live" "jsonb" (sqlTypeLive SqlJsonb)
```
(`sqlTypeDDL`/`sqlTypeLive` return `ByteString`; with `OverloadedStrings` the literals match.)

- [ ] **Step 4: Build + test**

`nix develop -c zinc test 2>&1 | tail -8` then `nix develop -c .zinc/build/spec 2>&1 | tail -3`.
Expected: **123/123** (122 + 1). The new dep must not break any existing test.

- [ ] **Step 5: Commit**
```bash
git add zinc.toml zinc.lock src/Manifest/Core/SqlType.hs test/CodecSpec.hs
git status   # if .beads/issues.jsonl staged: git restore --staged .beads/issues.jsonl
git commit -m "feat(core): add autodocodec dep + SqlJsonb type"
```

---

### Task 2: The `Json a` column (`Manifest.Json`)

**Files:** Create `src/Manifest/Json.hs`; Modify `src/Manifest.hs`, `test/JsonSpec.hs` (new), `test/Spec.hs`.

- [ ] **Step 1: Write the failing unit test**

Create `test/JsonSpec.hs`:
```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module JsonSpec (tests) where

import Autodocodec
import Data.Text (Text)
import Manifest (Json (..), DbType (..), Codec (..), encode)
import Manifest.Core.SqlType (SqlType (..))
import Harness (Test, group, test, assertEqual, assertBool)

data Prefs = Prefs { prefTheme :: Text, prefTags :: [Text] }
  deriving (Eq, Show)

instance HasCodec Prefs where
  codec = object "Prefs" $
    Prefs <$> requiredField "theme" "ui theme" .= prefTheme
          <*> requiredField "tags"  "tags"     .= prefTags

tests :: [Test]
tests = group "Json"
  [ test "Json column reports jsonb and round-trips its codec" $ do
      let p   = Prefs "dark" ["a", "b"]
          enc = encode (Json p)                          -- a -> SqlParam (Just jsonb bytes)
      assertEqual "sqltype is jsonb" SqlJsonb (cSqlType (dbType @(Json Prefs)))
      assertBool  "encodes to some bytes" (enc /= Nothing)
      assertEqual "decode . encode = id"
        (Right (Json p))
        (cDecode (dbType @(Json Prefs)) enc)
  ]
```
Register in `test/Spec.hs`: add `import qualified JsonSpec` and `JsonSpec.tests` to the test-tree list (mirror the other `*Spec` modules). Confirm the exact `Harness` API names against `test/Harness.hs` and the other specs.

`nix develop -c zinc test 2>&1 | tail -15` → expect compile failure (`Json`/`Manifest.Json` not defined).

- [ ] **Step 2: Create `src/Manifest/Json.hs`**

```haskell
{-# LANGUAGE FlexibleInstances #-}

module Manifest.Json
  ( Json (..)
  ) where

import Autodocodec (HasCodec, encodeJSONViaCodec, eitherDecodeJSONViaCodec)
import Data.Bifunctor (bimap)
import qualified Data.ByteString.Lazy as LB
import Manifest.Core.Codec (Codec (..), DbType (..))
import Manifest.Core.SqlType (SqlType (SqlJsonb))
import Manifest.Error (DecodeError (..))

-- | A column that stores its value as Postgres @jsonb@, serialized through the
-- value's autodocodec 'HasCodec' instance.
newtype Json a = Json { unJson :: a }
  deriving (Eq, Show)

instance HasCodec a => DbType (Json a) where
  dbType = Codec
    { cEncode   = \(Json x) -> Just (LB.toStrict (encodeJSONViaCodec x))
    , cDecode   = \p -> case p of
        Just bs -> bimap (DecodeError . ("jsonb decode: " <>)) Json
                         (eitherDecodeJSONViaCodec (LB.fromStrict bs))
        Nothing -> Left (DecodeError "expected jsonb, got NULL")
    , cSqlType  = SqlJsonb
    , cNullable = False
    }
```
(Confirm `DecodeError`'s constructor shape in `Manifest.Error` — it wraps a `String`/`Text`; adjust the `DecodeError . (...)` accordingly. `eitherDecodeJSONViaCodec` returns `Either String a`.)

- [ ] **Step 3: Re-export from `src/Manifest.hs`**

Add `import Manifest.Json (Json (..))` and `import Autodocodec (HasCodec (..))`; export `Json (..)` and `HasCodec (..)` from the umbrella (so a user declares a jsonb column against `import Manifest`, and `import Autodocodec` only to write the `codec`).

- [ ] **Step 4: Build + test**

`nix develop -c zinc test 2>&1 | tail -8` then `nix develop -c .zinc/build/spec 2>&1 | tail -3`.
Expected: **124/124**. Deliberate-failure check: change the decode expectation to `Right (Json (Prefs "light" []))`, confirm FAIL, restore.

- [ ] **Step 5: Commit**
```bash
git add src/Manifest/Json.hs src/Manifest.hs test/JsonSpec.hs test/Spec.hs
git status   # unstage .beads if needed
git commit -m "feat(core): Json a jsonb column via autodocodec"
```

---

### Task 3: JSONB column DB round-trip

Prove a `Json` column works end to end through Postgres (add/get/save), including a nullable one.

**Files:** Modify `test/JsonSpec.hs`.

- [ ] **Step 1: Write the DB test**

Read another DB spec (e.g. `test/TypedFieldsSpec.hs`) for the exact harness API (`withEmptyDb`/`withConnection`/`execText`/`withSession`/`add`/`get`/`save`/`Key`). Add to `JsonSpec.hs` (it already has `Prefs`/`HasCodec`):
```haskell
data SettingT f = Setting
  { settingId    :: Field f (Pk Int)
  , settingPrefs :: Field f (Json Prefs)
  , settingNote  :: Field f (Maybe (Json Prefs))     -- nullable jsonb
  } deriving Generic
type Setting = SettingT Identity
deriving via (Table "settings" SettingT) instance Entity Setting

settingsDDL :: BC.ByteString
settingsDDL = "CREATE TABLE settings ( setting_id BIGSERIAL PRIMARY KEY, setting_prefs JSONB NOT NULL, setting_note JSONB )"
```
Add the imports this needs (`Manifest` for `Field`/`Pk`/`Table`/`Entity`/`Key`/`add`/`get`/`save`/session verbs, `Manifest.Postgres`/`Fixtures` for `withEmptyDb`/`withConnection`/`execText` exactly as the other specs import them, `qualified Data.ByteString.Char8 as BC`, `GHC.Generics`, `Data.Functor.Identity`). Add the module pragmas `DerivingVia`, `StandaloneDeriving`, `DataKinds`, `DeriveGeneric`, `TypeApplications`.

Test:
```haskell
  , test "a jsonb column round-trips through add/get/save (and nullable)" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c settingsDDL [])
        out <- withSession pool $ do
          let p0 = Prefs "dark" ["x"]
          s  <- add (Setting { settingId = 0, settingPrefs = Json p0, settingNote = Nothing } :: Setting)
          g1 <- get @Setting (Key (settingId s))
          save (s { settingPrefs = Json (Prefs "light" ["y","z"]), settingNote = Just (Json p0) })
          g2 <- get @Setting (Key (settingId s))
          pure (fmap (unJson . settingPrefs) g1, fmap (fmap unJson . settingNote) g2, fmap (unJson . settingPrefs) g2)
        assertEqual "initial prefs"   (Just (Prefs "dark" ["x"]))        (\(a,_,_) -> a) `seq` (let (a,_,_) = out in a)
        assertEqual "updated note"    (Just (Just (Prefs "dark" ["x"]))) (let (_,b,_) = out in b)
        assertEqual "updated prefs"   (Just (Prefs "light" ["y","z"]))   (let (_,_,c) = out in c)
```
(Clean up the tuple destructuring to the harness's style; the intent is: initial `Nothing` note, then `save` sets prefs + note, and `get` reflects both. Remove the stray `seq` line — it is illustrative; use plain `let (a,_,_) = out in a`.)

- [ ] **Step 2: Run + deliberate-failure**

`nix develop -c .zinc/build/spec 2>&1 | tail -3` → **125/125**. Change one expected `Prefs` value, confirm FAIL, restore.

- [ ] **Step 3: Commit**
```bash
git add test/JsonSpec.hs
git commit -m "test(core): jsonb column round-trips through the DB"
```

---

### Task 4: JSONB query operators

**Files:** Modify `src/Manifest/Query.hs`, `src/Manifest.hs`, `test/JsonSpec.hs`.

- [ ] **Step 1: Add the operators to `src/Manifest/Query.hs`**

Read the module to confirm the `Expr` constructor (`Expr ByteString [SqlParam]`), `quoteLit`, and `encode` are in scope (they are — `Expr` and `quoteLit` are defined here; `encode` is imported from `Manifest.Core.Codec`). Add `import Manifest.Json (Json)` and `import Data.Text (Text)` (if not already). Add to the export list: `Jsonb`, `JsonbExpr`, `(.@>)`, `(.->)`, `(.->>)`. Then:

```haskell
-- | An opaque jsonb sub-document (the result of '.->'); its Haskell type is not
-- tracked, so it can only be further navigated with '.->'/'.->>'.
data Jsonb

-- | Expressions that evaluate to jsonb: a typed 'Json' column or an untyped
-- 'Jsonb' sub-document.
class JsonbExpr e where
  jRaw    :: e -> ByteString
  jParams :: e -> [SqlParam]

instance JsonbExpr (Expr (Json a)) where
  jRaw    (Expr s _) = s
  jParams (Expr _ p) = p

instance JsonbExpr (Expr Jsonb) where
  jRaw    (Expr s _) = s
  jParams (Expr _ p) = p

-- | jsonb containment: @lhs \@> rhs@. The right side is a typed literal bound as
-- a @?::jsonb@ parameter.
(.@>) :: DbType (Json a) => Expr (Json a) -> Json a -> Expr Bool
(Expr a pa) .@> lit = Expr (a <> " @> ?::jsonb") (pa ++ [encode lit])
infix 4 .@>

-- | Navigate to an object field (or array element key) as jsonb; chainable.
(.->) :: JsonbExpr e => e -> Text -> Expr Jsonb
e .-> k = Expr (jRaw e <> " -> " <> quoteLit k) (jParams e)

-- | Navigate to an object field as text (NULL if absent fails comparisons).
(.->>) :: JsonbExpr e => e -> Text -> Expr Text
e .->> k = Expr (jRaw e <> " ->> " <> quoteLit k) (jParams e)
infixl 8 .->, .->>
```
(`DbType (Json a)` in `.@>` is satisfied by `HasCodec a`; `encode lit` produces the jsonb text param.)

- [ ] **Step 2: Re-export from `src/Manifest.hs`**

Add `(.@>)`, `(.->)`, `(.->>)`, `Jsonb`, `JsonbExpr` to the umbrella exports (they come from `Manifest.Query`, already imported by the umbrella — extend that import/export).

- [ ] **Step 3: Write the operator DB tests**

Add to `test/JsonSpec.hs` (reuses the `settings` table + `Setting` entity from Task 3; import the query builder verbs `runQuery`/`from`/`where_`/`(^.)`/`val`/`(.==)` from `Manifest`):
```haskell
  , test "jsonb operators @> / ->> / -> filter on the document" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c settingsDDL [])
        res <- withSession pool $ do
          _ <- add (Setting 0 (Json (Prefs "dark"  ["x"])) Nothing :: Setting)
          _ <- add (Setting 0 (Json (Prefs "light" ["y"])) Nothing :: Setting)
          byText <- runQuery $ do
            s <- from @Setting
            where_ (s ^. #settingPrefs .->> "theme" .== val ("dark" :: Text))
            pure s
          byContain <- runQuery $ do
            s <- from @Setting
            where_ (s ^. #settingPrefs .@> Json (Prefs "light" ["y"]))
            pure s
          pure (map (unJson . settingPrefs) byText, map (unJson . settingPrefs) byContain)
        assertEqual "->> theme=dark finds the dark row" [Prefs "dark" ["x"]]  (fst res)
        assertEqual "@> finds the light row"            [Prefs "light" ["y"]] (snd res)
```
(Adjust `Setting 0 ... ` positional construction to record syntax if the field order differs; confirm `runQuery`/`from`/`where_`/`val` names against `Manifest.Query`'s exports. Use `(.==)` — the Expr-level equality — not `==.`.)

- [ ] **Step 4: Run + deliberate-failure**

`nix develop -c .zinc/build/spec 2>&1 | tail -3` → **126/126**. Flip an expected row (e.g. expect `"light"` from the `->> "dark"` query), confirm FAIL, restore.

- [ ] **Step 5: Commit**
```bash
git add src/Manifest/Query.hs src/Manifest.hs test/JsonSpec.hs
git status   # unstage .beads if needed
git commit -m "feat(query): jsonb operators @> -> ->>"
```

---

### Task 5: Docs

**Files:** Modify `docs/entities.md`.

- [ ] **Step 1: Add a "JSONB columns" section**

Read `docs/entities.md` for placement and voice. Add a section covering: declaring a `Json a` column (with the `HasCodec` instance via `import Autodocodec`), that the column type is `jsonb`, nullable jsonb via `Maybe (Json a)`, and querying with `.@>`/`.->`/`.->>` inside `runQuery`. Use this code, in the existing voice (no em-dashes, no other-ORM names, no positioning claims):

````markdown
## JSONB columns

A column can store a structured value as Postgres `jsonb`. Wrap the value type in
`Json` and give it an `autodocodec` `HasCodec` instance:

```haskell
import Autodocodec

data Prefs = Prefs { prefTheme :: Text, prefTags :: [Text] }
instance HasCodec Prefs where
  codec = object "Prefs" $
    Prefs <$> requiredField "theme" "ui theme" .= prefTheme
          <*> requiredField "tags"  "tags"     .= prefTags

data UserT f = User
  { userId    :: Field f (Pk Int)
  , userPrefs :: Field f (Json Prefs)          -- column type jsonb
  , userExtra :: Field f (Maybe (Json Prefs))  -- nullable jsonb
  } deriving Generic
```

The whole value encodes to and from `jsonb` on every read and write. Query into the
document with `.@>` (containment), `.->` (field as jsonb, chainable), and `.->>` (field
as text):

```haskell
runQuery $ do
  u <- from @User
  where_ (u ^. #userPrefs .->> "theme" .== val "dark")
  pure u
```
````

- [ ] **Step 2: Verify**

`nix develop -c .zinc/build/spec 2>&1 | tail -2` (126/126, unaffected); `grep -n "—" docs/entities.md` (no em-dashes in the new section).

- [ ] **Step 3: Commit**
```bash
git add docs/entities.md
git commit -m "docs: JSONB columns section"
```

---

## Self-Review

**1. Spec coverage** (against `2026-06-10-jsonb-columns-design.md`):
- §1 `Json a` + `DbType` via autodocodec → Task 2. ✓
- §2 `SqlJsonb` → Task 1. ✓
- §3 operators `.@>`/`.->`/`.->>` + `Jsonb`/`JsonbExpr` → Task 4. ✓
- §4 umbrella exports (`Json`, operators, `HasCodec`) → Tasks 2 & 4. ✓
- §5 dependency gating risk → resolved during planning (`zinc add autodocodec` compiles); Task 1 reproduces it. ✓
- §6 testing (unit byte round-trip + DB round-trip + nullable + each operator) → Tasks 2,3,4; out-of-scope items (path ops, GIN, aeson-only, `json`) not touched. ✓

**2. Placeholder scan:** Concrete code/commands per step. The two environment-dependent spots are flagged with explicit handling: the `Harness`/`Manifest` exact import names (instructed to confirm against the real modules) and the `DecodeError` constructor shape (confirm in `Manifest.Error`). The Task 3 tuple-destructuring note explicitly says to clean up the illustrative `seq`. No TBD/TODO.

**3. Type consistency:** `Json(..)`/`unJson`, `DbType (Json a)`, `cSqlType = SqlJsonb`, `encode`, `Jsonb`, `JsonbExpr`/`jRaw`/`jParams`, `.@>`/`.->`/`.->>` are used identically across tasks. `.@>` takes a `Json a` literal (matches `DbType (Json a) => ... -> Json a -> Expr Bool`); `.->`/`.->>` are `JsonbExpr e => e -> Text -> Expr Jsonb`/`Expr Text` and compose (`.-> "a" .->> "b"`). `.==`/`val`/`runQuery`/`from`/`where_`/`(^.)` are the slice-1 query-builder names. Test counts thread: 122 → 123 (Task 1) → 124 (Task 2) → 125 (Task 3) → 126 (Task 4) → 126 (Task 5).
