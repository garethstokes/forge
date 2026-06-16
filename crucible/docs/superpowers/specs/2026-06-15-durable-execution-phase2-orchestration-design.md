# Durable Execution — Phase 2: Orchestration (`Crucible.Workflow`) — Design

**Date:** 2026-06-15
**Status:** Committed spec — **pending your review** (esp. the scope decision) before plan/build
**Bead:** `crucible-7mt` (epic `crucible-w0k`). Depends on Phase 1 (`crucible-03x`, shipped).
**Design basis:** `docs/superpowers/specs/2026-06-15-durable-execution-design.md` (the `Workflow` effect section).

## The problem this solves

Phases 0–1 give durable activities + crash→resume. Phase 2 adds the
**determinism sandbox**: a `Crucible.Workflow` effect through which a workflow
obtains *all* its non-determinism (clock, ids, timers, signals, children) so the
program is fully replayable. The headline value is **orchestration** —
timer-driven and signal-driven multi-step workflows, and child workflows — built
on the journal + worker.

## The `Crucible.Workflow` effect

```haskell
data Workflow :: Effect where
  Now          :: Workflow m UTCTime                 -- journaled clock
  NewId        :: Workflow m Text                    -- journaled unique id
  DurableSleep :: Int        -> Workflow m ()        -- seconds; journaled timer (suspends)
  AwaitSignal  :: Text       -> Workflow m ByteString-- blocks on an external append (suspends)
  ExecuteChild :: Text -> ByteString -> Workflow m ByteString -- child workflow type+input; result journaled (suspends)
  RetryN       :: Int -> Eff es a -> ...             -- bounded retry (see "Retry", below)
type instance DispatchOf Workflow = Dynamic
```

(`Retry` in the design doc is higher-order — `RetryPolicy -> m a -> m a`. Modeled
here as a plain combinator over the journal rather than an effect constructor, to
avoid effectful higher-order-effect plumbing; see below.)

### Keying: orchestration prims are call-indexed (not content-keyed)

Domain activities are content-keyed (Phase 0, to tolerate code change). The
orchestration prims have little/no content (`Now`, `DurableSleep 5`), so they are
keyed by **call index** — a per-execution counter the interpreter threads
(`State Int`). The Nth `Workflow` primitive gets key `("now"/"sleep"/…, n)`. This
is sound because workflow *control flow* is deterministic across replay (changing
it is a genuine workflow-version change, not the localized code-change the
content-keying tolerates). This mirrors Temporal's command sequence.

## Journaled determinism (the non-suspending prims)

`Now`/`NewId`/`Retry` need **no suspension** — they journal a value (or outcome)
on first run and replay it:

- `Now` → on first run record the current `UTCTime` (encoded); on replay return
  the recorded value. Deterministic clock.
- `NewId` → record a freshly generated id; replay returns it.
- `Retry n act` → run `act`; on failure retry up to `n` times; journal the final
  successful result (the inner activity's own journal entry suffices). Backoff is
  in-process here; *durable* backoff (sleeping across a crash) needs `DurableSleep`
  → that variant is part of the suspending tier.

These reuse the Phase 0/1 `record`/`replay` (or `recordTo`/`replayFrom`) directly,
under a `Workflow` interpreter that threads the call-index counter. No worker or
schema change. **Testable with the in-memory `JournalStore`.**

## Suspension (the suspending prims — the crux)

`DurableSleep`/`AwaitSignal`/`ExecuteChild` cannot run to completion in one pass —
they must **suspend** the execution and resume it when an external event fires.

**The model (Temporal/durable-execution standard, in our idiom):**
1. On encountering a suspending prim, the interpreter checks the journal for that
   call-index key:
   - **present** (we're resuming, the event already fired) → decode + return the
     value (timer: `()`; signal: the bytes; child: the result). Continue.
   - **absent** (first encounter) → **register the wait** (a `wait` row: kind +
     wake_at / signal_key / child_id) and **`throwError (Suspended waitspec)`**.
2. The worker's `runOnce` catches `Left (Suspended w)` (a new effect in the stack,
   `Error Suspended`), persists the wait + sets `run_queue.state='waiting'` (not
   done, not ready), releases the claim. **Not** completed.
3. A **driver** fires the wait and makes the execution claimable again, appending
   the result entry the prim will find on replay:
   - **timers** — a `fireDueTimers` worker step: any `waiting` execution whose
     timer `wake_at <= now` gets a `("sleep", n)` journal entry appended and
     `run_queue.state='ready'`.
   - **signals** — `deliverSignal execId key payload`: append a `("signal", n)`
     entry with the payload, set `ready`.
   - **children** — `ExecuteChild` enqueues a new `workflow_execution` (+ ready
     run_queue row) tagged with its parent; on the child's completion the worker
     appends the child's result as the parent's `("child", n)` entry and sets the
     parent `ready`.
4. The next `runOnce` claims the now-ready execution, **replays to the suspend
   point** (all prior prims hit their journal entries — no side effects re-run),
   the suspending prim now finds its result entry → returns → the workflow
   continues (possibly to the next suspend, or completion).

New store surface: a `wait` table (or columns on run_queue), `fireDueTimers`,
`deliverSignal`, child enqueue + completion-propagation; the worker gains a
`waiting` state + the `Error Suspended` catch + the driver steps.

## Decomposition (this phase is large — two tiers)

- **2a — journaled determinism:** the `Crucible.Workflow` effect + `Now`/`NewId` +
  an in-process `Retry`, interpreted over the existing journal (call-indexed),
  **no suspension, no worker/schema change.** Ships a replayable clock/id/retry;
  validates the Workflow-effect-journaled pattern. Low risk, in-memory-testable.
- **2b — suspension + orchestration:** the `Error Suspended` model + the
  `waiting` state + `DurableSleep` (+ timer driver), then `AwaitSignal` (+ signal
  delivery), then `ExecuteChild` (+ child lifecycle). The heavy, novel part;
  needs the new store surface and ephemeral-pg crash/suspend tests.

2a is a clean, shippable slice that de-risks the effect + keying before the
suspend machinery. 2b is where the real orchestration lives and is itself
internally orderable (sleep → signal → child).

## Testing
- 2a: in-memory `JournalStore` — `Now`/`NewId` record-then-replay return the same
  value; `Retry` journals the successful result; call-index keying is stable.
- 2b: ephemeral Postgres — a workflow that `DurableSleep`s suspends (state
  `waiting`), `fireDueTimers` requeues it, resume returns and completes; a signal
  unblocks `AwaitSignal`; a child's result flows into the parent. Crash mid-wait
  resumes correctly.

## Out of scope / open
- A background timer/heartbeat thread + a real multi-worker poll loop (Phase-1
  `runOnce` is single-shot) — Phase 2b uses explicit driver calls in tests; a
  daemon loop is a later refinement.
- Intent/result exactly-once (`crucible-8bt`) is orthogonal and still deferred.
- `RetryPolicy` richness (backoff curves, durable backoff via `DurableSleep`) —
  start with bounded immediate retry.

## The scope decision for you
Phase 2 is big. Options for THIS cycle:
1. **2a only** — Workflow effect + Now/NewId/Retry (journaled determinism); 2b
   (suspension/orchestration) as the next cycle. Smaller, low-risk, ships the
   effect foundation but not the timer/signal/child orchestration.
2. **2a + 2b(DurableSleep)** — the above plus the suspend model + durable timers
   (the first real orchestration: suspend-and-resume on a timer). Medium.
3. **Full Phase 2** — 2a + all of 2b (sleep + signal + child). Largest; the
   complete orchestration phase in one go.
