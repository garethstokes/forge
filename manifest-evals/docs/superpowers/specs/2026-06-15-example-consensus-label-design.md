# Surface human consensus label + judge errors on the example page — design

**Date:** 2026-06-15
**Status:** approved

## Problem

On a HealthBench **calibration** run, the example-detail page's GRADES panel is
empty: a calibration run writes no per-output `score` rows. The actually-useful
per-example signal — the human gold label the grader is judged against, and
whether a judge errored on this example — lives in `criterion_labels` and
`meta_evals` but is never surfaced.

## Decision

Extend the existing example-detail endpoint and render the extra signal **inside
the existing "Grades" panel** (no new section header). Two additions:

1. **Human consensus label(s)** — from `criterion_labels` for the output: the
   rubric `criterion` text + the `human` gold verdict (met / not-met) + optional
   `source`.
2. **Judge-error flags** — from the run's `meta_evals`: if a judge (grader
   version) errored on this example, show "judge ⟨name⟩ v⟨n⟩ couldn't judge:
   ⟨criterion⟩".

### What this does NOT do

Per-judge **agreement** per example (did judge X match the human here?) is not
shown — those per-output verdicts were never persisted; `meta_evals` keeps only
the aggregate κ and the error list. Showing agreement would require a re-run with
verdict persistence (declined).

## Data facts

- `criterion_labels(output, criterion, human :: Bool, source :: Maybe Text)`,
  unique on `(output, criterion)`. In the HealthBench run: one label per output.
- `meta_evals.judge_errors` is a JSON array of `caseKey` strings, where
  `caseKey = "<exampleKey>:<criterion>"` (built in `Evals.MetaEval.caseTuples`).
  Match this example's errors by the `"<exampleKey>:"` prefix; the criterion is
  the remainder after the first `:`.
- A run may have multiple `meta_evals` per grader version (history). Use the
  **latest per grader version** (max `computedAt`), mirroring `runCalibration`.

## Server changes

### Wire DTOs (`evals-api/src/Evals/Api.hs`)

```haskell
data CriterionLabelDto = CriterionLabelDto
  { criterion :: Text, human :: Bool, source :: Maybe Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data JudgeErrorDto = JudgeErrorDto
  { graderName :: Text, graderVersion :: Int, criterion :: Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

`ExampleDetailDto` gains:

```haskell
  , labels      :: [CriterionLabelDto]
  , judgeErrors :: [JudgeErrorDto]
```

(`graderVersion`/`criterion` already appear on other DTOs;
`DuplicateRecordFields` is on, so no clash.)

### `exampleDetailHandler` (`src/Evals/Dashboard.hs`)

After resolving the output `o`:

1. `lbls <- selectWhere [ #output ==. o.id ] :: Db [CriterionLabel]`; map to
   `CriterionLabelDto`, sorted by `criterion`.
2. `metas <- selectWhere [ #run ==. rid ] :: Db [MetaEval]`; group by
   `graderVersion`, keep the latest per group. For each, decode `judgeErrors`
   (a JSON `[Text]`) and keep entries with prefix `key <> ":"`. For each kept
   entry: `criterion = T.drop (T.length key + 1) entry`; resolve grader
   name/version from the meta's `graderVersion`. Sort by `(graderName, version)`.

A small helper `judgeErrorList :: Aeson Value -> [Text]` (sibling to the existing
`judgeErrorCount`) decodes the array; reuse it for both.

## UI changes

### `exampleView` side panel (`evals-ui/src/Evals/Ui/View.hs`)

The side panel stays a single `exSection "Grades"`, but its children become:

```haskell
exSection "Grades"
  (  map gradeBlock d.grades
  ++ map labelBlock d.labels
  ++ map judgeErrorBlock d.judgeErrors )
```

- `labelBlock` mirrors `verdictRow` styling: a met ✓ / not-met ✗ chip
  (`.m ok` / `.m fail`) + the criterion text (`.ctxt`), in a `.cr` row. A
  trailing `.muted` "human consensus" tag distinguishes it from a model grade.
- `judgeErrorBlock` renders `⚠ ⟨name⟩ v⟨n⟩ couldn't judge` (reusing
  `.cell-error`) followed by the criterion in `.muted`.

When all three lists are empty the panel reads as before (just the header).

### Style (`static/style.css`)

Reuses existing `.cr`, `.m.ok`, `.m.fail`, `.ctxt`, `.cell-error`, `.muted`. No
new classes required; add a `.consensus-tag` only if the inline `.muted` tag
needs visual separation (optional).

## Tests (`test/ApiSpec.hs`)

`serverSpec` already seeds output `o1` (example `e1`) and a `rubric` score. Add:

1. A `CriterionLabel` on `o1` (criterion "names the capital", `human = True`).
2. A `MetaEval` whose `judgeErrors` contains `"e1:names the capital"` for a known
   grader version.

Then on `/acme/api/runs/<id>/ex/e1`:

- `labels` contains one entry: criterion "names the capital", `human == True`.
- `judgeErrors` contains one entry naming that grader version + criterion.
- On `e2` (no label, no matching error): both lists empty.

Update the `ExampleDetailDto` round-trip literal to include the two new fields.

## Addendum — persisted judge verdicts + agreement badge (shipped)

Follow-on from the same conversation:

- **Persisted verdicts.** Rather than add a new persistence path, the existing
  `score` command was used to run each judge as a grader over the run's outputs,
  writing a `Score` row per (output, grader version). The example page's existing
  `grades` path renders them. Operational sequence (live, needs API keys):
  `manifest-evals score <run> <gv…> --org <slug>`, then
  `manifest-evals metaeval report <run> <gv> --org <slug> --mode stored` per
  grader version to refresh κ from the stored verdicts. For the HealthBench run,
  stored κ matched live (v1 identical at 0.531; v2 0.437 over 200 vs live 0.398
  over 199).
- **Agreement badge.** `gradeBlock` takes the example's `[(criterion, human)]`
  map and badges each judge's criterion verdict "agrees / disagrees" by matching
  its `met` against the human gold verdict — pure UI over the existing DTO.
- **Security fix (incidental).** A burst of judge calls hit DNS failures; the
  provider HTTP exception embeds the request's `x-api-key` header, and a raw
  `show` wrote the live key into the `scores.error` column — which the dashboard
  renders. `renderExecError` now scrubs every `sk-…` token before the text is
  persisted or shown; the leaked rows were deleted. Regression test in
  `ExecuteSpec`.
