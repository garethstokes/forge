---
title: Evals
nav_order: 9
---

# Evals

`Crucible.Eval` scores a system under test against a dataset of cases. Each
case pairs an input with an expectation; deterministic expectations are scored
in pure code, judged expectations ask an LLM. The judge plumbing (the grader
prompt, JSON repair, majority voting) lives in `Crucible.Eval.Judge`, and a
calibration harness for the judge itself lives in `Crucible.Eval.Calibrate`.
Everything needs only `LLM :> es`, so the same suite runs scripted in CI,
from a cassette, or live.

## The grading ladder

Prefer the cheapest grader that can express the check. The `Expectation` type
is a ladder, from deterministic to judged:

```haskell
data Expectation a
  = Exactly a              -- must equal (needs Eq a)
  | Predicate (a -> Bool)  -- must satisfy
  | Rubric Text            -- LLM-as-judge against this rubric
  | Checklist [Criterion]  -- weighted binary criteria, judged one by one
```

`Exactly` and `Predicate` are free and deterministic: use them whenever the
property is computable from the output (an exact label, a length bound, a
parseable date). `Rubric` asks the LLM judge one holistic question; reserve it
for a single quality concern that resists a predicate. `Checklist` decomposes
a quality goal into weighted binary criteria, each judged with its own call:

```haskell
data Criterion = Criterion { label :: Text, weight :: Double }

criterion :: Text -> Criterion   -- a criterion with weight 1
```

A checklist score is passed weight over total weight, so it lands in [0,1],
but the case only counts as a pass (in `Report.passRate`) when every
criterion holds; weights affect `Report.meanScore` only. Binary criteria
grade more consistently than a 1-5 scale: nobody can say what separates a 3
from a 4, but "mentions a temperature" is checkable. If you need granularity,
add criteria rather than widening a scale.

Run a dataset with `runEval`:

```haskell
runEval :: (Eq a, LLM :> es)
        => (a -> Text)        -- render an output for the judge
        -> (i -> Eff es a)    -- the system under test
        -> [Case i a]
        -> Eff es (Report i a)
```

`Case` is `Case { input :: i, name :: Text, expect :: Expectation a }`, and
the `Report` carries per-case `results`, a `passRate` (fraction of cases that
scored 1.0), and a `meanScore`. From the demo in `app/Main.hs` (which uses
`runEvalN 3`; the system under test there is `pure`, grading fixed outputs):

```haskell
report <- runEff (Anthropic.run cfg (runEval id pure
  [ Case ("It is 26C and sunny in Brisbane." :: Text) "weather-report"
      (Checklist [criterion "mentions a temperature", criterion "mentions a city"])
  , Case "pong" "terse-pong" (Rubric "the output is a single short word")
  ]))
TIO.putStrLn (renderReport report)
```

`renderReport` prints one line per case (value, rationale, and any judge
annotations), then a summary:

```
weather-report: 1.0 ([pass] mentions a temperature: the output states "26C"
[pass] mentions a city: the output names Brisbane)
terse-pong: 1.0 (the output is the single word "pong")

pass-rate: 1.0  mean: 1.0
```

To attach cases to a skill instead of running a standalone dataset, see
`withTests`/`testSkill` in [Typed functions](typed-functions.md).

## Writing observable criteria

Write criteria that are observable, not aspirational. Each criterion should
be checkable by reading the output alone (plus the input if needed), with no
hidden judgement call.

Good:

```haskell
Checklist
  [ criterion "cites at least one source URL"
  , criterion "states the temperature with a unit"
  , criterion "does not recommend a specific product"
  ]
```

Aspirational, and therefore noisy:

```haskell
Checklist
  [ criterion "is trustworthy"
  , criterion "is high quality"
  , criterion "is helpful"
  ]
```

"Is trustworthy" forces the judge to invent its own standard on every call,
and two runs will invent different ones. "Cites at least one source URL" has
one answer. Negative criteria ("does not...") are fine and often the sharpest
way to pin a failure mode you have actually seen.

## Grounding criteria for context-receiving skills

A skill whose output reasons over provided material (retrieval answers,
summarisation, analysis, classification with a rationale) needs criteria
that check the output against its context, not only against the expected
answer. Accuracy-only evals are blind to grounding decay: a system can keep
returning the right verdict while its stated reasoning drifts away from the
evidence, and nothing in an exact-match or answer-level rubric will notice.

For any checklist over a context-receiving skill, include binary grounding
criteria alongside the content ones:

```haskell
Checklist
  [ criterion "every factual claim is supported by the provided context"
  , criterion "quotes or cites the source span for each key claim"
  , criterion "does not introduce facts absent from the context"
  ]
```

These double as verbosity-bias hardening: a longer answer earns nothing
from a grounding criterion unless its extra claims are actually supported.
The scope limit runs the other way too: skills that generate freely
(creative writing, brainstorming) have no context to ground against, so
they skip these criteria rather than inheriting them as boilerplate.

### Derived claims: groundingCheck

Authored criteria catch missing expected content; they cannot anticipate
invented content. `groundingCheck` closes that gap by deriving the
checklist from the output itself: an LLM call decomposes the output into
atomic factual claims (at most 20, trivia merged), then each claim is
verified against the evidence with its own binary judge vote. The score is
supported claims over total claims.

```haskell
groundingCheck :: (LLM :> es)
               => Int            -- votes per claim (odd)
               -> (o -> Text)    -- render the output
               -> Text           -- the evidence
               -> o
               -> Eff es Score
```

Or attach it as an expectation, with the evidence carried per case:

```haskell
Case answer "grounded" (Grounded retrievedContext)
```

A `Grounded` case passes only when every claim is supported: one
hallucinated fact fails the case, and the rationale names it with the
judge's reason (`[unsupported] <claim>: ...`). The fractional value still
feeds `meanScore` as a diagnostic. Use authored grounding criteria and a
`Grounded` case together: the first checks what should be there, the
second checks that nothing else is.

Two mechanics worth knowing. The protocol stays open-loop under the rule
below: the original evidence is re-injected verbatim into every
verification call, and the claim under test is the subject of the
judgement, not a substitute for the evidence. And the cost is one
decompose call (two if its JSON needs the repair re-prompt) plus claims
times votes judge calls; a decompose failure surfaces as a
`judge error:` tagged score, distinct from a fail.

## Lint your rubric

Before trusting a checklist, walk it with four checks:

- **Coverage.** Do the criteria span the failure modes you have actually
  observed? Criteria should come from reading real failing outputs, not from
  imagining what quality means. If a failure you care about maps to no
  criterion, the suite cannot catch it.
- **Conflation.** A criterion that tests two things ("mentions the city and
  the temperature") gives one bit for two facts; when it fails you do not
  know which half failed, and the judge must decide how to score a half-met
  criterion. Split it.
- **Direction.** Phrase each criterion so that "yes" is unambiguously the
  good outcome. "Avoids jargon" is judgeable; "uses appropriate language" is
  a coin flip.
- **Redundancy.** Near-duplicate criteria ("mentions a temperature",
  "includes the degrees") double-count under weights: one underlying failure
  drags the score down twice, and `meanScore` quietly overweights that
  concern. Merge them.

## When to split a rubric

Keep one `Rubric` per quality concern, and split when:

- **Criteria fail independently.** If one criterion keeps failing for a
  different reason than the others, make it its own case so it shows up as
  its own line in the report rather than a blended score.
- **A criterion is a hard gate.** Safety and format requirements should not
  be averaged away by weights. Express a gate as its own `Checklist` case:
  `passRate` already requires every criterion in a checklist to hold, so the
  gate fails the case outright regardless of weight.
- **The rubric outgrows the judge's attention.** Past roughly 5 to 7
  criteria in one prompt, judge consistency drops. `Checklist` already
  judges each criterion with its own call, so the per-criterion cost is the
  same; splitting into cases buys you per-concern reporting.

## Voting and uncertainty

A single judge sample is a coin with a bias; voting estimates the bias.
`judgeN` samples the judge up to n times and majority-votes, and `runEvalN`
threads the same n through `Rubric` cases and every `Checklist` criterion:

```haskell
judgeN   :: (LLM :> es) => Int -> (a -> Text) -> Text -> a -> Eff es Score
runEvalN :: (Eq a, LLM :> es)
         => Int -> (a -> Text) -> (i -> Eff es a) -> [Case i a] -> Eff es (Report i a)
```

`judge` and `runEval` are the n = 1 versions. Use odd n. The vote stops early
once one side holds a strict majority, so n = 3 typically costs about 2 calls
per judgement; the worst case is n calls, each doubled if its reply needs the
repair re-prompt (see [Judge errors](#judge-errors)). That multiplier applies
per criterion in a checklist, so a 5-criterion checklist at n = 3 is roughly
10 judge calls per case. Reserve n > 1 for the judged cases you act on.

For n > 1 the tally and any dissenting rationale land in the score:

```haskell
data Score = Score
  { value     :: Double
  , rationale :: Text
  , votes     :: Maybe (Int, Int)
  , dissent   :: Maybe Text
  }
```

`votes = Just (yes, no)` with both sides nonzero means the judge is genuinely
uncertain on this case. `renderReport` shows the tally as `[votes 2-1]` and
flags splits as `[judge uncertain: review by hand; dissent: ...]` with the
losing side's rationale inline. These split cases are exactly the ones worth
a human look, and the ones to label first when calibrating.

One honesty rule, baked into the rendering: the rationale on a voted score
is labelled `majority-side rationale` because that is what it is, a sample
from the winning votes. A rationale attached to a vote outcome is not
necessarily why the votes went that way (verdicts and reasoning can diverge),
so treat it as illustration, not explanation, especially during calibration
review.

One limitation: crucible does not set a sampling temperature, so vote
diversity rides entirely on the provider's default sampling. If the provider
returns near-deterministic replies, three votes are three copies of one
opinion and the tally will look more confident than it is.

## No closed-loop judging

A hard rule for any judge protocol, current or future: **every LLM call in
the protocol must receive the original skill output and the rubric,
verbatim.** Judging from a summary, a critique, or the transcript of another
judge step is forbidden. A previous step quoting the artifact does not
count; only the artifact does.

The reason is structural, not stylistic. In a closed chain (evidence shown
once, each step derived only from the previous step), the connection between
the evidence and the verdict can only decay as steps accumulate. The
measured failure mode is quiet: multi-step judge debates keep their accuracy
while the reasoning detaches from the evidence, and majority-voted debate
collapses reasoning faithfulness almost entirely. Re-injecting the original
artifact at every step is what prevents it; prompting the steps to argue
more carefully does not.

crucible's own voting is open-loop by construction: each `judgeN` sample is
an independent call that receives the original output and rubric, and the
votes are aggregated mechanically, not by another model. Keep that shape.
If a protocol cannot re-inject the originals at some step, do not build
that step: use independent one-shot judges plus a mechanical vote instead.

The review test, one line: does every LLM call in this protocol receive the
original output and the rubric? If any call sees only derived text, the
protocol is closed-loop and the answer is no.

## Calibrating the judge

Suite numbers are only as good as the judge that produced them, so calibrate
the judge against human labels before trusting it. The workflow:

1. Label around 30 real outputs pass/fail, each with a short critique. Keep
   labelling until new outputs stop revealing new failure modes.
2. Run `calibrate` with your rubric over the labelled set.
3. Compare the judge's rationales to your critiques and iterate the rubric
   wording until kappa exceeds 0.6.
4. Then trust the numbers `testSkill` and `runEval` produce, and spend
   further labelling effort on the `contested` cases the report lists.

One guardrail on the labels themselves: human calibration labels are binary
pass/fail on the task-level outcome, never numeric ratings of reasoning
quality. Humans rating reasoning on a scale agree with each other at chance
level, so a scale-rated "gold standard" calibrates nothing. The critique
text that accompanies each label is qualitative context and raw material
for few-shot judge examples, not a calibration target. If you need a human
signal about reasoning, decompose it into observable binary proxies
(grounding criteria, format checks) and label those.

`calibrate` runs the judge directly over hand-labelled outputs, bypassing any
skill: it evaluates only the judge. It uses full n-sample voting with no
early stopping, so vote margins are comparable across cases:

```haskell
calibrate :: (LLM :> es)
          => Int                 -- votes per case (odd)
          -> (a -> Text)         -- render an output for the judge
          -> Text                -- the rubric under test
          -> [(Text, a, Bool)]   -- (case name, output, human pass/fail)
          -> Eff es CalibrationReport
```

The `CalibrationReport` carries raw `agreement`, Cohen's `kappa` (agreement
corrected for chance; raw agreement flatters the judge when most cases pass),
`failPrecision` (of the judge's fails, how many a human also failed) and
`failRecall` (of the human fails, how many the judge caught), plus the
`contested` case names where the vote split and any `judgeErrors`.
`renderCalibration` prints it:

```
agreement:      0.9
kappa:          0.74
fail precision: 1.0
fail recall:    0.75
contested (label these next): edge-case-7, sarcastic-review
```

Low fail recall means the judge waves through outputs a human would reject:
tighten the rubric. Low fail precision means it fails good outputs: the
rubric is demanding something you did not intend.

## Judge errors

The judge replies in JSON (a rationale, then a verdict). When its own reply
fails to parse, crucible re-prompts it once with the raw reply and the parse
error; if the repair also fails, that sample errors out. A sample that errors
consumes a vote attempt without casting a vote, and if every attempt in a
vote errors, the result is the judge-error score: value 0 with a rationale
tagged `judge error:`.

This is a different animal from a fail. A fail means the judge read the
output and rejected it; a judge error means no verdict was obtained at all.
`renderReport` appends `[judge error]` to affected lines so the two are not
confused, and `calibrate` excludes judge-error cases from all four rates,
listing their names in `judgeErrors` instead. If judge errors recur, the fix
is usually in the rubric text (something in it is steering the judge away
from the required JSON shape), not in the system under test.

## Rubric rules at a glance

The whole page as a checklist. Each rule links back to the section that
explains it.

Writing criteria:

1. One observable fact per criterion; checkable from the output alone.
   ([Writing observable criteria](#writing-observable-criteria))
2. Binary, never scaled. Granularity comes from more criteria, not a wider
   scale. ([The grading ladder](#the-grading-ladder))
3. Phrase so "yes" is unambiguously the good outcome.
   ([Lint your rubric](#lint-your-rubric))
4. Negative criteria ("does not...") are first-class; state prohibitions
   explicitly. ([Writing observable criteria](#writing-observable-criteria))
5. One thing per criterion; split anything joined by "and".
   ([Lint your rubric](#lint-your-rubric))
6. Context-receiving skills get binary grounding criteria (supported claims,
   cited spans, no invented facts); creative skills skip them. Add a
   `Grounded` case to catch invented content the authored criteria cannot
   anticipate.
   ([Grounding criteria](#grounding-criteria-for-context-receiving-skills))

Structuring the rubric:

7. Derive criteria from failures you have actually observed, not from
   imagining what quality means. ([Lint your rubric](#lint-your-rubric))
8. Cap a checklist at roughly 5 to 7 criteria; split beyond that.
   ([When to split a rubric](#when-to-split-a-rubric))
9. Hard gates (safety, format) get their own `Checklist` case, never a
   weight. ([When to split a rubric](#when-to-split-a-rubric))
10. Merge near-duplicate criteria; they double-count under weights.
    ([Lint your rubric](#lint-your-rubric))
11. After writing, walk your failure list: every failure mode you care about
    maps to some criterion. ([Lint your rubric](#lint-your-rubric))

Setting up the judging:

12. Deterministic graders first: if `Exactly` or `Predicate` can check it,
    no judge call. ([The grading ladder](#the-grading-ladder))
13. Where possible, judge with a different model family than the system
    under test; judges measurably prefer outputs from their own family. With
    both providers wired in, a skill run on one can be judged through the
    other.
14. Vote (`runEvalN 3`) on contested or high-stakes cases; the `2-1` flag is
    a free uncertainty signal. ([Voting and uncertainty](#voting-and-uncertainty))
15. No closed-loop judging: every LLM call in a judge protocol receives the
    original output and rubric verbatim; a step that sees only derived text
    is forbidden. ([No closed-loop judging](#no-closed-loop-judging))

Trusting the numbers:

16. Calibrate before believing: ~30 hand labels, iterate wording until kappa
    clears 0.6. ([Calibrating the judge](#calibrating-the-judge))
17. Calibration labels are binary, task-level pass/fail; never scale-rate
    reasoning quality. Critiques are context, not targets.
    ([Calibrating the judge](#calibrating-the-judge))
18. Spend new labels on the `contested` list; that is where a label buys the
    most. ([Calibrating the judge](#calibrating-the-judge))
19. A voted score's rationale is a majority-side sample, not the reason the
    vote went that way; read the dissent on contested cases.
    ([Voting and uncertainty](#voting-and-uncertainty))
20. Every triaged production failure becomes a regression case; the eval set
    grows from real failures, not invented ones.
