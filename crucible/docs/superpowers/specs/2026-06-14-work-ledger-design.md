# Work-Ledger Effect Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-a6k` (follow-on filed at the close of `crucible-pch`, Spawn; from `docs/superpowers/research/2026-06-11-multi-agent-harnesses.md` rec 4).
**Goal:** A small work-ledger effect (`record`, `claim`, `complete`, `listReady`) with an in-memory test interpreter and a file-backed app interpreter, orthogonal to Spawn.

**Scope:** new `src/Crucible/Ledger.hs`; `test/Spec.hs`; `app/Main.hs`; new `docs/ledger.md`. No change to existing modules.

## What problem this solves

When more than one agent (or more than one session of the same agent) works
toward a shared goal, they need a single place that answers "what is left to do,
and who is doing it." Without one, agents re-do work another already finished,
two agents grab the same task, and progress made in one session is invisible to
the next. The harness research found this is exactly the part that survives in
practice (Gas Town runs on a shared ledger), and that the value is in a few
properties, not a product: the record of work must outlive a single session and
must let independent writers claim items without colliding. crucible has no such
seam today; a `Spawn` orchestrator can fan out workers but has nowhere to track
what has been handed out or completed across runs. This effect is that seam: a
typed, append-only ledger of work items with a compare-and-set claim, so an
orchestrator (or a human, or a cron job) can record work once, hand each item to
exactly one worker, mark it done, and ask for what remains, with the live record
sitting in a git-diffable file that the next session reads back. It is
deliberately small and decoupled from Spawn so it serves any caller, not just
subagents.

## Motivation

The research's rec 4 is "a work ledger effect, not a tracker": a small effect
with an in-memory interpreter for tests and a file-backed one for apps. The
lesson from beads is about properties (outlive sessions, tolerate concurrent
writers), which are interpreter concerns, not about shipping a tracker product;
a bd-backed interpreter belongs in an example or a separate package. The effect
is structurally the same shape as `Crucible.Memory`: an event-sourced log,
appended on write and folded on read, with a pure interpreter for tests and a
JSONL file interpreter for apps.

## Decisions taken during design

- **Flat readiness.** An item is `Ready` when it has been recorded and is
  neither claimed nor completed; `listReady` returns those in record order.
  There is no dependency graph. This matches the research's "small effect" and
  the Memory module's shape; dependency-gated readiness is a non-goal.
- **Claim is a compare-and-set.** `claim wid who` succeeds (returns `True`,
  appends a `Claimed` event) only when the item is currently `Ready`; an
  already-claimed, completed, or unknown id returns `False`. This is what stops
  two workers taking the same item.
- **Text payload.** A work item carries a `Text` payload, like a `Memory`'s
  content; structured work data is encoded through a codec to `Text` by the
  caller. No tags or priority fields (YAGNI).
- **Event-sourced, two interpreters.** `runLedgerState` (in-memory, for tests,
  returns the final ledger for assertions) and `runLedgerFile` (a JSONL event
  log, for apps, outlives sessions). The file interpreter's read-fold-append is
  not atomic across processes; true concurrent claim needs a real backend, which
  is an interpreter concern and out of core.

## Design (`Crucible.Ledger`)

```haskell
newtype WorkId = WorkId Int
  deriving (Eq, Show)

data WorkState = Ready | Claimed | Done
  deriving (Eq, Show)

data WorkItem = WorkItem
  { wid      :: WorkId
  , payload  :: Text         -- ^ the work description (structured data via a codec to Text)
  , state    :: WorkState
  , claimant :: Maybe Text   -- ^ who holds it (Nothing until claimed)
  }
  deriving (Eq, Show)

data Ledger :: Effect where
  Record    :: Text -> Ledger m WorkId         -- ^ add a Ready item, return its id
  Claim     :: WorkId -> Text -> Ledger m Bool  -- ^ claimant; True iff it was Ready
  Complete  :: WorkId -> Ledger m ()            -- ^ mark Done (no-op on unknown/Done)
  ListReady :: Ledger m [WorkItem]              -- ^ items currently Ready, in record order
type instance DispatchOf Ledger = Dynamic

record    :: (Ledger :> es) => Text -> Eff es WorkId
claim     :: (Ledger :> es) => WorkId -> Text -> Eff es Bool
complete  :: (Ledger :> es) => WorkId -> Eff es ()
listReady :: (Ledger :> es) => Eff es [WorkItem]

-- In-memory interpreter (tests): returns the result and the final ledger
-- (every item, in record order, any state) for assertions.
runLedgerState :: Eff (Ledger : es) a -> Eff es (a, [WorkItem])

-- File interpreter (apps): a JSONL event log appended on write and folded on
-- read. Outlives sessions. Single-writer: read-fold-append is not atomic across
-- processes, so concurrent Claim from separate processes can both observe Ready.
runLedgerFile :: (IOE :> es) => FilePath -> Eff (Ledger : es) a -> Eff es a
```

### State semantics

- `record p` appends `Recorded wid p` with `wid` the count of prior `Recorded`
  events; the item starts `Ready` with `claimant = Nothing`.
- `claim wid who`: fold the log; if `wid` is `Ready`, append `Claimed wid who`
  and return `True`; otherwise return `False` (already `Claimed`, `Done`, or
  unknown).
- `complete wid`: append `Completed wid`; folding sets the item `Done`. A
  `Completed` for an unknown id folds to nothing (no item to mark); completing
  an already-`Done` item is a no-op.
- `listReady`: the folded items whose state is `Ready`, in record order.

### Event log (file format)

```haskell
data LedgerEvent
  = Recorded  WorkId Text   -- {"event":"recorded","id":N,"payload":"..."}
  | Claimed   WorkId Text   -- {"event":"claimed","id":N,"by":"..."}
  | Completed WorkId        -- {"event":"completed","id":N}
```

Folding builds the current `WorkItem` per id: `Recorded` -> `Ready` with the
payload; `Claimed who` -> `Claimed` with `claimant = Just who`; `Completed` ->
`Done`. Codecs (`WorkId`, `WorkState` is not serialized directly since state is
derived from events, `WorkItem` for any future needs, and `LedgerEvent` tagged
on `event`) use the `Crucible.Codec` facade, mirroring `Crucible.Memory`'s
`entryCodec`. Reads tolerate blank or garbled lines (skipped), as `runMemoryFile`
does.

## Demo (`app/Main.hs`)

A small ledger flow needing no API key: under a temp `runLedgerFile` path,
`record` two items, `claim` the first as `"worker-1"` (prints `True`), `complete`
it, then `listReady` and print the remaining item's payload. Demonstrates the
file-backed, session-outliving ledger and the compare-and-set claim. Place it in
the key-gated block alongside the other demos for consistency (it does not use
the key).

## Manual (`docs/ledger.md`, new page, nav_order 13)

The `WorkItem`/`WorkState` model; the `Ledger` effect and its four operations;
the compare-and-set `claim` (one worker per item); the two interpreters
(`runLedgerState` for tests, `runLedgerFile` for apps); the outlives-sessions
property and the single-writer concurrency caveat (a real backend, e.g. a
bd-backed interpreter, is an application concern); and that the ledger is
independent of Spawn (any caller can use it). House style: no emdashes/endashes,
no hype words, no manifest mentions.

## Testing (hermetic)

`runLedgerState`:
- `record` returns sequential ids (`WorkId 0`, `WorkId 1`); both appear in
  `listReady` in record order.
- `claim w "worker-1"` on a `Ready` item returns `True`; the item's folded state
  is `Claimed` with `claimant = Just "worker-1"` and it drops from `listReady`.
- A second `claim` of the same item returns `False`.
- `claim` of an unknown id returns `False`.
- `complete w` sets the item `Done` and removes it from `listReady`.
- The returned final ledger reflects the end states of all items.

`runLedgerFile` (temp file via `openTempFile`/`removeFile`, as the Memory tests
do):
- **Outlives sessions:** `record` two items in one `runLedgerFile` call; in a
  separate `runLedgerFile` call on the same path, `listReady` returns both
  (state survived the interpreter boundary).
- A `claim` in one call is visible (state `Claimed`, dropped from `listReady`) in
  a later call on the same path.

Codec:
- The `LedgerEvent` codec round-trips each constructor and rejects an event tag
  missing a required field.

Live: the demo ledger flow before merge (no key needed).

## Non-goals

- Dependencies or ordering beyond record order.
- Priorities, due dates, assignee-based queries, or search.
- Cross-process atomic claim (the file interpreter is best-effort single-writer;
  a real backend handles true concurrency).
- A bd-backed interpreter in core (it belongs in an example or a separate
  package).
- Typed payloads in the effect (the payload is `Text`; callers encode through a
  codec, as with `Memory`).
- Reopening or unclaiming items (no `Unclaim`/`Reopen` in this release).
