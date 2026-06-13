# Eval Orchestrator — Meta-eval / Calibrate (HealthBench slice) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-13

**Goal:** A CLI harness measuring how well *our* pointed grader agrees with
gold/human labels — agreement, Cohen's κ (+95% CI), fail-class precision/recall
— over a labelled case set, in two modes (live re-judge / stored verdicts). It
validates the judge we actually ship. The calibration **statistics live in
crucible** (one source of truth); manifest-evals only acquires verdicts and
renders. HealthBench-number reproduction is a deliberate later slice.

---

## 0. Context & decisions (user-approved)

- **Purpose: both, staged.** Build the grader-validation harness first (our
  real judge vs. labels → κ/agreement report); HealthBench-number reproduction
  (macro-F1 over physician consensus data, their exact aggregation) is a
  separate later slice.
- **Crucible: add the capability, then re-pin.** Rather than reimplement the
  stats in manifest-evals, add a verdict-level report function to crucible in a
  **worktree**, merge to crucible master, **push**, then pin manifest-evals to
  that new master HEAD. The re-pin also incurs the breaking `Judge.vote`
  signature migration.
- **Verdict source: both modes.** Live re-judge AND stored-verdict comparison
  behind one shared verdict-tuple interface; only verdict-acquisition differs.
- **Report output: CLI-only.** Print the report via crucible's
  `renderCalibration`. No result entity, no dashboard work this slice —
  persistence + a dashboard "grader κ" surface are a follow-up.

Crucible's existing `calibrate` cannot be reused directly: it runs *its own*
single-rubric judge internally (`(a -> Text)` render + one rubric `Text`), with
no seam to inject our transcript-aware per-criterion `CriterionJudge`, and
stored mode has no live judge at all. The verdict-level function (below) fits
**both** modes: each just produces `[(caseKey, human, Maybe judge)]`.

**Crucible facts (verified, current master `4744789`).** `Crucible.Eval.Calibrate`
already has, module-level: `kappaOf :: [(Bool,Bool)] -> Double` (Cohen's κ,
degenerate→0), `bootstrapKappa :: Int -> Int -> [(Bool,Bool)] -> (Double,Double)`
(seed, resamples → 95% CI; pure), `bootstrapResamples = 1000`, and an
**unexported** `reportFrom :: Int -> [(Text,Bool,VoteOutcome)] -> Int -> Int ->
CalibrationReport`. `CalibrationReport` (10 fields) includes `agreement`,
`kappa`, `failPrecision`, `failRecall`, `contested`, `judgeErrors`,
`exampleCount`, `measured`, `kappaCI`, `abstained`. `renderCalibration ::
CalibrationReport -> Text` exists. The only signature drift vs. our pin: `vote ::
Bool -> JudgeOpts -> Text -> Text -> Eff es VoteOutcome` (was `Bool -> Int ->
…`); `JudgeOpts {votes :: Int, examples :: [JudgeExample]}`.

**manifest-evals facts (verified).** `type CriterionJudge = GraderVersion ->
Text -> Criterion' -> IO (Either ExecError CriterionVerdict)` (`Grade.hs:141`);
`CriterionVerdict {met :: Bool, explanation :: Text}` (`Grade.hs:134`). The only
`Judge.vote` call site is `liveCriterionJudge` (`Grade/Anthropic.hs:56–59`),
today `Judge.vote True (votesFrom cfgV) (renderCriterion c) transcriptTxt`. The
pointed `Score.detail` shape is `{achieved, possible, criteria:[{criterion,
points, tags, met, explanation}]}`. `Evals.Ingest` exposes `nonEmptyKey`, the
row parser, `IngestOpts`, the generic/healthbench adapters; current ingest
creates `Example`s only. Crucible is pinned to **pushed remote master** only
(zinc fetches the rev from GitHub) — the crucible change MUST be pushed before
the re-pin.

## 1. Crucible change (Task 0a — in a crucible worktree, merged to master, pushed)

Add a public, pure, verdict-level report builder to
`Crucible.Eval.Calibrate`, reusing the existing `kappaOf` / `bootstrapKappa` /
`bootstrapResamples`:

```haskell
-- | Build a calibration report from externally-acquired verdicts: each case is
-- (name, human, Just judge) or (name, human, Nothing) when the judge errored or
-- was unavailable. For callers that judge OUTSIDE crucible (a transcript-aware
-- grader, or stored verdicts read back from a database). Tally-derived fields
-- ('contested', 'abstained') are empty — a plain verdict carries no vote tally;
-- 'exampleCount' is 0; 'measured' counts the non-errored cases.
reportFromVerdicts :: Int -> [(Text, Bool, Maybe Bool)] -> CalibrationReport
reportFromVerdicts seed cases =
  CalibrationReport po kap fPrec fRec [] errs 0 (length judged) ci []
  where
    errs   = [nm | (nm, _, Nothing) <- cases]
    judged = [(nm, h, j) | (nm, h, Just j) <- cases]
    pairs  = [(h, j) | (_, h, j) <- judged]
    total  = length judged
    agree  = length [() | (_, h, j) <- judged, h == j]
    po     = ratio agree total 0
    kap    = kappaOf pairs
    ci     = bootstrapKappa seed bootstrapResamples pairs
    jFails = [h' | (_, h', False) <- judged]            -- judge said not-met
    fPrec  = ratio (length (filter not jFails)) (length jFails) 1
    hFails = [j' | (_, False, j') <- judged]            -- human said not-met
    fRec   = ratio (length (filter not hFails)) (length hFails) 1
    ratio :: Int -> Int -> Double -> Double
    ratio _ 0 dflt = dflt
    ratio num den _ = fromIntegral num / fromIntegral den
```

Export `reportFromVerdicts` (and, for completeness, `CalibrationReport (..)` and
`renderCalibration` are already exported). "Fail" = the **not-met** class,
matching `reportFrom`'s `failPrecision/failRecall` semantics. If the `ratio`
helper duplication bothers review, extract a shared `module`-level `ratio` that
`reportFrom` also uses — a small, optional refactor.

**Crucible tests** (`crucible/test/Spec.hs`, beside the existing calibrate
tests): `reportFromVerdicts` over hand vectors — perfect agreement (κ=1,
agreement 1), full disagreement, degenerate all-same (κ=0), mixed met/not-met
fail precision/recall, `Nothing` cases excluded-from-stats and listed in
`judgeErrors`, `measured` = non-errored count, empty / all-errored degenerate
defaults (agreement 0, κ 0, CI (0,0), precision/recall 1, measured 0), CI
brackets the point estimate.

**Workflow:** crucible worktree → implement + test (`zinc test` green in
crucible) → merge the branch to crucible `master` → **push master to GitHub**
(record the new HEAD rev for the re-pin).

## 2. Re-pin crucible (Task 0b — manifest-evals)

Bump crucible to the new master HEAD in `zinc.toml`, run `zinc update` (per
[[zinc-rev-change-needs-update]] a rev edit is not lock drift — `update` is
required), reconcile any transitive-closure stanza deltas. Migrate the single
`vote` call site: `votesFrom cfgV` (an `Int`) → `JudgeOpts {votes = votesFrom
cfgV, examples = []}`. Gate: the existing `GradeSpec` stays green; fix any other
crucible API drift the re-pin surfaces.

## 3. Schema — `CriterionLabel` (manifest-evals)

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
`Evals.Ids`. **No** `notifyChanges` (not part of the live run graph). Greenfield
CREATE — manifest's migrate handles a new entity.

## 4. Meta-eval ingest — `metaeval load`

`manifest-evals metaeval load <file.jsonl> --name N --slug S [--version V]
[--skip-bad] [--force]`.

Each labelled JSONL record:
```json
{ "key": "...", "input": { "messages": [...] },
  "completion": "<candidate response text>",
  "rubric": [ {"criterion": "...", "points": N, "tags": ["..."]} ],
  "labels": [ {"criterion": "...", "met": true}, ... ] }
```
(`input` accepts the shapes the generic/healthbench adapters accept; a bare
prompt string is wrapped as `{messages:[…]}`, consistent with existing ingest.)

Seeds the full graph atomically in one transaction:
- one `Dataset` + `DatasetVersion` (the `--name/--slug/--version` set);
- per record: an `Example` (`input`, `expected = rubric` verbatim, `meta`
  carrying tags), an `Output` (`text = completion`, no error) under one shared
  synthetic `Run` (status `"succeeded"`, `startedAt/finishedAt = now`), and one
  `CriterionLabel` per `labels[]` entry (`output`, `criterion`, `human = met`).
- A `labels[]` `criterion` not present in that record's `rubric` is a bad row:
  refuse (or skip under `--skip-bad`) — mirror existing ingest's policy. Refuse
  to clobber a version that already has runs unless `--force` (existing guard).

New module `Evals.MetaEval.Ingest`, reusing `Evals.Ingest`'s `nonEmptyKey` and
row-parsing helpers. Prints the seeded `runId` (needed by `metaeval report`).

## 5. Report runner — `metaeval report`

`manifest-evals metaeval report <runId> <graderVersionId> [--mode live|stored]
[--seed N] [--concurrency N]` (defaults: `--mode live`, `--seed 0`).

Gathers `[(caseKey, human, Maybe judgeBool)]` for the run's labels (join
`CriterionLabel → Output` filtered to `output.run == runId`; `caseKey =
example.key <> ":" <> criterion`), then:

```haskell
report = Calibrate.reportFromVerdicts seed tuples
putStrLn (T.unpack (Calibrate.renderCalibration report))
```

- **live** — per `(output, criterion)` label, call `liveCriterionJudge` (built
  from `ANTHROPIC_API_KEY` + the gv config) on `output.text` + the criterion;
  `Right v → Just v.met`, `Left _ → Nothing` (errored). No prior scoring needed;
  exercises the shipped judge path. Honours `--concurrency`.
- **stored** — read that run's `Score.detail.criteria[].met` per `(output,
  criterion)` for the given gv (requires the run already `score`d by that gv); a
  label with no matching stored criterion → `Nothing`. Zero judge calls.

Both share the verdict-tuple gather and the crucible report+render; only
verdict-acquisition differs. The runner takes the `CriterionJudge` as an
injected argument (the existing seam), so the engine test scripts a
deterministic judge.

New module `Evals.MetaEval` (the two verdict-acquisition functions + the gather;
it does NOT redefine any statistic — it calls crucible).

## 6. Testing (manifest-evals)

The pure statistic correctness is tested in **crucible** (§1). manifest-evals
tests focus on verdict acquisition + ingest:

- **Engine** (ephemeral PG, `Manifest.Testing.withEphemeralDb`): seed a labelled
  graph (via the loader); **stored** mode against seeded `Score.detail` →
  assert the gathered tuples and that the rendered report reflects them (e.g.
  agreement matches a hand-computed value); **live** mode with a scripted
  `CriterionJudge` (`met = predicate`) → assert likewise; a label with no
  matching stored criterion surfaces as a judge error.
- **Ingest** (`Evals.MetaEval.Ingest`): a `test/fixtures/metaeval.jsonl` fixture
  → assert `Example` + `Output` + `CriterionLabel` counts and shapes; a label
  referencing an unknown criterion is refused (and skipped under `--skip-bad`).

## 7. Out of scope (later slices)

- HealthBench-number reproduction: ingest their meta-eval/consensus dataset and
  match their macro-F1 aggregation.
- Report **persistence** (a `MetaEval` result entity) + **dashboard** surface
  (grader κ over time).
- Few-shot judge examples (`calibrateWith` / `JudgeOpts.examples`) wiring, and
  abstain/contested surfacing (needs vote tallies, not plain verdicts).
