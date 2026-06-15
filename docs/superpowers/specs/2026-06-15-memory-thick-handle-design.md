# Thick Backend Handle: Memory — Design

**Date:** 2026-06-15
**Status:** Committed spec (design basis: `2026-06-15-persistence-strategies-shaping.md`; sibling of `2026-06-15-thick-handles-research-ledger-design.md`)
**Bead:** crucible-qbh — child of epic crucible-5dl, Part 1.

## The problem this solves

Completes the thick-handle treatment for the third persistent effect, `Memory`,
so all three (`Memory`, `Research`, `Ledger`) share one seam. Persistence becomes
a parameter of the interpreter — a `MemoryStore` handle (a record of one `IO`
action per operation) run by a near-passthrough `runMemoryWith` — instead of a
fresh interpreter per backend. This is the seam the later `crucible-manifest`
workspace package plugs a Postgres backend into without crucible-core gaining a
`libpq` dependency.

### Non-breaking (corrected from the epic note)

The epic flagged this as breaking via "store-assigned identity (drops `itemOf d
n`)". On inspection that is **not breaking**: `Remember :: MemoryDraft -> Memory m
MemoryId` already returns the assigned id, `itemOf` is an internal helper, and the
id is already interpreter-assigned (the ordinal `n` = count of prior `Remembered`
entries). The Consolidate/Eval callers treat `MemoryId` as opaque and do not
consume `createdAt`. So this spec is a non-breaking, additive reframe identical in
shape to Research/Ledger. The genuinely structural identity change — a DB serial
PK that can diverge from the ordinal, `createdAt` as a wall-clock timestamp — has
teeth only once a real backend exists, and is deferred to crucible-gjm
(satellite + HKD), where it will be called out explicitly.

## Shape

```haskell
data MemoryStore = MemoryStore
  { doRemember :: MemoryDraft -> IO MemoryId   -- store-assigned key
  , doRecall   :: Query       -> IO [MemoryItem]
  , doForget   :: MemoryId    -> IO ()
  }

runMemoryWith :: (IOE :> es) => MemoryStore -> Eff (Memory : es) a -> Eff es a
runMemoryWith s = interpret $ \_ -> \case
  Remember d -> liftIO (s.doRemember d)
  Recall q   -> liftIO (s.doRecall q)
  Forget i   -> liftIO (s.doForget i)

memoryStoreFile :: FilePath -> MemoryStore
-- reuses readLog / appendEntry / queryLive / itemOf; doRemember keeps the
-- ordinal assignment (id = createdAt = count of prior Remembered), same caveat
-- (non-atomic read-count-append) as the original runMemoryFile.

memoryStorePure :: IORef [MemoryEntry] -> MemoryStore
newMemoryStorePure :: IO MemoryStore
-- IORef-backed handle (IO analogue of runMemoryPure). atomicModifyIORef' so
-- remember/forget are atomic within a process. newMemoryStorePure allocates a
-- fresh empty ref (so callers/tests need no access to the internal MemoryEntry).
```

- `runMemoryFile path = runMemoryWith (memoryStoreFile path)` — reframed, behaviour
  preserved (reuses the same helpers).
- `runMemoryPure` (pure, returns `(a, [MemoryItem])`) is **kept unchanged** for
  fast IO-free property tests.
- `runMemoryScripted` is **kept unchanged** (canned recalls for unit tests).
- `MemoryEntry` stays internal; `memoryStorePure` takes an `IORef [MemoryEntry]`,
  and `newMemoryStorePure` is the public constructor.

## What does NOT change

- No public type signatures change. `remember`, `recall`, `forget`, `recallAs`,
  `runMemoryPure`, `runMemoryFile`, `runMemoryScripted` are untouched.
- `Crucible.Memory.Consolidate` and `Crucible.Memory.Eval` are unaffected.
- No new package dependency.

## New module exports (`Crucible.Memory`)

`MemoryStore (..)`, `runMemoryWith`, `memoryStoreFile`, `memoryStorePure`,
`newMemoryStorePure`.

## Testing

Existing Memory tests must pass unchanged. Add:

- `runMemoryWith (memoryStorePure …)` round-trips remember→recall, and `forget`
  drops an item from recall — matching `runMemoryPure` semantics (most-recent
  first, budget honored).
- Handle parity: `runMemoryFile <tempfile>` and `runMemoryWith
  (newMemoryStorePure)` produce the same observable recall for the same program
  (remember a few, forget one, recall under a budget). A lightweight precursor to
  the m0b conformance suite.

## Docs

Add a short "backend handle" paragraph to `docs/memory.md` (mirroring the
Research/Ledger additions): the file/in-memory backends are now `MemoryStore`
handles run by `runMemoryWith`; `runMemoryFile = runMemoryWith (memoryStoreFile
…)`; this is the seam a Postgres backend plugs into.

## Out of scope

- HKD migration of `MemoryItem`/`MemoryDraft`, `memoryStoreManifest`, DB
  serial-PK identity and timestamp `createdAt` (crucible-gjm).
- Cross-backend conformance suite incl. manifest-ephemeral (crucible-m0b).
