# RunMetric bootstrap_std / CI — Design

**Status:** Approved (batch brainstorm 2026-06-13). · **Date:** 2026-06-13

**Goal:** Each `RunMetric` gains a bootstrap **standard error** of its mean
(HealthBench's `bootstrap_std`). The stat lives in **crucible**; manifest-evals
persists it per metric row (overall + every tag breakdown). Display (CI =
`mean ± 1.96·stderr`) is a later slice — this slice only computes + stores.

## Decisions (user-approved)
- `stderr :: Maybe Double` column on `RunMetric` (one column; CI derived at
  display, not stored).
- The bootstrap-mean stat goes in crucible (consistent with
  [[crucible-is-the-stats-substrate]]).
- No dashboard render this slice.

## 1. Crucible — `bootstrapStdErr` (worktree → master → push)
Add to `Crucible.Eval.Calibrate` (reusing the module's `xorshiftInts` seeded
RNG, same idiom as `bootstrapKappa`):

```haskell
-- | Bootstrap standard error of the mean: resample @xs@ with replacement to its
-- own size @resamples@ times, take each resample's mean, return the standard
-- deviation of those means. Deterministic per seed. 0 for <=1 value or
-- resamples<=0 (no spread to estimate).
bootstrapStdErr :: Int -> Int -> [Double] -> Double
bootstrapStdErr seed resamples xs
  | length xs <= 1 || resamples <= 0 = 0
  | otherwise =
      let n      = length xs
          idxs   = map (\x -> abs x `mod` n) (xorshiftInts seed)
          group r = [xs !! i | i <- take n (drop (r * n) idxs)]
          means  = [ sum (group r) / fromIntegral n | r <- [0 .. resamples - 1] ]
          mbar   = sum means / fromIntegral resamples
          var    = sum [ (m - mbar) ** 2 | m <- means ] / fromIntegral resamples
      in sqrt var
```
Export it. Tests: identical values → 0; a spread vector → > 0 and deterministic
per seed (`bootstrapStdErr 9 1000 xs == bootstrapStdErr 9 1000 xs`); empty /
single → 0.

## 2. manifest-evals — re-pin + schema + aggregator
- **Re-pin** crucible to the new master HEAD (`zinc update`); no API breakage
  expected (purely additive export).
- **Schema:** `RunMetric` gains `stderr :: Field f (Maybe Double)` as the LAST
  field (additive nullable, mirrors how `tag` was added). Patch existing
  `RunMetric {...}` literals across `src`/`test` with `stderr = Nothing`.
- **Aggregator:** `DimMetric` gains `stderr :: Double`. `dimensionalMetrics`
  takes a `seed :: Int` and, per emitted metric, computes
  `Cal.bootstrapStdErr seed resamples values` over that metric's contributing
  values (overall → the per-score values; theme/axis → their grouped
  contributing values). `resamples` is a module constant (`1000`). The existing
  mean/passRate/count semantics are unchanged.
- **`recompute`:** pass a fixed `seed = 0`, write `stderr = Just dm.stderr` in
  the `RunMetric` add.

## 3. Testing
- **Crucible:** the `bootstrapStdErr` tests above.
- **manifest-evals pure** (`dimSpec`): `dimensionalMetrics` over a vector with
  identical values → overall `stderr == 0`; over a spread vector → overall
  `stderr > 0`; a single-row group → `stderr == 0`. (Exact bootstrap values are
  crucible's responsibility; here we assert the 0-vs-positive qualitative
  behaviour.)
- **Engine** (`dimEngineSpec`/`metricSpec`): the emitted `RunMetric` rows now
  carry `stderr` (a `Just`); a single-score run → `stderr == Just 0.0`; an
  existing multi-score metric → `stderr` is `Just` and ≥ 0. No regression to
  mean/count/tag.

## 4. Out of scope
- Dashboard rendering of stderr / CI (chips, error bars).
- Configurable seed/resamples via CLI (fixed seed 0, constant 1000).
