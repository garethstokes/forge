# Dashboard tag-chips + stderr — Design

**Status:** Approved (brainstorm w/ visual companion 2026-06-13). · **Date:** 2026-06-13

**Goal:** Surface the `RunMetric` per-tag breakdowns (`theme:*`/`axis:*`/
`cluster:*`) and the bootstrap stderr on the Miso wasm dashboard. The data is
already in the DB (`RunMetric.tag` + `.stderr`) but nothing displays it — the
server filters to the overall row and the DTO drops both fields.

## Decisions (approved, visual companion)
- **Overall chip** (runs list, compare, detail) shows `μ X ±CI` where `±CI` is
  the 95% half-width `1.96·stderr`.
- **Breakdowns render in the run-DETAIL view only** (not the list/compare — the
  inline panel is too tall for a multi-row list). In detail, each grader's
  overall chip is clickable (when it has breakdowns) → expands a grouped bar
  panel (layout "A" from the mockups).
- **DTO is grouped by grader:** one `MetricDto` per grader carrying nested
  `breakdowns`, not flat per-tag rows.
- Namespace coloring: `theme:*` amber, `axis:*` teal, `cluster:*` purple.

## Facts (verified)
- `evals-api/src/Evals/Api.hs`: `MetricDto { graderName :: Text, graderVersion ::
  Int, mean :: Double, passRate :: Maybe Double, count :: Int }`
  (`deriving (Eq, Show, Generic, ToJSON, FromJSON)`), nested in `RunSummaryDto
  { …, metrics :: [MetricDto] }`. All DTOs are derived-JSON; the wasm UI imports
  `Evals.Api` directly (shared types, decoded via `eitherDecodeStrictText`).
- `src/Evals/Dashboard.hs` `runSummary`: `allMetrics <- selectWhere [#run ==.
  r.id]; let metrics = filter (\m -> isNothing m.tag) allMetrics; metricDtos <-
  mapM metricDto metrics; … sortOn graderName`. `metricDto rm` reads
  `rm.graderVersion/mean/passRate/count` (NOT `.tag`/`.stderr`) and resolves the
  grader name/version via `get @GraderVersion`/`get @Grader`. Used by `/api/runs`
  and `/api/runs/<id>` (`runDetailHandler` calls `runSummary`).
- `RunMetric { …, mean :: Double, passRate :: Maybe Double, count :: Int,
  computedAt, tag :: Maybe Text, stderr :: Maybe Double }`.
- `evals-ui/src/Evals/Ui/View.hs` `metricChip :: MetricDto -> View Model Action`
  renders `span_ [class "chip metric"] [text (graderName <> " v" <> ver <> " · μ
  " <> fmtD mean <> passTxt)]`. Used in `runRow` (list), `runHeader` (detail),
  `runCard` (compare). `Model` has `_expandedM :: [MisoString]` + an
  `ToggleExpand MisoString` action (existing expand mechanism). `fmtD` formats a
  Double to 3dp; `ms`/`msShow` are MisoString helpers.
- `static/style.css`: class-based chips (`.chip`, `.chip.metric` `#e8eefb/#1e3a8a`,
  `.chip.ok/.fail/.muted`) + `:root` CSS vars. The UI builds via
  `scripts/build-ui.sh` (wasm32-wasi from `evals-ui/`, restages `static/`); the
  miso + aeson dual pins live in both `zinc.toml`s. No new deps here.

## 1. DTO (`evals-api/src/Evals/Api.hs`)
```haskell
data TagMetricDto = TagMetricDto
  { tag :: Text, mean :: Double, stderr :: Maybe Double, count :: Int }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data MetricDto = MetricDto
  { graderName :: Text, graderVersion :: Int, mean :: Double, passRate :: Maybe Double
  , count :: Int
  , stderr :: Maybe Double          -- NEW: bootstrap stderr of the overall mean
  , breakdowns :: [TagMetricDto]     -- NEW: per-tag rows (empty for non-pointed/untagged)
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

## 2. Server (`src/Evals/Dashboard.hs`)
`runSummary` stops filtering. It groups the run's `RunMetric`s by
`graderVersion` and builds one `MetricDto` per grader:
- overall = the `tag == Nothing` row → `mean`/`passRate`/`stderr`/`count`;
- `breakdowns` = the `tag = Just t` rows → `TagMetricDto {tag = t, mean, stderr,
  count}`, sorted by `tag`.
A grader whose group has no `Nothing` row is skipped (defensive — `recompute`
always emits the overall). Group ordering by grader name (today's `sortOn`).
A small grouping helper replaces the per-row `mapM metricDto`; the grader
name/version resolve once per group (`get @GraderVersion`/`get @Grader`). Uses
`Data.Map.Strict` for the grouping. `runDetailHandler` is unchanged (it reuses
`runSummary`).

## 3. UI (`evals-ui/src/Evals/Ui/View.hs` + `static/style.css`)
- **`metricChip`** (list, compare, detail): append `±CI` —
  `… · μ <fmtD mean><ciTxt stderr><passTxt>` where `ciTxt = maybe "" (\s -> " ±"
  <> fmtD (1.96*s))`. No expansion in list/compare.
- **Run-detail header** (`runHeader`): wrap each grader's chip so that, when
  `breakdowns` is non-empty, it is clickable (`onClick (ToggleExpand key)`,
  `key = msShow runId <> ":" <> graderName <> "v" <> graderVersion`) and renders
  a caret; when expanded (`key ∈ _expandedM`), render `breakdownPanel` below.
- **`breakdownPanel :: MetricDto -> View Model Action`**: group `breakdowns` by
  namespace (`namespace t = takeWhile (/= ':') t`; `label t = drop 1 (dropWhile
  (/= ':') t)`, falling back to the whole tag if no colon). For each namespace
  group (ordered theme, axis, cluster, then any other): a `.grp-label` + a row
  per tag = colored `.chip.<ns>` label + a `.bar.<ns>` (inner width `mean*100%`)
  + `fmtD mean <> ciTxt stderr` + `count`.
- **CSS** (`static/style.css`): add `.chip.theme/.axis/.cluster` (amber/teal/
  purple, mirroring the mockup), and `.brk/.grp-label/.row/.bar` + the per-ns bar
  fills.

## 4. Testing
- **ApiSpec DTO round-trip:** extend the existing `MetricDto` round-trip for
  `stderr` + `breakdowns`; add a `TagMetricDto` round-trip.
- **ApiSpec server scenario:** the current dashboard test seeds an overall +
  an `axis:accuracy` tag `RunMetric` and asserts the tag row is *excluded* (one
  metric). UPDATE it: now assert the run has **one** `MetricDto` (the overall)
  whose `breakdowns` has **one** entry (`tag == "axis:accuracy"`), with the
  overall `mean`/`stderr` and the breakdown `mean` present.
- **Wasm UI render** is not unit-tested (no UI harness) — verified by
  `scripts/build-ui.sh` linking + manual `seed-demo` + dashboard eyeball.

## 5. Out of scope
- The meta-eval κ dashboard surface (separate slice).
- Sparklines / metric history; sort/filter by tag; CSV export.
- Showing breakdowns in the runs list / compare (detail-only by decision).
