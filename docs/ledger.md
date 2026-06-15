---
title: Work ledger
nav_order: 13
---

# Work ledger

When more than one agent, or more than one session, works toward a shared goal,
they need one place that answers what is left to do and who is doing it. The
work ledger is that place: an append-only record of work items with a
compare-and-set claim, so each item goes to exactly one worker and progress
survives across sessions.

## The model

```haskell
newtype WorkId = WorkId Int
data WorkState = Ready | Claimed | Done
data WorkItem = WorkItem { wid :: WorkId, payload :: Text, state :: WorkState, claimant :: Maybe Text }
```

An item is `Ready` when it has been recorded and is neither claimed nor
completed. The `payload` is text; structured work data is encoded through a codec
to text, as with a memory's content.

## The effect

```haskell
record    :: (Ledger :> es) => Text -> Eff es WorkId
claim     :: (Ledger :> es) => WorkId -> Text -> Eff es Bool
complete  :: (Ledger :> es) => WorkId -> Eff es ()
listReady :: (Ledger :> es) => Eff es [WorkItem]
```

`record` adds a `Ready` item. `claim wid who` is a compare-and-set: it succeeds
(returns `True`) only when the item is still `Ready`, so two workers cannot take
the same item; an already-claimed, completed, or unknown id returns `False`.
`complete` marks an item `Done`. `listReady` returns the `Ready` items in record
order.

## Interpreters

```haskell
runLedgerState :: Eff (Ledger : es) a -> Eff es (a, [WorkItem])
runLedgerFile  :: (IOE :> es) => FilePath -> Eff (Ledger : es) a -> Eff es a
```

`runLedgerState` keeps the ledger in memory and returns the final items
alongside the result, for tests. `runLedgerFile` keeps a git-diffable JSONL
event log at a path: each operation appends a line, and reads fold the log. It
outlives a session, so a later run on the same path sees earlier work.

Single-writer: the file interpreter reads then appends, which is not atomic
across processes, so true concurrent claim needs a real backend. That is an
interpreter concern; a backend-specific interpreter (for example one backed by
an issue tracker) belongs in an application, not in the library.

### The backend handle

`runLedgerFile` is a thin wrapper over a *thick backend handle* — a `LedgerStore`
record holding one `IO` action per operation
(`doRecord`/`doClaim`/`doComplete`/`doListReady`) — run by `runLedgerWith`:

```haskell
runLedgerWith   :: (IOE :> es) => LedgerStore -> Eff (Ledger : es) a -> Eff es a
ledgerStoreFile :: FilePath -> LedgerStore        -- the JSONL backend
newLedgerStorePure :: IO LedgerStore              -- in-memory over an IORef event log
```

`runLedgerFile path = runLedgerWith (ledgerStoreFile path)`. The handle is the
seam where persistence becomes a *parameter* of the interpreter: a real backend
(say Postgres in a satellite package) supplies its own `LedgerStore` — whose
`doClaim` can be a genuine atomic compare-and-set — and plugs into the same
`runLedgerWith`. The pure `runLedgerState` is kept for tests.

The ledger is independent of subagents: any caller can record and claim work,
not just a `spawn` orchestrator.
