# Eval Orchestrator — Meta-eval / Calibrate (HealthBench slice) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-13

**Goal:** A CLI harness measuring how well *our* pointed grader agrees with
gold/human labels — agreement, Cohen's κ (+95% CI), fail-class precision/recall
— over a labelled case set, in two modes (live re-judge / stored verdicts). It
validates the judge we actually ship. HealthBench-number reproduction is a
deliberate later slice; this slice is the self-contained validation harness,
built so reproduction can layer on.

---

## 0. Context & decisions (user-approved)

- **Purpose: both, staged.** Build the grader-validation harness first (our
  real judge vs. labels → κ/agreement report); HealthBench-number reproduction
  (macro-F1 over physician consensus data, their exact aggregation) is a
  separate later slice.
- **Crucible: re-pin to master.** Gains the pure
  `Crucible.Eval.Calibrate.bootstrapKappa` for the κ CI; costs the breaking
  `Judge.vote` signature migration.
- **Verdict source: both modes.** Live re-judge AND stored-verdict comparison
  behind one shared report core; only verdict-acquisition differs.
- **Report output: CLI-only.** Print the report (HealthBench-style, like
  crucible's `renderCalibration`). No result entity, no dashboard work this
  slice — persistence + a dashboard "grader κ" surface are a follow-up.

Crucible's own `calibrate` cannot be reused directly: it runs *its own*
single-rubric judge internally (`(a -> Text)` render + one rubric `Text`), with
no seam to inject our transcript-aware per-criterion `CriterionJudge`. So we
drive our real judge and compute the stats ourselves, reusing only the pure
`bootstrapKappa` from crucible.

**Repo facts (verified).** `type CriterionJudge = GraderVersion -> Text ->
Criterion' -> IO (Either ExecError CriterionVerdict)` (`Grade.hs:141`);
`CriterionVerdict {met :: Bool, explanation :: Text}` (`Grade.hs:134`). The
only `Judge.vote` call site is `liveCriterionJudge` (`Grade/Anthropic.hs:56–59`),
today `Judge.vote True (votesFrom cfgV) (renderCriterion c) transcriptTxt`. The
pointed `Score.detail` shape is `{achieved, possible, criteria:[{criterion,
points, tags, met, explanation}]}`. `Evals.Ingest` exposes `nonEmptyKey`, the
row parser, `IngestOpts`, and the generic/healthbench adapters; current ingest
creates `Example`s only. Schema entities: Dataset, DatasetVersion, Example,
Target, TargetVersion, Grader, GraderVersion, Run, Output, Score, RunMetric.

**Crucible API at the new pin (`4744789`).**
`bootstrapKappa :: Int -> Int -> [(Bool,Bool)] -> (Double,Double)` (seed,
resamples, (human,judge) pairs → 95% κ CI; pure, deterministic).
`vote :: (LLM :> es) => Bool -> JudgeOpts -> Text -> Text -> Eff es VoteOutcome`
with `JudgeOpts {votes :: Int, examples :: [JudgeExample]}`.

## 1. Crucible re-pin (Task 0)

Bump crucible `6229382 → 4744789` in `zinc.toml`, run `zinc update` (per
[[zinc-rev-change-needs-update]] a rev edit is not lock drift — `update` is
required), reconcile any transitive-closure stanza deltas. Migrate the single
`vote` call site: `votesFrom cfgV` (an `Int`) becomes
`JudgeOpts {votes = votesFrom cfgV, examples = []}`. Gate: the existing
`GradeSpec` stays green; fix any other crucible API drift the re-pin surfaces
(only `vote` is known to have changed, but build+test confirms).

## 2. Schema — `CriterionLabel`

One new entity; everything hangs off a real `Output`, so both verdict modes
share one label model.

```haskell
data CriterionLabelT f = CriterionLabel
  { id        :: Field f (Pk CriterionLabelId)
  , output    :: Field f OutputId      -- the candidate response this labels
  , criterion :: Field f Text          -- rubric criterion text (matches Score.detail's criterion)
  , human     :: Field f Bool          -- the gold verdict (met / not-met)
  , source    :: Field f (Maybe Text)  -- labeller / provenance
  , createdAt :: Field f UTCTime
  } deriving Generic
```

`indexes = [ unique [#output, #criterion] ]`. New `CriterionLabelId` in
`Evals.Ids`. **No** `notifyChanges` (not part of the live run graph). Additive
nullable-free `ADD`/CREATE — manifest's migrate handles a greenfield entity.

## 3. Meta-eval ingest — `metaeval load`

`manifest-evals metaeval load <file.jsonl> --name N --slug S [--version V]`.

Each labelled JSONL record:
```json
{ "key": "...", "input": { "messages": [...] },
  "completion": "<candidate response text>",
  "rubric": [ {"criterion": "...", "points": N, "tags": ["..."]} ],
  "labels": [ {"criterion": "...", "met": true}, ... ] }
```
(`input` accepts the same shapes the generic/healthbench adapters accept; a bare
prompt string is wrapped as `{messages:[…]}` consistent with existing ingest.)

Seeds the full graph atomically in one transaction, per record:
- `Example` — `input`, `expected = rubric` (verbatim, as the pointed grader
  expects), `meta` carrying the tags (mirrors existing ingestion).
- one synthetic `Run` (status `"succeeded"`, `startedAt/finishedAt = now`) for
  the whole load (a single dataset version → one run holding all outputs).
- one `Output` per record (`text = completion`, no error).
- one `CriterionLabel` per `labels[]` entry (`output`, `criterion`, `human =
  met`). A label whose `criterion` is not in the record's `rubric` is an
  ingest error (refuse the row, or skip under `--skip-bad` — mirror existing
  ingest's bad-row policy).

New module `Evals.MetaEval.Ingest`, reusing `Evals.Ingest`'s `nonEmptyKey` and
row-parsing helpers. Prints the seeded `runId` (needed by `metaeval report`).
`--version` defaults to 1; like existing ingest, refuse to clobber a version
that already has runs unless `--force` (reuse the existing guard pattern).

## 4. The pure report core — `Evals.MetaEval`

```haskell
data MetaReport = MetaReport
  { agreement     :: Double           -- matches / measured, over non-errored cases
  , kappa         :: Double           -- Cohen's κ (binary) on (human,judge) pairs
  , kappaCI       :: (Double, Double) -- 95% bootstrap CI (crucible bootstrapKappa)
  , failPrecision :: Double           -- of judge not-met, fraction humans also not-met (1 if none)
  , failRecall    :: Double           -- of human not-met, fraction the judge caught (1 if none)
  , judgeErrors   :: [Text]           -- case keys where the judge errored (excluded from stats)
  , measured      :: Int              -- number of non-errored cases the metrics cover
  } deriving (Eq, Show)

-- seed, resamples, [(caseKey, human, Just judge | Nothing = errored)]
metaReport :: Int -> Int -> [(Text, Bool, Maybe Bool)] -> MetaReport

renderMetaReport :: MetaReport -> Text
```

- "fail" = the **not-met** class (a failed criterion is the negative outcome),
  matching crucible's `CalibrationReport` `failPrecision/failRecall` semantics.
- Cohen's κ computed locally (crucible does not export `kappaOf`); degenerate
  expected-agreement = 1 → κ = 0 (crucible's convention).
- `kappaCI = bootstrapKappa seed resamples pairs` over the non-errored
  `(human, judge)` pairs.
- Errored cases (`Nothing`) are excluded from every statistic and listed in
  `judgeErrors`. Empty input / all-errored → defined degenerate values
  (agreement 0, κ 0, CI (0,0), precision/recall 1, measured 0).

Fully pure → fully unit-testable; the only crucible dependency is the pure
`bootstrapKappa`.

## 5. Report runner — `metaeval report`

`manifest-evals metaeval report <runId> <graderVersionId> [--mode live|stored]
[--seed N] [--resamples N]` (defaults: `--mode live`, `--seed 0`,
`--resamples 1000`).

Gathers `[(caseKey, human, Maybe judgeBool)]` for the run's labels (join
`CriterionLabel → Output` filtered to `output.run == runId`; `caseKey` =
`example.key <> ":" <> criterion`), then `metaReport seed resamples` →
`renderMetaReport` → stdout.

- **live** — per `(output, criterion)` label, call `liveCriterionJudge` (built
  from `ANTHROPIC_API_KEY` + the gv config) on `output.text` and the criterion;
  `Right v → Just v.met`, `Left _ → Nothing` (errored). No prior scoring
  needed; exercises the shipped judge path. Honours `--concurrency` like the
  other live commands.
- **stored** — read that run's `Score.detail.criteria[].met` per `(output,
  criterion)` for the given gv (requires the run already `score`d by that gv);
  a label with no matching stored criterion → `Nothing` (errored/missing).
  Zero judge calls.

Both share the report core and the label gather; only verdict-acquisition
differs. The runner takes the `CriterionJudge` as an injected argument (the
existing seam), so the engine test scripts a deterministic judge.

## 6. Testing

- **Pure** (`Evals.MetaEval`): `metaReport` over hand vectors — perfect
  agreement (κ=1, agreement 1), full disagreement, degenerate all-same (κ=0),
  fail precision/recall (mixed met/not-met), errored cases excluded-and-listed,
  CI brackets the point estimate, empty/all-errored degenerate defaults.
- **Engine** (ephemeral PG, `Manifest.Testing.withEphemeralDb`): seed a
  labelled graph (via the loader); **stored** mode against seeded
  `Score.detail`; **live** mode with a scripted `CriterionJudge`
  (`met = predicate`) → assert the reports (agreement/κ/precision/recall/
  measured/judgeErrors).
- **Ingest** (`Evals.MetaEval.Ingest`): a `test/fixtures/metaeval.jsonl`
  fixture → assert `Example` + `Output` + `CriterionLabel` counts and shapes;
  a label referencing an unknown criterion is refused (and skipped under
  `--skip-bad`).

## 7. Out of scope (later slices)

- HealthBench-number reproduction: ingest their meta-eval/consensus dataset and
  match their macro-F1 aggregation.
- Report **persistence** (a `MetaEval` result entity) + **dashboard** surface
  (grader κ over time).
- Few-shot judge examples (`calibrateWith` / `JudgeOpts.examples`) wiring.
