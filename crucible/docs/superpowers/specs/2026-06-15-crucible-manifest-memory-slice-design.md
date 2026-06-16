# crucible-manifest: Memory Vertical Slice — Design (Phase 1)

**Date:** 2026-06-15
**Status:** Committed spec
**Repo:** `crucible`
**Bead:** crucible-gjm (vertical slice; Research/Ledger backends are fast-follows)
**Depends on:** Phase 0 (manifest-core split), manifest rev
`62f097c9dbb68a385aeb8551df68990e1da2bba2`.

## The problem this solves

The three persistent effects now share a thick-handle seam (`MemoryStore` /
`ResearchStore` / `LedgerStore`). This phase plugs the FIRST real database backend
into that seam: a Postgres-backed `MemoryStore`, derived generically from the
domain type via manifest, proving the whole pattern end-to-end (HKD domain type →
`deriving via Table` Entity → store-assigned identity → ephemeral-Postgres tests)
before repeating it for Research and Ledger. It also stands up the new
`crucible-manifest` workspace package and the Postgres test infrastructure.

## Part A — crucible-core changes

### A1. `MemoryItem` becomes Higher-Kinded Data

`Crucible.Memory` migrates the domain record to HKD so a manifest `Entity` can be
generically derived from it. The runtime type and public API are **unchanged**.

```haskell
-- new imports (from manifest-core, libpq-free):
import Manifest.Core.Table (Field, Pk)   -- Pk a = PrimaryKey (Serial a)

data MemoryItemT f = MemoryItem
  { memId     :: Field f (Pk MemoryId)
  , kind      :: Field f MemoryKind
  , content   :: Field f Text
  , tags      :: Field f [Text]
  , source    :: Field f Provenance
  , createdAt :: Field f Int
  } deriving Generic

type MemoryItem = MemoryItemT Identity

deriving instance Eq   MemoryItem    -- StandaloneDeriving
deriving instance Show MemoryItem
```

Why this is non-breaking: at `f = Identity`, `Field Identity (Pk MemoryId) = Base
(Serial MemoryId) = MemoryId` and every other `Field Identity a = a`. So the
`Identity` constructor has the *same* argument types as today
(`MemoryId -> MemoryKind -> Text -> [Text] -> Provenance -> Int -> MemoryItem`),
and `itemOf`, record-dot accessors (`.memId` …), `memoryItemCodec`, and the
`Consolidate`/`Eval` callers all continue to compile unchanged. Requires
`{-# LANGUAGE StandaloneDeriving #-}` (and `DeriveGeneric`, already implied).

`MemoryDraft` stays a plain record (it has no identity; no need to HKD it).

### A2. Export a shared recall kernel

So every backend produces *identical* recall semantics (the whole point of the
conformance story), crucible-core exports the existing pure kernel rather than
each backend re-implementing it. Add to the `Crucible.Memory` export list:

- `MemoryEntry (..)` (currently internal: `Remembered MemoryItem | Forgot MemoryId`)
- `queryLive :: Query -> [MemoryEntry] -> [MemoryItem]` (already defined; the
  shared "live items matching query, most-recent first, budgeted" kernel)

No behaviour change — just widening visibility. `runMemoryPure`/`memoryStoreFile`
already use `queryLive`; the manifest backend will too.

### A3. Dependency

`crucible` library gains `manifest-core` (and its transitive `profunctors`, which
crucible does not yet depend on; `aeson`/`autodocodec` it already has). This grows
crucible-core's closure modestly (no libpq). Add `manifest-core` to
`[build.lib].depends` and the git-pin stanzas (see Part C).

## Part B — the `crucible-manifest` package

A new workspace member: `crucible-manifest/` (lib only for this slice).

### B1. Entities (in crucible-manifest, HKD `deriving via`)

```haskell
deriving via (Table "memory" MemoryItemT) instance Entity MemoryItem
```

`MemoryItemT` lives in core; the `Entity` instance + the manifest column codecs
live here. The generic deriver needs `DbType`/`FieldMeta` for each field type:
`Text`, `Int`, `[Text]` are provided by manifest; `MemoryId`, `MemoryKind`,
`Provenance` are crucible types and need `DbType` instances here:

- `MemoryId` — newtype over `Int`; reuse `Int`'s codec via `dimap`.
- `MemoryKind` — small enum; store as `Text` ("episodic"/"semantic"/"procedural")
  via `dimap`, reusing the spirit of `memoryKindCodec`.
- `Provenance` — store as the crucible-JSON of `provenanceCodec` in a `jsonb`
  column (via manifest's `Aeson`/`Json` wrapper, or a `dimap` to `Text`),
  preserving the by/name shape.

These are orphan instances (crucible types, manifest classes) → compile
crucible-manifest with `-Wno-orphans`. They are the small, deliberate "manifest
codec surface" for Memory.

A separate tiny entity models tombstones (Memory's `Forget` supersedes, never
erases — history survives, matching the file/pure log):

```haskell
deriving via (Table "memory_tombstones" MemoryTombstoneT) instance Entity MemoryTombstone
data MemoryTombstoneT f = MemoryTombstone
  { tombId :: Field f (Pk Int)
  , memRef :: Field f MemoryId   -- the forgotten item's id
  } deriving Generic
```

### B2. `memoryStoreManifest`

```haskell
memoryStoreManifest :: Pool -> MemoryStore
```

- **doRemember d** — `withSession pool` then `add` a `MemoryItem` with a placeholder
  `memId` (the `Serial` PK is DB-assigned and skipped on INSERT). Return
  `MemoryId <assigned serial>`. crucible's invariant is `createdAt == id`; the
  backend honors it by treating `createdAt` as a mirror of the assigned id (see
  note), so the stored `createdAt` column is vestigial and recall sets
  `createdAt = idInt memId`.
- **doRecall q** — `withSession pool`: load all `MemoryItem` rows and all tombstone
  `memRef`s, rebuild `[MemoryEntry]` (`Remembered` per item with `createdAt`
  normalized to its id, `Forgot` per tombstone), and return `queryLive q entries`.
  This reuses crucible's exact recall kernel, so semantics match file/pure by
  construction. (SQL-side WHERE/ORDER/LIMIT pushdown is a later optimization, not
  needed for correctness.)
- **doForget i** — `withSession pool`: `add` a `MemoryTombstone` referencing `i`.

**Identity note:** Postgres `BIGSERIAL` starts at 1; file/pure ordinals start at 0.
So raw id *values* differ across backends — the conformance suite (m0b) will
compare observable semantics (content order, forget-removes-from-recall, budget),
not raw ids. Within the manifest backend, ids are monotonic, so id order == insert
order == recency, matching crucible's `(createdAt, id)` ordering.

## Part C — infrastructure

### C1. `flake.nix` (devshell gets Postgres + libpq)

Mirror manifest's flake: add `pkgs.pkg-config` and `pkgs.postgresql` to `packages`,
and extend the shellHook so libpq links and the ephemeral cluster's
`initdb`/`pg_ctl`/`postgres` are on PATH:

```nix
export LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.postgresql ]}${LIBRARY_PATH:+:$LIBRARY_PATH}
export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.zlib pkgs.postgresql ]}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
```

### C2. `zinc.toml`

- `[workspace] members = [".", "crucible-manifest"]`.
- crucible `[build.lib].depends` += `manifest-core`.
- New git-pin stanzas in the root `[dependencies]` (mirror manifest-evals'
  copied-transitive pattern), all at the manifest rev above:
  - `[dependencies.manifest]` repo `…/manifest.git`, rev `62f097c…`
  - `[dependencies.manifest-core]` repo `…/manifest.git#manifest-core`, rev `62f097c…`
    (zinc's `#member` selects the workspace sub-package — same syntax crucible
    already uses for `effectful-core` = `…/effectful.git#effectful-core`).
  - `[dependencies.postgresql-libpq]` (rev + `flags = { use-pkg-config = true }`)
    and `[dependencies.profunctors]` — copied from manifest's pins.
- `crucible-manifest/zinc.toml`: package `crucible-manifest`; `[build.lib]` deps
  `base, text, bytestring, crucible, manifest, manifest-core, effectful,
  effectful-core, aeson, autodocodec`; `crucible = { path = ".." }`. A
  `[build.test.spec]` with `ghc-options = ["-lpq"]` and deps adding
  `crucible-manifest`.

## Testing

`crucible-manifest/test` (ephemeral Postgres via `Manifest.Testing.withEphemeralDb`):

1. **migrate** the `memory` + `memory_tombstones` tables (manifest `migrate`).
2. remember 3 drafts; assert `doRemember` returns 3 distinct, monotonically
   increasing ids.
3. `doRecall` (Query "" [tag] 10): assert content set + most-recent-first order.
4. `doForget` the middle id; `doRecall` again: assert it is gone and the others
   remain (tombstone works, history preserved).
5. budget: `doRecall` with `maxItems = 1` returns exactly the most recent.

These prove the backend end-to-end against real Postgres. Cross-backend equality
(file/pure/manifest) is m0b's job, not this slice's.

crucible's existing `zinc test` (the hermetic Spec.hs) must still pass after the
HKD migration (proves A1/A2 are non-breaking).

## Risks

- **zinc `#member` external dep** — high confidence (crucible already uses the
  syntax for effectful-core); proven by the build. Fallback if it fails:
  temporarily depend on the whole `manifest` for the types too, or publish
  manifest-core to the registry.
- **Dependency closure resolution** — adding manifest/manifest-core pulls a shared
  closure (autodocodec/aeson/profunctors/postgresql-libpq) already resolved by
  manifest-evals on this GHC; if `zinc` hits a registry gap, mirror manifest-evals'
  exact stanzas. Surfaced at build time.
- **GHC version skew** — manifest is built at 9.10.1 there, crucible at 9.12.2;
  zinc builds deps from source against crucible's GHC, so manifest/manifest-core
  compile under 9.12.2 here (manifest-evals already consumes manifest at 9.12.2 —
  precedent exists).

## Out of scope

- `researchStoreManifest`, `ledgerStoreManifest` (+ their HKD migrations) — fast-follow beads.
- Cross-backend conformance suite (crucible-m0b).
- SQL-side query pushdown (WHERE/ORDER/LIMIT/jsonb operators) — recall fetches and
  filters in Haskell via `queryLive` for now.
- `withRecursive` graph combinator (shaping Part 2).
