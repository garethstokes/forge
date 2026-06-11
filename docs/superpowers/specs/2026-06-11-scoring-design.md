# Eval Orchestrator — Scoring — Design

**Status:** Approved design (brainstorm complete; revised against `Crucible.Eval`). · **Date:** 2026-06-11

**Goal:** Grade a run's `Output`s with named grader versions: one `Score` row per
(output × grader version), then recompute per-grader `RunMetric` aggregates.
The grading machinery (judge prompts, CoT verdicts, JSON repair, majority
voting, checklist weighting) is crucible's; this sub-project is the
orchestration + persistence bridge — the same role C plays for model calls.

---

## 0. Context & history

Sub-project C (`Evals.Execute`) produces `Output` rows. Scoring was parked
until crucible's evals work landed; it has: `Crucible.Eval` (`Expectation` =
`Exactly`/`Predicate`/`Rubric`/`Checklist`, `Score {value, rationale, votes}`,
`scoreM`/`scoreN`/`judgeN`), `Crucible.Eval.Judge` (hardened CoT judge prompt,
validate-and-repair, sequential majority `vote`), `Crucible.Eval.Calibrate`
(out of scope here). Transport failures (`AnthropicError`) propagate as
exceptions; judge-reply failures are folded into `AllErrored` → a
`"judge error: "`-tagged score.

**Decisions** (user-approved): all three grader kinds; grader selection by
explicit args (no run↔grader table); grading failures recorded via a new
`Score.error` column; kind names follow crucible's vocabulary; crucible's
judge-error scores are ALSO mapped to error rows.

## 1. Grader kinds & config

`Grader.kind` ∈ `"exact" | "rubric" | "checklist"` (was exact/judge/rubric —
"judge" is crucible's `Rubric` [holistic], "rubric" is crucible's `Checklist`
[weighted criteria]). An unknown kind is a per-pair error row.
`GraderVersion.config` (jsonb) per kind:

- **exact** — `{}` (no knobs). Pure, no LLM. Grades `Output.text` against
  `Example.expected`:
  - expected is a JSON string → trimmed (`T.strip`) text equality;
  - expected is any other JSON value → parse the output text as JSON,
    structural (`Value`) equality; an unparseable output is a legitimate FAIL
    (value 0, rationale "output is not valid JSON"), not an error row;
  - `expected = NULL`, or the output has no text → error row
    ("no expected value" / "output has no text").
  - Score: value 1/0, rationale "exact match"/"mismatch".
- **rubric** — `{"rubric": <text>, "votes": <odd int, default 1>, "model":
  <text>?, "max_tokens"/"timeout"/"retries": <int>?}` → crucible
  `Rubric` judged with `scoreN votes`.
- **checklist** — `{"criteria": [{"label": <text>, "weight": <number,
  default 1>}...], "votes"/"model"/...}` as above → crucible
  `Checklist [Criterion]` via `scoreN votes`.

Missing/malformed required config (no `rubric` key; empty/missing `criteria`)
is a per-pair error row, not a crash.

## 2. The injected backend (`GradeRunner`)

```haskell
type GradeRunner =
  GraderVersion -> Eval.Expectation Text -> Text -> IO (Either ExecError Eval.Score)
```

(`Eval` = `Crucible.Eval` imported qualified — its `Score` clashes with the
entity.) The live runner builds an `AnthropicConfig` from the grader config
(model/max_tokens/timeout/retries → same mapping as C's `cfgFrom`, which is
generalised to share: `cfgFromParams :: Text -> Text -> Value ->
AnthropicConfig` (key, model, params jsonb) used by both `cfgFrom` and the
grader path; the grader's model defaults to `defaultAnthropicConfig`'s when
config has none) and runs
`try @AnthropicError (runEff (Anthropic.run cfg (Eval.scoreN votes id expectation text)))`,
mapping the exception to `Left (LlmError ...)`. The `votes` count is read from
config by the runner. Tests inject lambdas returning canned `Eval.Score`s (or
errors) — no network, no Eff.

**Upstream prerequisite:** `Crucible.Eval` exports `scoreM` but not `scoreN`;
add `scoreN` to the export list (one-line upstream commit + re-pin). The
crucible pin here predates `Crucible.Eval` entirely, so re-pin to current
master regardless.

## 3. Schema change

`Score` (greenfield tables — type-level change, fresh migrate):

- `value :: Field f Double` → `Field f (Maybe Double)` — an errored score has
  no value, and SQL `AVG` skips NULLs, keeping aggregates pure for free.
- New `error :: Field f (Maybe Text)`.

A graded row: `value = Just v`, `passed = Just (v >= 1.0)`, `detail = Just
{"rationale": <text>, "votes": [yes, no]?}`, `error = NULL`. An errored pair:
`value = NULL`, `passed = NULL`, `detail = NULL`, `error = Just <msg>`.
Crucible `AllErrored` scores (detected by `value == 0 &&
"judge error: " isPrefixOf rationale` — the tag is produced only by the error
path) are persisted as error rows, not zero scores.

## 4. The engine

```haskell
data ScoreOutcome = ScoreOutcome
  { total :: Int, scored :: Int, errored :: Int, skipped :: Int }

scoreRun :: Pool -> Int -> GradeRunner -> RunId -> [GraderVersionId] -> IO ScoreOutcome
```

1. One session: load the `Run` (missing → all-zero outcome, nothing written);
   the named `GraderVersion`s + their `Grader`s (any missing → all-zero
   outcome); the run's `Output`s with their `Example`s (for `expected`);
   existing `Score`s for (these outputs × these grader versions).
2. Work list = (output × graderVersion) pairs, minus: outputs with
   `Output.error` set (skipped — nothing to grade), pairs with an existing
   non-errored `Score` (resume), and counting pairs whose existing `Score` is
   errored as re-gradable (the errored row is deleted in the pair's own
   session just before the fresh insert — `deleteWhere`).
3. Bounded-concurrent over pairs (`async` + `QSem`, same shape as
   `executeRun`): build the `Expectation` from kind+config+example; call the
   runner; write one `Score` row per §3. Per-pair failure isolation: any
   exception → error row.
4. Per grader version, one session: recompute `RunMetric` — `deleteWhere
   [#run ==. runId, #graderVersion ==. gvId]` then insert
   `{mean = AVG(value) over graded rows, passRate = fraction of passed ==
   Just True over graded rows, count = graded-row count, computedAt = now}`.
   No graded rows → mean 0, passRate Nothing, count 0 (row still written —
   the recompute is the record that scoring ran).
5. `Run.status` is never touched — scoring does not own the run lifecycle.
   `ScoreOutcome.total` counts all (output × gv) pairs including skipped.

## 5. Trigger — CLI

`manifest-evals score <runId> <graderVersionId>... [--concurrency N]` — env
`MANIFEST_DATABASE_URL`, `ANTHROPIC_API_KEY`, `EVALS_CONCURRENCY` (flag wins;
default 4), printing the `ScoreOutcome` like `run` prints `RunOutcome`.

## 6. Testing

Deterministic, no network (injected runners + `withEphemeralDb`), in a new
`ScoreSpec` wired into `Spec.hs`:

- exact kind end-to-end without any runner call: string-expected pass+fail,
  structural-JSON pass, unparseable-output fail, missing-expected error row;
- rubric/checklist: a recording runner asserts the `Expectation` built from
  config (rubric text; criteria labels+weights; votes read from config) and
  returns canned scores → rows carry value/passed/detail correctly;
- error rows: runner returns `Left`, runner throws, and a canned
  `"judge error: "` score — all three become error rows (value NULL);
- resume: pre-existing good score skipped, errored score deleted + re-graded;
- outputs with `Output.error` are skipped and tallied;
- RunMetric: recompute over mixed graded/errored rows (AVG ignores errored),
  re-running replaces rather than duplicates;
- `cfgFromParams`: grader config model/knob mapping (pure).

## 7. Out of scope

- `Crucible.Eval.Calibrate` (kappa, fail-class precision/recall) — later,
  once human labels exist.
- Score-derived dashboards (sub-project B), live progress (D).
- A run↔grader association table; grader selection stays explicit args.
- Re-grading non-errored scores (no `--force`); delete rows by hand if needed.
- `Predicate` expectations (no sensible jsonb encoding for a function;
  crucible offers it, the bridge never builds it).
