# Manifest — User manual + literate tutorials + beads — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up (1) **beads** issue tracking, (2) a **just-the-docs** GitHub-Pages user manual under `docs/`, and (3) **literate `.lhs` tutorials** that are simultaneously runnable tests (`zinc test`, against real Postgres) and rendered doc pages — one file, both jobs.

**Architecture:** Documentation + tooling only; no library behaviour changes. The tutorials are `.lhs` Markdown files (prose + fenced ```` ```haskell ```` blocks) compiled by GHC via `-pgmL markdown-unlit` under zinc, and rendered by Jekyll via `markdown_ext: …,lhs`. The same file zinc compiles is the file the site serves — so a code change that breaks a tutorial breaks a test; the manual can't silently rot.

**Tech Stack:** GHC 9.10.1 · zinc · `markdown-unlit` (nixpkgs `haskellPackages.markdown-unlit` 0.6.0) · Jekyll + `remote_theme: just-the-docs/just-the-docs` (GitHub Pages' built-in build) · `bd` (beads) · the existing `test/Harness.hs` + `Fixtures.withTestDb`.

---

## VERIFIED PREREQUISITE (settled the spec §7 risks before this plan)

A scratch zinc project confirmed empirically:
- `markdown-unlit 0.6.0` is in `nixos-24.11` (`haskellPackages.markdown-unlit`); on `PATH` via the dev shell.
- **`-pgmL markdown-unlit` works under zinc's `ghc --make`**: a `.lhs` with a ```` ```haskell ```` block compiled and ran as a normal module; a ```` ```hs ```` block was NOT compiled (illustrative-only).
- **Module discovery requires PATH-MATCHING files.** zinc derives a module name from the file path, so the tutorial for `module Tutorial.UnitOfWork` MUST live at `docs/tutorials/Tutorial/UnitOfWork.lhs` (a kebab-case root file like `unit-of-work.lhs` would yield the invalid module name `unit-of-work`). **Convention for this plan:** `.lhs` files are `docs/tutorials/Tutorial/<CamelName>.lhs`; the human-readable page slug/URL is set via Jekyll front-matter (`title`, and `permalink` if a kebab URL is wanted), independent of the on-disk filename.

So the spec's "settle in the plan" items are settled: no `lhs2md` generator fallback needed; use path-matching `.lhs` filenames.

---

## EXECUTION NOTES

1. **Repo state:** work happens on the `docs/user-manual-and-tutorials` branch (it already carries the spec at `docs/superpowers/specs/2026-06-08-user-manual-and-literate-tutorials-design.md` and the SP3 code). Build/test commands run inside the dev shell: `nix develop -c zinc build` / `nix develop -c zinc test` (Bash `timeout: 600000`). After the flake change in Task 2, `nix develop` re-realizes the shell (adds markdown-unlit) — the first run is slower.
2. **Tutorials are tests.** Each `.lhs` exports `tests :: [Test]` (the `Harness` API: `group`/`test`/`assertEqual`/`assertBool`), uses `Fixtures.withTestDb`, and is wired into `test/Spec.hs` exactly like every existing `*Spec`. `zinc test` runs them against the ephemeral Postgres. Per-test detail: `nix develop -c .zinc/build/spec` (inside `nix develop`).
3. **Honesty about status (spec §4.3):** the manual documents the *designed* API but every page that describes an unbuilt/partly-built surface carries an explicit status callout. Migrations exist (SP3) and work; **joins/aggregates and the TH front-end are NOT built** — pages mentioning them say "Planned". Never imply something works that doesn't. Cross-check each claim against the actual `src/Manifest/*` and the design doc.
4. **Site build is GitHub-Pages-side.** Don't try to stand up a local Jekyll toolchain (not in the flake; `remote_theme` needs network). Verify pages by (a) valid YAML front-matter + Markdown, and (b) the tutorial `.lhs` files passing as tests. Note in the final task that GitHub Pages' built-in Jekyll build serves `docs/` once pushed (out of local scope).
5. The sibling **`zinc` repo** (`/home/gareth/code/garethstokes/zinc`) is the style/setup reference: its `docs/_config.yml`, its `CLAUDE.md` beads block, its page Why/What/How/Examples shape. Read those for exact wording/structure to mirror.

Baseline: `docs/user-manual-and-tutorials` at `30b7ebd`, `nix develop -c .zinc/build/spec` → 76/76 green.

---

## File Structure

| Path | Responsibility |
|---|---|
| `.beads/` (+ `issues.jsonl`, `.gitignore`) | beads tracker (Task 1). |
| `CLAUDE.md` | beads integration block (Task 1). |
| `flake.nix` | add `haskellPackages.markdown-unlit` to the dev shell (Task 2). |
| `zinc.toml` | `[build.test.spec]`: `source-dirs += "docs/tutorials"`, `ghc-options += "-pgmL","markdown-unlit"` (Task 2). |
| `docs/tutorials/Tutorial/UnitOfWork.lhs` | runnable tutorial + page (Task 2). |
| `docs/tutorials/Tutorial/Relationships.lhs` | runnable tutorial + page (Task 3). |
| `docs/tutorials/Tutorial/Cascades.lhs` | runnable tutorial + page (Task 4). |
| `test/Spec.hs` | wire `Tutorial.*` `tests` into the aggregate (Tasks 2–4). |
| `docs/_config.yml` | Jekyll/just-the-docs site config (Task 5). |
| `docs/index.md`, `docs/getting-started.md`, `docs/tutorials/index.md` | site pages + Tutorials section parent (Task 5). |
| `docs/entities.md`, `docs/unit-of-work.md`, `docs/relationships.md`, `docs/cascades.md`, `docs/migrations.md` | reference pages (Tasks 6–7). |

---

### Task 1: Beads

Mirror zinc's beads setup; no code changes.

- [ ] **Step 1: Init beads with the `manifest` prefix**

From the repo root:
```bash
bd init --prefix manifest
```
Expected: creates `.beads/` with `issues.jsonl` and a `.beads/.gitignore`. Confirm `bd ready` runs (empty list is fine).

> If `bd init` flags differ, run `bd init --help` and match zinc's invocation (zinc uses prefix-based init, JSONL-on-git, no Dolt remote). Do NOT configure a Dolt remote.

- [ ] **Step 2: Add the beads block to `CLAUDE.md`**

`CLAUDE.md` does not exist in `manifest` yet. Create it, copying the `<!-- BEGIN BEADS INTEGRATION … -->`…`<!-- END BEADS INTEGRATION -->` block VERBATIM from `/home/gareth/code/garethstokes/zinc/CLAUDE.md` (read that file). It tells agents to use `bd` for all task tracking and run `bd prime`. (Optionally add the same block to a new `AGENTS.md`, matching zinc, which has both.)

- [ ] **Step 3: Seed starter issues**

Create one issue per remaining task in this plan, so the tracker is self-hosting and non-empty:
```bash
bd create "docs: just-the-docs user manual site (_config.yml + reference pages)" -t feature
bd create "docs: markdown-unlit wiring (flake + zinc.toml) for literate .lhs tutorials" -t feature
bd create "docs: unit-of-work literate tutorial (.lhs, runs as a test)" -t feature
bd create "docs: relationships literate tutorial (.lhs, runs as a test)" -t feature
bd create "docs: cascades literate tutorial (.lhs, runs as a test)" -t feature
```
Confirm `bd ready` lists them.

- [ ] **Step 4: Commit**

```bash
git add .beads CLAUDE.md
git commit -m "chore(docs): beads issue tracking (prefix manifest) + CLAUDE.md block + seed issues

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(`.beads/.gitignore` keeps any local Dolt/db artifacts out; `issues.jsonl` IS tracked — it's the source of truth.)

---

### Task 2: markdown-unlit wiring + the unit-of-work tutorial

The wiring is verified; this lands it in-repo and produces the first real tutorial (which proves the wiring against the real `Manifest` + Postgres harness).

**Files:** Modify `flake.nix`, `zinc.toml`, `test/Spec.hs`; create `docs/tutorials/Tutorial/UnitOfWork.lhs`.

- [ ] **Step 1: Add `markdown-unlit` to the dev shell** (`flake.nix`)

Add `pkgs.haskellPackages.markdown-unlit` to the `packages = [ … ]` list in the devShell (alongside `ghc9101`, `alex`, `happy`, `postgresql`, etc.). Keep the existing `shellHook` (LIBRARY_PATH) unchanged.

- [ ] **Step 2: Wire the test component** (`zinc.toml`)

In `[build.test.spec]`:
- `source-dirs = ["test", "docs/tutorials"]`
- `ghc-options`: add `"-pgmL"` and `"markdown-unlit"` (keep the existing `-X…` flags and `-lpq`). Order: the `-pgmL markdown-unlit` pair can go anywhere in the list.

(`-pgmL` only affects `.lhs` files; the existing `.hs` specs are unaffected — GHC bypasses unlit for `.hs`.)

- [ ] **Step 3: Write `docs/tutorials/Tutorial/UnitOfWork.lhs`**

A Markdown page whose ```` ```haskell ```` blocks form `module Tutorial.UnitOfWork (tests)`. It must compile and pass against Postgres, mirroring design §4.6 (and the existing `EndToEndSpec`/`FlushSpec`). Structure:

````markdown
---
title: Unit of Work
parent: Tutorials
nav_order: 1
---

# Unit of Work — edit a plain value, get a minimal UPDATE

> Runnable: this page is `docs/tutorials/Tutorial/UnitOfWork.lhs`, compiled and run by `zinc test`.

<prose: the thesis — snapshot-diff; what the example shows>

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module Tutorial.UnitOfWork (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isPrefixOf)
import Fixtures (User, UserT (..), withTestDb)
import Manifest
import Harness
```

<prose: open a session, edit a value, save, flush emits a minimal UPDATE>

```haskell
tests :: [Test]
tests = group "Tutorial.UnitOfWork"
  [ test "edit a plain value -> minimal UPDATE" $
      withTestDb $ \pool -> do
        log' <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" } :: User)
          withTransaction $ save (u { userName = "Bob" } :: User)
          statementLog
        assertEqual "minimal update"
          ["UPDATE users SET user_name = $1 WHERE user_id = $2"]
          (filter ("UPDATE" `isPrefixOf`) (map (BC.unpack . fst) log'))
  ]
```

<closing prose>
````

> The compiled blocks must concatenate into a valid module: the LANGUAGE pragmas + `module …` header + imports come from the FIRST ```` ```haskell ```` block; later blocks add the body. The `Manifest` umbrella + `Fixtures`/`Harness` are exactly what the existing specs import. Use only API that EXISTS (verify against `EndToEndSpec.hs`/`FlushSpec.hs`). Keep illustrative-only snippets in ```` ```hs ```` fences so they render but don't compile.

- [ ] **Step 4: Wire into `test/Spec.hs`**

`import qualified Tutorial.UnitOfWork` and append `Tutorial.UnitOfWork.tests` to the `runTests (… ++ …)` concatenation (identical to every existing spec).

- [ ] **Step 5: Run → pass → commit**

`nix develop -c zinc test` then `nix develop -c .zinc/build/spec` → expect the new `Tutorial.UnitOfWork` test green (count = previous + 1). If GHC can't find the module, confirm the file is at `docs/tutorials/Tutorial/UnitOfWork.lhs` (path-matching) and `source-dirs` includes `docs/tutorials`. Commit:
```bash
git add flake.nix zinc.toml test/Spec.hs docs/tutorials/Tutorial/UnitOfWork.lhs
git commit -m "docs(tutorials): markdown-unlit wiring + unit-of-work literate tutorial (runs as a test)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: relationships tutorial

**Files:** Create `docs/tutorials/Tutorial/Relationships.lhs`; modify `test/Spec.hs`.

- [ ] **Step 1: Write `docs/tutorials/Tutorial/Relationships.lhs`**

`module Tutorial.Relationships (tests)`, mirroring design §5.1/§5.4 and the existing `RelationSpec`/`EntSpec`/`JoinedSpec`. Front-matter `title: Relationships / parent: Tutorials / nav_order: 2`. Demonstrate (against real code, verified to exist):
- A-path: `posts <- load #posts user` (`:: Db [Post]`).
- D-path: `e <- with (selectin #posts) (manage user)`; read via `rel #posts e`.
- Assert the loaded titles, and (optionally) that `joined #posts` emits a `LEFT JOIN` (via `statementLog`, as `JoinedSpec` does).
Uses `Fixtures (User, Post, …, withTestDb)` + `Manifest` + `Harness`. Same ```` ```haskell ````/```` ```hs ```` convention.

- [ ] **Step 2: Wire into `test/Spec.hs`** (`import qualified Tutorial.Relationships`, append `.tests`).

- [ ] **Step 3: Run → pass → commit**

`.zinc/build/spec` → the `Tutorial.Relationships` test green. Commit:
```bash
git add docs/tutorials/Tutorial/Relationships.lhs test/Spec.hs
git commit -m "docs(tutorials): relationships literate tutorial (A-path + D-path, runs as a test)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: cascades tutorial

**Files:** Create `docs/tutorials/Tutorial/Cascades.lhs`; modify `test/Spec.hs`.

- [ ] **Step 1: Write `docs/tutorials/Tutorial/Cascades.lhs`**

`module Tutorial.Cascades (tests)`, mirroring design §5.5 and the existing `CascadeSpec`/`RelE2ESpec`. Front-matter `title: Cascades / parent: Tutorials / nav_order: 3`. Demonstrate: the `User` fixture's `cascadeRules` (`cascade (Proxy @Post) (Proxy @"postAuthor") Cascade`) — `add` a user + posts, `withTransaction $ delete u`, assert `selectWhere @Post` count is 0 (children cascaded away). Use `Fixtures` + `Manifest` + `Harness`. (Reference `RelE2ESpec.hs`'s "cascade-on-delete through the public API" test for the exact shape.)

- [ ] **Step 2: Wire into `test/Spec.hs`.**

- [ ] **Step 3: Run → pass → commit**

`.zinc/build/spec` → the `Tutorial.Cascades` test green. Commit:
```bash
git add docs/tutorials/Tutorial/Cascades.lhs test/Spec.hs
git commit -m "docs(tutorials): cascades literate tutorial (onDelete at flush, runs as a test)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Jekyll site config + index + getting-started + Tutorials section

**Files:** Create `docs/_config.yml`, `docs/index.md`, `docs/getting-started.md`, `docs/tutorials/index.md`.

- [ ] **Step 1: `docs/_config.yml`** — verbatim from spec §4.1:
```yaml
title: manifest
description: The Unit-of-Work layer Haskell never had.
remote_theme: just-the-docs/just-the-docs
url: https://garethstokes.github.io
baseurl: /manifest
search_enabled: true
heading_anchors: true
markdown_ext: "markdown,mkdown,mkdn,mkd,md,lhs"
aux_links:
  GitHub: https://github.com/garethstokes/manifest
exclude:
  - superpowers/
```
(`exclude: [superpowers/]` keeps the design/spec/plan archive out of the published site. `markdown_ext … ,lhs` makes Jekyll render the `.lhs` tutorials as pages.)

- [ ] **Step 2: `docs/index.md`** (`nav_order: 1`) — the thesis ("the Unit-of-Work layer Haskell never had", design §0), what Manifest is (SQLAlchemy-style UoW on a thin HKD core), and start-here links (Getting started, Entities, Unit of Work, Tutorials). Why/What/How/Examples shape (mirror zinc's `index.md`).

- [ ] **Step 3: `docs/getting-started.md`** (`nav_order: 2`) — define a table (HKD `UserT f` + `deriving Generic` + the `Entity` instance), open a session (`withSession pool`), a first round-trip (`add`/`get`/`save`). Examples must be real (match `Fixtures.hs` + the tutorials). Add a short note that the test suite needs a Postgres (as the tutorials do).

- [ ] **Step 4: `docs/tutorials/index.md`** — the Tutorials section parent page (`title: Tutorials`, `nav_order: 8`, `has_children: true`). One paragraph: "these pages are literate Haskell — each is a runnable test in the suite", linking the three `.lhs` children (which set `parent: Tutorials`).

- [ ] **Step 5: Commit**
```bash
git add docs/_config.yml docs/index.md docs/getting-started.md docs/tutorials/index.md
git commit -m "docs(site): just-the-docs config + index + getting-started + Tutorials section

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Reference pages — entities, unit-of-work, relationships

**Files:** Create `docs/entities.md`, `docs/unit-of-work.md`, `docs/relationships.md`.

- [ ] **Step 1: `docs/entities.md`** (`nav_order: 3`, covers design §3/§6.1–6.2) — HKD records (`data UserT f`), `Col f` and `Identity` erasure (`type User = UserT Identity`), `deriving Generic` + the `Entity` instance (what it derives: table metadata, codec, CRUD, `#labels`), `Key`, the `#userName` label refs. Why/What/How/Examples. Examples match the real fixtures.
- [ ] **Step 2: `docs/unit-of-work.md`** (`nav_order: 4`, covers §4) — `Db`/`Session`, the identity map, the four entity states, snapshot-diff, the flush algorithm (inserts→updates→deletes), autoflush, the command path (`update`/`deleteWhere`). Link the runnable `Tutorial/UnitOfWork.lhs`.
- [ ] **Step 3: `docs/relationships.md`** (`nav_order: 5`, covers §5) — A-path `load`, D-path `Ent`/`with`/`rel`, `selectin` vs `joined`, one-level nesting (`#posts ./ #comments` via `loadNested`), self-referential relations, UoW integration (loaded children managed). Note what's built (all of this — SP2/2.5/2.6/2.7) vs deferred (arbitrary-depth nesting, D-path nested Ents). Link `Tutorial/Relationships.lhs`.
- [ ] **Step 4: Commit**
```bash
git add docs/entities.md docs/unit-of-work.md docs/relationships.md
git commit -m "docs(site): entities, unit-of-work, relationships reference pages

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Reference pages — cascades, migrations + final verification

**Files:** Create `docs/cascades.md`, `docs/migrations.md`.

- [ ] **Step 1: `docs/cascades.md`** (`nav_order: 6`, covers §5.5) — `onDelete` policies (`Cascade`/`SetNull`/`Restrict`), declared via `cascade (Proxy @Child) (Proxy @"fk") policy` in an `Entity`'s `cascadeRules`, honoured at flush (Restrict-first, then mutating). Built (SP2.6). Link `Tutorial/Cascades.lhs`.
- [ ] **Step 2: `docs/migrations.md`** (`nav_order: 7`, covers §6.4) — records as the schema source of truth; `managed (Proxy @Entity)`, `migrate`/`migrateUp`, the `manifest-migrate diff`/`up` CLI, `schema_migrations`, additive-only with destructive surfaced-not-applied. **Status callout:** migrations ARE built (SP3) — but call out the deferred parts honestly (Alembic-style versioned files, renames/drops/type-change auto-application, nullability diffs → **Planned**). Do NOT mark the whole page "Planned" (the core works); mark only the deferred follow-ups.
  - Also add a one-line "Planned" note on the **index/relationships** pages (or a small `roadmap` mention) for the genuinely-unbuilt surfaces: **joins/aggregates in Core** and the **TH front-end** (design §7 SP4, §8) — these are NOT built; never imply otherwise.
- [ ] **Step 3: Final verification**

Run the full suite: `nix develop -c zinc test` then `nix develop -c .zinc/build/spec` → all tests green, including the three `Tutorial.*` tests (count = baseline 76 + 3 = 79). This is the "no drift by construction" proof. Then sanity-check the site inputs:
- every `docs/**/*.md` and `docs/tutorials/Tutorial/*.lhs` page has valid YAML front-matter (`title`, `nav_order`/`parent`);
- `_config.yml` parses (valid YAML);
- no page claims an unbuilt feature works (grep the pages for "joins"/"aggregate"/"Template Haskell"/"TH" and confirm each is marked Planned/deferred).

Document (in `docs/index.md` or a short `CONTRIBUTING`/README note) that **GitHub Pages' built-in Jekyll build serves `docs/`** once pushed (no Actions workflow), and that the tutorials/tests require a Postgres (as the suite does). Local Jekyll build is out of scope (not in the flake).

- [ ] **Step 4: Commit**
```bash
git add docs/cascades.md docs/migrations.md docs/index.md docs/relationships.md
git commit -m "docs(site): cascades + migrations reference pages; honest status callouts

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-review (spec coverage)

| Spec § | Requirement | Task |
|---|---|---|
| §3 | Beads (prefix `manifest`, CLAUDE.md block, seed issues, JSONL-on-git, no Dolt) | Task 1 |
| §4.1 | `_config.yml` (just-the-docs, baseurl `/manifest`, `markdown_ext …,lhs`, exclude `superpowers/`) | Task 5 |
| §4.2 | The 8-page set grounded in the design | Tasks 5–7 |
| §4.3 | Honest status callouts (migrations deferred parts; joins/TH = Planned) | Task 7 |
| §5.1 | "one file, both jobs" via `markdown-unlit` (```haskell compiled, ```hs not) | Tasks 2–4 (VERIFIED mechanism) |
| §5.2 | Wiring: flake `markdown-unlit`, zinc.toml `source-dirs`+`-pgmL`, Spec.hs | Task 2 |
| §5.2 | Module-name↔filename (path-matching `Tutorial/<Name>.lhs`) | Settled in the VERIFIED PREREQUISITE; Tasks 2–4 |
| §5.3 | the 3 tutorials demonstrate real code (UoW §4.6, rel §5.1/5.4, cascade §5.5) | Tasks 2–4 |
| §6 | tutorials pass as tests; no drift by construction | Tasks 2–4, Task 7 |
| §7 | risks settled | VERIFIED PREREQUISITE (markdown-unlit ✓, module/filename ✓); just-the-docs `.lhs` rendering + CI-Postgres = documented, GitHub-Pages-side |
| §8 | out of scope (no lib features, no Actions workflow, no Dolt) | respected throughout |

**Notes:** This is a docs/tooling plan — only the three `.lhs` tutorials are TDD-verifiable (they're tests); the Jekyll pages are prose verified by valid front-matter + the honesty grep, with the actual site build done by GitHub Pages after push (out of local scope per spec §8). All code examples in pages/tutorials MUST use only API that exists in `src/Manifest/*` (cross-check against the existing `*Spec.hs` files) — the whole point is that the docs can't lie.
