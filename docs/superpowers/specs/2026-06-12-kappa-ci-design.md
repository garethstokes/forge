# Bootstrap Confidence Intervals on Calibration Kappa Design Spec

**Date:** 2026-06-12
**Status:** Approved design, pending implementation
**Tracker:** `crucible-2h9`.
**Research basis:** `docs/superpowers/research/2026-06-11-autorubric-review.md` item 4.
**Scope:** `src/Crucible/Eval/Calibrate.hs` (and a small export from `src/Crucible/Eval/Judge.hs`), `test/Spec.hs`, `docs/evals.md`.

## Motivation

Calibration runs on small labelled sets (the documented workflow starts at
about thirty). A kappa point estimate from a small sample can sit anywhere
in a wide interval; 0.65 with a 95% interval of [0.31, 0.85] should not be
trusted the way a tight interval is. The interval, not the point, is what
says "label more before trusting this".

## Design

### Report and rendering

`CalibrationReport` gains one final field:

```haskell
data CalibrationReport = CalibrationReport
  { agreement     :: Double
  , kappa         :: Double
  , failPrecision :: Double
  , failRecall    :: Double
  , contested     :: [Text]
  , judgeErrors   :: [Text]
  , exampleCount  :: Int
  , measured      :: Int
  , kappaCI       :: (Double, Double)  -- 95% bootstrap interval over judged cases
  }
```

`renderCalibration` extends the kappa line:
`kappa:          0.65  [95% CI 0.31, 0.85]` (always printed; for degenerate
inputs the interval collapses to the point estimate, see below).

### The pure core

In `Crucible.Eval.Calibrate`:

```haskell
-- | 95% bootstrap confidence interval for Cohen's kappa over (human, judge)
-- verdict pairs: resample with replacement to the original size, recompute
-- kappa per resample (same formula and degenerate rules as the headline
-- kappa, including pe >= 1 -> 0), sort, take the 2.5th and 97.5th
-- percentile elements. Deterministic for a given seed.
bootstrapKappa :: Int -> Int -> [(Bool, Bool)] -> (Double, Double)
-- args: seed, resample count, pairs
```

- Resample count is the named constant `bootstrapResamples = 1000`; no knob.
- Random indices come from the same xorshift step already used by
  `shuffleSeeded` in `Crucible.Eval.Judge`: export the step (or an index
  stream `xorshiftInts :: Int -> [Int]`) from Judge rather than duplicating
  the generator. Index into the pair list by `abs (x) \`mod\` n`.
- Percentiles by index on the sorted resampled kappas: with 1000 resamples,
  elements at zero-based indices 25 and 974.
- The per-resample kappa computation is the existing formula factored into
  a pure `kappaOf :: [(Bool, Bool)] -> Double` shared by the headline kappa
  and the bootstrap (po, pe from marginals, pe >= 1 -> 0, empty -> 0).

### Wiring and degenerates

- `calibrateWith seed nExamples votes ...` drives the bootstrap with the
  SAME seed it already takes for the example split; plain `calibrate`
  (= `calibrateWith 0 0`) bootstraps with seed 0. No signature changes.
- Pairs are the judged holdout cases only (judge errors already excluded
  upstream).
- Degenerates: zero or one judged pair -> `kappaCI = (kappa, kappa)` (no
  resampling); this also covers the all-errored case.

### Migration

`kappaCI` is appended last; the existing positional `CalibrationReport`
constructions in test/Spec.hs gain a final tuple. Record-dot readers are
untouched.

## Manual (`docs/evals.md`)

Two additions to "Calibrating the judge": the CI appears on the kappa line
of `renderCalibration`, and the reading rule: act on the LOWER bound, not
the point estimate; a wide interval means label more cases before trusting
the judge. House style: no emdashes, no hype, no manifest mentions.

## Testing (pure unless noted)

- `bootstrapKappa` determinism: same seed twice, identical interval;
  a different seed may differ.
- Perfect agreement pairs (all (True, True)/(False, False) mixed): every
  resample computes the same kappa, interval is (k, k)-tight.
- Mixed pairs: `lo <= kappa <= hi` and `lo < hi` for a hand-built sample
  with genuine disagreement (e.g. 6 agreeing, 2 disagreeing pairs).
- Degenerate rule: one pair and zero pairs -> `(kappa, kappa)` without
  resampling.
- `calibrateWith` end-to-end (scripted): report carries an interval
  satisfying `lo <= kappa <= hi`; the all-pass fixture from the existing
  few-shot test yields the degenerate-tight interval.
- `renderCalibration` shows the `[95% CI lo, hi]` segment on the kappa line.
- Existing calibrate checks migrated with their expected `kappaCI` values
  (the all-pass fixtures have deterministic, hand-derivable intervals:
  kappa 0 everywhere -> (0, 0); the 0.75/0.5 fixture's interval is
  seed-dependent, so that check asserts the bounds property via record-dot
  rather than positional equality, or pins the exact tuple after one
  observed run if it proves stable; the plan decides which and says so).

## Non-goals

- Intervals for agreement or fail precision/recall (kappa is the decision
  metric; add later only on demonstrated need).
- Configurable resample counts or confidence levels.
- BCa or studentized bootstrap variants (percentile method suffices at this
  sample scale).
