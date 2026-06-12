# Eval Orchestrator — Pointed Rubrics (HealthBench slice 1) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-12

**Goal:** A `"pointed"` grader kind: per-example, signed-point rubric criteria
judged one-by-one with full conversation context, scored with the HealthBench
normalization, persisted as structured per-criterion verdicts. The first of
the gaps blocking a HealthBench port (per-example rubrics, grader context,
per-criterion verdicts, the score formula) — closed in one slice.

---

## 0. Context

The HealthBench review (openai/simple-evals) established: rubric items are
physician-written PER EXAMPLE (`[{criterion, points, tags}]`, points −10..+10,
negatives common); the grader sees the full conversation (incl. the injected
system message) plus the criterion with its signed points; the example score
is `sum(points of met items) / sum(positive points)`, unclipped per example;
axis/cluster breakdowns re-score stored verdicts with no extra grader calls.

manifest-evals today: grading config is per-GraderVersion; the LLM kinds
(`rubric`, `checklist`) never see the example; the judge sees only the output
text; checklist folds verdicts into rationale text.

**Decisions** (user-approved): kind name `"pointed"`; criteria live on
`Example.expected`; ONE Score row per pair with structured `detail` (no
schema change — per-criterion rows deferred until queryability demands them);
this slice includes the HealthBench formula (verdicts and the score are
inseparable); tag metrics / ingestion / OpenAI grader are later slices.

## 1. The kind

`Grader.kind = "pointed"`. `GraderVersion.config`: judge knobs only
(`votes`, `model`, `max_tokens`, `timeout`, `retries` — the existing
`gradeCfg`/`votesFrom` mapping, unchanged). The criteria come from the
example:

```
Example.expected = [ {"criterion": <text>, "points": <number>, "tags": [<text>]} , ... ]
```

(`tags` optional, default `[]`; `points` required, any sign.) Per-pair error
rows (value NULL, error set, retried on re-score) for: missing/`NULL`
expected; expected not an array of well-formed criteria; an empty array; or
`sum(positive points) <= 0` ("no positive points"). The output having no text
is a per-pair error as with the other LLM kinds.

## 2. Judging — per criterion, with conversation context

A second injected runner; the existing `GradeRunner` is untouched:

```haskell
data Criterion' = Criterion'
  { criterion :: Text, points :: Double, tags :: [Text] }

data CriterionVerdict = CriterionVerdict
  { met :: Bool, explanation :: Text }

type CriterionJudge =
  GraderVersion -> Text {- transcript -} -> Criterion' -> IO (Either ExecError CriterionVerdict)
```

- **Transcript**: the run's `TargetVersion.prompt` (the injected system
  message — HealthBench's grader sees it) + the example's conversation
  (decoded with the existing `decodeInput`) + the candidate completion,
  flattened HealthBench-style: `"role: content"` blocks joined by blank
  lines. Assembled by a pure function. The engine therefore loads the run's
  `TargetVersion` in setup (it already loads the `Run`) and fetches the
  `Example` for pointed pairs (as `exact` already does).
- **Criterion rendering**: HealthBench-style `[<signed points>] <criterion>`
  plus their framing notes ("a criterion saying 'such as'/'for example' does
  not require all examples; for negative criteria, report whether the
  criterion is MET, not whether that is good").
- **Live runner** (`Evals.Grade.Anthropic`): wraps crucible's existing judge
  (`Crucible.Eval.Judge.vote`, n = `votesFrom config`) — crucible's
  `Verdict {why, pass}` is exactly `explanation + met`, with validate-and-
  repair and majority voting for free. `AllErrored` → `Left (LlmError ...)`.
- **Fidelity caveat (documented, accepted)**: crucible's hardened judge
  prompt + a Claude judge ≠ the published GPT-4.1 grader template. Scores are
  directionally comparable, not benchmark-comparable; the OpenAI grader edge
  and meta-eval are later slices.

## 3. Scoring & persistence

- `value = sum(points of items judged met) / sum(positive points)` —
  UNCLIPPED (negative values are legitimate; HealthBench clips only at the
  aggregate, which is the dimensional-metrics slice's concern).
- `passed = Nothing` (pass/fail is not meaningful for pointed scores).
- `detail = {"achieved": <num>, "possible": <num>, "criteria":
  [{"criterion","points","tags","met","explanation"}, ...]}` — everything the
  later tag/axis slice and the dashboard need. One Score row per
  (output, graderVersion); the unique pair index stands.
- ANY criterion judge erroring fails the WHOLE pair → error row; the next
  `score` invocation re-grades the pair from scratch (bounded, resumable —
  deliberately unlike simple-evals' unbounded retry).

## 4. Engine refinement riding along

`recompute`'s `passRate` currently counts `Just True` over ALL graded rows,
so an all-`passed = Nothing` pointed run would report a misleading `0`.
Refined: passRate is computed over rows where `passed` is `Just`;
`Nothing` when no graded row has a `Just` passed. (`mean`/`count` unchanged.)

## 5. Testing

Pure: criteria parsing (signed points, default tags, malformed/empty/no-
positive rejections); transcript assembly (system prompt + multi-turn +
completion, flattening); the formula with the HealthBench test vector
(points 7/5/10/−6, met T/F/T/T → 11/22) and a negative-total example; detail
shape golden. Engine (recording `CriterionJudge`): per-criterion calls carry
the rendered signed points and a transcript containing prompt/turns/
completion; canned verdicts → correct value + detail row; one criterion
errors → pair error row; resume re-grades errored pairs; the passRate
refinement (all-Nothing → Nothing; mixed kinds unaffected). Live edge: config
mapping pure tests only, per precedent.

## 6. Out of scope (later slices)

- Tag/axis/theme dimensional metrics + aggregate clipping + bootstrap stderr.
- JSONL ingestion CLI (the 5,000-example import).
- The OpenAI grader edge in crucible; meta-eval / `Crucible.Eval.Calibrate`.
- Length-adjusted scoring; dashboard rendering of per-criterion verdicts.
- Per-criterion Score rows.
