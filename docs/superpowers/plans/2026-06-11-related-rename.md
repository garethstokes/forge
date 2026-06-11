# Rename `HasRelation.Target` → `Related` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the `HasRelation` associated type family `Target` to `Related` so entities can be named `Target`, then strip every workaround from manifest-evals (un-split `Evals.Schema.Types`, drop all `hiding (Target)`).

**Architecture:** Pure compile-time rename, clean break (no compat alias). Manifest first (4 .hs files + 1 manual page, suite proves it), push; then manifest-evals re-pins and collapses its clash workarounds in one commit.

**Tech Stack:** GHC 9.10.1 (manifest) / 9.12.2 (manifest-evals), zinc, `nix develop -c zinc test`.

**Spec:** `docs/superpowers/specs/2026-06-11-related-family-rename-design.md` · **Issue:** manifest-jkq

---

### Task 1: the rename in manifest

**Files (every `Target` family token, verified by grep):**
- Modify: `src/Manifest/Core/Relation.hs:36,38,50`
- Modify: `src/Manifest/Relation.hs:33,34,39,109,110`
- Modify: `src/Manifest/Relation/Loaded.hs:84,95,165,167`
- Modify: `test/Fixtures.hs:111,117,132,137,142,147`
- Modify: `docs/relationships.md` (13 occurrences in code blocks/prose)

- [ ] **Step 1: Rename the family token.** In the four .hs files, replace the type-level token `Target` with `Related` at exactly the listed lines:
  - `Core/Relation.hs:36`: `type Target      a name :: Type` → `type Related     a name :: Type` (keep the `-- ^ [Post] / Maybe Profile` haddock; keep column alignment with `Cardinality` below it).
  - `Core/Relation.hs:38`: `relSpec :: RelSpec (Target a name)` → `RelSpec (Related a name)`.
  - `Core/Relation.hs:50` (comment): `The child type comes from the 'Target'.` → `The child type comes from the 'Related'.`
  - `Relation.hs:33` (comment): `returns the plain 'Target'` → `returns the plain 'Related'`.
  - `Relation.hs:34,39`: `Db (Target a name)` → `Db (Related a name)` in `load` and `loadRel`.
  - `Relation.hs:109,110`: `Target a n1 ~ [mid]` / `Target mid n2 ~ [leaf]` → `Related ...`.
  - `Loaded.hs:84,165`: `Typeable (Target a name)` → `Typeable (Related a name)`.
  - `Loaded.hs:95`: `joinedLoad ... Db (Target a name)` → `Db (Related a name)`.
  - `Loaded.hs:167`: `Rel a name -> Ent loaded a -> Target a name` → `... -> Related a name`.
  - `test/Fixtures.hs` (6 instance lines): `type Target      X "rel" = ...` → `type Related     X "rel" = ...` (keep alignment).

- [ ] **Step 2: Verify no stragglers.** Run: `grep -rn '\bTarget\b' src/ test/ docs/tutorials/ --include='*.hs' --include='*.lhs'`. Expected: NO matches (TargetId/TargetVersion etc. don't word-match `\bTarget\b`... they do not exist in manifest itself).

- [ ] **Step 3: Suite.** Run: `nix develop -c zinc test 2>&1 | tail -3`. Expected: `147/147 tests passed` (compile-time-only change; the relationship/joined/self-ref specs exercise every renamed signature).

- [ ] **Step 4: Manual page.** In `docs/relationships.md`, replace the family token in the code blocks and prose: `type Target` → `type Related`, `Target a name` → `Related a name`, `Db (Target a name)` → `Db (Related a name)`, and any prose sentence naming the family (`the `Target` family` → `the `Related` family`). Lower-case prose uses of the word "target" (e.g. "the target of the relation") stay.

- [ ] **Step 5: Commit + push.**

```bash
git add src/Manifest/Core/Relation.hs src/Manifest/Relation.hs src/Manifest/Relation/Loaded.hs test/Fixtures.hs docs/relationships.md
git commit -m "refactor(relation): rename HasRelation.Target -> Related (manifest-jkq)

Entities can now be named Target without clashing with the family."
git push 2>&1 | tail -1
```

---

### Task 2: strip the workarounds in manifest-evals

**Files (in /home/gareth/code/garethstokes/manifest-evals):**
- Modify: `zinc.toml` ([dependencies.manifest].rev), `zinc.lock` (via `zinc update manifest`)
- Modify: `src/Evals/Schema.hs` (absorbs the record types; instances use `Related`)
- Delete: `src/Evals/Schema/Types.hs`
- Modify: `src/Evals/Migrate.hs:5-11`, `src/Evals/Execute.hs:39`, `test/SchemaSpec.hs:14`, `test/ExecuteSpec.hs` (drop `hiding (Target)` + stale comments)

- [ ] **Step 1: Re-pin manifest.** In `zinc.toml`, set `[dependencies.manifest] rev` to Task 1's pushed sha (update the rev comment to mention the Related rename). Then run `nix develop -c zinc update manifest` — expect a closure delta line `~ manifest <old> -> <new>`. (Editing the rev alone is NOT picked up as lock drift — the `zinc update` is required.)

- [ ] **Step 2: Merge `Evals.Schema.Types` into `Evals.Schema`.** Rewrite `src/Evals/Schema.hs` as ONE module:
  - Pragmas: the union of both files' — `DataKinds, DeriveGeneric, DerivingVia, DuplicateRecordFields, FlexibleInstances, NoFieldSelectors, OverloadedLabels, OverloadedRecordDot, StandaloneDeriving, TypeApplications, TypeFamilies`.
  - Header: `module Evals.Schema where` (no export list — exports all locally defined types; instances export implicitly). New haddock: the schema module — record types, Entity instances with cascade rules, and the HasRelation graph; note the family is `Related` since manifest-jkq so the `Target` entity needs no module split.
  - Imports: `import Data.Aeson (Value)`, `import Data.Functor.Identity (Identity)`, `import Data.Proxy (Proxy(..))`, `import Data.Text (Text)`, `import Data.Time (UTCTime)`, `import GHC.Generics (Generic)`, `import Manifest` (NO hiding), `import Evals.Ids`.
  - Body: all record types from `Schema/Types.hs` verbatim (Dataset…RunMetric), followed by all instances from the old `Schema.hs` with these mechanical edits: every `type Target ` → `type Related `; every `T.Target` → `Target`; every `T.TargetVersion` → `TargetVersion`; drop the `import qualified Evals.Schema.Types as T` and `import Evals.Schema.Types`; drop the old module-split haddocks.
  - Delete `src/Evals/Schema/Types.hs` (and the now-empty `src/Evals/Schema/` directory).

- [ ] **Step 3: Drop `hiding (Target)` everywhere.** `src/Evals/Migrate.hs` (also rewrite its lines 4-8 haddock which explains the hiding), `src/Evals/Execute.hs:39`, `test/SchemaSpec.hs:14`, `test/ExecuteSpec.hs` (its `import Manifest hiding (Target)` line) — all become plain `import Manifest`.

- [ ] **Step 4: Suite.** Run: `nix develop -c zinc test 2>&1 | tail -5`. Expected: both lines green (`SchemaSpec ... OK`, `ExecuteSpec ... OK`), `1 test suite(s) passed`.

- [ ] **Step 5: Verify no stragglers.** `grep -rn 'hiding (Target)\|Schema.Types\|T\.Target' src/ test/` — expected: no matches.

- [ ] **Step 6: Commit + push (manifest-evals), close the issue (manifest).**

```bash
git add -A && git commit -m "refactor: drop Target-clash workarounds (manifest Related rename)

Re-pin manifest; merge Evals.Schema.Types back into Evals.Schema; plain
'import Manifest' everywhere."
git push 2>&1 | tail -1
cd /home/gareth/code/garethstokes/manifest
bd close manifest-jkq --reason "Family renamed to Related (clean break); manifest-evals un-split Evals.Schema.Types and dropped all hiding (Target)."
git add .beads/issues.jsonl && git commit -m "chore(bd): close manifest-jkq" && git push 2>&1 | tail -1
```

---

## Self-Review

**1. Spec coverage:** §1 rename + clean break → Task 1 Steps 1-3,5; §2 consumers (Fixtures, relationships.md, historical docs untouched) → Task 1 Steps 1,4 (no task touches docs/superpowers); §3 payoff (re-pin, un-split, drop hiding, qualified T.* gone, Execute/tests otherwise untouched) → Task 2; §4 testing (both suites + sweep greps) → Task 1 Steps 2-3, Task 2 Steps 4-5; §5 out-of-scope: no task renames Rel/RelSpec/Cardinality or adds a shim.

**2. Placeholder scan:** none — every edit is enumerated by file:line or as an exact mechanical token substitution with the full import/pragma lists given.

**3. Type consistency:** the new token is `Related` in every step; manifest-evals instance heads after the merge use entity `Target` + family `Related` consistently.
