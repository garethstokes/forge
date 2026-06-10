# Building LLM evaluation rubrics: practical techniques (research notes)

Date: 2026-06-11. In-repo notes for crucible's eval machinery
(`src/Crucible/Eval.hs`, `src/Crucible/Skill.hs`). Not published.

## Summary

Binary per-criterion checks beat Likert scales: they calibrate better against
humans and are harder to game with verbosity. Decompose vague quality goals
("helpful", "professional tone") into independently checkable yes/no criteria,
optionally weighted (HealthBench style). Make the judge reason before it
verdicts (CoT-then-answer, as in G-Eval and autoevals' `use_cot`), and reduce
variance with n-vote self-consistency or a small jury of judges. Crucially,
rubrics are not written once: the workflow is error analysis on real failures,
a small human-labelled seed set (~30 examples), then iterating the judge prompt
until judge-human agreement (precision/recall, Cohen's kappa) is acceptable.
crucible's `Verdict {pass, why}` shape is already the recommended primitive;
the gaps are multi-criterion rubrics, CoT before the verdict, repeat-voting,
and a calibration path that compares judge scores to hand labels.

## Techniques

### 1. Rubric construction

**Decompose, don't gestalt.** A single holistic question ("is this response
good?") produces noisy, unactionable verdicts. The consistent finding across
frameworks and papers is to break the quality goal into specific criteria that
can each be checked independently. TICK (arXiv 2410.03608) showed that
decomposing an instruction into a checklist of YES/NO questions, each asking
whether the response meets one specific requirement, raised exact agreement
between LLM judgements and human preferences from 46.4% to 52.2% versus direct
scoring ([TICK paper](https://arxiv.org/abs/2410.03608)). Analytic rubrics
(per-criterion scores) localise failures; holistic rubrics (one overall grade)
only tell you something is wrong somewhere.

**Binary checks calibrate better than Likert scales.** Hamel Husain's guide
argues hard for pass/fail over 1-5 scales: nobody can articulate what
separates a 3 from a 4, so scores drift between runs and between annotators,
and the scale invites verbosity gaming. A binary verdict forces you to define
the acceptability boundary up front ([Hamel Husain, LLM judge
guide](https://hamel.dev/blog/posts/llm-judge/)). Survey writeups echo the
hierarchy: binary best, 3-point acceptable, 5-point only with a very explicit
rubric and anchored examples, 10/100-point avoid ([Evidently
guide](https://www.evidentlyai.com/llm-guide/llm-as-a-judge),
[Monte Carlo](https://montecarlo.ai/blog-llm-as-judge/)). If you need
granularity, get it by adding more binary criteria, not by widening the scale.

**Rubric-as-weighted-checklist (HealthBench).** OpenAI's HealthBench is the
clearest production example: each test conversation has its own set of
physician-written rubric criteria (48,562 unique criteria across the
benchmark). Each criterion is a concrete statement of what an ideal response
should include or avoid ("mentions red-flag symptom X", "avoids unnecessary
jargon") and carries a point weight reflecting its importance; a grader model
checks each criterion independently and the case score is the weighted sum of
met criteria over total possible points ([HealthBench
paper](https://cdn.openai.com/pdf/bd7a39d5-9e9f-47b3-903c-8b847ca650c7/healthbench_paper.pdf),
[OpenAI announcement](https://openai.com/index/healthbench/)). Negative
criteria ("does NOT recommend...") are first-class. This gives graded scores
in [0,1] while every individual judge call stays binary, which is the sweet
spot for crucible's existing `Score` type.

**Write criteria that are observable, not aspirational.** Good criterion:
"cites at least one source URL". Bad criterion: "is trustworthy". Each item
should be checkable by reading the output alone (plus the input if needed),
with no hidden judgement calls. Anthropic's docs make the same point as
"empirical, specific evaluations": instruct the grader to output only
correct/incorrect rather than open-ended quality prose ([Anthropic, define
success criteria](https://docs.anthropic.com/en/docs/test-and-evaluate/develop-tests)).

### 2. Judge reliability

**Known biases.** Documented and reproducible, not hypothetical:

- Position bias: in pairwise comparisons judges favour the first-presented
  option; mitigate by running both orderings and averaging
  ([Future AGI survey](https://futureagi.com/blog/llm-as-a-judge/)).
- Verbosity bias: judges prefer longer, more fluent outputs regardless of
  substance. Binary pass/fail against concrete criteria is much harder to
  game with length than a quality scale
  ([Hamel Husain](https://hamel.dev/blog/posts/llm-judge/)).
- Self-preference bias: a judge scores outputs from its own model family
  higher (lower perplexity to itself reads as "better")
  ([survey](https://www.sciencedirect.com/science/article/pii/S2666675825004564)).
  Practical rule: judge with a different model (or at least different family)
  than the system under test where possible.
- Sycophancy / scoring bias: judges drift toward agreeable verdicts and are
  sensitive to superficial prompt features
  ([Evaluating Scoring Bias in LLM-as-a-Judge](https://arxiv.org/html/2506.22316v1)).

**Pairwise vs absolute.** Pairwise comparison ("which of A/B is better?") is
more reliable for ranking model variants but inherits position bias and does
not give you a regression-testable pass/fail per case. Absolute scoring
against an explicit rubric is the right shape for CI-style evals like
crucible's; pairwise is worth adding only if crucible later grows an A/B
prompt-comparison mode.

**CoT before verdict.** G-Eval's core result: having the judge generate
reasoning steps from the criteria, then evaluate step by step before emitting
the score, improves correlation with human judgement because the judge
actually walks the criteria instead of pattern-matching surface features
([DeepEval G-Eval docs](https://deepeval.com/docs/metrics-llm-evals),
[promptfoo G-Eval](https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/g-eval/)).
Braintrust's autoevals exposes this as `use_cot=True` on `LLMClassifier`: the
judge writes a short chain of thought, then a final line `Final: Y/N` that is
parsed for the verdict ([autoevals](https://github.com/braintrustdata/autoevals),
[Braintrust on LLM-as-judge](https://www.braintrust.dev/articles/what-is-llm-as-a-judge)).
The ordering matters: reasoning first, verdict last, so the verdict is
conditioned on the reasoning. crucible's current judge asks for
`{"pass", "why"}` with pass first, which is the wrong order for this effect.

**Self-consistency and juries.** Two cheap variance reducers:

- Self-consistency: sample the same judge n times at temperature ~0.7 and
  take the majority verdict. The Verdict library reports a GPT-4 judge with
  10 samples at temp 0.7 plus majority vote as a strong baseline
  ([Verdict](https://arxiv.org/pdf/2502.18018)). n=3 or n=5 captures most of
  the benefit at tolerable cost.
- Panel of LLM evaluators (PoLL): several smaller judges from disjoint model
  families, majority-voted, outperformed a single GPT-4 judge at ~1/7 the
  cost and with less intra-model bias
  ([Replacing Judges with Juries](https://arxiv.org/pdf/2404.18796),
  [Comet on LLM juries](https://www.comet.com/site/blog/llm-juries-for-evaluation/)).

**Temperature.** For a single-shot judge use temperature 0 (or as low as the
API allows) for repeatability. Use higher temperature (~0.7) only when
sampling multiple verdicts for majority voting, where diversity is the point.

**Calibration against humans.** A judge is itself a model that needs evals.
Standard recipe: label 100-300 traces with 2-3 humans on the same rubric;
check inter-annotator agreement first (Cohen's kappa > 0.6 acceptable, > 0.8
strong; if humans can't agree, the rubric is broken, not the judge); then run
the judge on the same traces and compute judge-human kappa. Below ~0.5,
rework the rubric or judge prompt; ~0.75+ agreement is a common target
([Vadim's blog](https://vadim.blog/llm-as-judge),
[Future AGI](https://futureagi.com/blog/llm-as-a-judge/)). With imbalanced
pass/fail rates raw agreement is misleading; report judge precision and
recall on the "fail" class separately
([Hamel Husain FAQ](https://hamel.dev/blog/posts/evals-faq/)).

### 3. Practical workflow

The consensus workflow (Hamel Husain's "critique shadowing", LangSmith's
Align Evals, Anthropic's grading guidance) looks like:

1. **Start from failures, not from the rubric.** Do error analysis on real
   traces: read outputs, write open-ended notes, cluster the notes into a
   failure taxonomy. Rubric criteria are then written to detect those
   specific failure modes. Husain reports 60-80% of eval effort going into
   this step ([error analysis FAQ](https://hamel.dev/blog/posts/evals-faq/why-is-error-analysis-so-important-in-llm-evals-and-how-is-it-performed.html)).
2. **Build a labelled seed set.** One principal domain expert labels ~30
   diverse examples pass/fail with a short critique for each; keep going
   until no new failure modes appear. The critiques become few-shot examples
   for the judge prompt ([Hamel Husain](https://hamel.dev/blog/posts/llm-judge/)).
3. **Iterate the judge against the seed set.** Run the judge, compare its
   verdict and rationale to the expert's side by side, adjust the rubric
   wording and few-shot examples, repeat. Husain reports >90% agreement in
   three iterations at Honeycomb. LangSmith productised exactly this loop as
   Align Evals: an alignment score against human labels, with human
   corrections stored and fed back as few-shot examples; a first calibration
   pass on 20-30 labels typically moves alignment 10-15 points
   ([Align Evals](https://blog.langchain.com/introducing-align-evals/),
   [LangSmith docs](https://docs.langchain.com/langsmith/improve-judge-evaluator-feedback)).
4. **Hold out and monitor.** Keep some labelled cases out of the iteration
   loop to estimate true judge accuracy; periodically re-label fresh traces
   to catch drift.

**When to split one Rubric into several cases.** Split when (a) one criterion
keeps failing for a different reason than the others, so you want it visible
as its own line in the report; (b) the criteria have different severities
(a safety criterion should be its own gate, not averaged away); or (c) the
rubric text exceeds what a judge can hold attention on, roughly more than
5-7 criteria in one prompt. Per-criterion judge calls cost more but localise
failures; HealthBench grades every criterion as its own judgement for this
reason. Anthropic's agent-evals writeup similarly recommends many small
targeted graders over one omnibus grader
([Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).

### 4. What the frameworks do (stealable parts)

- **OpenAI evals / graders API**: `string_check`, `text_similarity`,
  `python`, `label_model` (categorical verdict), `score_model` (numeric).
  Guidance: deterministic graders first, model graders only where needed;
  give the model grader few-shot examples of great/fair/poor answers
  ([Graders docs](https://developers.openai.com/api/docs/guides/graders)).
  crucible's `Exactly`/`Predicate`/`Rubric` triple already mirrors this
  deterministic-first hierarchy.
- **Anthropic**: code-based grading where possible, LLM grading where
  necessary, human grading for validation; LLM graders must be calibrated
  against human experts before being trusted at scale
  ([develop tests](https://docs.anthropic.com/en/docs/test-and-evaluate/develop-tests)).
- **Braintrust autoevals**: `LLMClassifier` with a prompt template,
  `choice_scores` mapping labels to numbers, and `use_cot` for
  reason-then-verdict. The mapped-choice-scores idea generalises crucible's
  bool to "judge picks a label, library maps label to score"
  ([autoevals](https://github.com/braintrustdata/autoevals)).
- **DeepEval G-Eval**: from a criteria string it auto-generates
  `evaluation_steps` once (CoT over the criteria), then reuses those fixed
  steps for every case, which makes scoring more repeatable across runs;
  users can also supply the steps explicitly
  ([G-Eval docs](https://deepeval.com/docs/metrics-llm-evals)). The
  "compile the rubric into explicit steps once, reuse verbatim" trick is
  directly stealable.
- **promptfoo**: `llm-rubric` is a plain-English rubric assertion returning
  pass/fail plus score with a threshold; a config-level `defaultTest` can
  pin the judge model and judge prompt separately from the system under test
  ([llm-rubric docs](https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/llm-rubric/)).
- **LangSmith Align Evals**: alignment score of judge vs human labels as a
  first-class metric, and human corrections auto-fed back into the judge
  prompt as few-shot examples
  ([Align Evals](https://blog.langchain.com/introducing-align-evals/)).

## Recommendations for crucible

Concrete, roughly in order of value per line of code.

### 1. Reorder the judge JSON: why before pass

Smallest possible change with real effect. The current schema
`{"pass": <bool>, "why": <string>}` makes the model commit to the verdict
before writing its reasoning. Swap field order in the prompt and codec so the
judge writes `why` first:

```
Respond ONLY with JSON {"why": <string>, "pass": <bool>}.
First reason briefly through each rubric requirement in "why", then verdict.
```

Autoregressive decoding means the verdict is then conditioned on the
reasoning, which is the whole G-Eval/CoT effect at zero extra cost.

### 2. Multi-criterion rubrics as weighted checklists

Add a checklist expectation alongside `Rubric`:

```haskell
data Criterion = Criterion
  { label  :: Text    -- e.g. "cites a source URL"
  , weight :: Double  -- importance, HealthBench-style; default 1
  }

data Expectation a
  = Exactly a
  | Predicate (a -> Bool)
  | Rubric Text
  | Checklist [Criterion]   -- new
```

Judge each criterion with its own binary call (or one call returning a JSON
array of per-criterion verdicts to save tokens; per-criterion calls are more
reliable, the array is cheaper; start with the array and a codec for
`[{"label", "why", "pass"}]`). Score = sum of weights of passed criteria /
total weight, yielding a graded `Score` while every judgement stays binary.
The per-criterion `why`s concatenate into the rationale, which makes
`renderReport` output actually diagnostic. Note `runEval`'s passRate counts
`>= 1.0`, so a checklist case only "passes" if every criterion passes, which
is the right default; weights then only matter for `meanScore`.

### 3. n-vote self-consistency on the judge

```haskell
judgeN :: (LLM :> es) => Int -> (a -> Text) -> Text -> a -> Eff es Score
```

Run `judge` n times (n=3 default, odd), majority-vote `pass`, keep the `why`
from the majority side. Requires the LLM effect to support nonzero
temperature for the judge calls if the interpreter pins temperature; if
temperature is not controllable per-call, the votes still help against
sampling noise on providers that never return fully deterministic output.
Document the cost multiplier. A jury of different models is better still but
needs multi-interpreter plumbing; not worth it yet.

### 4. Harden the judge prompt

Current system prompt is one line. Borrow the standard mitigations:

- State that length and style are not criteria unless the rubric says so
  (verbosity bias).
- Tell the judge to fail when the rubric requirement is not demonstrably met
  (sycophancy lean-to-pass).
- Instruct it to quote the part of the output that satisfies or violates
  each requirement (grounds the `why`, makes calibration review faster).

### 5. Calibration workflow on top of testSkill

No new machinery needed for a first version, just a documented pattern plus
one helper:

```haskell
-- compare judge verdicts to hand labels on the same cases
calibrate :: (LLM :> es)
          => (a -> Text) -> Text          -- render, rubric
          -> [(Text, a, Bool)]            -- (name, output, human pass label)
          -> Eff es CalibrationReport     -- agreement, kappa, fail-precision/recall
```

Run the judge over human-labelled outputs (note: outputs, not inputs; this
bypasses the skill under test and evaluates only the judge) and report raw
agreement, Cohen's kappa, and precision/recall on the fail class. Document
the workflow in the manual: label ~30 outputs pass/fail with critiques,
run `calibrate`, edit the rubric until kappa > 0.6, only then trust
`testSkill` numbers. This is the LangSmith Align Evals loop in library form
and is the piece none of the small frameworks ship as code.

### 6. Manual guidance on splitting rubrics

Documentation, not code: one `Rubric` per quality concern; split a rubric
when criteria fail independently, when one criterion is a hard gate (safety,
format), or when the rubric grows past ~5 criteria. Safety-style gates are
better expressed as their own `Checklist [Criterion]` case with weight
irrelevant, since passRate already requires all criteria.

Not recommended for crucible: Likert/numeric judge scales (calibrate worse,
nothing in the Report type needs them) and pairwise comparison (different
product: variant ranking, not regression testing).

## Sources

- https://hamel.dev/blog/posts/llm-judge/
- https://hamel.dev/blog/posts/evals-faq/
- https://hamel.dev/blog/posts/evals-faq/why-is-error-analysis-so-important-in-llm-evals-and-how-is-it-performed.html
- https://arxiv.org/abs/2410.03608 (TICK: generated checklists improve LLM evaluation)
- https://cdn.openai.com/pdf/bd7a39d5-9e9f-47b3-903c-8b847ca650c7/healthbench_paper.pdf
- https://openai.com/index/healthbench/
- https://arxiv.org/pdf/2404.18796 (Replacing Judges with Juries / PoLL)
- https://arxiv.org/pdf/2502.18018 (Verdict: scaling judge-time compute)
- https://arxiv.org/html/2506.22316v1 (Evaluating Scoring Bias in LLM-as-a-Judge)
- https://www.sciencedirect.com/science/article/pii/S2666675825004564 (LLM-as-a-judge survey)
- https://docs.anthropic.com/en/docs/test-and-evaluate/develop-tests
- https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- https://developers.openai.com/api/docs/guides/graders
- https://github.com/braintrustdata/autoevals
- https://www.braintrust.dev/articles/what-is-llm-as-a-judge
- https://deepeval.com/docs/metrics-llm-evals (G-Eval)
- https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/llm-rubric/
- https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/g-eval/
- https://blog.langchain.com/introducing-align-evals/
- https://docs.langchain.com/langsmith/improve-judge-evaluator-feedback
- https://www.evidentlyai.com/llm-guide/llm-as-a-judge
- https://montecarlo.ai/blog-llm-as-judge/
- https://futureagi.com/blog/llm-as-a-judge/
- https://vadim.blog/llm-as-judge
- https://www.comet.com/site/blog/llm-juries-for-evaluation/
