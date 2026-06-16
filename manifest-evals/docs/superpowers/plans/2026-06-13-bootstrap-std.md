# RunMetric bootstrap_std Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Each `RunMetric` gains a bootstrap standard error (`stderr`); the stat lives in crucible.

**Spec:** `docs/superpowers/specs/2026-06-13-bootstrap-std-design.md`

**Repo facts (verified):** `Crucible.Eval.Calibrate` imports `xorshiftInts` from `Crucible.Eval.Judge` and already has `bootstrapKappa :: Int -> Int -> [(Bool,Bool)] -> (Double,Double)` using `idxs = map (\x -> abs x `mod` n) (xorshiftInts seed)` + `group r = [pairs !! i | i <- take n (drop (r*n) idxs)]`. crucible builds/tests with `nix develop -c zinc test`; tests are `Harness.check` items in `test/Spec.hs`. — manifest-evals: `DimMetric {tag :: Maybe Text, mean :: Double, passRate :: Maybe Double, count :: Int}` (`Grade.hs:424`); `dimensionalMetrics :: [(Maybe Double, Maybe Bool, Maybe Value, Maybe Value)] -> [DimMetric]` (`Grade.hs:464`) builds `overall` (record syntax) + `themeMetrics`/`axisMetrics` (positional `DimMetric (Just t) mean Nothing count`); `recompute` (`Grade.hs:384`) calls `dimensionalMetrics (map unwrap rows)` and `add (RunMetric {... tag = dm.tag, computedAt = now})` per dm (`Grade.hs:399-402`). `RunMetric` literals: `recompute` (multi-line, `Grade.hs:399`) + `test/ApiSpec.hs:315,317,424,432`. crucible pin in `zinc.toml` `[dependencies.crucible]` + `zinc.lock`. Build/test: `nix develop -c zinc build` / `nix develop -c zinc test 2>&1 | tail -8`.

---

### Task 1: crucible `bootstrapStdErr` (worktree → master → push)

**Files (in `/home/gareth/code/garethstokes/crucible`):** `src/Crucible/Eval/Calibrate.hs`, `test/Spec.hs`.

- [ ] **Step 1: worktree.** `cd /home/gareth/code/garethstokes/crucible && git fetch origin && git worktree add .worktrees/bootstrap-stderr -b feat/bootstrap-stderr origin/master && cd .worktrees/bootstrap-stderr`
- [ ] **Step 2: failing tests.** In `test/Spec.hs`, append `, bootstrapStdErr` to the existing `import Crucible.Eval.Calibrate (...)` line. Add these `check` items near the `bootstrapKappa` ones:

```haskell
  , check "bootstrapStdErr: identical values -> 0"
      0.0
      (bootstrapStdErr 1 1000 [0.5, 0.5, 0.5, 0.5])
  , check "bootstrapStdErr: single / empty -> 0"
      (0.0, 0.0)
      (bootstrapStdErr 1 1000 [0.7], bootstrapStdErr 1 1000 [])
  , check "bootstrapStdErr: spread -> positive, deterministic per seed"
      True
      (let xs = [0.0, 0.25, 0.5, 0.75, 1.0, 0.1, 0.9]
       in bootstrapStdErr 9 1000 xs > 0 && bootstrapStdErr 9 1000 xs == bootstrapStdErr 9 1000 xs)
```
Run `cd /home/gareth/code/garethstokes/crucible/.worktrees/bootstrap-stderr && nix develop -c zinc test 2>&1 | tail -6`. Expected: compile failure (`bootstrapStdErr` not in scope).

- [ ] **Step 3: implement.** In `src/Crucible/Eval/Calibrate.hs`, add `bootstrapStdErr` to the export list (after `bootstrapKappa`), then add:

```haskell
-- | Bootstrap standard error of the mean: resample @xs@ with replacement to its
-- own size @resamples@ times, take each resample's mean, return the standard
-- deviation of those means. Deterministic per seed. 0 for <=1 value or
-- resamples<=0 (no spread to estimate).
bootstrapStdErr :: Int -> Int -> [Double] -> Double
bootstrapStdErr seed resamples xs
  | length xs <= 1 || resamples <= 0 = 0
  | otherwise =
      let n       = length xs
          idxs    = map (\x -> abs x `mod` n) (xorshiftInts seed)
          group r = [xs !! i | i <- take n (drop (r * n) idxs)]
          means   = [ sum (group r) / fromIntegral n | r <- [0 .. resamples - 1] ]
          mbar    = sum means / fromIntegral resamples
          var     = sum [ (m - mbar) ** 2 | m <- means ] / fromIntegral resamples
      in sqrt var
```
Run `nix develop -c zinc test 2>&1 | tail -6`. Expected: all green.

- [ ] **Step 4: commit (worktree).** `git add src/Crucible/Eval/Calibrate.hs test/Spec.hs && git commit -m "$(printf 'feat(eval): bootstrapStdErr — bootstrap standard error of the mean\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"`
- [ ] **Step 5: merge + push + record rev.** From the crucible repo root: `cd /home/gareth/code/garethstokes/crucible && git checkout master && git merge --ff-only feat/bootstrap-stderr && nix develop -c zinc test 2>&1 | tail -3 && git push origin master && git rev-parse HEAD && git worktree remove .worktrees/bootstrap-stderr && git branch -d feat/bootstrap-stderr`. RECORD the printed HEAD rev (the re-pin target). If `--ff-only` fails, use `git merge --no-ff feat/bootstrap-stderr`, re-test, push.

---

### Task 2: re-pin crucible (manifest-evals)

**Files:** `zinc.toml`, `zinc.lock`.

- [ ] **Step 1:** In `zinc.toml` `[dependencies.crucible]`, set `rev` to the Task 1 HEAD rev; update the comment to mention `bootstrapStdErr`. Run `nix develop -c zinc update 2>&1 | tail -10`; confirm `zinc.lock`'s crucible block shows the new rev.
- [ ] **Step 2:** `nix develop -c zinc build 2>&1 | tail -5` and `nix develop -c zinc test 2>&1 | tail -6` — both green (purely additive crucible export; no breakage expected; fix any drift minimally).
- [ ] **Step 3: commit.** `git add zinc.toml zinc.lock && git commit -m "$(printf 'chore(deps): re-pin crucible for bootstrapStdErr\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"`

---

### Task 3: `RunMetric.stderr` column + aggregator + recompute (TDD)

**Files:** `src/Evals/Schema.hs`, `src/Evals/Grade.hs`, `test/GradeSpec.hs`, `test/ApiSpec.hs`.

- [ ] **Step 1: the column.** In `src/Evals/Schema.hs`, add `stderr :: Field f (Maybe Double)` as the LAST field of `RunMetricT` (after `tag`), with comment `-- bootstrap standard error of the mean (Nothing pre-bootstrap)`.

- [ ] **Step 2: patch existing literals.** `grep -rn "RunMetric" src/ test/` and add `stderr = Nothing` to every `RunMetric {...}` literal EXCEPT `recompute`'s (Task 3 Step 5 rewrites that one). Confirm: `test/ApiSpec.hs:315,317,424,432` get `stderr = Nothing`; check `test/SchemaSpec.hs` for any RunMetric literal and patch it too. Build to confirm the literals compile: `nix develop -c zinc build 2>&1 | tail -3` (recompute's literal will be a compile error until Step 5 — acceptable; or do Steps 3–5 together then build).

- [ ] **Step 3: failing pure tests.** In `test/GradeSpec.hs`'s `dimSpec`, add (the existing `dimensionalMetrics` calls take a new leading `seed` arg now — update them to `dimensionalMetrics 0 [...]`):

```haskell
  -- stderr: identical-value group -> 0; spread -> > 0
  let same = [ (Just 0.5, Nothing, Nothing, Nothing), (Just 0.5, Nothing, Nothing, Nothing) ]
  expect "dim overall stderr 0 on identical values"
    (case [ m | m <- dimensionalMetrics 0 same, m.tag == Nothing ] of [m] -> m.stderr == 0; _ -> False)
  let spread = [ (Just 0.0, Nothing, Nothing, Nothing), (Just 1.0, Nothing, Nothing, Nothing), (Just 0.5, Nothing, Nothing, Nothing) ]
  expect "dim overall stderr > 0 on spread"
    (case [ m | m <- dimensionalMetrics 0 spread, m.tag == Nothing ] of [m] -> m.stderr > 0; _ -> False)
```
Also update the EXISTING `dimSpec` `dimensionalMetrics [row1, row2]` / `dimensionalMetrics [neg]` calls to pass the seed: `dimensionalMetrics 0 [row1, row2]`, `dimensionalMetrics 0 [neg]`. Run `nix develop -c zinc test 2>&1 | tail -6` — compile FAIL (`dimensionalMetrics` arity, `m.stderr` missing).

- [ ] **Step 4: implement the aggregator.** In `src/Evals/Grade.hs`:
  - Add `import qualified Crucible.Eval.Calibrate as Cal` (with the other crucible imports).
  - Add `stderr :: Double` to `DimMetric` (after `count`):
    ```haskell
    data DimMetric = DimMetric
      { tag :: Maybe Text, mean :: Double, passRate :: Maybe Double, count :: Int, stderr :: Double }
      deriving (Eq, Show)
    ```
  - Change `dimensionalMetrics` to take a leading `seed :: Int` and compute stderr per group via a local helper. New signature + body head:
    ```haskell
    dimensionalMetrics :: Int -> [(Maybe Double, Maybe Bool, Maybe Value, Maybe Value)] -> [DimMetric]
    dimensionalMetrics seed rows = overall : themeMetrics ++ axisMetrics
      where
        stderrOf = Cal.bootstrapStdErr seed 1000
        ...
        overall = DimMetric { tag = Nothing, mean = clip01 (if null vals then 0 else avg vals)
                            , passRate = ..., count = length graded, stderr = stderrOf vals }
        themeMetrics = [ DimMetric (Just t) (clip01 (avg ss)) Nothing (length ss) (stderrOf ss) | (t, ss) <- grouped themePairs ]
        axisMetrics  = [ DimMetric (Just t) (clip01 (avg ss)) Nothing (length ss) (stderrOf ss) | (t, ss) <- grouped axisPairs ]
    ```
    (Keep `graded`/`vals`/`judged`/`themePairs`/`axisPairs`/`avg`/`grouped` as-is. `vals` is `overall`'s value list; `ss` each tag group's.)
  Run `nix develop -c zinc test 2>&1 | tail -6` — `dimSpec` green.

- [ ] **Step 5: recompute writes stderr.** In `src/Evals/Grade.hs` `recompute`, update the `dimensionalMetrics` call to `dimensionalMetrics 0 (map unwrap (...))`, and add `, stderr = Just dm.stderr` to the `RunMetric {...}` add (after `tag = dm.tag`). Run `nix develop -c zinc test 2>&1 | tail -8` — `dimEngineSpec`/`metricSpec` green.

- [ ] **Step 6: engine assertion.** In `test/GradeSpec.hs` `dimEngineSpec` (the pointed run with one example/one criterion-set), after the existing assertions add one proving stderr is persisted. The single-output run has one contributing value per metric, so stderr is 0:
```haskell
  expect "dim engine: overall stderr persisted (single output -> 0)"
    (case [ (m.stderr) | m <- ms, m.tag == Nothing ] of [s] -> s == Just 0.0; _ -> False)
```
(`ms` is the `[RunMetric]` already selected in `dimEngineSpec`; `m.stderr :: Maybe Double`.) Run `nix develop -c zinc test 2>&1 | tail -8` — green; `nix develop -c zinc build 2>&1 | tail -3` — links.

- [ ] **Step 7: commit + push.** `git add -A && git commit -m "$(printf 'feat(grade): RunMetric.stderr — bootstrap standard error per metric\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')" && git push`

---

## Self-Review
- Spec §1 (crucible bootstrapStdErr + tests) → Task 1; §2 re-pin → Task 2, schema+aggregator+recompute → Task 3; §3 testing (crucible + pure 0-vs-positive + engine stderr persisted) → Tasks 1,3; §4 out-of-scope (no dashboard, fixed seed/resamples) absent.
- Type consistency: `bootstrapStdErr :: Int -> Int -> [Double] -> Double` (crucible) called as `Cal.bootstrapStdErr seed 1000` (Grade); `DimMetric` gains `stderr :: Double`; `dimensionalMetrics :: Int -> [...] -> [DimMetric]` (seed added) updated at its one call site (`recompute`) and all test call sites; `RunMetric.stderr :: Maybe Double` written `Just dm.stderr`.
