# forge monorepo — design

**Date:** 2026-06-16
**Status:** Approved

## Goal

Combine three separate git repositories — `crucible`, `manifest`, and
`manifest-evals` — into a single git monorepo named `forge`, and unify their
zinc build configurations into **one zinc workspace** whose members are the
eight packages drawn from the three repos. Today the three repos depend on each
other through pinned git revisions; in the monorepo those cross-repo
dependencies resolve as in-tree workspace siblings, eliminating the pins.

## Background (current state)

- `/home/gareth/code/garethstokes/` is the user's **code root** — not a git
  repo. It holds the three target repos plus unrelated ones (`bar-sensord`,
  `hbar`, `lune`, `planning-portal`, and `zinc` — the build tool itself).
- All three targets are zinc workspaces with their own `zinc.toml`,
  `zinc.lock`, and `flake.nix`:

  | Repo | zinc members | GHC | Cross-repo deps (git rev today) |
  |------|--------------|-----|----------------------------------|
  | crucible | `.`, `crucible-manifest`, `crucible-worker` | 9.12.2 | `manifest`, `manifest-core` |
  | manifest | `.`, `manifest-core` | **9.10.1** | none |
  | manifest-evals | `.`, `evals-api`, `evals-ui` | 9.12.2 | `manifest`, `crucible` |

- Each repo is clean (no dirty files). Remotes:
  `git@github.com:garethstokes/{crucible,manifest,manifest-evals}.git`.
- zinc model: a root `zinc.toml` declares `[workspace] members` (nestable
  directory paths) and a shared `[dependencies]`; each member declares
  `[package]` + `[build.*]`; members depend on each other **by name** as
  siblings (sibling's library builds first, no git fetch). One workspace = one
  `ghc` pin. The `flake.nix` only supplies the compiler + system libs; zinc
  manages all Haskell deps via `zinc.lock`. `zinc update` re-resolves and
  rewrites the lockfile.

## Decisions

1. **Git strategy:** single repo, **history preserved** via subtree merge.
2. **Location/name:** new subdir `/home/gareth/code/garethstokes/forge/` (keeps
   it isolated from the other repos in the code root).
3. **GHC:** unify on **9.12.2** (manifest moves up from 9.10.1; it already
   compiles under 9.12.2 today as a transitive dep of the other two).
4. **Cross-repo git pins → in-tree siblings** (the core payoff).
5. Per-subdir `.beads/`, `.claude/`, `AGENTS.md`, `CLAUDE.md` left untouched.

## Design

### 1. Git assembly

Create `forge/`, `git init` (branch `main`), then bring each repo in with
history preserved:

```
git subtree add --prefix=crucible       ../crucible       master
git subtree add --prefix=manifest       ../manifest       main
git subtree add --prefix=manifest-evals ../manifest-evals main
```

Each repo's files land under its subdir; their commit histories become
ancestors of `forge`. Nested `.git` dirs are untracked, so nothing
submodule-like is pulled in. The three original repos are left untouched on
disk and on GitHub (archives). Setting a new `origin` for `forge` is out of
scope unless requested.

### 2. Single zinc workspace — root `forge/zinc.toml`

```toml
[workspace]
members = [
  "crucible", "crucible/crucible-manifest", "crucible/crucible-worker",
  "manifest", "manifest/manifest-core",
  "manifest-evals", "manifest-evals/evals-api", "manifest-evals/evals-ui",
]
ghc = "9.12.2"

[dependencies]   # union of the three repos' deps, deduped
```

All eight package names are unique (`crucible`, `crucible-manifest`,
`crucible-worker`, `manifest`, `manifest-core`, `manifest-evals`, `evals-api`,
`evals-ui`), so there are no collisions in one workspace.

### 3. Cross-repo pins → siblings

Delete the `[dependencies.manifest]`, `[dependencies.manifest-core]`, and
`[dependencies.crucible]` git stanzas. The members' `depends = [...]` lists
already reference these by name, so those entries stay and now resolve to the
in-tree siblings. manifest-evals's transitive dependency stanzas (copied
verbatim from crucible/manifest) get deduped into the single root
`[dependencies]`. The root `[dependencies]` is therefore the union of all three
repos' deps minus the three cross-repo pins.

### 4. Member manifests

Strip the `[workspace]` section (members + ghc + `[dependencies]`) from
`crucible/zinc.toml`, `manifest/zinc.toml`, and `manifest-evals/zinc.toml`,
leaving each as a pure `[package]` + `[build.*]` member manifest. The five
sub-member zinc.tomls (`crucible-manifest`, `crucible-worker`, `manifest-core`,
`evals-api`, `evals-ui`) are unchanged. manifest inherits the root 9.12.2 pin;
its own 9.10.1 pin is removed.

### 5. Flake + lockfile

One root `forge/flake.nix` equal to the manifest-evals flake (already on
9.12.2): `ghc9122`, `git`, `alex`, `happy`, `markdown-unlit`, `pkg-config`,
`postgresql`, `zlib`, plus the libpq `LIBRARY_PATH`/`LD_LIBRARY_PATH`
shellHook. The per-repo `flake.nix` and `flake.lock` are deleted; the per-repo
`zinc.lock` files are deleted. Regenerate a single `forge/zinc.lock` via
`zinc update`.

Add a top-level `forge/README.md` and `.gitignore` (union: `.zinc/`, `result`,
`.direnv/`).

### 6. Verification

- `zinc status` reports 8 members and clean lock drift.
- `zinc doctor` reports no problems.
- `zinc build` builds libraries first, incrementally
  (manifest-core → manifest → crucible → manifest-evals). A full Haskell build
  of this closure is heavy/long; any failure that needs hands-on fixing will be
  reported honestly rather than glossed over.

## Out of scope

- Consolidating per-repo `.beads/`, `.claude/`, `AGENTS.md`, `CLAUDE.md`.
- Deleting the on-disk original repos or their GitHub remotes.
- Configuring a new `origin` remote for `forge`.

## Risks

- **Build breakage from GHC unification:** manifest on 9.12.2 is expected to
  work (proven transitively) but not yet directly verified in a workspace.
- **Dependency dedup conflicts:** if two repos pin the same package at
  different revs, the root `[dependencies]` must pick one. Spot-checks show the
  shared stanzas (effectful, aeson, autodocodec, postgresql-libpq, profunctors,
  etc.) are already identical across repos; `zinc update` will surface any
  remaining conflict.
- **Long build times:** the full closure build is the slowest step; plan for
  incremental builds.
