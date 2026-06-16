# Concurrent Spawn Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-qyc` (follow-on to `crucible-pch`, Spawn; from `docs/superpowers/research/2026-06-11-multi-agent-harnesses.md` rec 5).
**Goal:** Run independent subagent spawns concurrently, without changing the `Agents` effect, with a thread-safe shared budget and a safe coordination story.

**Scope:** `src/Crucible/Agents.hs` (atomic budget + a `spawnAll` combinator); `test/Spec.hs`; `app/Main.hs`; `docs/subagents.md` (a "Concurrent spawn" section). No change to the `Agents`/`Spawn`/`SubAgent`/`spawn` API.

## What problem this solves

When an orchestrator has several independent subtasks (read three documents,
check five sources, summarize four threads), running them one after another
wastes wall-clock time: each waits for a slow model call before the next starts.
Running them at once collapses that to the slowest single task. But naive
parallel fan-out is also where multi-agent systems fail most: siblings that
share mutable state make conflicting decisions, an unbounded fan-out multiplies
the token bill, and a single sibling error can take down the batch. This work
gives bounded, isolated, typed parallel fan-out. `spawnAll` runs a batch of
spawns concurrently; each worker keeps the foundation's isolated transcript and
returns its own typed `Either AgentFailure o`, so siblings never share state; a
single atomic budget caps the whole tree so concurrency cannot over-spend; and a
worker failure is a value, not a thrown exception, so one bad sibling does not
silently kill the rest. It is the synchronous spawn made parallel where the
subtasks are genuinely independent, with the coordination hazards designed out.

## Motivation

The foundation's `runAgents` is synchronous and its budget is a non-atomic
read-then-write `IORef`, which races under concurrency. The bead asks for
concurrency "without changing the `Agents` effect". The realization: make the
budget a compare-and-set so the existing interpreter is safe under concurrent
dispatch, and add a fan-out combinator built on effectful's `Concurrent`
(`mapConcurrently`). No new effect, no new interpreter; the one synchronous
interpreter becomes concurrency-safe and a combinator opts callers into
parallelism.

## Decisions taken during design

- **Atomic budget, not a second interpreter.** `runAgents`'s budget becomes a
  compare-and-set (`atomicModifyIORef'`); sequential behavior is unchanged, and
  concurrent spawns can no longer over-spend. No `runAgentsConc`.
- **Caller-driven concurrency via `spawnAll`.** A combinator `mapConcurrently`s
  over `spawn`, so the `Agents` effect and `spawn` are untouched. Concurrency is
  opt-in: synchronous callers keep using `spawn`.
- **No shared sibling state.** Each worker is an isolated transcript returning
  its own typed result. There is no blackboard, no cross-sibling channel. This
  is the antidote to the uncoordinated-sibling failure mode.
- **Failures are values; exceptions cancel.** A worker `AgentFailure` is a `Left`
  and does not cancel siblings (the batch returns every result). A worker that
  throws (for example a live provider error) cancels the siblings and rethrows,
  the standard `async` semantics.
- **One shared tree budget.** The atomic counter is shared across the whole tree
  (concurrent or nested); with `cap < N` exactly `cap` spawns succeed and the
  rest return `SpawnBudgetExceeded`. The success/fail count is deterministic
  even when the order is not.

## Design (`Crucible.Agents`, evolved)

```haskell
-- New export: a concurrent fan-out over spawn.
spawnAll :: (Agents es :> r, Concurrent :> r)
         => [(SubAgent es i o, i)] -> Eff r [Either AgentFailure o]
spawnAll = mapConcurrently (uncurry spawn)
```

`Concurrent` and `mapConcurrently` come from `Effectful.Concurrent` /
`Effectful.Concurrent.Async` (in the `effectful` package). Results are in input
order. The batch is homogeneous (one `i`/`o` pair across the list); a
heterogeneous fan-out uses `mapConcurrently` directly with the `Concurrent`
effect (documented).

### Atomic budget (the only change to `runAgents`)

Replace the non-atomic read-then-write with a compare-and-set claim:

```haskell
claimSlot :: IORef Int -> IO Bool
claimSlot ref = atomicModifyIORef' ref (\r -> if r <= 0 then (r, False) else (r - 1, True))
```

In the handler:

```haskell
Spawn sub i -> do
  claimed <- liftIO (claimSlot ref)
  if not claimed
    then pure (Left (SpawnBudgetExceeded cap))
    else do
      res <- go (runToolAgentN sub.maxIters sub.tools (workerPrompt sub i))
      pure $ case res of
        Left (ToolLoopExceeded n) -> Left (WorkerLoopExceeded sub.name n)
        Right finalText           -> decodeFinal sub finalText
```

This preserves the exact sequential semantics (a single caller sees the same
behavior as before) and makes the interpreter safe under concurrent dispatch.
`runAgentsScripted` is unchanged.

### Dependency

`spawnAll` imports `Effectful.Concurrent.Async (mapConcurrently)` and
`Effectful.Concurrent (Concurrent)`, both in the `effectful` package (already a
dependency). If the build needs `async` declared explicitly (a transitive of
effectful), add it to the library `depends`; otherwise no dependency change.

## Spike (de-risk first)

The interpreter stack for a concurrent test is
`runEff . runConcurrent . runChatScripted . runAgents`, which mixes `Concurrent`
with `runChatScripted`'s thread-local `State` (a forked worker gets a clone of
the script at fork time). The plan's first task is a spike: confirm `spawnAll`
runs over a scripted `Chat` under `runConcurrent` with the atomic budget
enforced, before tests and demo. If that stack does not work cleanly, the
fallback is a direct deterministic unit test of `claimSlot` plus proving real
parallelism only in the live demo; the implementer reports which path held.

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block, under `runConcurrent`: `spawnAll` three weather
workers for three cities at once and print the three summaries. Shows parallel
siblings with live concurrent provider calls and one shared budget. Stack:
`runEff (Concurrent.runConcurrent (Anthropic.runChat cfg (runAgents 6 (spawnAll pairs))))`
(confirm the interpreter order compiles; the plan resolves the exact nesting).

## Manual (`docs/subagents.md`)

A "Concurrent spawn" section: `spawnAll`, that callers discharge `Concurrent`
with `Effectful.Concurrent.runConcurrent`, the shared atomic budget across the
tree, failures-are-values (siblings independent, no cancellation) versus a
thrown worker exception (cancels siblings, `async` semantics), and that siblings
share no state. Remove "concurrent spawn" from "What is not covered" (it now
exists). House style: no emdashes/endashes, no hype words, no manifest mentions.

## Testing (hermetic)

The atomic budget gives a deterministic success/fail count even under
concurrency. Using `runEff (runConcurrent (runChatScripted [...] (runAgents cap
(spawnAll pairs))))` (forked workers each clone the script, so identical canned
answers are deterministic):

- **All succeed:** `spawnAll` of N workers with `cap >= N` and a canned answer
  returns N `Right`s in input order, each decoded from the canned answer.
- **Budget caps the batch:** `spawnAll` of N workers with `cap < N` returns
  exactly `cap` `Right`s and `N - cap` `Left (SpawnBudgetExceeded cap)` (the
  count is deterministic; which spawns fail is not asserted).
- **Atomic claim (deterministic core):** a direct test of the budget claim (run
  many claims against a small cap and count successes) if the concurrent-over
  -scripted stack proves unworkable; otherwise the budget-caps-the-batch test
  covers it.

If the spike shows the concurrent-over-scripted stack does not work, keep the
direct `claimSlot` count test (deterministic) and move the all-succeed/budget
demonstrations to the live demo, and say so in the test comments.

Live: the concurrent weather fan-out demo before merge (gated on the Anthropic
key).

## Non-goals

- A second interpreter (`runAgentsConc`); the one interpreter is made atomic.
- Changing the `Agents` effect, `spawn`, or `SubAgent`.
- Structured cancellation policies beyond `async`'s defaults.
- Streaming partial results as siblings finish (the batch returns when all do).
- Cross-sibling communication (blackboard, shared memory, debate); siblings are
  independent by design.
- Per-sibling or per-depth budgets (one shared total-spawn budget).
