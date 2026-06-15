# Durable Execution — AwaitSignal + Real Env + Poll Loop — Design

**Date:** 2026-06-15
**Status:** Committed spec
**Bead:** `crucible-5gr` (epic `crucible-w0k`), scoped this cycle to **AwaitSignal +
real WorkflowEnv + poll loop**; **ExecuteChild split to a new bead** (it is the
most complex remaining primitive — child lifecycle + output propagation + parent
linkage — and warrants its own focused cycle).
**Depends on:** Phase 2a (`crucible-7mt`, shipped — the suspend/resume model).

## The problem this solves

Phase 2a shipped the suspend/resume model + `DurableSleep` (timers). This adds the
second suspending primitive — **`AwaitSignal`** (block until an external signal is
delivered) — on the same model, plus the **operational** pieces the substrate
needs to run for real: a production `WorkflowEnv` (real clock/id) and a **poll
loop** that drains the run queue and fires due timers (Phase 1/2a `runOnce` is
single-shot; tests called drivers explicitly).

## AwaitSignal (mirrors DurableSleep)

`AwaitSignal` is structurally the timer pattern with an external payload and an
external delivery trigger:

```haskell
-- effect ctor (added to Crucible.Workflow's Workflow GADT):
AwaitSignal :: Text -> Workflow m ByteString    -- signal name -> delivered payload

awaitSignal :: (Workflow :> es) => Text -> Eff es ByteString
```

- **WaitSpec** gains `WaitSignal CassetteKey Text` (the call-index key + the signal
  name).
- **Interpreter** (`runWorkflow`): `AwaitSignal name` at call-index `n` → if the
  journal has the `("signal", n)` key, return the recorded payload; else
  `throwError (Suspended (WaitSignal k name))`.
- **Worker** on `Suspended (WaitSignal k name)` → `suspendSignal pool eid k name`
  (run_queue `state='waiting'`, `wait_kind='signal'`, `wait_key=k`,
  `wait_name=name`). Not completed.
- **Delivery driver** `deliverSignal pool eid name payload`: find the execution's
  waiting-signal row matching `name`; append a `status="result"` journal entry
  under the stored `wait_key` carrying `payload`; set `state='ready'`, clear the
  wait. (Targets a specific execution + signal name.)
- **Resume**: the next `runOnce` replays to the await point; `AwaitSignal` now
  finds its entry → returns the payload → continues.

Store change: `run_queue` gains `rq_wait_name :: Maybe Text` (the signal name to
match on delivery). Everything else reuses the 2a wait machinery.

## Real WorkflowEnv

```haskell
realWorkflowEnv :: IO WorkflowEnv
```
`weNow` = `getCurrentTime` formatted with the exact `%Y-%m-%dT%H:%M:%SZ` used by
`addSeconds` (so lexical wake/lease compares stay valid); `weNewId` = a unique id
(time + a per-process counter, or a random suffix — uniqueness is all that's
needed; it's journaled so replay is deterministic regardless). Lives in
`Crucible.Workflow` (no new dep beyond `time`; avoid a uuid dep).

## Poll loop

```haskell
-- drain all currently-ready executions (run each to completion/suspension), once.
drainOnce :: Pool -> Text -> WorkflowEnv -> WorkflowDef i o -> (Int -> IO i) -> IO [RunResult o]
-- a bounded poll: fire due timers, drain, repeat up to n rounds (a test-friendly driver;
-- a daemon with threadDelay is a trivial wrapper, noted).
pollRounds :: Pool -> Text -> WorkflowEnv -> Int -> WorkflowDef i o -> (Int -> IO i) -> IO ()
```
`drainOnce` loops `runOnce` until it returns `Nothing` (queue empty), collecting
results. `pollRounds n` does `fireDueTimers (now) >> drainOnce` up to `n` times (or
until the queue is empty and no timers pending). This gives a single-process
worker loop; a real daemon is `pollRounds`/`drainOnce` under `forever`+`threadDelay`
(out of scope — the bead's "daemon" is the wrapper).

**Observability hook:** on each reclaim/drain, surface `unkeyablePending` (from
`crucible-8bt`) via the worker log — gives the exactly-once observability a runtime
consumer (addresses an 8bt review nit).

## Scope

**IN:** `AwaitSignal` (effect + interpreter + `WaitSignal`); `run_queue.rq_wait_name`;
`suspendSignal` + `deliverSignal`; `realWorkflowEnv`; `drainOnce`/`pollRounds`;
ephemeral-pg tests (signal suspend→deliver→resume; poll loop drains a timer-driven
workflow end-to-end).

**OUT (→ new bead):** `ExecuteChild` (child workflow enqueue, output propagation,
parent linkage, workflow_execution parent/result columns). A real always-on daemon
(just the `forever`+`threadDelay` wrapper).

## Testing
- crucible (in-memory): `awaitSignal "x"` on an empty journal → `Suspended
  (WaitSignal k "x")`; with the `("signal", n)` entry present → returns the payload.
- crucible-manifest (ephemeral pg): `suspendSignal` parks waiting with the name;
  `deliverSignal` with the matching name appends the payload entry + readies the
  exec; a non-matching name delivers nothing; `rq_wait_name` round-trips.
- crucible-worker (ephemeral pg): a workflow `do { p <- awaitSignal "go"; activity p }`
  → first `runOnce` suspends (waiting, activity not run); `deliverSignal pool eid
  "go" "payload"` → ready; second `runOnce` → `awaitSignal` returns "payload",
  activity runs once, completes. Plus a `pollRounds` test that drains a
  `durableSleep`-then-activity workflow across `fireDueTimers` automatically.

## Risks
- **Signal targeting** — `deliverSignal` targets (execId, name); if multiple awaits
  share a name in one execution, the call-index key disambiguates the journal entry
  but the run_queue wait holds one name at a time (an execution waits on one signal
  at a time in this model) — fine for the single-wait-at-a-time suspend model.
- **`realWorkflowEnv` id uniqueness** — journaled, so replay is deterministic;
  liveness only needs uniqueness, not cryptographic randomness.
- **ExecuteChild deferral** — clearly split to its own bead; `AwaitSignal` does not
  depend on it.
