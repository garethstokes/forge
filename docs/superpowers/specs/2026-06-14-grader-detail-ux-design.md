# Grader-detail UX (Slice A) — Design

**Status:** Approved direction (brainstorm w/ visual companion 2026-06-14). · **Date:** 2026-06-14

**Goal:** Make a run's graders legible: each pill shows *what kind* it is, and
expanding it opens a full-width, run-level **grader-detail section** with a
plain-language "how it scores" line and a proper charted tag breakdown — instead
of the current cramped pill-dropdown. (The per-example criteria + the
input/prompt/response/grades inspector are **Slice B**, sequenced after this.)

## Decisions (approved)
- **Kind labels = internal kind words** (`exact`/`rubric`/`checklist`/`pointed`)
  shown verbatim on the pill + the table column header; the expanded section
  carries the plain-language explanation.
- **Two sequenced slices.** This is Slice A (run-level grader legibility). Slice
  B is the per-example inspector (separate spec), which absorbs the
  per-criterion verdicts.

## Data-model note
A pointed grader's criteria are **per-example** (`Example.expected` is each
example's own rubric), not one grader-level list — so the grader-detail section
is **run-level only**: kind + method + the aggregate tag breakdown. The actual
criteria are surfaced per-example in Slice B's inspector.

## Facts (verified)
`Evals.Api`: `MetricDto {graderName, graderVersion, mean, passRate, count,
stderr, breakdowns :: [TagMetricDto]}`; `TagMetricDto {tag, mean, stderr,
count}`. Derived JSON, shared by server + wasm UI. `Grader.kind :: Text`
(exact/rubric/checklist/pointed). `Evals.Dashboard.groupedMetricDtos` builds
MetricDtos (grader name/version via `get @Grader` — already in hand, read
`.kind`). UI: `Evals.Ui.View` `metricChip`/`metricChipDetail`/`breakdownPanel`
(the current cramped panel), `runHeader` (threads `_expandedM`/`ToggleExpand`).
Miso 1.11 inline style: `Miso.CSS.styleInline_ :: MisoString -> Attribute`. CSS
in `static/style.css` (class-based). Demo seed has a `pointed` grader "rubric"
with tagged `run_metrics` on run 1.

## 1. DTO (`evals-api/src/Evals/Api.hs`)
`MetricDto` gains `graderKind :: Text`.

## 2. Server (`src/Evals/Dashboard.hs`)
`groupedMetricDtos`: set `graderKind = <grader>.kind` (it already fetches the
`Grader` for the name).

## 3. UI (`evals-ui/src/Evals/Ui/View.hs` + `static/style.css`)
**Pills (headlines).** `metricChip`/`metricChipDetail` append a **kind tag**
(`mc.graderKind`) as a small sub-label. In the run-detail view **every** grader
pill is expandable (`cursor:pointer` + a hover/focus ring + a caret) so any
grader — including a plain `exact` one with no breakdown — can be clicked to
learn what kind it is and how it scores. (List/compare keep the plain
non-interactive `metricChip` + kind tag.)

**Grader-detail section (full-width, run-level).** Replace the cramped
`breakdownPanel` with a full-width section rendered below the chips row when a
grader is expanded (pushes the outputs table down). It contains:
- **Identity + method:** `<name> <version>` + the kind word + a static
  plain-language "how it scores" line keyed by kind (a UI lookup; no extra wire
  data) — pointed → "An LLM judges each criterion; score = points met ÷ points
  possible (partial credit, no pass/fail)"; exact → "Compares the answer to the
  expected value (all-or-nothing)"; rubric → "LLM pass/fail against a rubric";
  checklist → "Weighted yes/no checklist". Unknown kind → a generic line.
- **Score by tag (the chart):** the existing `breakdowns` rendered as a proper
  labeled horizontal bar chart — column headers (score / 95% CI / n), a 0–1
  scale with a midpoint gridline, namespace groups (theme/axis/cluster) each
  with a one-line explainer (axis = criterion-level; theme = example-level),
  higher-contrast bars, a μ/±/n legend. Shown only when `breakdowns` is
  non-empty.
- For pointed graders, a pointer line: *"criteria vary per example — open an
  example to see its criteria"* (the example inspector is Slice B).

**CSS:** kind-tag styling; the grader-detail section container + chart (bars,
scale, headers, legend); `cursor:pointer`/hover on the expandable chip.

## 4. Testing
- **DTO round-trip** (ApiSpec): `MetricDto.graderKind`.
- **Server** (ApiSpec serverSpec): the run's metric carries `graderKind ==
  "<kind>"` for the seeded grader.
- **UI render** has no harness — verified by the wasm build linking +
  eyeballing `seed-demo` + dashboard.

## 5. Out of scope (Slice A)
- The example inspector (input / generated prompt / response / grades) and the
  per-criterion verdicts → **Slice B** (separate spec).
- Surfacing grader CONFIG (the exact `field`, a rubric's text) — the static
  per-kind "how it scores" line covers it without new wire data.
- Keyboard/ARIA semantics (cursor + hover only).
