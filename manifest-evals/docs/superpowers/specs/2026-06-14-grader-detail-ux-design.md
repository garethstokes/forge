# Grader-detail UX (Slice A) — Design

**Status:** Approved; revised after first render (2026-06-14). · **Date:** 2026-06-14

**Goal:** In the run-detail view, each grader is **always shown as a section**
(no pills, no click-to-expand) with its headline values as a sub-heading, a
plain-language "how it scores" line, the rubric's criteria (the run's union, for
pointed graders), and a charted tag breakdown. Make graders self-explanatory.

## Decisions (approved)
- **Kind labels = internal kind words** (`exact`/`pointed`/…), shown on the
  section header (and on the list/compare pills).
- **Run-detail = no pills.** Every grader renders an always-open section; the
  pill `μ/±CI/pass%` values fold into the section as a **sub-heading**. (The runs
  *list* and *compare* keep their compact `metricChip` pills with a kind tag.)
- **Rubric extra info = the run's criteria union.** A pointed grader's section
  lists the distinct criteria it used across this run (criterion + points +
  tags). Per-*answer* verdicts remain Slice B (the example inspector).

## Data-model note
A pointed grader's criteria are **per-example** (`Example.expected`). The
run-level section shows the **union** of criteria seen across the run's scores
(deduped by criterion text) — meaningful when a rubric is reused (long but
honest when fully per-example). The met/explanation are per-answer → Slice B.

## Facts (verified)
`Evals.Api`: `MetricDto {graderName, graderVersion, graderKind, mean, passRate,
count, stderr, breakdowns :: [TagMetricDto]}` (graderKind already added);
`TagMetricDto {tag, mean, stderr, count}`. Derived JSON, shared server + wasm UI.
`Grader.kind :: Text`. Pointed `Score.detail = {achieved, possible,
criteria:[{criterion, points, tags, met, explanation}]}`
(`Grade.hs:213`). `axisScoresFromDetail` (`Grade.hs:448`) is the tolerant
parse template. `Evals.Dashboard.runSummary` → `groupedMetricDtos` builds
MetricDtos from `RunMetric`s; `runSummary` is called by BOTH the runs-list
handler (`runsHandler`) and `runDetailHandler`. A `Score→Output` `runQuery` join
(filter `output.run == runId && score.graderVersion == gvId`) is the pattern
(see `recompute`/`existingFor` in `Grade.hs`). UI `Evals.Ui.View`: current
`graderPill`/`graderDetailSection`/`runHeader` (the pill + expand machinery to
remove); `metricChip` (list/compare, keeps kind tag); `chipText`/`ciTxt`/
`passTxt`/`namespace`/`labelOf`/`widthStyle`/`fmtD`/`msShow` helpers exist.
`static/style.css` has the Slice-A `.gdetail`/`.chart`/`.chip .kind` rules.

## 1. DTO (`evals-api/src/Evals/Api.hs`)
New `RubricCriterionDto { criterion :: Text, points :: Double, tags :: [Text] }`
(derived JSON). `MetricDto` gains `criteria :: [RubricCriterionDto]` (the run's
criteria union; empty for non-pointed graders / the list view).

## 2. Server (`src/Evals/Dashboard.hs`)
- `runSummary` gains a `detail :: Bool` parameter; `runsHandler` calls it
  `False`, `runDetailHandler` calls it `True` — so the list doesn't pay for the
  criteria query.
- `groupedMetricDtos` takes `detail` + the `RunId`; in `buildOne`, when `detail
  && gKind == "pointed"`, set `criteria = rubricCriteriaFor runId gvId`, else
  `[]`.
- `rubricCriteriaFor :: RunId -> GraderVersionId -> Db [RubricCriterionDto]`:
  `runQuery` joining `Score→Output` (filter `output.run == runId &&
  score.graderVersion == gvId`) projecting `score.detail`; parse each detail's
  `criteria` array into `[RubricCriterionDto]` (tolerant); **dedup by criterion
  text** (keep first points/tags), sort by criterion. Reuse a
  `rubricCriteriaFromDetail :: Maybe (Aeson Value) -> [RubricCriterionDto]`
  parser (template: `axisScoresFromDetail`).

## 3. UI (`evals-ui/src/Evals/Ui/View.hs` + `static/style.css`)
- **Remove** `graderPill`, `gKey`, and the pill/expand wiring from `runHeader`.
  `runHeader` no longer needs `_expandedM` for graders — render
  `div_ [P.class_ "grader-details"] (map graderDetailSection r.metrics)`
  (every grader, always open). (`runHeader`'s `[MisoString]` arg may become
  unused for graders — keep the signature; the output-cell expand still uses
  `_expandedM`.)
- **`metricChip`** (list/compare) unchanged (kind tag, no expand).
- **`graderDetailSection mc`** (always-open card):
  - **Head:** `strong name` + ` v<version>` + the `kind big` tag + a
    **sub-heading** `valsLine mc` (`"μ " <> fmtD mc.mean <> ciTxt mc.stderr <>
    passTxt mc.passRate`) + the `methodLine mc.graderKind`.
  - **Criteria** (pointed, when `criteria` non-empty): a "what it checks · N
    criteria" block listing each `RubricCriterionDto` — a points pill (`+P`/`−P`)
    + the criterion text + its tag chips.
  - **Breakdown chart** (when `breakdowns` non-empty): the existing
    `breakdownChart` (column headers, 0–1 scale, namespace groups + hints,
    legend) — unchanged.
  - For pointed, keep the pointer line *"per-answer verdicts: open an example"*
    (Slice B) — reworded from the old "criteria vary per example" note since the
    criteria are now listed here.
- **CSS:** the sub-heading (`.gvals`), the criteria block (`.criteria`, points
  pills, tag chips); drop the `.chip.metric.expandable`/`.caret` rules (no longer
  used in detail).

## 4. Testing
- **DTO round-trips** (ApiSpec): `RubricCriterionDto`; `MetricDto.criteria`.
- **Server** (ApiSpec serverSpec): seed a pointed grader's `Score` with
  `detail.criteria` on the run, hit `/api/runs/<id>` (detail) → assert the
  grader's `MetricDto.criteria` carries the deduped criterion(s) (criterion +
  points + tags); assert the runs-LIST (`/api/runs`) returns `criteria == []`
  for the same grader (the `detail=False` path).
- **UI render** — no harness; wasm build linking + demo eyeball (run 1 pointed
  grader now shows its criteria union + always-open section).

## 5. Out of scope
- Per-answer criterion verdicts (met/explanation) + the example inspector →
  Slice B.
- Grader CONFIG display (the exact `field`, a rubric's prose) — static per-kind
  method line covers the explanation.
