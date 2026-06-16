# Rehome manifest-evals to its own repo (with manifest + crucible) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the eval app (sub-project A, currently `examples/manifest-evals/` in the manifest workspace) into its own repo at `../manifest-evals/`, depending on git-pinned `manifest` and `crucible`, then slim the manifest repo back to a lean ORM.

**Architecture:** A new standalone zinc project that git-pins `manifest` (the ORM, for the schema/Db/query API) and `crucible` (the LLM substrate, for sub-project C next). Crucible drags a ~60-package TLS/crypto closure, so it lives in this repo, not in the manifest library repo. This rehome also resolves the gating risk: that a fresh project depending on BOTH git-pinned `manifest` and `crucible` actually resolves and builds.

**Tech Stack:** GHC 9.10.1 via zinc, a Nix devShell (GHC + postgres for tests). Deps: `manifest` (git-pin github.com/garethstokes/manifest), `crucible` (git-pin github.com/garethstokes/crucible) + their transitive git-pinned closures.

**Spec:** the eval data model spec `docs/superpowers/specs/2026-06-10-eval-orchestrator-data-model-design.md` (the schema being rehomed) and the C spec `docs/superpowers/specs/2026-06-10-eval-run-orchestrator-design.md` (why crucible is needed). This plan is the housing/rehome step the C spec's §6 requires before C.

**Source material to copy:**
- The eval package code: `examples/manifest-evals/{src,test,zinc.toml}` in the manifest repo (this worktree).
- Manifest's `flake.nix` and `zinc.toml` (for the devShell + dependency-stanza patterns).
- **Crucible's `zinc.toml` (`../crucible/zinc.toml`) and `zinc.lock`** — the source of the git-dependency URLs for crucible's whole transitive closure (the manifest workspace's `[registry]` is empty; crucible's URLs live in its config/lock).

---

## Pre-flight facts (verified during planning)

- The eval package (A) is built and its `SchemaSpec` passes (migrate/round-trip/cascade/restrict/aggregate/compare) as a manifest workspace member depending on the LOCAL manifest.
- `crucible` is at `../crucible` (github.com/garethstokes/crucible), a standalone zinc project. Its closure includes the full `crypton` TLS stack + `hpke`/`mlkem`/`ech-config`/`megaparsec`/`cborg` (~60 packages) because it makes real HTTPS calls.
- `manifest` and `crucible` both pin `autodocodec`/`aeson` from the SAME repos (NorfairKing/autodocodec, haskell/aeson) with no explicit rev — so they should reconcile to one version under a single lock. This is the gating assumption Task 1 proves.
- The manifest library extensions C/A need (`DbType Double`/`UTCTime`, `unique` index, `Manifest.Testing.withEphemeralDb`, the `GPrimKeyType` fix, the umbrella re-exports) are all on manifest `main` and pushed — so git-pinning manifest at current `main` provides them.

---

### Task 1: Stand up the new repo + GATING dependency resolution

**Files:** Create `../manifest-evals/{zinc.toml, flake.nix, flake.lock, .gitignore, src/Probe.hs}`; `git init`.

- [ ] **Step 1: Scaffold the repo**
```bash
mkdir -p ../manifest-evals/src
cd ../manifest-evals && git init -q
cp -f ../manifest/flake.nix ../manifest/flake.lock ../manifest/.gitignore .
```
Adapt `flake.nix` if needed (it provides GHC 9.10.1 + git + postgres + pkg-config + zlib — the same devShell manifest uses; the eval tests need postgres via `Manifest.Testing.withEphemeralDb`, and crucible's HTTPS needs the system TLS certs — confirm the devShell exposes `cacert`/`SSL_CERT_FILE`; add `pkgs.cacert` + `export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt` to the shellHook if HTTPS calls later need it — not needed for this rehome, but note it for C).

- [ ] **Step 2: Author `zinc.toml`** — a single-package project that git-pins manifest + crucible AND carries the union of their transitive git-dependency stanzas.
```toml
[workspace]
members = ["."]
ghc = "9.10.1"

[package]
name = "manifest-evals"
version = "0.1.0.0"

[build.lib]
source-dirs = ["src"]
ghc-options = ["-Wall", "-XOverloadedStrings"]
depends = ["base", "text", "time", "bytestring", "aeson", "manifest", "crucible"]

[dependencies.manifest]
repo = "https://github.com/garethstokes/manifest.git"
# rev pinned in Step 3

[dependencies.crucible]
repo = "https://github.com/garethstokes/crucible.git"
# rev pinned in Step 3
```
Then **append crucible's entire `[dependencies.*]` block** from `../crucible/zinc.toml` (effectful, effectful-core, monad-control, strict-mutable-base, hpke, mlkem, ram, http-client-tls, retry, autodocodec, aeson, autodocodec-schema, neat-interpolation, AND any `[registry]` it has), **plus manifest's unique ones** (`postgresql-libpq`, `profunctors` — autodocodec/aeson already present from crucible). If a dep is git-pinned via a `[registry]` URL in either project rather than a `[dependencies.X]` stanza, copy those `[registry]` entries too. The goal: every transitive git package has a known repo URL in THIS zinc.toml.

- [ ] **Step 3: Pin manifest + crucible revs and resolve**
```bash
git -C ../manifest rev-parse main            # manifest rev -> [dependencies.manifest].rev
git -C ../crucible rev-parse HEAD            # crucible rev -> [dependencies.crucible].rev
```
Put each `rev = "<sha>"` in the corresponding stanza. Add a trivial probe module `src/Probe.hs`:
```haskell
{-# LANGUAGE OverloadedStrings #-}
module Probe where
import Manifest (DbType)                       -- the ORM
import Crucible.LLM (Message(..), Role(..), complete)   -- the LLM substrate
probe :: [Message]
probe = [Message System "ping"]
```
Then **THE GATING BUILD**:
```bash
nix develop -c zinc build 2>&1 | tail -30
```
Expected: resolves the union closure (manifest + crucible + ~60 transitive git deps) and compiles `Probe` (imports from BOTH manifest and crucible). This is the make-or-break.
**If it fails:**
- "no repo in [registry] for dependency X" → add X's git URL (find it in `../crucible/zinc.lock` or its upstream) to a `[registry]` / `[dependencies.X]` stanza, retry.
- A version conflict on `autodocodec`/`aeson` (two revs) → pin both manifest's and crucible's to the same rev (they use the same repo; pick one rev), retry.
- If it cannot be reconciled after a reasonable effort, **STOP and report** the exact unresolved conflict — this is the reassess trigger from the C spec.

- [ ] **Step 4: Commit the skeleton**
```bash
cd ../manifest-evals
git add -A && git commit -q -m "chore: scaffold manifest-evals repo (git-pin manifest + crucible)"
```

---

### Task 2: Move sub-project A's code into the new repo

**Files:** Create `../manifest-evals/src/Evals/*` and `../manifest-evals/test/*` (from the manifest repo's `examples/manifest-evals/`); update `../manifest-evals/zinc.toml` (test target); delete `src/Probe.hs`.

- [ ] **Step 1: Copy the eval code**
```bash
cd ../manifest/.../  # the manifest worktree root
cp -rf examples/manifest-evals/src/Evals ../manifest-evals/src/
cp -rf examples/manifest-evals/test/*     ../manifest-evals/test/   # mkdir -p first
rm -f ../manifest-evals/src/Probe.hs
```
(Create `../manifest-evals/test/` first. The modules — `Evals.Ids`, `Evals.Schema`, `Evals.Schema.Types`, `Evals.Migrate`, `SchemaSpec`, `Spec` — keep their names.)

- [ ] **Step 2: Add the test target to `../manifest-evals/zinc.toml`**
```toml
[build.test.spec]
source-dirs = ["test"]
main = "Spec.hs"
ghc-options = ["-XOverloadedStrings", "-lpq"]
depends = ["base", "text", "time", "bytestring", "aeson", "containers", "manifest", "crucible", "manifest-evals"]
```
(Mirror the member test target from `examples/manifest-evals/zinc.toml`; keep `-lpq` for libpq.)

- [ ] **Step 3: Build**
```bash
cd ../manifest-evals && nix develop -c zinc build 2>&1 | tail -10
```
Expected: the eval schema compiles against the git-pinned `manifest` (the extensions it needs are on `main`). Fix any import that assumed the workspace-local manifest.

- [ ] **Step 4: Commit**
```bash
git add -A && git commit -q -m "feat: import eval data model (sub-project A) into the repo"
```

---

### Task 3: Verify sub-project A's tests pass in the new repo

**Files:** none (verification).

- [ ] **Step 1: Run the eval tests against git-pinned manifest + ephemeral Postgres**
```bash
cd ../manifest-evals
nix develop -c zinc test 2>&1 | tail -10
nix develop -c ./.zinc/build/spec 2>&1 | tail -2    # confirm the exact binary path from the build output
```
Expected: `manifest-evals SchemaSpec: migrate + round-trip + cascade + restrict + aggregate + compare-runs OK`, exit 0 — i.e. the full schema migrates and all A scenarios pass using the GIT-PINNED manifest (proving the published library has everything A needs, not just the local checkout).

- [ ] **Step 2: If green, tag the milestone**
```bash
git commit --allow-empty -q -m "test: sub-project A green in the standalone repo"
```

---

### Task 4: Slim the manifest repo back to a lean ORM

**Files (in the manifest repo):** Delete `examples/manifest-evals/`; Modify `zinc.toml` (revert the workspace member).

- [ ] **Step 1: Remove the eval package from the manifest workspace**
```bash
cd <manifest repo root>
git rm -r examples/manifest-evals
```
In `zinc.toml`, revert `[workspace] members = [".", "examples/manifest-evals"]` back to `members = ["."]`.

- [ ] **Step 2: Confirm manifest is still green + lean**
```bash
nix develop -c zinc test 2>&1 | tail -2
nix develop -c .zinc/build/spec 2>&1 | grep -E "tests passed"
```
Expected: **140/140** (the library extensions + the `GPrimKeyType` regression test stay; only the example package is removed). The manifest dependency closure no longer carries anything eval/crucible-related.

- [ ] **Step 3: Commit (exclude `.beads/issues.jsonl`)**
```bash
git add -A
git status   # if .beads/issues.jsonl staged: git restore --staged .beads/issues.jsonl
git commit -m "chore: extract manifest-evals to its own repo; manifest stays a lean ORM"
```

---

### Task 5: Publish the new repo + set up its workflow

**Files:** `../manifest-evals/{README.md, CLAUDE.md or AGENTS.md, .beads/}` (optional infra).

- [ ] **Step 1: Create the GitHub repo + push**
```bash
cd ../manifest-evals
gh repo create garethstokes/manifest-evals --private --source=. --remote=origin --push
```
(Private or public per preference; `--source=.` pushes the current repo. If `gh repo create` needs the branch, ensure `main`.)

- [ ] **Step 2: Minimal project files**
- `README.md`: one paragraph (an LLM-eval orchestrator built on `manifest` (data) + `crucible` (LLM); links to both).
- Copy the beads/CLAUDE workflow conventions if this repo will use `bd` (optional — it can share the manifest project's tracking, or run its own `bd init`).

- [ ] **Step 3: Commit + push**
```bash
git add -A && git commit -q -m "docs: README + project setup" && git push 2>&1 | tail -1
```

---

## Self-Review

**1. Coverage:** The rehome decision (extract to `../manifest-evals/` with git-pinned manifest + crucible) → Tasks 1-2; the crucible-integration gating risk (C spec §6) → Task 1 Step 3 (build-or-STOP); verify A unaffected by the dep change → Task 3; slim manifest → Task 4; stand the repo up → Task 5. After this, the C spec (`2026-06-10-eval-run-orchestrator-design.md`) is implemented in `../manifest-evals/` with crucible available.

**2. Placeholder scan:** The one irreducibly open spot is the exact dependency-stanza union (Task 1 Step 2) — it depends on reading `../crucible/zinc.toml`/`zinc.lock` at execution time; the task says precisely what to copy (crucible's `[dependencies.*]` + any `[registry]`, plus manifest's unique pins) and how to debug a resolution failure (Step 3's failure cases). That is a concrete procedure, not a TBD. No other placeholders.

**3. Consistency:** the package name `manifest-evals`, the module set (`Evals.*`, `SchemaSpec`), the git-pin stanzas (`[dependencies.manifest]`/`[dependencies.crucible]`), and the test target are consistent across tasks. Manifest's post-slim count is 140/140 (matches the merged state). The git-pinned manifest rev is taken from `main` (which has the extensions A needs).
