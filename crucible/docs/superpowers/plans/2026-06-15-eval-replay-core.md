# Eval Flywheel Core (replay-to-eval + ddmin) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.
> **Spec:** `docs/superpowers/specs/2026-06-15-eval-replay-core-design.md`.

**Goal:** `Crucible.Eval.Replay` — `runReplayEval`/`settle`/`noteDivergence` (divergence collection for replay-to-eval) + `ddmin` (delta-debugging minimizer), with hermetic tests.

**Build/test:** `nix develop . --command timeout -s KILL 300 zinc build|test` (137 → retry once). Success = ALL PASS.
**Reference (READ):** `src/Crucible/Journal.hs` (`Divergence`, `ReplayOutcome (Replayed | Diverged)`, `replayFrom`, `record`/`recordTo`, `mkKey`, `MissPolicy(Signal)`, in-memory store); `src/Crucible/Eval/Judge.hs` for module style; the effectful `State.Static.Local` API.

---

### Task 1: `Crucible.Eval.Replay` module + tests

**Files:** Create `src/Crucible/Eval/Replay.hs`; `test/Spec.hs`.

- [ ] **Step 1: write the module.** Pragmas as needed (DataKinds, FlexibleContexts, TypeOperators, ScopedTypeVariables, GADTs/LambdaCase if the test interpreter needs them — the module itself is plain). Export `runReplayEval`, `noteDivergence`, `settle`, `ddmin`.
```haskell
module Crucible.Eval.Replay
  ( runReplayEval, noteDivergence, settle, ddmin ) where

import Data.List (nub)
import Effectful
import Effectful.State.Static.Local (State, runState, modify)
import Crucible.Journal (Divergence, ReplayOutcome (..))

-- collect the divergences surfaced during a replay-to-eval run (in encounter order).
runReplayEval :: Eff (State [Divergence] : es) a -> Eff es (a, [Divergence])
runReplayEval m = do
  (a, ds) <- runState [] m
  pure (a, reverse ds)

noteDivergence :: (State [Divergence] :> es) => Divergence -> Eff es ()
noteDivergence d = modify (d :)

-- record a divergence (if any) and return the value. An app's replay interpreter:
--   LookupTwin mid -> replayFrom j Signal (key ...) decode live >>= settle
settle :: (State [Divergence] :> es) => ReplayOutcome a -> Eff es a
settle (Replayed a)    = pure a
settle (Diverged d a)  = noteDivergence d >> pure a

-- Zeller delta-debugging: the smallest sub-list of xs for which `repro` still
-- returns True. granularity n doubles from 2; test subsets, then complements;
-- recurse on the first that reproduces; stop when n > length.
ddmin :: Monad m => ([a] -> m Bool) -> [a] -> m [a]
ddmin repro xs0 = go xs0 2
  where
    go xs n
      | length xs < 2 = pure xs
      | otherwise = do
          let k      = max 1 (length xs `div` n)
              chunks = chunksOf k xs
          -- try each chunk as the reduced input
          msub <- firstM repro chunks
          case msub of
            Just sub -> go sub 2                      -- reduce to subset, reset granularity
            Nothing  -> do
              -- try each complement (input minus one chunk)
              let comps = [ concat (deleteAt i chunks) | i <- [0 .. length chunks - 1] ]
              mcomp <- firstM repro comps
              case mcomp of
                Just comp -> go comp (max 2 (n - 1))  -- reduce to complement, decrease granularity
                Nothing
                  | n >= length xs -> pure xs          -- 1-minimal
                  | otherwise      -> go xs (min (length xs) (n * 2))
    chunksOf _ [] = []
    chunksOf k ys = let (a, b) = splitAt k ys in a : chunksOf k b
    deleteAt i ys = [ y | (j, y) <- zip [0 ..] ys, j /= i ]
    firstM _ [] = pure Nothing
    firstM p (y : ys) = do ok <- p y; if ok then pure (Just y) else firstM p ys
```
(Verify the ddmin logic compiles and the test passes; adjust the granularity bookkeeping if the standard algorithm differs — the key property the test pins is "returns a minimal sub-list still satisfying the oracle". `nub` import can be dropped if unused.)

- [ ] **Step 2: tests in `test/Spec.hs`.** Import `Crucible.Eval.Replay`. Add:
  - **settle/runReplayEval (pure-ish via runPureEff):**
```haskell
  , check "replay: settle collects diverged, passes values"
      ( [1,2,3] :: [Int], 2 )   -- values, number of divergences
      ( let (vals, ds) = runPureEff (runReplayEval (do
                a <- settle (Replayed (1::Int))
                b <- settle (Diverged dvg1 2)
                c <- settle (Diverged dvg2 3)
                pure [a,b,c]))
        in (vals, length ds) )
```
  where `dvg1`/`dvg2` are `Divergence` values (construct via the exported `Divergence` ctor — check its shape in Journal.hs, e.g. `Divergence (mkKey "op" ["1"])`).
  - **end-to-end replay-to-eval (in-memory journal):** record a journal of a couple of `record`ed ops with "original" values; then replay a program that `replayFrom j Signal`s those keys plus one NEW key (changed code), each `>>= settle`, under `runReplayEval`; assert the new key shows up as a divergence and the recorded keys replay without divergence. (Use the pure `record`/`replayFrom`-over-`State Journal` path or the in-memory store; mirror the existing Journal tests' setup. `replayFrom` needs `Error JournalError` + `IOE` — run under `runEff`+`runErrorNoCallStack`; or if a pure replay variant exists use it. Keep it consistent with how Journal's tests drive replay.)
  - **ddmin:**
```haskell
  , do got <- ddmin (\sub -> pure (5 `elem` sub)) [1..8 :: Int]
       check "ddmin: reduces to the single required element" [5] got
  , do got <- ddmin (\sub -> pure (sum sub >= 10)) [1..8 :: Int]
       check "ddmin: minimal subset is small" True (sum got >= 10 && length got < 8)
```
  (ddmin is monadic; use `pure` oracles in `IO`/the check's monad. If `check` expects a pure value, run `ddmin` with `Identity`/`runIdentity` or in IO `do`-block checks like the existing IO checks.)

- [ ] **Step 3: build + test → ALL PASS. Step 4: commit** (`feat(eval): Crucible.Eval.Replay — replay-to-eval divergence collection + ddmin` + trailer).

---

## Self-Review
- **Spec coverage:** the module's four functions + the three test groups (settle/runReplayEval, end-to-end replay divergence, ddmin). Manifest-evals consumer explicitly out of scope (handoff).
- **Type consistency:** `runReplayEval`/`settle`/`noteDivergence` over `State [Divergence]`; `ddmin` generic monadic. Uses `Divergence`/`ReplayOutcome` from `Crucible.Journal`.
- **Risk:** ddmin algorithm — the test pins the minimal-subset property; adjust bookkeeping if needed to satisfy it. Verify `Divergence`'s constructor/fields before building test values.
- **Placeholder scan:** none.
