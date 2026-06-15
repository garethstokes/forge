# Store Conformance Suite — Design

**Date:** 2026-06-15
**Status:** Committed spec
**Bead:** crucible-m0b — final piece of the persistence epic (crucible-5dl).
**Depends on:** all three thick handles + all three Postgres backends (shipped).

## The problem this solves

The thick handle (`MemoryStore`/`ResearchStore`/`LedgerStore`) is a record of `IO`
actions, so the effect interface no longer *structurally* enforces the invariants
the interpreters used to bake in (recall ordering, the CAS claim, tombstone
semantics, listReady order). Decision 2 of the shaping doc accepted that risk:
backends can silently diverge. This suite is the mitigation — **one shared set of
observable-behaviour checks per effect, run against every backend** (file/dir,
in-memory, and manifest-ephemeral Postgres), so any divergence fails a test.

## Design

### Where it lives
`crucible-manifest/test/` — the only place with all three backends in scope
(crucible-core's file/pure stores + the manifest stores) and the ephemeral-Postgres
machinery. A new module `Conformance.hs` holds the parameterized checks; `Spec.hs`
runs them across backends.

### Parameterization
Each backend has a different lifetime: the manifest store lives inside
`withEphemeralDb`'s bracket; file stores need a temp file/dir; pure stores are a
plain `IO`. So the checks take a **bracket**, not an `IO Store`:

```haskell
type WithStore s = forall a. (s -> IO a) -> IO a   -- needs RankNTypes

memoryConformance   :: String -> WithStore MemoryStore   -> [Test]
ledgerConformance   :: String -> WithStore LedgerStore   -> [Test]
researchConformance :: String -> WithStore (ResearchStore Text) -> [Test]
```

`Spec.hs` supplies one `WithStore` per backend and concatenates:

```haskell
runTests $ concat
  [ memoryConformance "file"     (\k -> withTempFile (k . memoryStoreFile))
  , memoryConformance "pure"     (\k -> newMemoryStorePure >>= k)
  , memoryConformance "manifest" (\k -> withEphemeralDb (\p -> migrateMemory p >> k (memoryStoreManifest p)))
  , ledgerConformance "file"     (\k -> withTempFile (k . ledgerStoreFile))
  , ledgerConformance "pure"     (\k -> newLedgerStorePure >>= k)
  , ledgerConformance "manifest" (\k -> withEphemeralDb (\p -> migrateLedger p >> k (ledgerStoreManifest p)))
  , researchConformance "dir"      (\k -> withTempDir (k . researchStoreDir C.str))
  , researchConformance "state"    (\k -> do { pr <- newIORef []; lr <- newIORef []; k (researchStoreState pr lr) })
  , researchConformance "manifest" (\k -> withEphemeralDb (\p -> migrateResearch p >> k (researchStoreManifest C.str p)))
  ]
```

Each check label is prefixed with the backend name (e.g. `memory[manifest]: …`) so
a failure pinpoints the diverging backend.

### Comparison projects away backend-specific identity
Raw ids differ legitimately: file/pure assign 0-based ordinals; Postgres
`BIGSERIAL` starts at 1. So checks compare **observable projections**, never raw
ids, and use each backend's *own* returned ids for follow-up ops:

- **Memory** — assert on recalled `content` lists (order + membership), not
  `memId`/`createdAt`. `forget` uses the id returned by the corresponding
  `doRemember`.
- **Ledger** — assert on `payload`/`state` of `listReady` (in record order) and on
  `doClaim`/`doComplete` boolean/observable effects; `claim`/`complete` use the
  ids returned by `doRecord`.
- **Research** — slugs are caller-chosen natural keys (stable across backends), so
  full `Page` round-trips can be compared directly.

### Checks per effect (the shared invariants)

**Memory** (`Query` needle/tags/budget):
1. remember a,b,c → `doRecall (Query "" [] 10)` content == `["c","b","a"]` (most-recent-first).
2. forget the middle → recall excludes it.
3. budget `maxItems = 1` → only the most recent.
4. tag filter → only items carrying the tag.
5. recall on empty store → `[]`.

**Ledger**:
1. record A,B,C → `doListReady` payloads == `["A","B","C"]` (record order).
2. `doClaim` first (returns `True`) → drops from listReady; remaining order preserved.
3. claim the *same* id again → `False` (the CAS invariant).
4. claim an unknown id → `False`.
5. `doComplete` a Ready id → drops from listReady.

**Research** (`meta = Text`):
1. write page → `doRead` round-trips title/links/body/meta exactly.
2. `doRead` an absent slug → `Nothing`.
3. overwrite a slug → `doRead` shows the new title/body/links/meta.
4. `doIndex` → slugs sorted.
5. `doSearch` → slugs whose title/body match (case-insensitive), sorted.

Because all backends are asserted against the *same* expected values, passing
implies they are mutually consistent.

## Backend fix this surfaces

`ledgerStoreManifest.doListReady` currently does `selectWhere [#state ==. Ready]`
with **no `ORDER BY`**, so Postgres may return Ready items in arbitrary order,
whereas file/pure return them in record order. Conformance check Ledger-1/2 would
fail for the manifest backend. **Fix:** sort the result by `wid` in Haskell
(`sortOn (.wid) <$> selectWhere …`) so record order is honoured. (Memory recall
already sorts via `queryLive`, and Research index/search already sort, so only
Ledger needs this.)

## Spec.hs refactor

The existing ad-hoc per-backend tests in `crucible-manifest/test/Spec.hs` (the
Memory/Ledger/Research smoke checks) are **subsumed** by the conformance suite run
against the manifest backend. Replace them with the conformance harness, but
**keep** the manifest-specific assertions the conformance suite does not cover:
the Memory `createdAt`-mirrors-id check and the Ledger distinct-increasing-ids
check (these assert backend-specific identity behaviour, not cross-backend
semantics).

## Testing

`nix develop . --command zinc test` runs the conformance suite (3 effects × 3
backends) plus crucible's hermetic suite. All green. The file/dir and pure/state
backends run fast (no Postgres); the manifest backend runs under `withEphemeralDb`.

## Out of scope
- Randomized property-based generation (QuickCheck-style op sequences) — the
  scenario table covers the known invariants; randomized fuzzing is a possible
  follow-up.
- Concurrency/contention tests for the CAS claim across connections.
- `withRecursive` graph combinator (shaping Part 2).

## Risks
- **Postgres ordering** — addressed by the `doListReady` sort fix; any other
  unordered query surfaces as a conformance failure (the suite's purpose).
- **Temp file/dir helpers** — reuse the patterns already in the test suite
  (`openTempFile`/`/tmp` + cleanup); ensure cleanup via `bracket` so a failing
  check doesn't leak files.
