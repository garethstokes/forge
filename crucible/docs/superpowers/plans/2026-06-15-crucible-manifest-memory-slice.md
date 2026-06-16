# crucible-manifest Memory Vertical Slice — Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A Postgres-backed `MemoryStore` (`memoryStoreManifest`) in a new `crucible-manifest` workspace package, derived from an HKD `MemoryItemT`, proven against ephemeral Postgres — without crucible-core gaining libpq.

**Architecture:** crucible-core depends on `manifest-core` (pure) and migrates `MemoryItem` to HKD (Identity instance unchanged). `crucible-manifest` depends on full `manifest` (libpq) + crucible (path), adds the `Entity` instance + `DbType` orphans + the backend, and reuses crucible's `queryLive` kernel so recall semantics match file/pure by construction.

**Tech Stack:** GHC 9.12.2, zinc workspace, manifest rev `62f097c9dbb68a385aeb8551df68990e1da2bba2`, ephemeral Postgres.

**Build/test commands:**
- Whole workspace: `nix develop . --command timeout -s KILL 300 zinc build`
- crucible hermetic tests: `nix develop . --command timeout -s KILL 300 zinc test`
- a single member's test: `nix develop . --command timeout -s KILL 600 zinc test crucible-manifest` (if member-targeted syntax works; else run the workspace tests)
- exit 137 = GHC iserv flake → retry once.

Tasks are dependency-ordered; do them in sequence (each touches different files except crucible-manifest/, which Task 1 creates and Task 3 fills).

---

### Task 1: Dependency plumbing + flake + crucible-manifest skeleton (the de-risking task)

**Files:**
- Modify: `flake.nix`, `zinc.toml` (root)
- Create: `crucible-manifest/zinc.toml`, `crucible-manifest/src/Crucible/Manifest/Memory.hs` (placeholder)

- [ ] **Step 1: `flake.nix` — add Postgres + libpq to the devshell.**

Add `pkgs.pkg-config` and `pkgs.postgresql` to the `packages` list, and extend the
shellHook to put libpq on the link/load paths (mirrors the manifest repo's flake):

```nix
            packages = [
              ghc
              pkgs.git
              pkgs.haskellPackages.alex
              pkgs.haskellPackages.happy
              pkgs.pkg-config
              pkgs.postgresql
              pkgs.zlib
            ];
            shellHook = ''
              export LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.postgresql ]}''${LIBRARY_PATH:+:$LIBRARY_PATH}
              export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.zlib pkgs.postgresql ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            '';
```

- [ ] **Step 2: root `zinc.toml` — workspace member + dependency pins.**

- `[workspace] members = ["."]` → `members = [".", "crucible-manifest"]`.
- Add `"manifest-core"` to the crucible `[build.lib].depends` (crucible-core will
  import `Manifest.Core.Table` in Task 2).
- Add these stanzas to the root `[dependencies]` (all manifest pins at the rev
  above; mirror the syntax crucible already uses for `effectful-core`):

```toml
[dependencies.manifest]
repo = "https://github.com/garethstokes/manifest.git"
rev = "62f097c9dbb68a385aeb8551df68990e1da2bba2"

[dependencies.manifest-core]
repo = "https://github.com/garethstokes/manifest.git#manifest-core"
rev = "62f097c9dbb68a385aeb8551df68990e1da2bba2"

[dependencies.postgresql-libpq]
rev = "240147a5225b4e19e20abb9d1103e66b1b55b5a2"
repo = "https://github.com/haskellari/postgresql-libpq"
flags = { use-pkg-config = true }

[dependencies.profunctors]
repo = "https://github.com/ekmett/profunctors.git"
```

- [ ] **Step 3: `crucible-manifest/zinc.toml`.**

```toml
[package]
name = "crucible-manifest"
version = "0.1.0"

[build.lib]
source-dirs = ["src"]
ghc-options = ["-Wall", "-Wno-orphans", "-lpq"]
depends = ["base", "text", "bytestring", "crucible", "manifest", "manifest-core", "effectful", "effectful-core", "aeson", "autodocodec"]

[build.test.spec]
source-dirs = ["test"]
main = "Spec.hs"
ghc-options = ["-lpq", "-threaded"]
depends = ["base", "text", "crucible", "crucible-manifest", "manifest", "manifest-core"]

[dependencies.crucible]
path = ".."
```

(If zinc wants the `crucible` path dep declared differently for a workspace
sibling, mirror how manifest-evals' members reference each other; the goal is
crucible resolved as the sibling workspace package, manifest/manifest-core from
the git pins.)

- [ ] **Step 4: placeholder module proving BOTH packages resolve.**

`crucible-manifest/src/Crucible/Manifest/Memory.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Manifest.Memory () where

import Manifest.Core.Table (Field)   -- from manifest-core (pure)
import Manifest (withSession)         -- from manifest (libpq umbrella)
import Crucible.Memory (MemoryStore)  -- from crucible (sibling)

-- placeholder: proves manifest-core, manifest, and crucible all resolve and
-- co-build under GHC 9.12.2 with libpq linked. Real backend lands in Task 3.
_unused :: ()
_unused = ()
```

(Imports may warn as unused — that is fine for the skeleton; they exist to force
resolution. If `-Wall` makes unused imports an error, add `{-# OPTIONS_GHC
-Wno-unused-imports #-}` to this placeholder only.)

- [ ] **Step 5: Build the whole workspace.**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: crucible builds (manifest-core declared but as-yet unused is fine);
crucible-manifest skeleton builds, proving manifest/manifest-core/crucible all
resolve. **This is the key risk gate.** If `#manifest-core` does not resolve,
report the exact zinc error (do not silently work around it); likely fixes:
adjust the `#member` syntax, or confirm the manifest rev contains the
`manifest-core` member (it does, on rev `62f097c…`).

- [ ] **Step 6: Commit.**

```bash
git add flake.nix zinc.toml crucible-manifest/
git commit -m "build(crucible-manifest): workspace member + manifest/manifest-core pins + pg devshell

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: HKD-migrate Crucible.Memory + export the recall kernel

**Files:**
- Modify: `src/Crucible/Memory.hs`

- [ ] **Step 1: Add language pragmas + import.**

At the top of `src/Crucible/Memory.hs` add `{-# LANGUAGE StandaloneDeriving #-}`
and `{-# LANGUAGE DeriveGeneric #-}` (if not present). Add imports:

```haskell
import GHC.Generics (Generic)
import Data.Functor.Identity (Identity)
import Manifest.Core.Table (Field, Pk)
```

- [ ] **Step 2: Replace the `MemoryItem` declaration with the HKD version.**

Replace:
```haskell
data MemoryItem = MemoryItem
  { memId     :: MemoryId
  , kind      :: MemoryKind
  , content   :: Text
  , tags      :: [Text]
  , source    :: Provenance
  , createdAt :: Int
  }
  deriving (Eq, Show)
```
with:
```haskell
data MemoryItemT f = MemoryItem
  { memId     :: Field f (Pk MemoryId)
  , kind      :: Field f MemoryKind
  , content   :: Field f Text
  , tags      :: Field f [Text]
  , source    :: Field f Provenance
  , createdAt :: Field f Int
  }
  deriving Generic

type MemoryItem = MemoryItemT Identity

deriving instance Eq   MemoryItem
deriving instance Show MemoryItem
```

- [ ] **Step 3: Export the HKD type, the kernel, and MemoryEntry.**

In the module export list:
- change `MemoryItem (..)` to `MemoryItemT (..), MemoryItem` (export the HKD type
  with its fields AND the `MemoryItem` type alias).
- add `MemoryEntry (..)` and `queryLive`.

- [ ] **Step 4: Build crucible-core.**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: builds. Likely fixes: if `itemOf`/`recallAs`/`memoryItemCodec`/the
`Consolidate` module reference fields in a way that now needs a type annotation,
add the minimal annotation. The `Identity` field types are unchanged, so most code
should compile untouched. If `Eq`/`Show` instances are needed for `MemoryItemT
Identity` somewhere else, the standalone derivations cover `MemoryItem`. If exit
137, retry once.

- [ ] **Step 5: Run the hermetic test suite — proves non-breaking.**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the existing Spec.hs (Memory tests incl. the thick-handle ones) passes
unchanged. This is the acceptance gate for the HKD migration.

- [ ] **Step 6: Commit.**

```bash
git add src/Crucible/Memory.hs
git commit -m "feat(memory): MemoryItem becomes HKD (MemoryItemT f); export queryLive kernel

Non-breaking: type MemoryItem = MemoryItemT Identity has identical field types.
Enables a generic manifest Entity in crucible-manifest.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: The Postgres backend (crucible-manifest)

**Files:**
- Modify: `crucible-manifest/src/Crucible/Manifest/Memory.hs` (replace placeholder)
- Create: `crucible-manifest/test/Spec.hs`

**Before coding, READ these in the manifest repo for the exact, working API
patterns (do not guess signatures):**
- `~/code/garethstokes/manifest/test/Fixtures.hs` — real `Entity` definitions
  (`deriving via Table`), `DbType`/codec usage for custom field types.
- `~/code/garethstokes/manifest/test/Harness.hs` and any `*Spec.hs` using
  `withEphemeralDb` + table migration + `add`/`selectWhere` — copy that
  migration + session pattern verbatim for the test.
- `Manifest.Core.Codec` for the `Codec`/`DbType`/`dimap` API; `Manifest` umbrella
  for `withSession`, `add`, `selectWhere`, `migrate`/`managed`, `Pool`.

- [ ] **Step 1: Entities + DbType instances.**

In `crucible-manifest/src/Crucible/Manifest/Memory.hs`:
- `deriving via (Table "memory" MemoryItemT) instance Entity MemoryItem`.
- A tombstone entity:
  ```haskell
  data MemoryTombstoneT f = MemoryTombstone
    { tombId :: Field f (Pk Int)
    , memRef :: Field f MemoryId
    } deriving Generic
  type MemoryTombstone = MemoryTombstoneT Identity
  deriving via (Table "memory_tombstones" MemoryTombstoneT) instance Entity MemoryTombstone
  ```
- `DbType` instances (orphans; `-Wno-orphans` is set) for the crucible field types,
  following the `dimap`/`Codec` patterns from `Manifest.Core.Codec` and manifest's
  Fixtures:
  - `MemoryId` — reuse `Int`'s `dbType` via `dimap idInt MemoryId` (idInt is not
    exported from Crucible.Memory; either export it, or `dimap (\(MemoryId i) -> i)
    MemoryId`). NOTE: `MemoryId`'s constructor IS exported (`MemoryId (..)`).
  - `MemoryKind` — store as `Text` ("episodic"/"semantic"/"procedural") via a
    `dimap` over `Text`'s `dbType`.
  - `Provenance` — store the crucible-JSON of `provenanceCodec` as `Text` (use
    `Crucible.Codec.encodeText provenanceCodec` / `Crucible.Decode.decodeLLM
    provenanceCodec`) via a `dimap`/`refine`-style codec over `Text`. (`provenanceCodec`
    is not currently exported from Crucible.Memory — export it, OR re-derive the
    by/name mapping here. Prefer exporting `provenanceCodec` from Crucible.Memory.)

  If exporting `idInt`/`provenanceCodec` from `Crucible.Memory` is needed, add them
  to its export list (a small, safe widening) and commit that with Task 3.

- [ ] **Step 2: `memoryStoreManifest`.**

```haskell
memoryStoreManifest :: Pool -> MemoryStore
memoryStoreManifest pool = MemoryStore
  { doRemember = \d -> withSession pool $ do
      it <- add (MemoryItem (MemoryId 0) d.kind d.content d.tags d.source 0)
      pure it.memId            -- the DB-assigned serial
  , doRecall = \q -> withSession pool $ do
      items <- selectWhere []          -- all memory rows  (use the all-rows form manifest provides)
      tombs <- selectWhere []          -- all tombstones
      let entries = [ Remembered it { createdAt = idInt it.memId } | it <- items ]
                 ++ [ Forgot t.memRef | t <- tombs ]
      pure (queryLive q entries)
  , doForget = \i -> withSession pool $ do
      _ <- add (MemoryTombstone 0 i)
      pure ()
  }
```

Adjust to the real `selectWhere`/all-rows API and `Db`/`withSession` types
discovered in Step 0 reading. `createdAt = idInt it.memId` is the agreed "mirror"
(crucible's invariant createdAt == id; serial is monotonic so ordering is correct).
Export `memoryStoreManifest` (and the entities if useful) from the module.

- [ ] **Step 3: Migration helper.**

Provide whatever the test needs to create the two tables (mirror manifest's test
migration pattern — e.g. a `migrate`/`managed [ ... ]` over the two entities). If a
small `migrateMemory :: Pool -> IO ()` helper is natural, export it.

- [ ] **Step 4: `crucible-manifest/test/Spec.hs` — ephemeral Postgres.**

Mirror manifest's `withEphemeralDb` + migration test pattern. Use a simple
pass/fail harness (or copy crucible's `test/Harness.hs` style). The test:

```
withEphemeralDb $ \pool -> do
  migrate the memory + memory_tombstones tables
  let store = memoryStoreManifest pool
  i1 <- store.doRemember (MemoryDraft Semantic "a" ["t"] Curated)
  i2 <- store.doRemember (MemoryDraft Episodic "b" ["t"] Curated)
  i3 <- store.doRemember (MemoryDraft Semantic "c" ["t"] Curated)
  -- assert i1<i2<i3 (distinct, monotonic)
  r1 <- store.doRecall (Query "" ["t"] 10)     -- assert contents {a,b,c}, newest-first => [c,b,a]
  store.doForget i2
  r2 <- store.doRecall (Query "" ["t"] 10)     -- assert [c,a] (b gone)
  r3 <- store.doRecall (Query "" ["t"] 1)      -- budget: assert [c]
  report results
```

Assert on `.content` lists (not raw ids). Exit non-zero on any failed check so
zinc reports failure.

- [ ] **Step 5: Build + test.**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Then: `nix develop . --command timeout -s KILL 600 zinc test` (runs crucible's
hermetic suite AND crucible-manifest's ephemeral-pg suite; both must pass). If
member-targeted test syntax exists, you may run `... zinc test crucible-manifest`
to iterate faster, but finish with the full `zinc test`.
exit 137 → retry once. If Postgres binaries aren't found, the flake change from
Task 1 may need `nix develop` to be re-entered — report precisely, don't fake.

- [ ] **Step 6: Commit.**

```bash
git add crucible-manifest/ src/Crucible/Memory.hs
git commit -m "feat(crucible-manifest): memoryStoreManifest — Postgres MemoryStore via manifest

HKD MemoryItem -> Entity (deriving via Table); store-assigned serial identity;
tombstone table for Forget; recall reuses crucible's queryLive kernel. Proven
against ephemeral Postgres.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** Task 1 = Part C infra (flake C1, zinc C2) + de-risk #member. Task 2 = Part A (A1 HKD, A2 kernel export, A3 dep). Task 3 = Part B (B1 entities + DbType, B2 backend, tombstones) + Testing.
- **Type consistency:** `MemoryItemT`/`MemoryItem`, `MemoryTombstoneT`, `memoryStoreManifest`, `queryLive`/`MemoryEntry` exported and used consistently. The `idInt`/`provenanceCodec` export-widening is called out where needed.
- **Risk handling:** Task 1 Step 5 is the dependency-resolution gate; Task 2 Step 5 is the non-breaking gate; Task 3 Step 5 is the real-Postgres gate. Each has an explicit "report precisely, don't fake" instruction.
- **Placeholder scan:** the only intentional placeholder is the Task 1 skeleton module, replaced in Task 3.
