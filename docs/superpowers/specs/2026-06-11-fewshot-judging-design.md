# Few-Shot Calibrated Judging Design Spec

**Date:** 2026-06-11
**Status:** Approved design, pending implementation
**Tracker:** `crucible-tfu`.
**Research basis:** `docs/superpowers/research/2026-06-11-autorubric-review.md` item 1 (the only autorubric feature with published effect sizes: RiceChem 77.2 to 80.0 percent, p = 0.023; their cookbook reports 75 to 90 on contract review). Verdict balancing credited to Batch Calibration (Zhou et al. 2023): roughly equal pass/fail examples stop the judge inferring a base-rate prior.
**Scope:** `src/Crucible/Eval/Judge.hs` (JudgeExample, JudgeOpts, balanceExamples, judgePrompt, example-aware judgeOnce/vote), `src/Crucible/Eval.hs` (judgeWith, runEvalWith, specializations), `src/Crucible/Eval/Calibrate.hs` (calibrateWith), `test/Spec.hs`, `docs/evals.md`.

## Motivation

`calibrate` collects human pass/fail labels to measure the judge, then never
uses them again. Feeding a few verdict-balanced labelled examples into the
judge prompt is the cheapest known judge improvement with measured gains,
and the labels already exist. The discipline that matters: never measure
agreement on examples the judge saw.

## Decisions taken during design

- API shape: a `JudgeOpts` record (`votes`, `examples`) with
  `defaultJudgeOpts`; `judgeWith`/`runEvalWith` are the general forms and
  the existing `judge`/`judgeN`/`runEval`/`runEvalN` become one-line
  specializations. Future judge knobs (abstain policy, panels) extend the
  record instead of breeding function variants.
- `JudgeExample {rendered, pass, why :: Maybe Text}`: verdicts always,
  critique rendered only when present (autorubric's measured default is
  verdicts-only; the optional field accommodates the critiques the
  calibration workflow already collects).
- Holdout: `calibrateWith` splits internally with a seed; metrics are
  computed only on the holdout remainder. Plain `calibrate` is unchanged.
- Scope: examples feed Rubric judging (and direct `judgeWith` calls) only.
  Checklist criteria and Grounded claim votes take `opts.votes` but ignore
  examples (each criterion/claim is its own micro-rubric; one example list
  rarely fits all). Per-criterion examples are future work.

## Design

### 1. `Crucible.Eval.Judge`

```haskell
-- | A labelled output shown to the judge as a worked example for the
-- rubric under test. Verdicts always render; the critique renders only
-- when present.
data JudgeExample = JudgeExample
  { rendered :: Text
  , pass     :: Bool
  , why      :: Maybe Text
  }
  deriving (Eq, Show)

-- | Knobs for a judged evaluation. Future judge options (abstain policy,
-- panels) extend this record.
data JudgeOpts = JudgeOpts
  { votes    :: Int             -- ^ samples per judgement (odd; 1 = single call)
  , examples :: [JudgeExample]  -- ^ few-shot examples for Rubric judging
  }
  deriving (Eq, Show)

defaultJudgeOpts :: JudgeOpts   -- votes = 1, examples = []
```

**Verdict balancing**, pure and seeded (no new dependencies; a small
xorshift/LCG permutation over indices is sufficient):

```haskell
-- | Pick n examples, roughly balanced between pass and fail, in a
-- deterministic order for a given seed. Shuffle both classes with the
-- seed, then alternate picks (pass first); when one class runs out, fill
-- from the other. n larger than the supply returns everything (shuffled,
-- balanced-first). Same seed and input order always yields the same list.
balanceExamples :: Int -> Int -> [JudgeExample] -> [JudgeExample]
```

**The judge prompt becomes a pure, exported builder** (mirrors
`Skill.prompt`; this is also what makes prompt content directly testable):

```haskell
judgePrompt :: [JudgeExample] -> Text -> Text -> [Message]
-- args: examples, rubric, rendered output to grade
```

- System message: byte-identical to today's hardened grader message.
- User message, assembled by concatenation (the Skill lesson: conditional
  blocks do not belong in quasiquotes):

  ```
  Rubric: <rubric>

  Examples of past verdicts for this rubric:

  Example output:
  <example rendered>
  Verdict: pass
  Why: <critique>          (line present only when why is Just)

  ...one block per example...

  Output to grade: <graded>
  ```

  With zero examples the user message is byte-identical to today's
  two-line form (`Rubric: ...` newline `Output to grade: ...`); the
  examples header renders only when the list is non-empty.
- No-closed-loop compliance: examples are additional context; every call
  still receives the original output and the rubric verbatim.

**Plumbing.** `judgeOnce` gains the example list (the repair re-prompt is
unchanged and appends to whatever messages were sent). `vote` carries it
through: signature becomes
`vote :: Bool -> JudgeOpts -> Text -> Text -> Eff es VoteOutcome` (early
stop flag, opts, rubric, graded). Existing internal callers update; the
exported behaviour of every current function is unchanged.

### 2. `Crucible.Eval`

```haskell
judgeWith   :: (LLM :> es) => JudgeOpts -> (a -> Text) -> Text -> a -> Eff es Score
runEvalWith :: (Eq a, LLM :> es)
            => JudgeOpts -> (a -> Text) -> (i -> Eff es a) -> [Case i a]
            -> Eff es (Report i a)

-- Specializations (exact semantics preserved, including votes <= 1
-- suppressing the tally):
judge      = judgeWith defaultJudgeOpts
judgeN n   = judgeWith defaultJudgeOpts { votes = n }
runEval    = runEvalWith defaultJudgeOpts
runEvalN n = runEvalWith defaultJudgeOpts { votes = n }
```

Internally `scoreN` generalizes to `scoreWith :: JudgeOpts -> ...`:

- `Rubric r` uses `judgeWith opts` (examples flow through);
- `Checklist cs` and `Grounded ev` use `opts.votes` only, passing empty
  examples to their per-criterion / per-claim votes;
- `Exactly` / `Predicate` unchanged (pure).

`scoreM` keeps its exported signature (= `scoreWith defaultJudgeOpts`).
`testSkill` is unchanged (single-judge, no examples), matching its
existing relationship to `runEval`.

### 3. `Crucible.Eval.Calibrate`

```haskell
calibrateWith :: (LLM :> es)
              => Int                  -- seed for the example split
              -> Int                  -- nExamples fed to the judge
              -> Int                  -- votes per case (full voting)
              -> (a -> Text) -> Text
              -> [(Text, a, Bool)]
              -> Eff es CalibrationReport
```

- Render all labelled outputs; build candidate examples
  `JudgeExample rendered humanLabel Nothing` (the labelled-triple type
  carries no critique; stated in the haddock).
- Select with `balanceExamples seed n'` where
  `n' = max 0 (min nExamples (length labelled - 1))`: at least one
  measurement case always remains; degenerate inputs degrade toward plain
  `calibrate` behaviour instead of erroring.
- Judge ONLY the holdout cases (full voting, no early stop, examples fed
  to every call). Examples cost prompt tokens, not extra calls.
- Compute all metrics (agreement, kappa, fail precision/recall, contested,
  judgeErrors) over the holdout only; the metric fields keep their exact
  meanings, now scoped to the holdout.
- `calibrate` itself is redefined as `calibrateWith` with zero examples
  (seed irrelevant); behaviour byte-identical.
- `renderCalibration` adds one line, only when examples were used:
  `examples fed: <n>  measured on: <holdout count>`, which requires the
  report to know; add `exampleCount :: Int` and `measured :: Int` fields
  to `CalibrationReport` (0 and full count for plain `calibrate`). This is
  the one report-shape change; existing positional constructions in tests
  gain the two fields.

The split discipline, stated everywhere it matters: kappa measured on
examples the judge saw is inflated and meaningless; `calibrateWith` makes
the wrong thing inexpressible by construction.

## Manual (`docs/evals.md`)

- "Voting and uncertainty": introduce `JudgeOpts` and the
  `judgeWith`/`runEvalWith` general forms (existing functions described as
  specializations); note the Rubric-only scope of examples.
- "Calibrating the judge": add the forward-feeding step to the workflow:
  once kappa is healthy, feed the labels forward with `calibrateWith` and
  reuse the same example set in `runEvalWith` for the production suite;
  show the signature; state the holdout rule plainly.
- At-a-glance checklist, one new rule in "Trusting the numbers": labels
  trusted for calibration can be fed forward as judge examples; never
  measure on examples the judge saw.
- House style: no emdashes, no hype, no manifest mentions.

## Demo

Not extended. The feature is fully exercised hermetically; a live few-shot
judging round adds cost without a stable observable.

## Testing (hermetic via runLLMScripted unless noted)

- `balanceExamples`: deterministic for a fixed seed (same output twice);
  different seeds may differ; balance with surplus on one side (6 pass /
  1 fail, n = 4 yields the 1 fail + 3 pass); n exceeding supply returns
  all; n = 0 / empty input return [].
- `judgePrompt` content, directly: zero-example output byte-identical to
  the current two-line user message; with examples, the block contains
  `Example output:`, the rendered text, `Verdict: pass` / `Verdict: fail`,
  and `Why:` only for examples carrying a critique; rubric and graded
  output appear verbatim; System message unchanged.
- `judgeWith` end-to-end scripted: examples change no call counts; a
  scripted verdict still decodes (the prompt grew, the protocol did not).
- `runEvalWith`: a Rubric case and a Checklist case in one run; both score
  correctly from scripted verdicts (examples affect only prompt content,
  which the scripted interpreter ignores; the test pins behaviour parity
  and call counts).
- `calibrateWith` scripted: four labelled cases, nExamples = 2, votes = 1;
  exactly two judge calls consumed (reply counting); metrics computed over
  the two holdout cases only (hand-derived expectations);
  `exampleCount = 2`, `measured = 2`.
- Clamping: nExamples = 10 with 3 labelled cases feeds 2 and measures 1.
- Plain `calibrate` regression: existing calibrate tests pass with the two
  new report fields added to their expected constructions
  (`exampleCount = 0`, `measured = <case count>`).
- `renderCalibration`: the examples line present only when
  `exampleCount > 0`.

## Non-goals

- Per-criterion or per-claim examples (Checklist/Grounded stay
  example-free this cycle).
- Critiques in `calibrateWith`'s input type (would change the labelled
  triple; revisit when a labelled-case record exists).
- Automatic example refresh/rotation policies.
- Reasoning-chain exemplars (autorubric's data says verdicts suffice;
  the optional `why` covers the exception).
