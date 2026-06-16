# Latency Assertions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone `Crucible.Eval.Latency` module to measure and assert the wall-clock latency of a live skill or eval call.

**Architecture:** `timed` wraps any effectful action and reports its monotonic-clock duration in ms; it is gated on `IOE` so it runs only under live interpreters (the live-only marker is the type). Pure `withinMs`/`maxLatencyMs` predicates assert budgets. Nothing in `Crucible.Eval`, `runEval`, `testSkill`, or `Report` changes.

**Tech Stack:** GHC 9.12.2, effectful, GHC.Clock; zinc build (`nix develop . --command timeout -s KILL 300 zinc build|test`).

**Spec:** `docs/superpowers/specs/2026-06-14-latency-assertions-design.md`

## Conventions (every task)
- Build: `nix develop . --command timeout -s KILL 300 zinc build`. Test: `nix develop . --command timeout -s KILL 300 zinc test`. Judge success by exit status or the "test suite(s) passed" line, never a pipeline tail. Exit 137 = GHC iserv flake: retry once; second 137 = BLOCKED. Ignore the "Git tree is dirty" warning.
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot, `(.field)` access (annotate an ambiguous getter section and report it).
- Tests use the custom harness `test/Harness.hs`: `check :: (Eq a, Show a) => String -> a -> a -> IO Bool`, called `check "label" expected actual`. Entries are comma-separated in the `runChecks` list at the END of `test/Spec.hs`; each entry is an `IO Bool`, so a `do { ...; check ... }` block is a valid entry. No hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit at the end of each task; do not push.
- Modules are auto-discovered from `source-dirs`; a new module file needs no zinc.toml change.

## File Structure
- Create `src/Crucible/Eval/Latency.hs` — the `Timed` value, `timed`/`timeEach`, `withinMs`/`maxLatencyMs` (Task 1).
- Modify `test/Spec.hs` — pure + IOE timing tests (Task 1).
- Modify `app/Main.hs` — live demo (Task 2).
- Modify `docs/evals.md` — a Latency section (Task 3).

---

### Task 1: `Crucible.Eval.Latency` module + tests

**Files:**
- Create: `src/Crucible/Eval/Latency.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Create `src/Crucible/Eval/Latency.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeOperators #-}

-- | Live-only latency measurement for skills and eval calls. 'timed' wraps any
-- effectful action and reports its wall-clock duration in milliseconds using a
-- monotonic clock. It requires @IOE :> es@, so it runs only under live
-- interpreters: the scripted and pure interpreters have no 'IOE', and a
-- near-zero scripted latency would be meaningless anyway. The 'IOE' constraint
-- is the live-only marker. 'withinMs' and 'maxLatencyMs' are pure budget
-- predicates a test asserts. Latency is orthogonal to the content score and is
-- deliberately kept out of 'Crucible.Eval' and 'Report'.
module Crucible.Eval.Latency
  ( Timed (..)
  , timed
  , timeEach
  , withinMs
  , maxLatencyMs
  ) where

import GHC.Clock (getMonotonicTimeNSec)

import Effectful

-- | A value paired with the wall-clock milliseconds its production took.
data Timed a = Timed { value :: a, latencyMs :: Int }
  deriving (Eq, Show, Functor)

-- | Measure wall-clock milliseconds around an effectful action.
timed :: (IOE :> es) => Eff es a -> Eff es (Timed a)
timed act = do
  t0 <- liftIO getMonotonicTimeNSec
  a  <- act
  t1 <- liftIO getMonotonicTimeNSec
  pure (Timed a (fromIntegral ((t1 - t0) `div` 1000000)))

-- | Time an action over each input of a dataset, in order.
timeEach :: (IOE :> es) => (i -> Eff es a) -> [i] -> Eff es [Timed a]
timeEach f = mapM (timed . f)

-- | A single result met its budget (latencyMs <= budget).
withinMs :: Int -> Timed a -> Bool
withinMs budget t = t.latencyMs <= budget

-- | The largest latency in a batch (0 for an empty batch).
maxLatencyMs :: [Timed a] -> Int
maxLatencyMs ts = maximum (0 : map (.latencyMs) ts)
```
Note: if the `(.latencyMs)` getter section in `maxLatencyMs` is ambiguous under DuplicateRecordFields, annotate it as `(.latencyMs :: Timed a -> Int)` (needs no extra extension) and report it. `liftIO` is from `Effectful`.

- [ ] **Step 2: Add the import to `test/Spec.hs`**

Add near the other crucible imports (around line 19-69):
```haskell
import Crucible.Eval.Latency (Timed (..), timed, timeEach, withinMs, maxLatencyMs)
```
`runEff`, `runPureEff` are already imported from `Effectful` (line 26); `threadDelay` is already imported from `Control.Concurrent` (line 56). You also need `liftIO` for the `threadDelay` test: check whether `liftIO` is in the `Effectful (...)` import list (line 26); if not, add it there (e.g. `import Effectful (Eff, runEff, runPureEff, liftIO)`).

- [ ] **Step 3: Add the pure tests to `test/Spec.hs`**

Add these entries to the `runChecks` list (at the end, before the closing `]`, each preceded by a comma):
```haskell
  , check "withinMs: under budget passes" True  (withinMs 100 (Timed () 50))
  , check "withinMs: over budget fails"  False (withinMs 100 (Timed () 150))
  , check "withinMs: at budget passes"   True  (withinMs 100 (Timed () 100))
  , check "maxLatencyMs: returns the largest" 30 (maxLatencyMs [Timed () 10, Timed () 30, Timed () 20])
  , check "maxLatencyMs: empty is zero" 0 (maxLatencyMs ([] :: [Timed ()]))
  , check "Timed Functor: maps value, keeps latency"
      (Timed (2 :: Int) 42)
      (fmap (+1) (Timed (1 :: Int) 42))
```

- [ ] **Step 4: Add the IOE timing tests to `test/Spec.hs`**

These run effectful programs; a `check` entry is `IO Bool`, so use a `do` block that `runEff`s the program (which supplies `IOE`):
```haskell
  , do t <- runEff (timed (pure (7 :: Int)))
       check "timed: preserves value, latency >= 0" True (t.value == 7 && t.latencyMs >= 0)
  , do t <- runEff (timed (liftIO (threadDelay 50000)))
       check "timed: a 50ms delay measures >= 30ms" True (t.latencyMs >= 30)
  , do ts <- runEff (timeEach pure [1, 2, 3 :: Int])
       check "timeEach: times each input, values preserved" True
         (map (.value) ts == [1, 2, 3] && all (\x -> x.latencyMs >= 0) ts)
```
Note: `threadDelay 50000` is 50 ms (microseconds). The `>= 30` lower bound is generous to avoid CI timing flakiness; do NOT assert an upper bound. If a `(.value)`/`(.latencyMs)` getter section is ambiguous, annotate it (e.g. `((.value) :: Timed Int -> Int)`).

- [ ] **Step 5: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the nine new checks pass; full suite green. Retry once on exit 137.

- [ ] **Step 6: Commit**

```bash
git add src/Crucible/Eval/Latency.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(eval): Crucible.Eval.Latency timed + budget predicates

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Live demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a latency demo to the Anthropic-key-gated block**

Read `app/Main.hs`. In the `Just key -> do` block there is an existing typed-skill demo using `classify` (a `Skill T.Text Sentiment`) called via `runEff (Anthropic.run cfg (call classify "..."))`. After an existing demo near the end of the block (for example after the multimodal demo), add:
```haskell
      -- Latency: time a live call and check it against a budget (live-only).
      tcall <- runEff (Anthropic.run cfg (timed (call classify "I love this!")))
      TIO.putStrLn ("latency: " <> T.pack (show tcall.latencyMs) <> " ms (within 5000ms: "
                    <> T.pack (show (withinMs 5000 tcall)) <> ")")
```
Add imports near the other crucible imports: `import Crucible.Eval.Latency (timed, withinMs)`. `call`, `classify`, `cfg`, `Anthropic.run`, `runEff`, `TIO`, `T` are already in scope (used by the existing classify demo). If `tcall.latencyMs` getter is ambiguous, annotate `(tcall.latencyMs :: Int)`. The action `timed (call classify ...)` typechecks because `Anthropic.run` discharges `LLM` and `runEff` provides the base `IOE` that `timed` needs.

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. Retry once on 137. (Do not run the binary; it needs a key.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "$(cat <<'EOF'
demo(eval): time a live call against a latency budget

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Latency section in `docs/evals.md`

**Files:**
- Modify: `docs/evals.md`

- [ ] **Step 1: Add a "Latency" section**

Read `docs/evals.md`. Insert a new `## Latency` section AFTER the `## Judge errors` section and BEFORE the `## Rubric rules at a glance` section (so the at-a-glance summary stays last). Use this content (real triple-backtick fences):

```markdown
## Latency

Latency is a live-only axis, separate from the content score. A scripted or
cassette run returns near-instantly, so a wall-clock budget there means
nothing. `Crucible.Eval.Latency` keeps timing out of the eval core and gates it
on `IOE`, so you can only time a live call. That `IOE` constraint is the
live-only marker.

```haskell
data Timed a = Timed { value :: a, latencyMs :: Int }

timed     :: (IOE :> es) => Eff es a -> Eff es (Timed a)
timeEach  :: (IOE :> es) => (i -> Eff es a) -> [i] -> Eff es [Timed a]
withinMs     :: Int -> Timed a -> Bool   -- one result met its budget
maxLatencyMs :: [Timed a] -> Int         -- the slowest of a batch
```

`timed` wraps any effectful action (a `call`, a `converse`, a `callMedia`, a
tool-agent run) and reports its duration in milliseconds. `withinMs` and
`maxLatencyMs` are pure, so a test asserts a budget without any further effect:

```haskell
t <- timed (call mySkill input)
-- assert: withinMs 2000 t

ts <- timeEach (call mySkill) inputs
-- assert: maxLatencyMs ts <= 2000
```

Latency stays out of `Report`: the content score and the latency budget are
independent, and only the latter needs a live interpreter. For per-provider
call timing in a fallback chain, see `Crucible.LLM.CallLog`, which records a
`durationMs` per member attempt.
```

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/evals.md` (expected: no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/evals.md` (expected: no output; if a pre-existing hit appears outside your new section, leave it, but your new text must be clean).

- [ ] **Step 3: Commit**

```bash
git add docs/evals.md
git commit -m "$(cat <<'EOF'
docs(evals): Latency section (live-only timing utility)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** `Timed`/`timed`/`timeEach`/`withinMs`/`maxLatencyMs` (T1); pure + IOE tests incl. lower-bound timing (T1); demo (T2); `docs/evals.md` Latency section (T3). Non-goals are "do not build". All spec sections map to a task.
- **Type consistency:** `Timed a = Timed { value :: a, latencyMs :: Int }`, `timed :: (IOE :> es) => Eff es a -> Eff es (Timed a)`, `timeEach :: (IOE :> es) => (i -> Eff es a) -> [i] -> Eff es [Timed a]`, `withinMs :: Int -> Timed a -> Bool`, `maxLatencyMs :: [Timed a] -> Int` are identical across the module, the tests, the demo, and the doc.
- **Placeholder scan:** no TBD/TODO/vague steps; every code step shows complete code. The only judgement points flagged are getter-section annotations (with the exact annotation to add) and the `liftIO` import check.
- **Test design:** timing assertions are lower-bound only (`>= 0`, `>= 30`), never upper-bound, to avoid CI flakiness, per the spec.
