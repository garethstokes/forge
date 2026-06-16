# Manifest — User manual + literate tutorials + beads — Design

**Status:** Approved design (brainstorm complete) · **Date:** 2026-06-08
**Scope:** Stand up issue tracking, a GitHub-Pages user manual styled like zinc's docs, and
runnable literate-Haskell tutorials that double as published pages.

---

## 0. Goal

Three deliverables for the `manifest` repo, mirroring how the sibling `zinc` project is set up:

1. **Beads** issue tracking (like zinc).
2. A **doc-driven user manual** — a Jekyll + `just-the-docs` site served from `docs/` on GitHub
   Pages, documenting Manifest's *designed* API (from `spec/manifest_design_v0_1.md`).
3. **Literate-Haskell tutorials** — `.lhs` files that are simultaneously a runnable test in the
   suite (under `zinc test`) and a rendered documentation page. One file, both jobs.

This is documentation + tooling infrastructure, not a change to the library's behaviour.

---

## 1. Context (what already exists)

- `manifest` is a Haskell SQLAlchemy-style ORM / Unit-of-Work library, built **with zinc**
  (`zinc.toml`/`zinc.lock`, GHC 9.10.1). Implementation is substantial: full `Manifest.*` tree
  (`Core.{Table,Query,Sql,Codec,Meta,Cascade,Relation}`, `Session`, `Session.Command`, `Relation`,
  `Relation.Loaded`, `Entity`, `Postgres`, `Error`). Sub-projects 1–2 (UoW + relationships +
  cascades) are real code the tutorials can exercise.
- **Tests**: a custom zero-dependency harness (`test/Harness.hs`), *not* hspec. A module exports
  `tests :: [Test]`; `test "name" act`, `group "label" [...]`, `assertEqual`/`assertBool`. The
  aggregator `test/Spec.hs` imports each `*Spec` module and concatenates `Module.tests` into
  `runTests`. Tests run against a **real Postgres** via `Fixtures.withTestDb`.
- **No `.beads/`** yet. **`docs/`** holds only `superpowers/` (this spec archive) — no site yet.
- The build already depends on `postgresql-libpq` with `flags = { use-pkg-config = true }` (the
  zinc cabal-flags feature), so the test exe links `libpq`.

## 2. zinc's docs setup (the "looks like" target)

- Jekyll, `remote_theme: just-the-docs/just-the-docs`, served from the repo's `docs/` folder via
  GitHub Pages' built-in build (no Actions workflow).
- `_config.yml`: `title`, `description`, `url: https://garethstokes.github.io`, `baseurl: /<repo>`,
  `search_enabled`, `aux_links.GitHub`, and `exclude: [superpowers/]` (keeps the design archive
  out of the published site).
- Every page carries `--- title / nav_order ---` front-matter and follows a **Why / What / How /
  Examples** structure.

---

## 3. Part 1 — Beads

Mirror zinc's beads setup exactly:

- `bd init` with issue prefix **`manifest`**.
- Add the `BEGIN BEADS INTEGRATION` block to `CLAUDE.md` (create `CLAUDE.md`/`AGENTS.md` if absent,
  matching zinc's wording: "use bd for all task tracking; `bd prime` for workflow").
- Commit `.beads/` with `issues.jsonl` git-tracked; **no Dolt remote** (same as zinc — JSONL on git
  is the source of truth). `.beads/.gitignore` from `bd init` handles the rest.
- Seed starter issues for the work in this very spec (docs site, the three tutorials, the
  markdown-unlit wiring) so the tracker is non-empty and self-hosting.

No code changes; purely additive repo scaffolding.

---

## 4. Part 2 — Doc-driven user manual

A `just-the-docs` site under `docs/`, byte-for-byte stylistically consistent with zinc.

### 4.1 Site config

`docs/_config.yml`:

```yaml
title: manifest
description: The Unit-of-Work layer Haskell never had.
remote_theme: just-the-docs/just-the-docs
url: https://garethstokes.github.io
baseurl: /manifest
search_enabled: true
heading_anchors: true
markdown_ext: "markdown,mkdown,mkdn,mkd,md,lhs"   # render .lhs tutorials as pages (Part 3)
aux_links:
  GitHub: https://github.com/garethstokes/manifest
exclude:
  - superpowers/
```

### 4.2 Page set (grounded in `manifest_design_v0_1.md`)

| Page | `nav_order` | Covers (design §) |
|---|---|---|
| `index.md` | 1 | Thesis — "the Unit-of-Work layer Haskell never had"; start-here links (§0) |
| `getting-started.md` | 2 | Define a table, open a session, first round-trip |
| `entities.md` | 3 | HKD records, `Col f`, `Identity` erasure, `deriving (Entity)`, `Key`, `#labels` (§3, §6.1–6.2) |
| `unit-of-work.md` | 4 | `Db`/`Session`, identity map, four entity states, snapshot-diff, flush algorithm, autoflush, command path (§4) |
| `relationships.md` | 5 | A-path `load`, D-path `Ent`/`with`, `selectin`/`joined`, nesting, UoW integration (§5) |
| `cascades.md` | 6 | `onDelete` policies honoured at flush (§5.5) |
| `migrations.md` | 7 | `migrate diff`/`up`, reviewable DDL — **Planned** callout (§6.4, §8) |
| Tutorials (section) | 8 | parent for the literate tutorials (Part 3) |

### 4.3 Honesty about status

The library is mid-build (design §7 sub-projects; §8 deferred non-goals). Each page documents the
**designed** API but carries an explicit status callout where the surface isn't built yet — e.g.
`migrations.md` is marked **Planned**, joins/TH-sugar noted as deferred. The manual must never imply
something works that doesn't. Voice and "Why/What/How/Examples" shape match zinc.

---

## 5. Part 3 — Literate tutorials (runnable + published, one file)

Three `.lhs` files that are **simultaneously** a runnable test module and a rendered doc page, via
the `markdown-unlit` preprocessor:

- `docs/tutorials/unit-of-work.lhs` — `module Tutorial.UnitOfWork (tests)`
- `docs/tutorials/relationships.lhs` — `module Tutorial.Relationships (tests)`
- `docs/tutorials/cascades.lhs` — `module Tutorial.Cascades (tests)`

### 5.1 The "one file, both jobs" mechanism

A file is plain **Markdown** (front-matter + prose), with fenced ```` ```haskell ```` blocks that
ARE the Haskell source:

- **As a doc page:** Jekyll renders it because `markdown_ext` includes `lhs` (§4.1) and it carries
  `--- title / parent: Tutorials / nav_order ---` front-matter. The prose and code render normally.
- **As a test:** `markdown-unlit` (a GHC literate preprocessor) extracts the ```` ```haskell ````
  blocks as the module source. GHC selects it via `-pgmL markdown-unlit`. The blocks concatenate
  into a valid module: header + imports first, the `tests :: [Test]` export last.

Convention: compiled code uses ```` ```haskell ````; illustrative-only snippets use a different
fence (e.g. ```` ```hs ````) so they render but aren't compiled.

### 5.2 Wiring (config only — no zinc source change)

zinc passes `ghc-options` straight to `ghc --make`, and its preprocessor stage only handles
`.x/.y/.hsc` — `.lhs` is left to GHC, whose `-pgmL` chooses the unlit program. So:

- **`flake.nix`**: add `haskellPackages.markdown-unlit` to the dev shell (provides the
  `markdown-unlit` executable on `PATH`).
- **`zinc.toml`** test component (`[build.test.spec]`):
  - `source-dirs = ["test", "docs/tutorials"]` — the *same* files zinc compiles are the ones the
    site serves (no duplication, no generator).
  - `ghc-options += "-pgmL", "markdown-unlit"` — only affects `.lhs` files; existing `.hs` specs are
    untouched (GHC bypasses unlit for `.hs`).
- **`test/Spec.hs`**: `import qualified Tutorial.UnitOfWork` (etc.) and append their `tests` to the
  concatenation — identical to how every existing spec is wired.

Module naming: with source-dir `docs/tutorials`, `docs/tutorials/unit-of-work.lhs` must declare
`module Tutorial.UnitOfWork` — GHC resolves it by the module name on the `-i docs/tutorials` path, so
the on-disk filename is free to be the kebab-case page slug while the module is `Tutorial.*`. (If
GHC's module-name/path matching proves strict, fall back to `docs/tutorials/Tutorial/UnitOfWork.lhs`
or matching filenames — settled in the plan.)

### 5.3 What each tutorial demonstrates (against real code)

- **unit-of-work.lhs** — the headline: `withSession`/`withTransaction`, `get` a row (baseline
  snapshot), `save u { userName = "Bob" }`, `flush` emits a *minimal* `UPDATE` (assert via
  `statementLog`), plus an `add` round-trip with `RETURNING` PK. Mirrors design §4.6.
- **relationships.lhs** — A-path `load #posts user`, then the D-path `with (selectin #posts)` +
  total accessor; assert the emitted query shape. Mirrors §5.1, §5.4.
- **cascades.lhs** — an `onDelete = Cascade` relation: delete a parent, assert children removed at
  flush. Mirrors §5.5.

Each uses `Fixtures.withTestDb` and the `Harness` API, so it runs under `zinc test` against Postgres
exactly like the existing suite.

---

## 6. Testing & verification

- **Tutorials pass as tests:** `zinc test` (Postgres available) runs the three `Tutorial.*` modules
  green alongside the existing suite — proof the documented code is correct.
- **Site builds:** the `docs/` site builds under Jekyll/just-the-docs with the three `.lhs` pages
  appearing under the Tutorials section and rendering their prose + code.
- **No drift by construction:** because the page and the test are the same file, a code change that
  breaks the tutorial breaks the test — the manual can't silently rot.

---

## 7. Risks / open questions (settle in the plan)

- **`-pgmL markdown-unlit` under zinc** — verify GHC invokes it for `.lhs` in zinc's `ghc --make`
  call (high confidence; standard GHC, zinc passes options through). Fallback if not: a `tools/lhs2md`
  generator (`.lhs` → `.md`) run in CI — the rejected "generator" approach kept as a safety net.
- **Module-name ↔ filename** for kebab-case `.lhs` page slugs vs `Tutorial.*` module names (§5.2).
- **just-the-docs rendering `.lhs`** via `markdown_ext` — confirm kramdown processes the extension;
  fallback is `include`-ing generated `.md`.
- **Postgres in CI** — the tutorials, being tests, need the same Postgres the suite needs; document
  the requirement, don't solve CI here.

---

## 8. Out of scope

- Writing the library features themselves (the docs describe the existing/designed API; building
  unbuilt sub-projects is separate work).
- A GitHub Actions Pages workflow (GitHub Pages' built-in Jekyll build serves `docs/`, like zinc).
- Dolt remote for beads (JSONL-on-git, like zinc).
