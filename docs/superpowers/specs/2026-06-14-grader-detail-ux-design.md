# Grader-detail UX — Design

**Status:** Approved direction (brainstorm w/ visual companion 2026-06-14). · **Date:** 2026-06-14

**Goal:** Make the run-detail page legible to a curious explorer: graders
explain *what kind they are* and *what they grade*, and the rubric breakdown
becomes a proper, connected view instead of a cramped pill-dropdown. One
criterion can be traced from "what it checks" → "the run's tag scores" → "this
answer's verdict".

## Decisions (approved)
- **Kind labels = internal kind words** (`exact`/`rubric`/`checklist`/`pointed`)
  shown verbatim on the pill + the table column header; the expanded section
  carries the plain-language explanation.
- **One slice (full loop):** kind tags + full-width grader-detail section +
  charted breakdown + per-row criterion verdicts.
- **Per-row verdicts show the judge's explanation inline** (the curious get
  "why 0.73?" without another click).

## Reconciliation with the data model (important)
A pointed grader's criteria are **per-example** (`Example.expected` is each
example's own signed-criteria rubric — HealthBench-style), NOT one grader-level
list. So the mockup's fixed grader-level criteria list would mislead in general.
Resolution: the **grader-detail section is run-level** (kind + method + the
aggregate tag breakdown + "criteria vary per example — expand a row"); the
**actual criteria live in the per-row expansion**, where they are real. Same
three-views story, truthful to the data.

## Facts (verified)
`Evals.Api`: `MetricDto {graderName, graderVersion, mean, passRate, count,
stderr, breakdowns :: [TagMetricDto]}`; `TagMetricDto {tag, mean, stderr,
count}`; `ScoreDto {graderName, graderVersion, value, passed, scoreError,
rationale}`; `OutputRowDto {…, scores :: [ScoreDto]}`. All derived JSON, shared
by server + wasm UI. `Grader.kind :: Text` (exact/rubric/checklist/pointed).
Pointed `Score.detail = {achieved, possible, criteria:[{criterion, points,
tags, met, explanation}]}`. `Evals.Dashboard.runSummary`/`groupedMetricDtos`
builds MetricDtos (grader name/version via `get @Grader`); `outputRowDto` builds
`ScoreDto`s. UI: `Evals.Ui.View` `metricChip`/`metricChipDetail`/
`breakdownPanel` (the current cramped panel), `runHeader` (threads
`_expandedM`), `outputsTable`/`scoreCell` (the outputs grid). `_expandedM ::
[MisoString]` + `ToggleExpand` is the expand mechanism. Miso 1.11 inline style:
`Miso.CSS.styleInline_ :: MisoString -> Attribute`. CSS in `static/style.css`
(class-based). Demo seed (`scripts/seed-demo.sh`) already has a `pointed`
grader "rubric" with per-criterion `Score.detail` on run 1.

## 1. DTO (`evals-api/src/Evals/Api.hs`)
- `MetricDto` gains `graderKind :: Text`.
- New `CriterionVerdictDto { criterion :: Text, points :: Double, tags ::
  [Text], met :: Bool, explanation :: Text }` (derived JSON).
- `ScoreDto` gains `criteria :: [CriterionVerdictDto]` (empty for non-pointed
  scores).

## 2. Server (`src/Evals/Dashboard.hs`)
- `groupedMetricDtos`: set `graderKind = <the grader's kind>` (already fetching
  `get @Grader` for the name — read `.kind`).
- `outputRowDto`/`scoreDto`: when building a `ScoreDto`, parse the `Score.detail`
  for the pointed shape (`criteria:[{criterion, points, tags, met,
  explanation}]`) into `[CriterionVerdictDto]`; non-pointed / absent → `[]`. (A
  small `criteriaFromDetail :: Maybe (Aeson Value) -> [CriterionVerdictDto]`
  helper; tolerant — malformed → `[]`.)

## 3. UI (`evals-ui/src/Evals/Ui/View.hs` + `static/style.css`)
**Pills (headlines).** `metricChip`/`metricChipDetail` append a **kind tag**
(`mc.graderKind`) as a small sub-label. The expandable chip (detail view) gets
`cursor:pointer` + a hover/focus affordance (box-shadow ring) so it reads as
interactive; non-expandable pills don't.

**Grader-detail section (full-width, run-level).** Replace the current cramped
`breakdownPanel` with a full-width section rendered below the chips row when a
grader is expanded (pushes the outputs table down). It contains:
- **Identity + method:** `<name> <version>` + the kind word + a static
  plain-language "how it scores" line keyed by kind (a UI lookup; no extra wire
  data) — e.g. pointed → "An LLM judges each criterion; score = points met ÷
  points possible (partial credit, no pass/fail)"; exact → "Compares the answer
  to the expected value (all-or-nothing)".
- **Score by tag (the chart):** the existing `breakdowns` rendered as a proper
  labeled horizontal bar chart — column headers (score / 95% CI / n), a 0–1
  scale with a midpoint gridline, namespace groups (theme/axis/cluster) each
  with a one-line explainer (axis = criterion-level; theme = example-level),
  higher-contrast bars, and a μ/±/n legend. Only shown when `breakdowns` is
  non-empty.
- For pointed graders, a line: *"criteria vary per example — expand a row below
  to see an answer's criteria."*

**Per-row criterion verdicts (outputs table).** In `outputsTable`, a pointed
grader's score cell (a `ScoreDto` with non-empty `criteria`) becomes expandable
(its own `_expandedM` key, e.g. `"sc:<exampleKey>:<grader>v<ver>"`, `cursor:
pointer` + caret). Expanded, it reveals a panel (spanning the row) listing each
`CriterionVerdictDto`: a ✓/✗ mark, the criterion text, its tag(s), the points
earned (`+P` met / `0 / P` missed; penalties shown as `+0 ok` / `−P`), and the
judge's `explanation` inline, then the total (`points met ÷ possible = value`).
Non-pointed score cells keep today's plain `value ✓/✗` (no expansion).

**CSS:** kind-tag styling; the grader-detail section container + chart (bars,
scale, headers, legend); the per-row criteria panel (✓/✗ marks, points pills,
explanation text); `cursor:pointer`/hover on the two expandable affordances.

## 4. Testing
- **DTO round-trips** (ApiSpec): `MetricDto.graderKind`; `CriterionVerdictDto`;
  `ScoreDto.criteria`.
- **Server** (ApiSpec serverSpec): the run's metric carries `graderKind ==
  "<kind>"`; a pointed output's `ScoreDto.criteria` is parsed from the seeded
  `Score.detail` (assert a criterion's `met`/`points`/`explanation`); a
  non-pointed score has `criteria == []`.
- **UI render** has no harness — verified by the wasm build linking +
  eyeballing `seed-demo` + dashboard.

## 5. Demo seed
The existing seed already has pointed `Score.detail` on run 1, so the per-row
expansion has data. (Optional, separate from this slice: enrich the seed so the
criteria/tags read coherently — the current demo mixes capitals data with
hand-set medical-flavoured tags.)

## 6. Out of scope
- Surfacing grader CONFIG (the exact `field`, a rubric's text, a checklist's
  criteria) in the grader-detail "method" area — the static per-kind line covers
  the explanation without new wire data; config display is a later slice.
- Keyboard/ARIA semantics on the expandable cells (cursor + hover only here).
- The meta-eval κ surface; HealthBench-number reproduction.
