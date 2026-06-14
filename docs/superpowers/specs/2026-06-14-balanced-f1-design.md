# Balanced-F1 + per-class F1 in the calibration harness — design

**Date:** 2026-06-14
**Status:** approved (pending spec review)

## Goal

Make HealthBench's headline grader metric — `pairwise_model_f1_balanced` (the mean of the
met-class and not-met-class F1) — a first-class output of the calibration harness, computed
in crucible, persisted on `MetaEval`, and shown on the dashboard. Today we hand-reconstruct
it from agreement + fail-precision/recall (see the HealthBench reproduction results doc);
this makes it native.

Expose three numbers: `passF1` (met class), `failF1` (not-met class), and `balancedF1`.

## Why this shape

Calibration math is crucible's job (the stats substrate — see [[crucible-is-the-stats-substrate]]).
The F1s derive entirely from the `judged = [(human, judge)]` verdict pairs already inside
`reportFrom`/`reportFromVerdicts`; the not-met (fail) class precision/recall are already
computed there. So this is a small, pure extension of `CalibrationReport`, then plumbing it
through the manifest-evals persistence → DTO → dashboard path that the κ-surface already laid.

The κ-CI-vs-0.6 **trust verdict is unchanged**. Balanced-F1 is reported alongside for
HealthBench parity, not as the trust cue.

## Component 1 — Crucible: `Crucible.Eval.Calibrate`

`CalibrationReport` gains three `Double` fields (place after `failRecall`):

```haskell
  , passF1        :: Double  -- ^ F1 of the met (pass) class
  , failF1        :: Double  -- ^ F1 of the not-met (fail) class
  , balancedF1    :: Double  -- ^ mean of passF1 and failF1 (HealthBench pairwise_model_f1_balanced)
```

Computed in BOTH `reportFrom` and `reportFromVerdicts` from the judged `(human, judge)`
pairs. The fail class is already there (`failPrecision`, `failRecall`); add the symmetric
pass class and the F1s:

```haskell
-- pass (met) class: predicted-pass = judge True; actual-pass = human True
passPrecision = ratio (#judge-True ∧ human-True) (#judge-True) 1
passRecall    = ratio (#human-True ∧ judge-True) (#human-True) 1
passF1        = harmonic passPrecision passRecall
failF1        = harmonic failPrecision failRecall
balancedF1    = (passF1 + failF1) / 2

harmonic :: Double -> Double -> Double
harmonic p r = if p + r == 0 then 0 else 2 * p * r / (p + r)
```

`passPrecision`/`passRecall` follow the exact pattern of the existing `failPrecision`/
`failRecall` (mirror the `jFails`/`hFails` lines with `True` instead of `False`). They stay
internal (not added to the report) unless trivially convenient — only the three F1s are new
report fields. Use the existing `ratio _ 0 dflt` helper (default 1, matching the fail-class
convention) for the precision/recall, and `harmonic` for the F1 (default 0 when both are 0).

`renderCalibration` prints the three new numbers (after the fail lines):
```
balanced F1:    0.757   (met 0.859 · not-met 0.655)
```

**Tests** (crucible's pure calibration tests): assert the F1s on a hand-built verdict list
with a known confusion matrix. E.g. for pairs giving TP/FP/FN/TN that yield
passF1 = X, failF1 = Y, balancedF1 = (X+Y)/2; plus the degenerate all-agree case
(both F1 = 1, balanced = 1) and an empty case (0/0 → 0).

**Cross-repo:** implement in a crucible worktree, merge to crucible `master`, push, then
re-pin here — bump the crucible `rev` in `zinc.toml` and run `zinc update` (a rev change is
not lock drift; see [[zinc-rev-change-needs-update]]). Crucible pins to **pushed remote
master only**.

## Component 2 — manifest-evals persistence

`MetaEval` entity (`src/Evals/Schema.hs`) gains three columns after `failRecall`:
```haskell
  , passF1 :: Field f Double, failF1 :: Field f Double, balancedF1 :: Field f Double
```
`migrate` is additive (`ALTER TABLE … ADD COLUMN`); the demo/repro DBs are recreated, so
fresh `CREATE TABLE` includes them. (A pre-existing persistent DB with `MetaEval` rows would
need the ALTER to carry a default — noted, same class of caveat as the Output→CriterionLabel
cascade; not relevant to our ephemeral/demo DBs.)

`saveMetaEval` (`src/Evals/MetaEval.hs`) writes `passF1 = rep.passF1`, `failF1 = rep.failF1`,
`balancedF1 = rep.balancedF1`.

`MetaEvalSpec` (the existing persist test) asserts the three round-trip.

## Component 3 — DTO + dashboard

`MetaEvalDto` (`evals-api/src/Evals/Api.hs`) gains `passF1`, `failF1`, `balancedF1 :: Double`
(after `failRecall`/`measured` region — order is free since it's a record). `metaEvalDto`
(`src/Evals/Dashboard.hs`) maps `me.passF1`/`me.failF1`/`me.balancedF1`.

Dashboard calib card (`evals-ui/src/Evals/Ui/View.hs`): add a line under the κ verdict in
`calibCard` (or in the `.calib-sub` block):
```
balanced-F1 0.76 (met 0.86 · not-met 0.66)
```
using `fmtD`. No CSS structural change needed (reuse `.calib-sub`/`.calib-band` styling; add
a `.calib-f1` class only if a distinct line is wanted). The trust verdict and κ bar are
untouched.

`ApiSpec` MetaEval seed rows + the `CalibrationSeriesDto`/`MetaEvalDto` round-trip get the
three fields. Rebuild wasm (`scripts/build-ui.sh`) and restart `evals-dashboard` (wire-shape
change → both the wasm and the running server binary must be current).

## Component 4 — Demo seed

`scripts/seed-demo.sh` `meta_evals` INSERT: add `pass_f1`, `fail_f1`, `balanced_f1` columns
with reconciling values for the two existing rows (exactness trustworthy → higher balanced-F1,
e.g. 0.82/0.78; rubric borderline → lower, e.g. 0.60/0.58). `setval` line unchanged.

## Out of scope

- Re-running the live HealthBench reproduction to populate real balanced-F1 (the user opted
  for plumbing + demo + tests; the reproduction results doc keeps its reconstructed ~0.76,
  and a future `healthbench-repro.sh` run will now persist the harness-native number).
- Per-category F1 breakdown (HealthBench stratifies by cluster; we report the aggregate).
- Changing the trust verdict to use balanced-F1.
- Exposing pass-precision/pass-recall as report/DTO fields (only the three F1s ship).

## File map

- crucible: `src/Crucible/Eval/Calibrate.hs` (+ its calibration test module).
- Modify: `src/Evals/Schema.hs` (MetaEval cols), `src/Evals/MetaEval.hs` (saveMetaEval),
  `evals-api/src/Evals/Api.hs` (MetaEvalDto), `src/Evals/Dashboard.hs` (metaEvalDto),
  `evals-ui/src/Evals/Ui/View.hs` (calibCard line), `scripts/seed-demo.sh`,
  `test/MetaEvalSpec.hs`, `test/ApiSpec.hs`, `zinc.toml` (crucible rev).
- Build: `nix develop -c zinc test spec` + `zinc build`; `scripts/build-ui.sh`; restart server.
