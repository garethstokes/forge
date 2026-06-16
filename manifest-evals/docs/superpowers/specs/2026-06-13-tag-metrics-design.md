# Eval Orchestrator — Tag Dimensional Metrics (HealthBench slice 3) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-13

**Goal:** `RunMetric` breakdowns by tag — HealthBench's axis/cluster scores
(re-scoring the stored pointed per-criterion verdicts by tag, no extra judge
calls) and theme scores (the example's overall score bucketed by
`example_tags`), with aggregate clipping. The dimensional report HealthBench
publishes, minus bootstrap stderr.

---

## 0. Context

The pointed grader (slice 1) persists per-criterion verdicts in
`Score.detail = {achieved, possible, criteria: [{criterion, points, tags,
met, explanation}]}`; ingestion (slice 2) folds HealthBench `example_tags`
into `Example.meta`. So the tag breakdowns are computable from stored data —
HealthBench re-scores the rubric-level (axis/cluster) tags from existing
verdicts with NO extra grader calls, and buckets the example-level (theme)
tags by the example's overall score.

`recompute` (in `Evals.Grade`) today, per grader version, queries
`(s.value, s.passed)` over the run's Scores and writes one `RunMetric`
(`mean` unclipped, `passRate` over verdict-bearing rows, `count`).

**Decisions** (user-approved): clip EVERY `RunMetric.mean` to [0,1] (a no-op
for exact/rubric/checklist, the real thing for pointed); the dashboard only
gets a no-regression filter (overall metric still shown; tag-chip rendering
is a later slice); `bootstrap_std`/CI is a later slice.

## 1. Schema

`RunMetric` gains `tag :: Field f (Maybe Text)` — `Nothing` is the overall
metric (today's row); `Just t` is a per-tag breakdown. Greenfield → an
additive nullable `ADD COLUMN` (manifest's migrate handles it). No new index:
`recompute`'s `deleteWhere [#run, #graderVersion]` already clears all of a
grader's metric rows (overall + every tag) before re-inserting.

## 2. The aggregation (pure)

A pure function takes the run's per-Score data and returns the metric rows.
Input per Score (for one grader version): `(value :: Maybe Double,
passed :: Maybe Bool, detail :: Maybe Value, exampleMeta :: Maybe Value)`.

```haskell
-- one emitted metric row
data DimMetric = DimMetric
  { tag :: Maybe Text, mean :: Double, passRate :: Maybe Double, count :: Int }

clip01 :: Double -> Double                 -- max 0 . min 1
axisScoresFromDetail :: Value -> [(Text, Double)]   -- per-tag achieved/possible for one example
exampleThemes :: Value -> [Text]           -- example_tags from meta
dimensionalMetrics :: [(Maybe Double, Maybe Bool, Maybe Value, Maybe Value)] -> [DimMetric]
```

`dimensionalMetrics` produces, in this order:

- **overall** (`tag = Nothing`): over rows with a `Just` value — `mean =
  clip01 (avg values)`, `passRate` over `Just`-passed rows (today's rule),
  `count = #graded`.
- **themes** (any kind): for each graded row, for each tag in
  `exampleThemes meta`, contribute the row's `value`. Per theme → `mean =
  clip01 (avg)`, `count = #contributing rows`, `passRate = Nothing`.
- **axes/clusters** (pointed only): for each graded row WITH a `detail`, for
  each `(tag, score)` from `axisScoresFromDetail detail`, contribute `score`.
  Per tag → `mean = clip01 (avg)`, `count`, `passRate = Nothing`.

`axisScoresFromDetail detail`: decode `criteria`; group its items by each tag
(an item with multiple tags contributes to each); per tag,
`sum(points of met items) / sum(positive points)` over that tag's items;
emit a `(tag, score)` only when that tag's positive points `> 0` (else the
example doesn't contribute to that axis — HealthBench's `None` skip). A
non-pointed or malformed `detail` yields `[]`.

`exampleThemes meta`: read `example_tags` (a `[Text]`); anything else → `[]`.

Theme and axis tag namespaces are distinct in practice (`theme:*` vs
`axis:*`/`cluster:*`), but the function makes no assumption — if the same tag
string appeared in both, the two sources would (correctly, separately) be
distinct metrics only if disjoint; since they share the `tag` key, a clash
would merge them. Acceptable: HealthBench's namespaces don't collide, and a
collision would simply pool the contributions, which is defensible.

## 3. `recompute` rewrite

Per grader version, one session: a `runQuery` joining `Score → Output →
Example` (`output.run == runId && score.graderVersion == gv.id`) projecting
`(s.value, s.passed, s.detail, e.meta)`. Run `dimensionalMetrics`.
`deleteWhere [#run ==. runId, #graderVersion ==. gv.id]` (clears the gv's
overall + all tag rows), then `add` one `RunMetric` per `DimMetric`
(`tag` from the row; `mean`/`passRate`/`count` likewise; `computedAt = now`).

## 4. Dashboard (no-regression)

`runSummary`'s metric query (`selectWhere [#run ==. r.id] :: [RunMetric]`)
gains `#tag ==. (Nothing :: Maybe Text)` so the existing chips show only the
overall metric. `MetricDto` and the UI are unchanged; tag-chip rendering is a
later slice.

## 5. Testing

- **Pure**: `clip01` (negative → 0, >1 → 1, in-range identity);
  `axisScoresFromDetail` over a hand detail (two tags, mixed met, the
  no-positive-points skip); `exampleThemes` (present / absent / malformed);
  `dimensionalMetrics` over a hand vector of 2–3 rows — assert the overall
  (clipped), a theme bucket mean+count, an axis bucket mean+count, and that a
  negative-overall row clips the overall to 0.
- **Engine** (ephemeral PG): a pointed run with axis-tagged criteria on
  examples carrying `meta.example_tags` → assert the emitted RunMetric rows
  (overall `tag = Nothing`, the `axis:*` rows, the `theme:*` rows) by their
  clipped means and counts; the existing `metricSpec` (rubric, untagged
  examples) still yields exactly one overall row, unchanged (clipping a
  no-op).
- **Dashboard**: a run seeded with an overall + a tag RunMetric → the API
  returns only the overall metric in the run summary.

## 6. Out of scope (later slices)

- `bootstrap_std` / metric stderr + confidence interval.
- Dashboard rendering of the tag breakdowns (chips, grouping).
- The OpenAI judge provider knob.
