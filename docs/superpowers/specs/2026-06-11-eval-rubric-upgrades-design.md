# Eval Rubric Upgrades — Design Spec

**Date:** 2026-06-11
**Status:** Approved design, pending implementation
**Research basis:** `docs/superpowers/research/2026-06-11-evaluation-rubrics.md` (all seven recommendations ship in this cycle).
**Scope:** `Crucible.Eval` (types, loop, report), new `Crucible.Eval.Judge`, new `Crucible.Eval.Calibrate`, `test/Spec.hs`, new manual page `docs/evals.md`, demo additions in `app/Main.hs`.

## Motivation

crucible's judge is one line of prompt and one binary verdict. The research
note identifies the gaps, each with measured backing: the judge commits to
`pass` before writing `why` (backwards for the CoT effect); quality goals
cannot be decomposed into independently checkable criteria; single-sample
verdicts are noisy with no uncertainty signal; malformed judge JSON scores a
silent zero; and there is no way to measure whether the judge agrees with a
human before trusting suite numbers.

## Decisions taken during design

- All seven research recommendations in one cycle.
- Checklist criteria are judged with one call per criterion (reliability over
  cost; HealthBench style). This also means every judgement in the system
  reuses the single `{why, pass}` verdict codec, so validate-and-repair lives
  in exactly one place. The array-of-verdicts call is explicitly not built.
- Vote margin is structured: `Score` gains `votes :: Maybe (Int, Int)`.
- `judgeN` stops voting early once the majority is decided; `calibrate`
  always votes fully so margins are comparable.
- Module layout: `Crucible.Eval` (types + loop + report), `Crucible.Eval.Judge`
  (judge machinery), `Crucible.Eval.Calibrate` (calibration). Mirrors the
  `Tool` / `Tool.Generic` precedent. `Crucible.Eval` re-exports `judge` (and
  `Verdict (..)`) so existing imports keep working.

## Design

### 1. `Crucible.Eval.Judge`

**Verdict, reordered.** The type and codec declare `why` first:

```haskell
data Verdict = Verdict { why :: Text, pass :: Bool } deriving (Eq, Show)

verdictCodec :: JSONCodec Verdict
verdictCodec = object (Verdict <$> field "why"  (.why)  str
                               <*> field "pass" (.pass) bool)
```

Decoding is order-insensitive (old `{"pass", "why"}` JSON still parses);
encoding and the prompt teach reason-then-verdict.

**Hardened judge prompt.** One system message used by every judge call:

```
You are a strict grader.
Reason through each rubric requirement in "why" first, quoting the part of
the output that satisfies or violates it, then give the verdict.
Length and style are not criteria unless the rubric says so.
If a requirement is not demonstrably met, fail it.
Respond ONLY with JSON {"why": <string>, "pass": <bool>}.
```

The user message keeps the current shape (`Rubric: ...` / `Output to grade: ...`).

**Validate-and-repair.** Every judge call goes through one internal entry:

```haskell
newtype JudgeError = JudgeError Text deriving (Eq, Show)

judgeOnce :: (LLM :> es) => Text -> Text -> Eff es (Either JudgeError Verdict)
-- args: rubric text, rendered output
```

On a verdict decode failure, append the raw reply as an Assistant message
plus a User reprompt carrying the parse error (the `Skill.call` retry idiom),
try once more, then give up with `JudgeError` carrying the final decode
message. A judge error is distinct from a fail: it scores 0, the rationale is
prefixed `judge error: `, and `renderReport` flags it.

**Score gains votes** (defined in `Crucible.Eval`, listed here for the judge
contract):

```haskell
data Score = Score { value :: Double, rationale :: Text, votes :: Maybe (Int, Int) }
  deriving (Eq, Show)

score :: Double -> Text -> Score      -- smart constructor; votes = Nothing
```

**Judging functions:**

```haskell
judge  :: (LLM :> es) => (a -> Text) -> Text -> a -> Eff es Score   -- judgeN 1
judgeN :: (LLM :> es) => Int -> (a -> Text) -> Text -> a -> Eff es Score
```

`judgeN n` (callers should use odd n; n <= 1 behaves as a single call):

- samples sequentially, stopping as soon as one side holds a strict majority
  of n (at n=3, two agreeing votes settle it; the third call is skipped);
- `votes = Just (yes, no)` records the tally actually cast, so a full 2-1
  and an early-stopped 2-0 are distinguishable;
- the rationale is the `why` from the first vote on the majority side;
- a `JudgeError` sample is excluded from the tally and consumes one of the n
  attempts; if all n samples error, the result is the judge-error score
  (value 0, `judge error: ` rationale, `votes = Nothing`);
- ties on an exhausted budget (possible only via errors, e.g. 1-1-error)
  resolve to fail with the fail side's `why` and the true tally in `votes`.

Documented limitation: `Complete` carries no per-call temperature; vote
diversity rides on provider sampling (both live providers default to
temperature 1). Cost note in haddock: n-vote multiplies judge calls.

### 2. `Crucible.Eval` — checklists, loop, report

**Criterion and the new expectation:**

```haskell
data Criterion = Criterion { label :: Text, weight :: Double }

criterion :: Text -> Criterion        -- weight 1

data Expectation a
  = Exactly a
  | Predicate (a -> Bool)
  | Rubric Text
  | Checklist [Criterion]             -- new
```

**Checklist scoring.** Each criterion is one binary judge call whose rubric
text frames the label as the entire requirement:
`"the output must satisfy: " <> label`. Then:

- case score value = sum of weights of passed criteria / total weight;
- `value == 1.0` iff every criterion passed, so `runEval`'s existing
  `passRate >= 1.0` rule means a checklist case passes only when all
  criteria pass; weights affect `meanScore` only (document this);
- rationale = one line per criterion in order:
  `"[pass] <label>: <why>"` / `"[fail] <label>: <why>"`, joined by newlines;
  a criterion whose judge call errors becomes
  `"[fail] <label>: judge error: <msg>"` and counts as failed;
- the case-level `votes` for a checklist score is `Nothing` (margins are
  per-criterion; surfacing them is out of scope this cycle);
- empty checklist: value 1.0, rationale `"empty checklist"`, no judge calls;
- non-positive total weight (all weights 0): value is defined as 1.0 if all
  criteria passed else 0.0, avoiding division by zero (and is a degenerate
  configuration the manual warns against).

**Threading n.** Additive variant; existing functions keep n=1:

```haskell
runEvalN :: (Eq a, LLM :> es)
         => Int -> (a -> Text) -> (i -> Eff es a) -> [Case i a]
         -> Eff es (Report i a)

runEval = runEvalN 1
```

`runEvalN n` uses `judgeN n` for `Rubric` cases and for each `Checklist`
criterion. `scoreM` gains the n parameter internally (exported signature may
stay `scoreM :: ... => (a -> Text) -> Expectation a -> a -> Eff es Score`
delegating to n=1, with an internal `scoreN`). `testSkill` is unchanged
(single-judge); callers wanting votes use `runEvalN` with `call sk` directly.

**renderReport annotations.** A case line gains:

- `  [judge uncertain <yes>-<no>: review by hand]` when `votes = Just (y, n)`
  with both sides nonzero;
- `  [judge error]` when the rationale starts with or contains the
  `judge error: ` tag.

Everything else about `Report` (`results`, `passRate`, `meanScore`) is
unchanged.

### 3. `Crucible.Eval.Calibrate`

```haskell
data CalibrationReport = CalibrationReport
  { agreement     :: Double    -- raw judge-human agreement over judged cases
  , kappa         :: Double    -- Cohen's kappa, binary
  , failPrecision :: Double    -- of judge-fails, fraction humans also failed
  , failRecall    :: Double    -- of human-fails, fraction the judge caught
  , contested     :: [Text]    -- case names with split votes (both sides nonzero)
  , judgeErrors   :: [Text]    -- case names where the judge errored out
  }
  deriving (Eq, Show)

calibrate :: (LLM :> es)
          => Int                      -- votes per case (full voting, no early stop)
          -> (a -> Text) -> Text      -- render, rubric
          -> [(Text, a, Bool)]        -- (name, OUTPUT, human pass label)
          -> Eff es CalibrationReport

renderCalibration :: CalibrationReport -> Text
```

- Inputs are outputs, not skill inputs: calibrate evaluates only the judge.
- Full voting: `calibrate` uses its own vote loop (or a no-early-stop mode of
  the internal voting helper) so all margins are comparable.
- Judge-error cases are excluded from agreement/kappa/precision/recall and
  listed in `judgeErrors`.
- Degenerate denominators are defined, not crashed: kappa = 0 when expected
  agreement is 1 (all labels on one side); failPrecision/failRecall = 1.0
  when their denominator is 0; agreement over zero judged cases = 0.
- `renderCalibration` prints the four numbers, the contested list (labelled
  "label these next"), and the judge-error list.

Cohen's kappa (binary): with observed agreement po and expected agreement
pe = (yesJ*yesH + noJ*noH) / total^2 (products of marginal rates),
kappa = (po - pe) / (1 - pe), with the pe = 1 case defined as 0.

### 4. Manual: `docs/evals.md` (new page)

Sections, in the house style (no emdashes, no hype, no manifest mentions):

1. The grading ladder: `Exactly` / `Predicate` first (deterministic),
   `Rubric` for one quality concern, `Checklist` for decomposed criteria.
2. Writing observable criteria (good/bad examples from the research note).
3. Rubric lint: coverage, conflation, direction, redundancy (warn that
   near-duplicate criteria double-count under weights).
4. When to split a rubric: independent failures, hard gates (safety as its
   own Checklist case), more than ~5-7 criteria.
5. `judgeN`, the votes field, and reading `[judge uncertain]` flags; the
   cost multiplier; early stopping.
6. The calibration workflow: label ~30 outputs with critiques, run
   `calibrate`, iterate rubric wording until kappa > 0.6, only then trust
   `testSkill` numbers; spend further labels on contested cases.
7. Judge errors: what the `judge error:` tag means (the judge's own reply
   failed to parse after one repair attempt) and that it is distinct from a
   fail.

Add the page to the nav (front-matter `nav_order` after Typed functions) and
link it from `index.md`'s Pages list and from typed-functions.md's testSkill
section. This partially discharges the open backlog issue about Eval having
no manual page.

### 5. Demo (`app/Main.hs`)

One small addition before the OpenAI section: a `Checklist` case and a
`judgeN`-scored `Rubric` case run live via `runEvalN 3` over a fixed output
(rendered with `renderReport`), proving the judge path end to end. Keep it to
a handful of lines; the demo is a smoke test, not a tutorial.

## Migration

Breaking change: `Score` gains a third field.

- `Crucible.Eval` internal constructions move to the `score` smart
  constructor; pattern matches on `Score` in `renderReport`/`runEval` adapt.
- `test/Spec.hs` constructs `Score` in eval fixtures: switch to `score` or
  add `Nothing`.
- `Eval.judge`'s behaviour is otherwise unchanged for existing callers
  (`testSkill`, suite tests): same single call, same Score semantics, votes
  = Nothing... except the verdict JSON order, which scripted tests must
  follow if they assert the prompt (they assert replies, not prompts, so no
  change expected).
- `Crucible.Eval` re-exports `judge` and `Verdict (..)` from
  `Crucible.Eval.Judge`; `Criterion`/`criterion`/`Checklist` export from
  `Crucible.Eval`.

## Testing (all hermetic via runLLMScripted unless noted)

- Verdict codec: decodes `{"why", "pass"}` AND legacy `{"pass", "why"}`;
  encodes why-first.
- Repair: junk then valid reply -> Right Verdict (two completes consumed);
  junk twice -> judge-error Score with `judge error: ` rationale.
- judgeN: 3-0 unanimous stops after 2 calls (observable: a third scripted
  reply remains unconsumed by a following `complete`); 2-1 consumes 3 and
  yields `votes = Just (2,1)`; majority `why` kept; an error vote excluded
  (e.g. junk, junk, pass, pass with n=3 -> repair consumes the junk pair as
  one errored sample, then two passes decide); all-error -> judge error.
- Checklist: weighted score (weights 2 and 1, one fails -> value 2/3 or
  1/3 as scripted); all-pass gives 1.0 and counts in passRate; per-criterion
  rationale lines in order; empty checklist 1.0 with no LLM calls; judge
  error on one criterion -> that line tagged, criterion failed.
- runEvalN: n threads to Rubric and Checklist (scripted call counting).
- renderReport: shows `[judge uncertain 2-1: review by hand]` and
  `[judge error]` annotations.
- calibrate: scripted verdicts vs hand labels with hand-computed agreement,
  kappa, failPrecision, failRecall; a contested case listed; a judge-error
  case excluded from stats and listed; degenerate cases (all labels pass;
  zero fail denominators) hit the defined values.
- Existing suite: all current eval/skill tests keep passing with Score
  construction updated.
- Live smoke: the demo's new eval section runs against a real provider
  before merge.

## Non-goals

- Pairwise comparison / variant ranking (different product).
- Likert or numeric judge scales.
- Jury of distinct models (needs multi-interpreter plumbing).
- Per-criterion vote margins on checklist scores.
- Per-call temperature control on `Complete`.
- Auto-generated checklists (treat as authoring aid, out of library scope).
- Bandit budget allocation across cases (regression suites judge every case).
