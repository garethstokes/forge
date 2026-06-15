# manifest-core Split Implementation Plan (Phase 0)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Split `manifest` into `manifest-core` (pure, libpq-free) + `manifest` (libpq, depends on manifest-core), in one zinc workspace, with the `Manifest` umbrella API unchanged.

**Architecture:** Move the 15 pure module *files* (names unchanged) to a new `manifest-core/` workspace member; `manifest` depends on it. Pure modules import only pure modules, so `manifest-core` builds without libpq. The umbrella and impure modules import the Core modules transitively — no source import edits needed (module names are identical).

**Tech Stack:** zinc workspace, GHC 9.10.1, libpq; ephemeral-Postgres test suite. Build/test under `nix develop`.

**Build/test commands (verify exact form against the repo's flake before relying on them):**
- Whole workspace build: `nix develop . --command timeout -s KILL 300 zinc build`
- A single member: `nix develop . --command timeout -s KILL 300 zinc build manifest-core`
- Tests (ephemeral pg, libpq linked): `nix develop . --command timeout -s KILL 600 zinc test`

---

### Task 1: Create the manifest-core member and move pure modules

**Files:**
- Create: `manifest-core/zinc.toml`
- Move (git mv, names unchanged): 15 files from `src/Manifest/…` to `manifest-core/src/Manifest/…`
- Modify: `zinc.toml` (root)

- [ ] **Step 1: Create `manifest-core/zinc.toml`.**

Follow the `evals-api` sub-member pattern (a sub-member declares only `[package]` +
`[build.lib]`; git-pin source overrides stay in the ROOT `[dependencies]` and are
inherited):

```toml
[package]
name = "manifest-core"
version = "0.1.0.0"

[build.lib]
source-dirs = ["src"]
ghc-options = [
  "-Wall",
  "-XOverloadedStrings",
  "-XScopedTypeVariables",
  "-XTypeApplications",
  "-XLambdaCase",
  "-XTupleSections",
]
depends = [
  "base",
  "bytestring",
  "containers",
  "text",
  "time",
  "transformers",
  "profunctors",
  "autodocodec",
  "aeson",
]
```

- [ ] **Step 2: Move the 15 pure module files (preserve the `Manifest/` subpath so module names are unchanged).**

```bash
cd /home/gareth/code/garethstokes/manifest
mkdir -p manifest-core/src/Manifest/Core
git mv src/Manifest/Core/SqlType.hs   manifest-core/src/Manifest/Core/SqlType.hs
git mv src/Manifest/Core/Table.hs     manifest-core/src/Manifest/Core/Table.hs
git mv src/Manifest/Core/Codec.hs     manifest-core/src/Manifest/Core/Codec.hs
git mv src/Manifest/Core/Meta.hs      manifest-core/src/Manifest/Core/Meta.hs
git mv src/Manifest/Core/Query.hs     manifest-core/src/Manifest/Core/Query.hs
git mv src/Manifest/Core/Sql.hs       manifest-core/src/Manifest/Core/Sql.hs
git mv src/Manifest/Core/Cascade.hs   manifest-core/src/Manifest/Core/Cascade.hs
git mv src/Manifest/Core/Rls.hs       manifest-core/src/Manifest/Core/Rls.hs
git mv src/Manifest/Core/Index.hs     manifest-core/src/Manifest/Core/Index.hs
git mv src/Manifest/Core/Relation.hs  manifest-core/src/Manifest/Core/Relation.hs
git mv src/Manifest/Entity.hs         manifest-core/src/Manifest/Entity.hs
git mv src/Manifest/Derive.hs         manifest-core/src/Manifest/Derive.hs
git mv src/Manifest/Error.hs          manifest-core/src/Manifest/Error.hs
git mv src/Manifest/Json.hs           manifest-core/src/Manifest/Json.hs
git mv src/Manifest/Index.hs          manifest-core/src/Manifest/Index.hs
```

(Do NOT edit the module headers — `module Manifest.Core.Table (…)` etc. stay
exactly as they are; only the file's package/dir changed.)

- [ ] **Step 3: Edit root `zinc.toml`.**

- Change `[workspace] members = ["."]` → `members = [".", "manifest-core"]`.
- In `[build.lib].depends` (the `manifest` library), ADD `"manifest-core"`. Leave
  the rest (libpq/process/directory/stm still needed by the impure modules).
- Leave `[build.test.spec].depends` as-is (it depends on `manifest`, which now
  pulls `manifest-core` transitively). The root `[dependencies]` git-pin block
  (postgresql-libpq, profunctors, autodocodec) stays unchanged — inherited by both
  members.

- [ ] **Step 4: Build `manifest-core` alone — this is the cut-line proof.**

Run: `nix develop . --command timeout -s KILL 300 zinc build manifest-core`
Expected: builds clean with NO libpq. (If a pure module turns out to import an
impure one, the build fails with a not-in-scope/missing-module error — that module
either keeps an impure import (move it back to `manifest`) or its offending helper
must be relocated. Report any such module rather than guessing.)
If exit 137 (GHC iserv flake), retry once.

- [ ] **Step 5: Build the whole workspace.**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: `manifest` builds on top of `manifest-core`, exit 0. Fix any dependency
or resolution error (e.g. if zinc needs the member listed differently). If `zinc
build manifest-core` is not the correct single-member syntax, build the whole
workspace and confirm manifest-core compiled.

- [ ] **Step 6: Commit.**

```bash
git add zinc.toml manifest-core/ docs/superpowers/
git commit -m "refactor(manifest-core): split pure layer into a libpq-free package

Move the 15 pure modules (Core.*, Entity, Derive, Error, Json, Index) to a new
manifest-core workspace member; manifest depends on it. Module names and the
Manifest umbrella API are unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Verify the umbrella and tests are unchanged

**Files:** none (verification only), unless a fix is needed.

- [ ] **Step 1: Confirm the `Manifest` umbrella still re-exports everything.**

`src/Manifest.hs` should be unchanged and still compile (it imports from Core.*
modules now resolved via manifest-core, plus the impure modules). The whole-workspace
build in Task 1 Step 5 already proves it compiles. No edit expected.

- [ ] **Step 2: Run the full test suite (ephemeral Postgres).**

Run: `nix develop . --command timeout -s KILL 600 zinc test`
Expected: the existing suite passes unchanged (Session/Query/Relation/Migrate/
Notify/RLS/Cascade etc. against an ephemeral cluster). Success = exit 0 / the
suite's pass line. A pure relocation must not change any test outcome.
If exit 137, retry once.

- [ ] **Step 3 (optional): manifest-core test target.**

Only if zinc requires every member to have a test stanza, OR to give the new
package a CI target: add `manifest-core/test/Spec.hs` with one pure codec
round-trip check and a `[build.test.spec]` stanza in `manifest-core/zinc.toml`
(deps: base + manifest-core + the codec deps). Skip if not required.

- [ ] **Step 4: Final verification.**

```bash
git status        # clean
nix develop . --command timeout -s KILL 300 zinc build   # exit 0
```

---

## Self-Review

- **Spec coverage:** Task 1 = the split (cut line, packaging, manifest-core build proof = invariant 1). Task 2 = umbrella unchanged (invariant 2) + test suite passes (invariant 3). Invariant 4 (manifest-evals pin bump) is out-of-phase, noted only.
- **No placeholders:** the 15 files are listed explicitly; the zinc.toml deltas are concrete.
- **Risk handling:** Step 4 of Task 1 isolates the cut-line proof; a leaked impure import surfaces there with a clear remediation.
