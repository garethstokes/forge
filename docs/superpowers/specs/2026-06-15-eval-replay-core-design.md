# Eval Flywheel Core (replay-to-eval + ddmin) — Design

**Date:** 2026-06-15
**Status:** Committed spec
**Bead:** `crucible-ymd` (Phase 3) — **core slice in crucible**; the manifest-evals
consumer (promotion, dataset, RunMetric tracking, CLI, executeRun capture) is the
handed-off remainder (needs a crucible pin bump + schema/effect-stack changes —
out of scope for this slice).

## The problem this solves

Phase 0 gave per-op replay (`replayFrom` → `ReplayOutcome (Replayed | Diverged)`).
The eval flywheel needs two reusable pieces on top, both domain-agnostic and
self-contained (no Postgres, no manifest-evals): (1) **collect the divergences**
surfaced while replaying changed code against a captured journal (the eval signal),
and (2) **minimize** a failing input/journal to its simplest reproduction (ddmin).
These belong in crucible (alongside `Crucible.Journal` + `Crucible.Eval`); the
manifest-evals consumer then wires them to datasets/metrics.

## API (`Crucible.Eval.Replay`)

```haskell
-- divergences surfaced during a replay-to-eval run (Signal mode), in order.
runReplayEval :: Eff (State [Divergence] : es) a -> Eff es (a, [Divergence])

-- record a divergence (used by an app's replay interpreter).
noteDivergence :: (State [Divergence] :> es) => Divergence -> Eff es ()

-- settle a per-op ReplayOutcome: record the divergence (if any), return the value.
-- An app's replay interpreter does:  replayFrom j Signal k dec live >>= settle
settle :: (State [Divergence] :> es) => ReplayOutcome a -> Eff es a

-- delta-debugging minimizer (Zeller ddmin): the smallest sub-list of `xs` for which
-- the monadic oracle still returns True (e.g. "the grader still fails" / "still
-- reproduces"). Used to reduce jiInput or a journal's entries to a minimal repro.
ddmin :: Monad m => ([a] -> m Bool) -> [a] -> m [a]
```

- `runReplayEval`/`settle`/`noteDivergence` are the **replay-to-eval** seam: an app
  replays a captured journal with `MissPolicy = Signal` (per the design doc — a miss
  is the measurement), and every `Diverged` is collected as a first-class output.
  The eval result is `(replayed output, [Divergence])`; the output is then graded
  reference-free by the existing `Crucible.Eval`/`Crucible.Eval.Judge`.
- `ddmin` is the standard delta-debugging algorithm (granularity-doubling), oracle
  = "still reproduces"; returns a 1-minimal failing sub-list.

## Scope

**IN:** `Crucible.Eval.Replay` (the four functions above) + a hermetic test proving
(a) replay of *changed* code against a captured in-memory journal collects exactly
the diverged ops, and (b) `ddmin` reduces to the minimal reproducing subset.

**OUT (handed off — manifest-evals consumer):** journal→`Example` promotion;
journal capture inside `executeRun`; `RunMetric` `app_version × tool_policy`
tracking; CLI `replay`/`compare`; the crucible pin bump. These need manifest-evals
schema + effect-stack changes and a pin bump (finicky), so they are their own
cycle — see the handoff note on `crucible-ymd`.

## Testing (hermetic, in `test/Spec.hs`)
- **replay-to-eval:** a tiny domain effect with a replay interpreter using
  `replayFrom j Signal … >>= settle`; record a journal with "original" code, replay
  a "changed" program (an extra/different op) under `runReplayEval` → assert the
  returned output AND that `[Divergence]` contains exactly the changed op's key.
- **settle:** `settle (Replayed a)` adds nothing; `settle (Diverged d a)` records `d`
  and returns `a`.
- **ddmin:** oracle "the subset contains element X" over `[1..8]` → `[X]`; oracle
  "sum ≥ k" → a minimal subset reaching k; empty/already-minimal inputs are no-ops.

## Risks
- **ddmin correctness** — implement the standard algorithm carefully (granularity n
  starts at 2, test subsets then complements, increase n up to |xs|, stop when n >
  |xs|); the test pins it with deterministic oracles.
- **Scope honesty** — this is the flywheel *core*, not the full manifest-evals
  consumer; the bead handoff says so explicitly.
