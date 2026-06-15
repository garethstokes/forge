# Durable Execution — Phase 1: Durable Store + Worker — Design

**Date:** 2026-06-15
**Status:** Committed spec — **pending your review** before plan/build
**Bead:** `crucible-03x` (under epic `crucible-w0k`). Depends on Phase 0 (`crucible-9t3`, shipped).
**Design basis:** `docs/superpowers/specs/2026-06-15-durable-execution-design.md` (Phase 1 + the architecture/exactly-once sections).

## The problem this solves

Phase 0 gave a pure, in-memory `Journal` + `record`/`replay`. Phase 1 makes it
**durable and recoverable**: a workflow's journal is persisted in Postgres, a
worker runs the program backed by that store, and if the worker dies mid-run a
fresh worker reclaims the execution and **replay-to-resumes** — rebuilding
in-flight state from the journal and continuing past the head, with at most the
uncommitted tail lost. End state (the acceptance): *a workflow survives a worker
kill and resumes, re-running nothing it had already committed.* Single workflow
type; orchestration (timers/signals/children) is Phase 2.

## Decisions resolved here

- **Q5 — worker package home → `crucible-worker`, a new workspace member** of the
  crucible repo (path-deps `crucible`, git-pins `manifest`), exactly like
  `crucible-manifest`. It is the bridge that knows both the substrate and the
  store. (Rejected: manifest-side — wrong layer, manifest knows no effects;
  app-level — every app would re-implement the loop.)
- **Q1 — exactly-once → intent/result + idempotency key**, with an honest
  at-least-once tail for un-keyable side effects (per the design doc). See
  "Exactly-once" below. In Phase 1 we build the intent/result discipline and the
  per-activity *activity-kind* annotation; the un-keyable residual is documented
  as at-least-once (no fabricated guarantee).
- **Journal composition → an IO `JournalStore` thick handle** (the bead's "IO
  journal sink"), mirroring the persistence epic's `MemoryStore`/`LedgerStore`
  pattern. crucible gains a store-backed journaling path; the Postgres
  implementation lives in the satellite. The pure `State Journal` path from Phase
  0 stays for tests and the eval (in-memory) consumer.

## Layer A — crucible: IO journal sink + clock (additions to `Crucible.Journal`)

Phase 0's `record`/`replay` are over `State Journal` (pure). Phase 1 adds a
store-backed path so a journal can live in Postgres without crucible knowing about
Postgres:

```haskell
-- a thick handle: one IO action per journal operation (the seam, à la MemoryStore)
data JournalStore = JournalStore
  { jsLoad   :: IO Journal                         -- full journal for an execution (replay source)
  , jsAppend :: CassetteKey -> Entry -> IO ()      -- durable append (one entry)
  , jsIntent :: CassetteKey -> Text -> IO ()       -- record an activity 'intent' (exactly-once, below)
  }

-- IO-backed record/replay over a store (the durable analogues of the State ones).
recordTo  :: (IOE :> es) => JournalStore -> CassetteKey -> (a -> ByteString) -> Eff es a -> Eff es a
replayFrom:: (IOE :> es) => JournalStore -> Journal -> MissPolicy -> CassetteKey
          -> (ByteString -> Either Text a) -> Eff es a -> Eff es (ReplayOutcome a)
```

- `recordTo` runs the action, `jsAppend`s the encoded result, returns it (durable
  capture). `replayFrom` serves from the already-loaded `Journal` (a worker loads
  once per claim) and on a miss applies the policy; in **replay-to-resume** the
  policy is `Fallthrough` (replay to head, run live past it) and the live
  fallthrough is itself a `recordTo` so past-head progress is persisted.
- `JournalIdentity` gains `jiCapturedAt :: Text` (ISO-8601), set when the
  execution is first recorded (Phase 0 omitted it — no clock; Phase 1 has one).
  This is a Phase-0-format change → bump the wire codec; journals are not yet in
  production so no migration burden.
- crucible ships an **in-memory `JournalStore`** (over an `IORef Journal`) so the
  store-backed path is testable without Postgres, and so the eval consumer
  (Phase 3) can use it.

## Layer B — the durable store (manifest-backed, in `crucible-manifest`)

New Postgres tables (HKD entities + `migrateUp`, the shipped pattern). Stored in
`crucible-manifest` (it already bridges crucible↔manifest and has the
ephemeral-pg test rig):

- **`workflow_execution`** — `(id serial PK, workflow_type text, input bytea/jsonb,
  app_version text, captured_at text, status text)` where status ∈
  `running|completed|failed`. One row per execution; carries `JournalIdentity`.
- **`journal_entry`** — `(id serial PK, execution_id → workflow_execution, seq int,
  cassette_key bytea, op text, result bytea, kind text)` — the persisted entries.
  `jsLoad` selects by `execution_id` ordered by `seq`; `jsAppend` inserts one.
- **`run_queue`** — `(execution_id PK, state text [ready|claimed|done], claimant
  text null, lease_until text null)` — the worker work-list. `state=ready` rows
  are claimable.
- **claim-with-lease** — reuse the Ledger CAS pattern (`execDb "UPDATE run_queue
  SET state='claimed', claimant=$1, lease_until=$2 WHERE execution_id=$3 AND
  state='ready' RETURNING execution_id"`); non-empty = claimed. **Heartbeat**
  extends `lease_until`; **reclaim** = a `ready`-or-expired-lease row another
  worker can claim (lease comparison in SQL).
- **transactional append+transition** — `jsAppend` + the run_queue progress update
  in one `withTransaction` (the DBOS guarantee: a crash never leaves an entry
  without its queue advance, or vice-versa).

`journalStoreManifest :: Pool -> ExecutionId -> JournalStore` wires the handle to
these tables for one execution.

## Layer C — `crucible-worker` (new package): the engine

The claim/run/heartbeat/recover loop:

1. **Poll** `run_queue` for a claimable row (ready, or claimed with expired lease).
2. **Claim** via CAS-with-lease (reuse Ledger CAS).
3. **Load** the execution's journal (`jsLoad`).
4. **Run** the workflow program under `runError` + the store-backed journaling
   interpreter in **replay-to-resume** mode (`Fallthrough`): entries up to the
   head replay (no side effects re-run); past the head, activities run live and
   `recordTo` persists each.
5. **Heartbeat** (extend lease) — in Phase 1, between activities (a background
   heartbeat thread is a refinement, noted).
6. **On completion** mark `workflow_execution.status=completed`, `run_queue.state=done`.
7. **Recover** = step 1 naturally reclaims an execution whose worker died (lease
   expired); step 4 replays the persisted journal and continues. This *is* the
   crash-recovery path — no special code.

The worker is generic over a `WorkflowDef` (input type, output type, the program
`input -> Eff (… : IOE) output`); Phase 1 ships one example def for the test.

## Exactly-once (the crux — Q1)

- **Transactional journaling** gives exactly-once for the *journal+queue* writes
  (one txn).
- **The activity's own side effect is not transactional with its journal.**
  Adopt **intent-then-result**: `recordTo` first `jsIntent`s a row (key, started),
  performs the effect, then appends the result. On resume, if intent is present
  but result absent, the activity *may* have run — policy by **activity kind**
  (crucible exposes the annotation; the app declares it per op):
  - **idempotent** → re-run safely;
  - **non-idempotent + keyable** → pass an **idempotency key** derived from the
    `CassetteKey` so the downstream dedupes;
  - **un-keyable** → at-least-once, marked (no fabricated guarantee).
  Phase 1 builds the intent/result rows + the activity-kind annotation and the
  idempotent / keyable paths; the un-keyable tail is documented, not solved.

## Phase 1 slice boundary (what's IN vs deferred)

**IN:** the three tables + migrations; `journalStoreManifest`; the IO
`recordTo`/`replayFrom` + in-memory `JournalStore` in crucible; the
`crucible-worker` claim/run/heartbeat/recover loop for **one** example workflow
type; intent/result exactly-once (idempotent + keyable); an **ephemeral-Postgres
test that simulates a crash** (run a workflow partway recording activities, drop
the in-memory runtime, reclaim with a fresh worker, assert it resumes — replaying
the pre-crash activities (side effects NOT re-run) and completing).

**DEFERRED (Phase 2/3):** `Crucible.Workflow` orchestration (timers, signals,
children, retry, journaled now/newId); a real multi-process worker pool + a
background heartbeat thread; the eval consumer.

## Testing

Hermetic where possible; the durable path needs ephemeral Postgres (in
`crucible-manifest`/`crucible-worker` tests, which already have the rig):
- store: append→load round-trips ordered entries; claim-with-lease CAS (second
  claim fails; expired lease reclaimable); transactional append+transition.
- crash/resume: the simulated-crash test above — the acceptance.
- crucible: the in-memory `JournalStore` + `recordTo`/`replayFrom` round-trip,
  pure-ish (IORef) — proves the store-backed path independent of Postgres.

## Risks / open
- **Worker package needs Postgres in its devshell** — mirror the flake change
  crucible got for crucible-manifest.
- **"Crash" in a hermetic test is simulated** (drop in-memory state + reclaim),
  not a real process kill — faithful to the recovery logic (reload-from-journal),
  noted as not exercising OS-level process death.
- **Heartbeat granularity** — between-activities in Phase 1; a background thread
  is the production refinement.
- **Decomposition** — this is large; the plan will likely split into (1) the
  manifest store + crucible IO sink, then (2) the crucible-worker loop + crash
  test. Flagged for the planning step.
