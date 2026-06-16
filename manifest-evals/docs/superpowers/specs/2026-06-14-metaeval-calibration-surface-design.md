# Meta-eval κ calibration surface — design

**Date:** 2026-06-14
**Status:** approved (pending spec review)

## Goal

Surface the persisted `MetaEval` calibration reports (agreement, Cohen's κ + 95% CI,
fail precision/recall) on the Miso dashboard so a curious user can answer **"can I trust
this grader?"** — on a single run *and* across the grader version's whole history.

Two surfaces:

1. **Run-detail calibration section** — for the run being viewed, the latest report per
   `(graderVersion, mode)`, with a κ-over-time sparkline drawn from that grader version's
   full meta-eval history across all runs.
2. **Cross-run calibration view** — a `#/calibration` route grouped by grader version,
   showing every grader's latest report and trend in one place.

## Why this shape (the headline cue)

κ stays the central summary statistic, but the **judgment** is not the arbitrary
Landis–Koch adjective. The headline verdict is driven by **the κ 95%-CI lower bound vs a
trust threshold** (default **0.6**, exposed as a tunable constant), because that accounts
for sample size where the qualitative band ignores it and κ suffers the prevalence
paradox. Supporting cues:

- **κ + 95% CI on a 0–1 bar** with a threshold marker (headline visual).
- **Verdict text** from CI-lower-bound vs threshold: `lower bound 0.64 ≥ 0.60 → trustworthy`.
- **κ-over-time sparkline** across the grader version's runs, current run's point marked.
- **fail-precision / fail-recall** pair (the grader's actual job: catching failures).
- **agreement %** + measured-N as context.
- **Landis–Koch adjective** demoted to a learnable sub-label / tooltip
  (`κ 0.72 — "substantial"`), never the verdict.

The trust threshold is a single named constant `kappaTrustThreshold = 0.6` so it is easy
to find and change.

## Data model

No schema change. `MetaEval` is append-history (no `notifyChanges`), keyed by
`(run, graderVersion)` with `mode`, `seed`, `computedAt`, and the report fields
(`agreement`, `kappa`, `kappaLow`, `kappaHigh`, `failPrecision`, `failRecall`,
`measured`, `judgeErrors`). Multiple rows per `(run, graderVersion, mode)` over time;
"latest" = max `computedAt`.

## DTOs (evals-api `Evals.Api`)

```haskell
-- One calibration report, denormalised with grader identity for display.
data MetaEvalDto = MetaEvalDto
  { graderName    :: Text
  , graderVersion :: Int          -- the human-facing version number, not the Pk
  , graderKind    :: Text         -- "exact" | "pointed" | ...
  , mode          :: Text         -- "live" | "stored"
  , agreement     :: Double
  , kappa         :: Double
  , kappaLow      :: Double
  , kappaHigh     :: Double
  , failPrecision :: Double
  , failRecall    :: Double
  , measured      :: Int
  , judgeErrors   :: Int          -- count, derived from the stored Aeson array length
  , computedAt    :: Text         -- ISO-8601, for ordering/labelling the trend
  , trusted       :: Bool         -- kappaLow >= kappaTrustThreshold
  , band          :: Text         -- Landis–Koch adjective for kappa
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- A grader version's calibration history: the latest report + the κ trend.
data CalibrationSeriesDto = CalibrationSeriesDto
  { graderName    :: Text
  , graderVersion :: Int
  , graderKind    :: Text
  , mode          :: Text
  , latest        :: MetaEvalDto       -- most recent by computedAt
  , trend         :: [TrendPointDto]   -- chronological, oldest → newest
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

data TrendPointDto = TrendPointDto
  { runId      :: Int
  , kappa      :: Double
  , kappaLow   :: Double
  , kappaHigh  :: Double
  , computedAt :: Text
  , isCurrent  :: Bool   -- run-detail only: marks the run being viewed; always False cross-run
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

`RunDetailDto` gains one field:

```haskell
data RunDetailDto = RunDetailDto
  { run         :: RunSummaryDto
  , outputs     :: [OutputRowDto]
  , calibration :: [CalibrationSeriesDto]   -- per (graderVersion, mode) for this run; [] when none
  }
```

The trust verdict (`trusted`) and `band` are computed **server-side** so the threshold and
the Landis–Koch cut-points live in one place (`Evals.Api` or a small `Evals.Calibration`
helper module shared by server and any future consumer). `band` mapping:
`<0.2 slight · 0.2–0.4 fair · 0.4–0.6 moderate · 0.6–0.8 substantial · ≥0.8 almost perfect`.

## Server (`Evals.Dashboard`)

### Shared helper

`calibrationSeriesFor :: Maybe RunId -> [GraderVersionId] -> Db [CalibrationSeriesDto]`
or simpler two builders:

- `metaEvalDto :: MetaEval -> Db MetaEvalDto` — resolves grader identity
  (`GraderVersion` → grader name/version-number/kind), counts `judgeErrors`, computes
  `trusted`/`band`.
- For each `(graderVersion, mode)` present, fetch that grader version's full MetaEval
  history (all runs) ordered by `computedAt`, build `trend`, pick `latest`.

### Run-detail (`runDetailHandler`)

After building `summary`/`outputs`, gather the `MetaEval` rows for **this** run, group by
`(graderVersion, mode)`. For each group:

- `latest` = the most recent row **for this run**.
- `trend` = that grader version's history **across all runs** (chronological), each point's
  `isCurrent = (runId == thisRun)`. This is what lets the sparkline show whether this run's
  κ is typical.

Add `calibration` to the returned `RunDetailDto`. Empty list when the run has no meta-evals.

### Cross-run (`GET /api/calibration`)

New route `["api","calibration"]`. Returns `[CalibrationSeriesDto]` for **every**
`(graderVersion, mode)` that has any MetaEval row:

- `latest` = most recent row overall for that group.
- `trend` = full history across runs, `isCurrent = False` throughout.

Sorted by grader name, then version, then mode.

## UI (`evals-ui`)

### Model

- `Route` gains `CalibrationR` (hash `#/calibration`). `parseHash`/`relevantTo`
  (detailTables include `meta_evals`) / `SetRoute` / `fetchRoute` / `viewModel` get the
  new arm. New remote field `_calibrationM` + lens + `GotCalibration` action with the
  usual stale guard.
- `RunR` already loads run-detail; `calibration` rides inside `RunDetailDto`, so no extra
  fetch on run-detail.

### Run-detail section (`View.hs`)

Below the grader-detail sections, render a `calibrationSection :: [CalibrationSeriesDto] -> View`
(omitted entirely when empty). Per series, a `.calib-card`:

- Header: grader name + kind tag + mode chip.
- κ bar: a 0–1 track with the CI band shaded and the point marked; a threshold tick at
  0.6; verdict text (`trusted` → "trustworthy" / else "below trust threshold") with the
  CI-lower-bound number.
- Sparkline: inline SVG polyline of `trend` κ values, current point highlighted.
- Secondary line: `fail-precision`, `fail-recall`, `agreement %`, `n=measured`.
- Sub-label: `κ 0.72 — "substantial"` (the demoted band), with `judgeErrors` count if > 0.

### Cross-run view (`View.hs`)

`calibrationView :: RemoteData [CalibrationSeriesDto] -> View` — a back link, a heading,
a short legend explaining the κ bar / threshold / band vocabulary (the teaching aid), then
one `.calib-card` per series reusing the same card renderer as run-detail. A nav link to
`#/calibration` added wherever the runs-list / compare nav lives.

### Sparkline

Hand-rolled inline SVG (no new dep): a `<svg>` with a `<polyline>` over the trend points
scaled to the card width, a faint horizontal line at the 0.6 threshold, and a highlighted
`<circle>` for the current/latest point. Single point → just the dot. Empty trend → skip.

### Styles (`static/style.css`)

New classes following the existing card idiom (`--line`, `--muted`, `--accent`): `.calib`,
`.calib-card`, `.calib-bar`/`.calib-track`/`.calib-ci`/`.calib-mark`/`.calib-threshold`,
`.calib-verdict.trusted` / `.calib-verdict.untrusted`, `.calib-spark`, `.calib-sub`,
`.calib-legend`.

## Demo seed (`scripts/seed-demo.sh`)

The demo currently has 0 `meta_evals` rows. Enrich so both surfaces have content:

- Insert MetaEval rows for the two graders (`exactness/exact`, `rubric/pointed`) against
  the existing runs, with several `computedAt` timestamps to make a visible trend.
- Numbers chosen so the surface teaches: one grader comfortably above threshold
  (κ ≈ 0.78, CI low ≈ 0.66 → trustworthy) and one borderline (κ ≈ 0.55, CI low ≈ 0.38 →
  below threshold), with fail-precision/recall and agreement that reconcile with the κ.
- A short upward trend on at least one grader so the sparkline is meaningful.

## Testing

- **`test/ApiSpec.hs`**: seed MetaEval rows in the ephemeral DB; assert
  `GET /api/runs/N` includes a non-empty `calibration` with correct `latest`/`trend`/
  `trusted`/`band`; assert `GET /api/calibration` returns one series per
  `(graderVersion, mode)` with history ordered chronologically and `isCurrent = False`.
- **Band/trust helper**: pure unit assertions over `bandOf`/`trusted` at the cut-points
  (0.2, 0.4, 0.6, 0.8 boundaries; CI-low exactly 0.6).
- Rebuild wasm via `scripts/build-ui.sh`; restart the `evals-dashboard` process (wire-shape
  change → both the wasm and the running server binary must be current).

## Out of scope

- No new persistence or meta-eval *execution* changes — this slice only reads existing
  `MetaEval` rows.
- No drift-across-grader-*versions* comparison (trend is within a single grader version).
- No configurable threshold UI — `kappaTrustThreshold` is a code constant for now.
