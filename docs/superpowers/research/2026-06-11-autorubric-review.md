# Autorubric vs crucible's eval stack: gap analysis (research notes)

Date: 2026-06-11. In-repo notes comparing Autorubric (arXiv 2603.00077, the
Python library at github.com/delip/autorubric, docs at autorubric.org) against
crucible's eval stack (`src/Crucible/Eval.hs`, `src/Crucible/Eval/Judge.hs`,
`src/Crucible/Eval/Calibrate.hs`, `src/Crucible/Eval/Grounding.hs`,
`docs/evals.md`). Not published.

## Summary

Autorubric (Rao and Callison-Burch, UPenn) is a Python library that packages
rubric-based LLM-as-judge evaluation with opinionated defaults: weighted
binary/ordinal/nominal criteria, per-criterion independent judge calls,
heterogeneous judge ensembles, few-shot calibration with verdict balancing,
a CANNOT_ASSESS abstain verdict, psychometric metrics, and LLM-driven rubric
quality checks and refinement. Crucible already matches its core judging
discipline (per-criterion binary calls, reason-then-verdict, majority voting,
Cohen's kappa calibration) and exceeds it on deterministic graders, grounding
via derived claims, and protocol rules. The real gaps are few-shot calibrated
judging, cross-model judge panels, an abstain verdict, and bootstrap
confidence intervals on calibration metrics. Autorubric's own results
vindicate crucible's binary-only stance: ordinal criteria get 38-58% exact
agreement vs 87% for binary.

## What autorubric ships

From the paper (https://arxiv.org/abs/2603.00077, v2 HTML at
https://arxiv.org/html/2603.00077v2) and the library docs
(https://autorubric.org/docs/, repo https://github.com/delip/autorubric,
Python, MIT, v1.5.0 as of May 2026).

**Criterion types.** Analytic rubrics with three criterion kinds: binary
(MET/UNMET), ordinal (ordered levels, 3-5 recommended), nominal (unordered
categories). Every criterion is `Criterion(name=..., weight=..., requirement=...)`
with configurable positive or negative weights; negative weights are penalty
criteria. Continuous-valued criteria are deliberately excluded. Rubrics load
from dicts or YAML (`Rubric.from_dict([...])`).

**Aggregation formula.** Score is a weighted sum clamped to [0,1]
(paper, Eq. 1): `score = max(0, min(1, sum(v_i * w_i) / sum(w_i > 0)))`,
where v is 1/0 for binary or the option's explicit value for multi-choice.
Negative weights are excluded from the denominator so a perfect response
scores exactly 1; clamping stops penalties pushing below zero.

**Judge modes.** Single judge (`CriterionGrader(llm_config=LLMConfig(...))`)
or an ensemble of heterogeneous judges:
`CriterionGrader(judges=[JudgeSpec(LLMConfig(model="openai/..."), "gpt"),
JudgeSpec(LLMConfig(model="anthropic/..."), "claude")], aggregation="majority")`.
Aggregation strategies: majority vote, weighted vote, unanimous, any-vote.
Ensembles issue N judges x M criteria concurrent calls. Multi-provider via
LiteLLM (100+ providers). Optional extended-thinking budgets per judge; the
paper says evidence for thinking benefits "is mixed".

**Few-shot calibration.** Labeled examples are injected into the judge
prompt: `CriterionGrader(training_data=train_data,
few_shot_config=FewShotConfig(n_examples=3, balance_verdicts=True, seed=42))`.
Verdict balancing keeps roughly equal MET/UNMET examples "to prevent the
judge from inferring a base-rate prior" (paper sec. on calibration; the idea
is credited to Batch Calibration, Zhou et al. 2023). Default is 3
verdict-balanced examples, verdicts only, no exemplar reasoning chains.
Measured effect: RiceChem accuracy 77.2% zero-shot to 80.0% 5-shot
(p = 0.023); the cookbook case study reports 75% to 90% on contract review
(https://autorubric.org/docs/cookbook/few-shot-calibration/). The docs
recommend 3-5 examples, with diminishing returns beyond.

**Abstention.** A CANNOT_ASSESS verdict with four resolution strategies:
SKIP (exclude from the denominator), ZERO, PARTIAL, FAIL. Rationale:
"forcing a verdict produces unreliable scores".

**Bias mitigations.** Per-criterion independent LLM calls (against criterion
conflation and halo effects); shuffled option order with explicit numeric
values and deterministic per-item seeds (against position bias on
multi-choice criteria); a mandatory reason field per verdict (against
opacity); ensembles (against single-judge unreliability). Verbosity bias is
acknowledged as unmitigated in the limitations.

**Metrics.** Cohen's kappa, quadratic-weighted kappa, intraclass correlation,
Earth Mover's Distance, agreement with bootstrap confidence intervals
(https://autorubric.org/docs/api/metrics/ per the cookbook index).

**Rubric quality and refinement.** Two LLM-driven tools
(https://autorubric.org/docs/api/meta/): a standalone meta-rubric that grades
a rubric's clarity, structure, decision boundaries, and anti-patterns
(double-barreled criteria, vague wording, circular definitions, missing
negative criteria, unfalsifiable criteria), plus an in-context mode that adds
construct alignment and discriminative power against a task prompt. And
held-out rubric improvement
(https://autorubric.org/docs/cookbook/held-out-rubric-improvement/):
`improve_rubric(seed_rubric, strategy="held_out", validation_data=...,
max_iterations=5)` grades against ground-truth labels, computes per-criterion
accuracy and FP/FN rates, and has a revision LLM tighten only the requirement
wording (criterion count and order preserved), stopping at mean accuracy 90%
or max iterations. The paper notes automatic rubric induction from scratch is
out of scope; refinement of user-authored rubrics is in.

**Reporting and infra.** Per-criterion verdicts with explanations,
`EnsembleEvaluationReport` preserving per-judge reasoning, cost tracking at
per-call, per-criterion, per-item, and per-run granularities, response
caching, checkpointing with resumable batch runs (`EvalRunner`), async
throughout, length-penalty configuration.

**Validation.** RiceChem (college chemistry grading, 80% with 5-shot),
ResearcherBench (931 criteria, cross-judge agreement analysis), CHARM-100
(new chatbot dataset mixing all three criterion types; 87% binary accuracy,
kappa 0.642). Headline reliability finding: binary criteria are the most
reliable; ordinal criteria show 38-58% exact agreement (85-93% adjacent);
nominal criteria 81% but with asymmetric category sensitivity (verbosity
detection recall 0.14). Limitations: judge model quality dominates all
mitigation effects; English-only prompts; rubric quality measurement still
open. Future work: adaptive ensembling (more judges only on low-confidence
items), criterion-type-aware reward shaping.

**What it cites that is worth knowing about.** G-Eval (Liu et al. 2023,
CoT-then-score), Prometheus 2 (open judge model), FActScore (Min et al. 2023,
atomic-claim factual precision; crucible's `Grounded` already implements this
shape), CheckEval (Lee et al. 2025, checklist decomposition against
conflation), RocketEval (Wei et al. 2025, cheap checklist grading),
LLM-Rubric (Hashemi et al. 2024, a calibration network over multi-dimensional
judge outputs trained on human labels), RULERS (Hong et al. 2026, locked
rubrics plus evidence-anchored scoring, supervised regime with 200+ labels
per dataset), FLASK, HelpSteer 2, Batch Calibration (Zhou et al. 2023, the
base-rate-prior argument behind verdict balancing).

## Side-by-side

| Capability | autorubric | crucible | Verdict |
|---|---|---|---|
| Deterministic graders | none; every criterion is a judge call | `Exactly`, `Predicate`, free and pure | crucible better |
| Binary criteria | MET/UNMET, weighted | `Checklist [Criterion]`, weighted, per-criterion calls | parity |
| Ordinal/nominal criteria | yes | no (deliberate) | crucible better; autorubric's own data shows ordinal exact agreement 38-58% |
| Negative-weight (penalty) criteria | yes, with denominator exclusion and clamping | no; weights assumed positive | autorubric better, small gap |
| Criterion independence | independent per-criterion calls | same (`checklistScore` calls `vote` per criterion) | parity |
| Reason-then-verdict | mandatory reason field | `Verdict { why, pass }`, why-first codec and prompt | parity |
| Judge output repair | not documented | one repair re-prompt with the parse error, then `JudgeError` | crucible better |
| Same-model voting | via ensemble of identical judges | `judgeN` with early stop, vote margins, dissent capture | crucible better mechanics (early stop, dissent) |
| Heterogeneous judge ensemble | `JudgeSpec` list, majority/weighted/unanimous/any | no; one `LLM` effect per run | autorubric better |
| Few-shot calibrated judging | `training_data` + `FewShotConfig`, verdict balancing | no; labels measure the judge but never feed it | autorubric better, measured gains |
| Abstain verdict | CANNOT_ASSESS + SKIP/ZERO/PARTIAL/FAIL | no; pass/fail plus judge-error only | autorubric better |
| Judge-vs-human calibration metrics | kappa, weighted kappa, ICC, EMD, bootstrap CIs | agreement, Cohen's kappa, fail precision/recall, contested list, judge errors | mostly parity; crucible lacks CIs, autorubric lacks fail P/R and the contested workflow |
| Grounding / derived claims | none (cites FActScore but does not ship it) | `Grounded` expectation, `groundingCheck`, decompose + per-claim votes | crucible better |
| Position bias mitigation | option shuffling, seeded | n/a (no multi-choice criteria) | not applicable to crucible |
| Rubric lint | executable meta-rubric LLM check | documented four-check walk (coverage, conflation, direction, redundancy) | autorubric ships it as code; crucible ships it as discipline |
| Rubric refinement loop | `improve_rubric` against held-out labels | no | autorubric better |
| Protocol rules | none stated | no-closed-loop-judging rule, binary-labels-only rule | crucible better |
| Concurrency | async, N x M concurrent | sequential `mapM` | autorubric better |
| Cost tracking | per-call/criterion/item/run | `Usage` monoid + `estimateCost` at the interpreter level, not attributed per criterion | autorubric better granularity |
| Caching / resumable runs | response cache, checkpointing | cassette replay at the LLM effect level | different shapes; crucible's cassette covers CI replay, not resumable long runs |
| Test integration | EvalRunner batch harness | `runEval`/`runEvalN`, `withTests`/`testSkill`, same suite scripted/cassette/live | crucible better (effect polymorphism) |

## What crucible should add

Ranked. Sketches use crucible's idiom (effectful, records with
OverloadedRecordDot, pure cores).

**1. Few-shot calibrated judging.** The one feature with published effect
sizes (p = 0.023 on RiceChem; 75% to 90% in the cookbook study), and
crucible's docs already anticipate it: calibration critiques are "raw
material for few-shot judge examples" (docs/evals.md). The labels exist in
the `calibrate` input; they are just never fed forward. Add examples to the
judge call, with deterministic verdict balancing as a pure function:

```haskell
-- Crucible.Eval.Judge
data JudgeExample = JudgeExample { rendered :: Text, pass :: Bool }

-- Pure, seeded selection: roughly equal pass/fail, n total.
balanceExamples :: Int -> Int -> [JudgeExample] -> [JudgeExample]

judgeOnceWith :: (LLM :> es)
              => [JudgeExample] -> Text -> Text
              -> Eff es (Either JudgeError Verdict)
```

`judgeOnceWith` renders examples into the user message before the graded
output (verdicts only, no reasoning chains, matching autorubric's default).
Thread an optional example list through `vote`, `judgeN`, and a
`scoreNWith`/`runEvalNWith` pair; `calibrate` gains a variant that splits the
labelled set into few-shot examples and a held-out measurement set so the
kappa is not computed on the examples the judge saw. This stays inside the
no-closed-loop rule: examples are extra context, and every call still
receives the original output and rubric verbatim.

**2. Cross-model judge panels.** crucible's own docs name the weakness
twice: no sampling temperature means "three votes are three copies of one
opinion", and rule 13 says to judge with a different model family. A panel
of judges across providers fixes both. The crucible-shaped move is to keep
the tally pure and let the caller run each judge under its own interpreter:

```haskell
-- Crucible.Eval.Judge
-- Pure mechanical combination of independent verdicts (no LLM here),
-- same dissent/first-rationale semantics as vote.
tally :: [Either JudgeError Verdict] -> VoteOutcome

-- And a runner for the common two-provider case, parameterised by
-- judge actions rather than a single LLM effect:
votePanel :: Monad m
          => [Text -> Text -> m (Either JudgeError Verdict)]  -- one per judge
          -> Text -> Text -> m VoteOutcome
```

Each panel member is `judgeOnce` partially applied under a different
interpreter (Anthropic vs the other wired provider). Aggregation stays
majority; unanimous-as-gate falls out of inspecting the tally. This is
open-loop by construction, matching the existing rule.

**3. An abstain verdict with an explicit policy.** Today a judge that cannot
tell is forced to guess, and the guess is indistinguishable from a
considered verdict. Autorubric's CANNOT_ASSESS plus a resolution strategy is
the right shape, and it composes with crucible's vote loop (an abstain
consumes an attempt without casting a vote, exactly like a judge error but
honestly labelled):

```haskell
data VerdictKind = Pass | Fail | CannotAssess
data Verdict = Verdict { why :: Text, kind :: VerdictKind }

data AbstainPolicy
  = AbstainFails   -- strictest, a sane default
  | AbstainSkips   -- criterion drops out of the checklist denominator
```

The codec keeps parsing legacy `{"why", "pass"}` JSON. Report rendering gets
a `[judge abstained]` annotation, distinct from `[judge error]`; `calibrate`
counts abstains separately from disagreement.

**4. Bootstrap confidence intervals on calibration metrics.** Thirty labels
is a small sample; a kappa of 0.65 with a CI of [0.3, 0.85] should not be
trusted the way a tight one is. Pure code, no LLM calls, cheap to add:

```haskell
data CalibrationReport = CalibrationReport
  { ...
  , kappaCI :: (Double, Double)  -- 95% bootstrap interval over judged cases
  }
```

Resample the (human, judge) pairs with a seeded generator, recompute kappa,
take the 2.5/97.5 percentiles. `renderCalibration` prints it next to kappa.

**5. Penalty criteria.** Negative weights for failure modes you want to
subtract for ("recommends a specific product": weight -2). Adopt
autorubric's formula exactly: positive weights only in the denominator,
clamp to [0,1], and keep the pass rule strict (a case passes only when every
positive criterion holds and no negative criterion fires).
`checklistScore` changes a few lines; document that gates should still be
their own case, not a large negative weight.

**6. Executable rubric lint.** docs/evals.md's four-check walk (coverage,
conflation, direction, redundancy) is currently prose. Autorubric shows it
works as an LLM call. A `lintChecklist :: (LLM :> es) => [Criterion] -> Eff
es [Text]` that runs the documented anti-pattern checks (double-barreled
"and" criteria, direction ambiguity, near-duplicates) over the criterion
labels would make the discipline enforceable in CI. Keep it advisory, not a
gate. The held-out `improve_rubric` loop is worth noting but not building
yet: crucible's workflow already iterates rubric wording against `calibrate`
with a human in the loop, and an automated revision loop only pays off once
labelled sets are large.

Not worth adding: ordinal and nominal criteria (autorubric's own CHARM-100
numbers are the argument against), position-bias shuffling (no multi-choice
criteria to shuffle), LiteLLM-style provider sprawl (the `LLM` effect plus
interpreters is the crucible answer).

## What crucible already does better

- **A grading ladder.** Autorubric judges everything; crucible's `Exactly`
  and `Predicate` score deterministically for free, and the docs push users
  down the ladder before any judge call. Autorubric has no equivalent.
- **Grounding via derived claims.** `Grounded` / `groundingCheck` implement
  the FActScore-shaped decompose-and-verify recipe with per-claim votes and
  named unsupported claims. Autorubric cites FActScore but ships nothing
  like it; its verbosity-bias gap is exactly the gap grounding criteria
  close (extra claims earn nothing unless supported).
- **Protocol rules as first-class documentation.** The no-closed-loop rule
  (every judge call receives the original output and rubric verbatim) and
  the binary-labels-only rule for human calibration have no counterpart in
  autorubric; its ensemble report "preserves per-judge reasoning" but states
  no rule about what downstream steps may consume.
- **Vote mechanics.** Early stopping (n=3 typically costs ~2 calls), the
  explicit honesty note that a voted rationale is a majority-side sample,
  dissent capture, and the contested-case list feeding the labelling loop.
  Autorubric's ensemble aggregates but does not surface dissent or direct
  the next labelling dollar.
- **Judge self-repair.** One re-prompt with the raw reply and the parse
  error before a sample errors out, and a hard distinction between a fail
  and a judge error throughout reporting and calibration.
- **Fail-class precision/recall in calibration.** Autorubric reports
  agreement-style metrics; crucible's failPrecision/failRecall directly
  answer "does the judge wave bad outputs through" vs "does it fail good
  ones", which is the actionable split when iterating rubric wording.
- **Effect polymorphism.** One suite runs scripted, from a cassette, or
  live because everything needs only `LLM :> es`. Autorubric's answer is a
  response cache, which replays only what was previously paid for.

## Sources

- Paper abstract: https://arxiv.org/abs/2603.00077
- Paper full text (v2): https://arxiv.org/html/2603.00077v2
- Library repo: https://github.com/delip/autorubric (Python, MIT, v1.5.0)
- Docs index: https://autorubric.org/docs/
- Quickstart: https://autorubric.org/docs/quickstart/
- Few-shot calibration cookbook: https://autorubric.org/docs/cookbook/few-shot-calibration/
- Meta-rubric API: https://autorubric.org/docs/api/meta/
- Held-out rubric improvement: https://autorubric.org/docs/cookbook/held-out-rubric-improvement/
- Cookbook index: https://autorubric.org/docs/cookbook/
- Cited prior work referenced above: G-Eval (Liu et al. 2023), FActScore
  (Min et al. 2023), CheckEval (Lee et al. 2025), RocketEval (Wei et al.
  2025), LLM-Rubric (Hashemi et al. 2024, https://github.com/microsoft/LLM-Rubric),
  RULERS (Hong et al. 2026), Batch Calibration (Zhou et al. 2023)
- Crucible sources compared: src/Crucible/Eval.hs, src/Crucible/Eval/Judge.hs,
  src/Crucible/Eval/Calibrate.hs, src/Crucible/Eval/Grounding.hs, docs/evals.md
