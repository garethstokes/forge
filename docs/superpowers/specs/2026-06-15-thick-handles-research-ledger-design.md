# Thick Backend Handles: Research + Ledger — Design

**Date:** 2026-06-15
**Status:** Committed spec (design basis: `2026-06-15-persistence-strategies-shaping.md`)
**Beads:** crucible-80m (Research), crucible-2l9 (Ledger) — both children of epic crucible-5dl, Part 1.

## The problem this solves

Persistence in crucible is hand-rolled inside each effect's interpreter: `Research`
has `runResearchDir` (markdown-per-page) and `runResearchState` (pure); `Ledger`
has `runLedgerFile` (JSONL) and `runLedgerState` (pure). Each new backend
(Postgres, a graph store) today means a *fresh interpreter per effect* — an
N-effects × M-backends problem. The shaping doc's decision is to make persistence
a **parameter** of each interpreter: a thick backend handle (a record of the
effect's operations) that the interpreter near-passes-through. This decouples
"which effect" from "which backend" and gives a later `crucible-manifest`
satellite a single seam to plug a Postgres backend into, without crucible-core
gaining a `libpq` dependency.

This spec covers only the **two non-breaking effects**: `Research` (slugs are
caller-chosen, so identity does not change) and `Ledger` (its `WorkId` is already
interpreter-assigned, so a handle that returns the store-assigned id keeps the
public `record :: Text -> Eff es WorkId` signature). `Memory`'s thick handle
(crucible-qbh) is deliberately *out of scope here* because shaping decision 3
("store-assigned identity") drops `itemOf d n` — a breaking change that ripples to
`manifest-evals` and needs explicit sign-off. The `crucible-manifest` satellite
(gjm), HKD migration, and the cross-backend conformance suite (m0b) are likewise
separate, larger pieces.

## Shape

### Research

```haskell
data ResearchStore meta = ResearchStore
  { doRead   :: Slug -> IO (Maybe (Page meta))
  , doWrite  :: Page meta -> IO ()
  , doIndex  :: IO [Slug]
  , doSearch :: Text -> IO [Slug]
  , doLog    :: Text -> IO ()
  }

runResearchWith :: (IOE :> es) => ResearchStore meta -> Eff (Research meta : es) a -> Eff es a
runResearchWith s = interpret $ \_ -> \case
  ReadPage sl  -> liftIO (s.doRead sl)
  WritePage p  -> liftIO (s.doWrite p)
  Index        -> liftIO s.doIndex
  Search q     -> liftIO (s.doSearch q)
  AppendLog ln -> liftIO (s.doLog ln)

researchStoreDir :: JSONCodec meta -> FilePath -> ResearchStore meta
-- reuses the existing readPageFile / writePageFile / indexDir / searchDir / logFile

researchStoreState :: IORef [Page meta] -> IORef [Text] -> ResearchStore meta
-- IORef-backed handle (the IO analogue of the pure state interpreter)
```

- `runResearchDir mc dir = runResearchWith (researchStoreDir mc dir)` — the existing
  interpreter is now a thin wrapper over the handle. Its docstring/behaviour
  (path-unsafe slugs refused, tolerant decode, `activity.log`) is preserved
  because it reuses the same helper functions.
- `runResearchState` (pure, returns `(a, [Page meta], [Text])`) is **kept
  unchanged** for fast IO-free property tests, per shaping §3.

### Ledger

```haskell
data LedgerStore = LedgerStore
  { doRecord    :: Text -> IO WorkId
  , doClaim     :: WorkId -> Text -> IO Bool
  , doComplete  :: WorkId -> IO ()
  , doListReady :: IO [WorkItem]
  }

runLedgerWith :: (IOE :> es) => LedgerStore -> Eff (Ledger : es) a -> Eff es a

ledgerStoreFile :: FilePath -> LedgerStore
-- reuses the existing readLog / appendEvent / stateOf / readyOf

ledgerStorePure :: IORef [WorkItem-event-log] -> LedgerStore
-- IORef [LedgerEvent]-backed handle (IO analogue of runLedgerState)
```

- `runLedgerFile path = runLedgerWith (ledgerStoreFile path)` — same single-writer
  non-atomic caveat documented; preserved because it reuses the same helpers.
- `runLedgerState` (pure, returns `(a, [WorkItem])`) is **kept unchanged** for
  property tests.
- `LedgerEvent` stays internal; `ledgerStorePure` takes an `IORef [LedgerEvent]`.
  (The existing event/codec machinery is unchanged.)

## What does NOT change

- No public type signatures change. `record`, `claim`, `complete`, `listReady`,
  `readPage`, `writePage`, `index`, `search`, `appendLog` are untouched.
- `runResearchDir`, `runResearchState`, `runLedgerFile`, `runLedgerState` keep
  their existing signatures and observable behaviour.
- No new package dependency. The handles are plain records over `IO`.

## New module exports

- `Crucible.Research`: add `ResearchStore (..)`, `runResearchWith`,
  `researchStoreDir`, `researchStoreState`.
- `Crucible.Ledger`: add `LedgerStore (..)`, `runLedgerWith`, `ledgerStoreFile`,
  `ledgerStorePure`.

## Testing

Existing Research and Ledger tests must pass unchanged (they exercise the
reframed `runResearchDir`/`runResearchState`/`runLedgerFile`/`runLedgerState`).
Add direct-handle tests:

- `runResearchWith (researchStoreState …)` round-trips a write→read and
  index/search, matching `runResearchState` behaviour.
- `runLedgerWith (ledgerStorePure …)` records→claims→completes, matching
  `runLedgerState` behaviour, including the compare-and-set claim (second claim of
  a claimed item returns `False`).
- Handle parity: `runResearchDir` (a temp dir) and `runResearchWith
  (researchStoreState …)` produce the same observable results for the same
  program; same for `runLedgerFile` vs `ledgerStorePure`. (A lightweight
  precursor to the full m0b conformance suite — kept minimal here.)

## Docs

Update `docs/research.md` and `docs/ledger.md` interpreter sections to mention the
thick handle as the seam (one short paragraph each), noting the file/state
interpreters are now handles over `runResearchWith`/`runLedgerWith`.

## Out of scope (named so they don't sneak in)

- `Memory` thick handle + store-assigned identity (crucible-qbh) — breaking,
  ripples to manifest-evals; needs sign-off.
- `crucible-manifest` satellite, HKD migration of domain types (crucible-gjm).
- Full cross-backend conformance suite incl. manifest-ephemeral (crucible-m0b).
