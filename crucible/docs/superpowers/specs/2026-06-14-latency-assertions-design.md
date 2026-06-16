# Latency Assertions Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-czs` (from the BAML review, item 7; ranked last, low priority, filed for completeness).
**Goal:** Let a test measure and assert the wall-clock latency of a live skill or eval call, without contaminating the pure eval path.

**Scope:** new `src/Crucible/Eval/Latency.hs`; `test/Spec.hs`; `app/Main.hs`; `docs/evals.md` (a Latency section). No change to `Crucible.Eval`, `runEval`, `testSkill`, or `Report`.

## Motivation

BAML test asserts can reference `latency_ms`. crucible has no latency axis. The
constraint is that latency is only meaningful under a live interpreter: a
scripted or cassette run returns near-instantly, so a wall-clock assertion
there is noise. The eval runner is also pure (`LLM`/`Embed`, no `IOE`), and
`manifest-evals` depends on `runEval`/`scoreN`, so threading timing through the
core would be a breaking change for a low-priority feature. The design is a
small standalone utility that times any effectful action and offers budget
predicates, gated on `IOE` so it cannot be called under the pure interpreters.
The `IOE` constraint is itself the live-only marker; no runtime flag is needed.

## Decisions taken during design

- **Standalone, not integrated into `Report`.** Latency is orthogonal to the
  content score and stays out of `runEval`/`testSkill`/`Report`, so the pure
  eval path and `manifest-evals` are untouched.
- **Live-only by type.** `timed` requires `IOE :> es`; the scripted/pure
  interpreters have no `IOE`, so a meaningless measurement cannot be written.
- **Same clock as `CallLog`.** `GHC.Clock.getMonotonicTimeNSec`, applied at the
  effect level so it covers any `Eff` action (`call`, `converse`, `callMedia`,
  a tool-agent run), not just `Provider` chains the way `CallLog` does.
- **Budget predicates are pure.** `withinMs` and `maxLatencyMs` are pure
  functions the caller asserts in a test or demo; there is no latency-aware
  report type (YAGNI for a P4 feature).
- **Lower-bound tests only.** Hermetic tests assert `latencyMs >= 0` and, for a
  delayed action, a generous lower bound; never an upper bound (which would be
  timing-flaky on CI).

## Design (`Crucible.Eval.Latency`)

```haskell
-- | A value paired with the wall-clock milliseconds its production took.
data Timed a = Timed { value :: a, latencyMs :: Int }
  deriving (Eq, Show, Functor)

-- | Measure wall-clock milliseconds around an effectful action, using a
-- monotonic clock. Requires IOE, so it runs only under live interpreters
-- (the scripted/pure interpreters, which have no IOE, cannot call it, and a
-- near-zero scripted latency would be meaningless anyway).
timed :: (IOE :> es) => Eff es a -> Eff es (Timed a)

-- | Time an action over each input of a dataset, in order (e.g. a skill's
-- test inputs run through 'Crucible.Skill.call').
timeEach :: (IOE :> es) => (i -> Eff es a) -> [i] -> Eff es [Timed a]

-- | A single result met its budget (latencyMs <= budget).
withinMs :: Int -> Timed a -> Bool

-- | The largest latency in a batch (0 for an empty batch); a batch meets a
-- budget when @maxLatencyMs ts <= budget@.
maxLatencyMs :: [Timed a] -> Int
```

Implementation notes:
- `timed act = do { t0 <- liftIO getMonotonicTimeNSec; a <- act; t1 <- liftIO getMonotonicTimeNSec; pure (Timed a (fromIntegral ((t1 - t0) \`div\` 1000000))) }`. `getMonotonicTimeNSec :: IO Word64` from `GHC.Clock`.
- `timeEach f = mapM (timed . f)`.
- `withinMs budget t = t.latencyMs <= budget`.
- `maxLatencyMs ts = maximum (0 : map (.latencyMs) ts)` (a `(.latencyMs)` getter section under DuplicateRecordFields may need an inline type annotation; annotate and report if so).
- The `Functor` instance maps `value` and preserves `latencyMs`.

The module imports only `Effectful` (for `Eff`, `IOE`, `liftIO`, `(:>)`) and `GHC.Clock`. No dependency on `Crucible.Eval` or `Crucible.Skill`, so it composes with any action and adds no coupling.

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block: time a live `call` of an existing demo skill
through `Anthropic.run`, then print the latency and a budget check, for example
`latency: 842 ms (within 5000ms: True)`. The action runs as
`runEff (Anthropic.run cfg (timed (call someSkill someInput)))`: `Anthropic.run`
discharges `LLM`, `runEff` provides the base `IOE` that `timed` needs.

## Manual (`docs/evals.md`)

A "Latency" section near the end: that latency is a live-only axis separate from
the content score; the `Timed`/`timed`/`timeEach` API; the `withinMs`/
`maxLatencyMs` budget predicates; that the `IOE` constraint is the live-only
marker (scripted/cassette runs cannot time, by design); and a short snippet
timing a `call` and asserting a budget. House style: no emdashes/endashes, no
hype words, no manifest mentions.

## Testing (hermetic)

`withinMs` / `maxLatencyMs` (pure):
- `withinMs 100 (Timed () 50)` is `True`; `withinMs 100 (Timed () 150)` is
  `False`; the boundary `withinMs 100 (Timed () 100)` is `True`.
- `maxLatencyMs [Timed () 10, Timed () 30]` is `30`; `maxLatencyMs ([] :: [Timed ()])` is `0`.

`Functor`:
- `fmap (+1) (Timed (1 :: Int) 42)` is `Timed 2 42` (value mapped, latency kept).

`timed` (under `runEff`, which supplies `IOE`; a `check` entry is `IO Bool`, so
run the effectful program inline):
- `timed (pure (7 :: Int))` yields a `Timed` whose `value` is `7` and whose
  `latencyMs >= 0`.
- `timed (liftIO (threadDelay 50000))` (50 ms) yields `latencyMs >= 30` (a
  generous lower bound; `threadDelay` from `Control.Concurrent`). No upper-bound
  assertion.

`timeEach`:
- `timeEach pure [1,2,3 :: Int]` yields three `Timed` whose `value`s are
  `[1,2,3]` and each `latencyMs >= 0`.

Live: the demo `call` timing before merge (gated on the Anthropic key).

## Non-goals

- Aggregates beyond the max (no p50/p95/percentiles or histograms).
- Integrating latency into `Report`/`runEval`/`testSkill` (kept separate to keep
  the eval core pure and non-breaking for `manifest-evals`).
- Per-provider attribution (`Crucible.LLM.CallLog` already records per-call
  `durationMs` for `Provider`/`Fallback` chains).
- Token or cost budgets (a separate concern; `Crucible.Usage` already exists).
- Timing under scripted/cassette interpreters (meaningless; prevented by the
  `IOE` constraint).
