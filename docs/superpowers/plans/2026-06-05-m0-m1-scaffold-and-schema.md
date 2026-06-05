# Crucible M0 + M1: Scaffold + Schema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `crucible` project so it builds and tests under `zinc` (with `aeson` + `http-client` proven to resolve), then build a Generics-derived `Schema` layer with tests.

**Architecture:** A pure-core Haskell library. This plan delivers the foundation: a buildable zinc workspace with a minimal in-repo test harness (dependency-light, to avoid fighting zinc's no-solver git-pinned dep model), plus `Crucible.Schema` — a `HasSchema` typeclass that derives a `Schema` description of a type via GHC Generics (records → `SObj`, nullary sums → `SEnum`, plus base/`Maybe`/list instances).

**Tech Stack:** Haskell (GHC via `nix develop`), `zinc` build tool, GHC Generics, `aeson` (for the later `Value` type — installed and smoke-tested here, not yet used), `http-client` (smoke-tested here, used at M6).

**Beads:** Implements `crucible-f20` (M0) and `crucible-b87` (M1). Claim with `bd update <id> --claim`; close with `bd close <id>` when its tasks are done.

---

## File Structure

| File | Responsibility |
|---|---|
| `zinc.toml` | Workspace manifest: package name, library + test targets, dependencies (created by `zinc new`, edited here) |
| `zinc.lock` | Dependency lockfile (managed by `zinc add`) |
| `flake.nix` | Nix dev shell providing GHC + zinc (created by `zinc new` or copied from zinc's repo) |
| `src/Crucible/Schema.hs` | `Schema` type, `HasSchema` class, Generics derivation |
| `test/Harness.hs` | Minimal assertion harness (`check`, `runChecks`) — no external test framework |
| `test/Main.hs` | Test entry point; aggregates all checks |
| `app/Main.hs` | Throwaway smoke-test executable proving `aeson` + `http-client` link (kept minimal) |

> **Module layout note:** `src/` and `app/` and `test/` are the *hypothesised* source dirs. Task 1 confirms the real layout from the `zinc new` scaffold and you adjust paths if zinc differs. Do not assume — read the generated `zinc.toml`.

---

## Task 1: Scaffold the zinc workspace

**Files:**
- Create (via tool): `zinc.toml`, `flake.nix`, scaffold dirs

- [ ] **Step 1: Enter a dev shell with zinc available**

Run: `cd ~/code/garethstokes/crucible && nix develop` (if the repo has no flake yet, this fails — that's fine, continue to Step 2 which generates one, then re-enter).
Expected: either a shell with `ghc` and `zinc` on PATH, or a "no flake.nix" error.

- [ ] **Step 2: Scaffold the project**

Run: `zinc new crucible` (run from inside `~/code/garethstokes/crucible`; if it insists on creating a subdir, run from the parent and merge, or use the workspace-member form `zinc new --here` if supported — check `zinc new --help` first).
Expected: a `zinc.toml`, a `flake.nix` (or instructions to add one), and a starter source tree.

- [ ] **Step 3: Read and record the generated manifest**

Run: `cat zinc.toml` and `cat flake.nix`.
Action: Note the exact keys zinc uses — package/target stanza names, how the library target declares `source-dirs`, and whether a test or executable target is scaffolded. **Write these findings as comments at the top of `zinc.toml`** so later tasks reference the real schema, not guesses. If zinc's own repo is the only reference for the test-target format, run `zinc add` is not needed yet — instead read it directly: `nix run nixpkgs#git -- clone --depth 1 https://github.com/garethstokes/zinc /tmp/zinc-ref` and `cat /tmp/zinc-ref/zinc.toml` (zinc is self-hosting, so its own manifest is a worked example of library + test targets).

- [ ] **Step 4: Confirm a clean build of the empty scaffold**

Run: `zinc build`
Expected: success with no modules, or a build of the starter module. If it fails, resolve toolchain issues (usually `nix develop` not active) before proceeding.

- [ ] **Step 5: Commit the scaffold**

```bash
git add -A
git commit -m "chore(m0): scaffold zinc workspace"
```

---

## Task 2: Prove aeson + http-client resolve under zinc

This is the de-risking core of M0: zinc has no solver and pins transitive git deps, so we confirm the two heaviest deps link *before* the design relies on them.

**Files:**
- Modify: `zinc.toml` (deps), `zinc.lock` (auto)
- Create: `app/Main.hs`

- [ ] **Step 1: Add the dependencies**

Run:
```bash
zinc add aeson
zinc add http-client
```
Expected: each resolves to a git-pinned entry written into `zinc.lock`. If a transitive dep is missing (no-solver model surfaces this as a build error later, not here), record the error text verbatim — that is the M0 risk materialising and must be reported back, not worked around silently.

- [ ] **Step 2: Write a smoke executable that forces both libraries to link**

Create `app/Main.hs` (adjust dir to the scaffold's executable convention from Task 1):

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.Aeson as Aeson
import Network.HTTP.Client (newManager, defaultManagerSettings)

main :: IO ()
main = do
  -- Force aeson to link: round-trip a value through JSON.
  let encoded = Aeson.encode (Aeson.object ["ok" Aeson..= True])
  print encoded
  -- Force http-client to link: construct a manager (no request sent).
  _mgr <- newManager defaultManagerSettings
  putStrLn "aeson + http-client linked OK"
```

- [ ] **Step 3: Wire the executable target**

Action: Ensure `zinc.toml` declares an executable target pointing at `app/Main.hs` with deps `aeson`, `http-client`, following the exact stanza format recorded in Task 1, Step 3.

- [ ] **Step 4: Build and run it**

Run: `zinc run` (or `zinc run <target-name>` if multiple targets — name discovered in Task 1).
Expected output:
```
"{\"ok\":true}"
aeson + http-client linked OK
```
If the build fails on a missing transitive dependency, **stop and report** — resolving zinc's manual dep graph is the M0 deliverable and may need `zinc add <transitive>` repeated until the graph closes. Record each dep added.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(m0): prove aeson + http-client link under zinc"
```

---

## Task 3: Minimal in-repo test harness + smoke test (establish the test loop)

Establishes *how tests run under zinc* — the convention every later milestone depends on.

**Files:**
- Create: `test/Harness.hs`, `test/Main.hs`
- Modify: `zinc.toml` (test target)

- [ ] **Step 1: Write the assertion harness**

Create `test/Harness.hs`:

```haskell
module Harness (check, runChecks) where

import System.Exit (exitFailure, exitSuccess)

-- | Assert structural equality. Returns False on mismatch (does not abort),
-- so a run reports every failure, not just the first.
check :: (Eq a, Show a) => String -> a -> a -> IO Bool
check name expected actual
  | expected == actual = do
      putStrLn ("ok   " ++ name)
      pure True
  | otherwise = do
      putStrLn ("FAIL " ++ name)
      putStrLn ("  expected: " ++ show expected)
      putStrLn ("  actual:   " ++ show actual)
      pure False

-- | Run all checks; exit non-zero if any failed (so `zinc test` fails the build).
runChecks :: [IO Bool] -> IO ()
runChecks checks = do
  results <- sequence checks
  if and results
    then putStrLn "ALL PASS" >> exitSuccess
    else putStrLn "FAILURES" >> exitFailure
```

- [ ] **Step 2: Write a smoke test that must pass**

Create `test/Main.hs`:

```haskell
module Main (main) where

import Harness (check, runChecks)

main :: IO ()
main = runChecks
  [ check "harness self-test" (2 + 2 :: Int) 4
  ]
```

- [ ] **Step 3: Wire the test target**

Action: Add a test target to `zinc.toml` pointing at `test/Main.hs` with `source-dirs` including `test`, following the format from Task 1 (cross-checked against zinc's own `zinc.toml` test stanza). Record the final stanza shape as a comment so M1 can add to it.

- [ ] **Step 4: Run the test suite**

Run: `zinc test`
Expected output ends with:
```
ok   harness self-test
ALL PASS
```
and exit code 0. If `zinc test` does not discover the target, fix the stanza until it does — **this working loop is the M0 deliverable.**

- [ ] **Step 5: Commit and close M0**

```bash
git add -A
git commit -m "chore(m0): minimal in-repo test harness + green smoke test"
```
Run: `bd close crucible-f20 --reason="zinc workspace builds; aeson+http-client link; test loop established via in-repo harness"`

---

## Task 4: The `Schema` type + base-type instances

Begins M1. Claim it: `bd update crucible-b87 --claim`.

**Files:**
- Create: `src/Crucible/Schema.hs`
- Modify: `test/Main.hs`, `zinc.toml` (add `src` to the library/test source-dirs if not already)

- [ ] **Step 1: Write the failing test for base instances**

Add to `test/Main.hs` (import the module and extend the check list):

```haskell
import Crucible.Schema (Schema(..), schema)
import Data.Text (Text)

-- inside main's runChecks list, add:
  , check "Text  is SStr"  SStr  (schema @Text)
  , check "Int   is SNum"  SNum  (schema @Int)
  , check "Bool  is SBool" SBool (schema @Bool)
  , check "Maybe Int is SOpt SNum" (SOpt SNum) (schema @(Maybe Int))
  , check "[Bool] is SArr SBool"   (SArr SBool) (schema @[Bool])
```

Add the extensions at the top of `test/Main.hs`: `{-# LANGUAGE TypeApplications, OverloadedStrings #-}`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `zinc test`
Expected: FAIL to compile — `Crucible.Schema` / `schema` not in scope.

- [ ] **Step 3: Write the minimal Schema module**

Create `src/Crucible/Schema.hs`:

```haskell
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveGeneric #-}
module Crucible.Schema
  ( Schema(..)
  , HasSchema(..)
  ) where

import Data.Text (Text)
import GHC.Generics

-- | A description of a type's shape. v1 subset.
data Schema
  = SObj  [(String, Schema)]  -- ^ record: field name -> field schema
  | SArr  Schema              -- ^ list
  | SEnum [String]            -- ^ nullary sum: constructor names
  | SStr
  | SNum
  | SBool
  | SOpt  Schema              -- ^ Maybe
  deriving (Eq, Show)

-- | Types that can describe their own shape. Default via Generics.
class HasSchema a where
  schema :: Schema
  default schema :: (Generic a, GSchema (Rep a)) => Schema
  schema = gschema @(Rep a)

-- Base instances (no Generics).
instance HasSchema Text   where schema = SStr
instance HasSchema Int    where schema = SNum
instance HasSchema Double where schema = SNum
instance HasSchema Bool   where schema = SBool
instance HasSchema a => HasSchema (Maybe a) where schema = SOpt (schema @a)
instance HasSchema a => HasSchema [a]       where schema = SArr (schema @a)

-- | Generic schema over a type's representation. Instances added in later tasks;
-- declared here so the default signature compiles.
class GSchema (f :: * -> *) where
  gschema :: Schema
```

> Note: `gschema` over a `* -> *` rep is called via `@(Rep a)`; `AllowAmbiguousTypes` + `TypeApplications` make this resolve. The executor may need to nudge a kind annotation; that is expected GHC.Generics ergonomics, not a design change.

- [ ] **Step 4: Add `src` to source-dirs and run the test**

Action: Ensure the test target (and a library target) in `zinc.toml` includes `src` in `source-dirs` so `Crucible.Schema` is visible.
Run: `zinc test`
Expected: the five base-instance checks print `ok`, and `ALL PASS`. (No `GSchema` instances exist yet, but none are exercised by base types, so it links.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(m1): Schema type + base/Maybe/list HasSchema instances"
```

---

## Task 5: Generic derivation for records (single constructor → `SObj`)

**Files:**
- Modify: `src/Crucible/Schema.hs`, `test/Main.hs`

- [ ] **Step 1: Write the failing test with a sample record**

Add to `test/Main.hs`:

```haskell
import GHC.Generics (Generic)

data Forecast = Forecast { city :: Text, tempC :: Double, rainy :: Bool }
  deriving (Generic)
instance HasSchema Forecast

-- in the checks list:
  , check "record -> SObj"
      (SObj [("city", SStr), ("tempC", SNum), ("rainy", SBool)])
      (schema @Forecast)
```

- [ ] **Step 2: Run to verify failure**

Run: `zinc test`
Expected: compile FAIL — no `GSchema` instance for the record's `Rep` (`D1`/`C1`/`S1`/`:*:`/`K1`).

- [ ] **Step 3: Add the record-deriving Generic instances**

Add to `src/Crucible/Schema.hs` (below the `GSchema` class):

```haskell
-- Descend through the datatype wrapper.
instance GSchema f => GSchema (D1 d f) where
  gschema = gschema @f

-- A single constructor with fields is a record -> SObj.
instance GFields f => GSchema (C1 c f) where
  gschema = SObj (gfields @f)

-- Collect (fieldName, schema) pairs from a product of selectors.
class GFields (f :: * -> *) where
  gfields :: [(String, Schema)]

instance (GFields a, GFields b) => GFields (a :*: b) where
  gfields = gfields @a ++ gfields @b

instance (Selector s, HasSchema t) => GFields (S1 s (K1 r t)) where
  gfields = [ (selName (undefined :: S1 s (K1 r t) p), schema @t) ]
```

Add `{-# LANGUAGE KindSignatures #-}` to the module header.

- [ ] **Step 4: Run to verify pass**

Run: `zinc test`
Expected: `record -> SObj` prints `ok`, `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(m1): Generic schema derivation for records"
```

---

## Task 6: Generic derivation for enums (nullary sum → `SEnum`)

**Files:**
- Modify: `src/Crucible/Schema.hs`, `test/Main.hs`

- [ ] **Step 1: Write the failing test with a sample enum**

Add to `test/Main.hs`:

```haskell
data Sky = Clear | Cloudy | Storm
  deriving (Generic)
instance HasSchema Sky

-- in the checks list:
  , check "enum -> SEnum"
      (SEnum ["Clear", "Cloudy", "Storm"])
      (schema @Sky)
```

- [ ] **Step 2: Run to verify failure**

Run: `zinc test`
Expected: compile FAIL — no `GSchema` instance for the sum (`:+:`) of nullary constructors.

- [ ] **Step 3: Add the enum-deriving Generic instances**

Add to `src/Crucible/Schema.hs`:

```haskell
-- A sum of constructors is an enum -> SEnum of constructor names.
instance (GCon a, GCon b) => GSchema (a :+: b) where
  gschema = SEnum (gconNames @a ++ gconNames @b)

-- Collect constructor names from nullary constructors.
class GCon (f :: * -> *) where
  gconNames :: [String]

instance (GCon a, GCon b) => GCon (a :+: b) where
  gconNames = gconNames @a ++ gconNames @b

instance Constructor c => GCon (C1 c U1) where
  gconNames = [ conName (undefined :: C1 c U1 p) ]
```

- [ ] **Step 4: Run to verify pass**

Run: `zinc test`
Expected: `enum -> SEnum` prints `ok`, `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(m1): Generic schema derivation for nullary-sum enums"
```

---

## Task 7: Nested records + a combined fixture (integration check)

Confirms the record and enum paths compose (a record field whose type is itself a derived record or enum).

**Files:**
- Modify: `test/Main.hs`

- [ ] **Step 1: Write the failing test for a nested type**

Add to `test/Main.hs`:

```haskell
data Report = Report { sky :: Sky, forecast :: Forecast, notes :: Maybe Text }
  deriving (Generic)
instance HasSchema Report

-- in the checks list:
  , check "nested record composes"
      (SObj
        [ ("sky", SEnum ["Clear","Cloudy","Storm"])
        , ("forecast", SObj [("city", SStr), ("tempC", SNum), ("rainy", SBool)])
        , ("notes", SOpt SStr)
        ])
      (schema @Report)
```

- [ ] **Step 2: Run the test**

Run: `zinc test`
Expected: PASS with no new implementation — Task 5/6 instances already compose because `GFields`'s `S1` case calls `schema @t` recursively, dispatching back through `HasSchema`. If it does *not* pass, the bug is in the recursion and must be fixed in `Crucible.Schema`, not the test.

- [ ] **Step 3: Commit and close M1**

```bash
git add -A
git commit -m "test(m1): nested record/enum composition"
```
Run: `bd close crucible-b87 --reason="HasSchema derives records, enums, base/Maybe/list, and nested compositions; golden-style equality tests green under zinc test"`

---

## Self-Review

**Spec coverage (M0, M1 sections of the design):**
- M0 "zinc builds hello-world + aeson + http-client" → Tasks 1–2. ✓
- M0 implicit "establish dependency-light test harness" (design §3, §7) → Task 3. ✓
- M1 "Schema + Generics derivation" → Tasks 4–6. ✓
- M1 v1 scope: records ✓ (Task 5), nullary-sum enums ✓ (Task 6), Maybe/list/Text/Int/Double/Bool ✓ (Task 4). Deferred recursive/nested-sum-with-fields per spec — Task 7 covers nested *records/enums* (in scope) and does not attempt sum-with-fields (correctly deferred). ✓
- M1 "golden tests" → realised as in-code equality checks against expected `Schema` values (true golden *files* are reserved for M2's SAP fixtures, where messy text inputs make files worthwhile). Noted as a deliberate choice. ✓

**Placeholder scan:** No TBD/TODO. The only forward-references ("format recorded in Task 1", "stanza from Task 1") point at a concrete artifact (annotated `zinc.toml`) the engineer creates, not at undefined code. Acceptable because zinc's manifest format is genuinely undocumented and must be discovered, not invented.

**Type consistency:** `Schema` constructors (`SObj`/`SArr`/`SEnum`/`SStr`/`SNum`/`SBool`/`SOpt`) are used identically across Tasks 4–7. `schema`, `gschema`, `gfields`, `gconNames`, `GSchema`, `GFields`, `GCon` names are consistent between definition (Tasks 4–6) and use. `check expected actual` argument order is consistent across all tests.

**Known executor caveats (not plan failures):**
- The `gschema @(Rep a)` call under `AllowAmbiguousTypes` may need a minor kind/`Proxy` nudge depending on GHC version — expected GHC.Generics ergonomics.
- `zinc.toml` exact stanza names are confirmed in Task 1; all later edits follow that confirmed format.
