# Eval schemas, suite design, and domain evals (research notes)

Date: 2026-06-12. In-repo notes for crucible's eval machinery, companion to
`2026-06-11-evaluation-rubrics.md` (rubric construction, judge reliability,
calibration). This note covers four follow-up questions: (1) formal
eval/rubric schemas and ontologies, (2) the design decisions in an eval suite,
(3) how to pick an eval design for a use case, and (4) published domain evals
analogous to HealthBench across six target verticals.

Provenance: researched via three adversarially-verified web sweeps (each claim
survived a 3-vote refutation panel against primary sources unless marked
otherwise) plus two single-pass extraction agents for the decision-framework
prescriptions (§3) and the long-tail domain benchmarks (parts of §4) — those
are single-sourced from the cited primary pages, not adversarially verified.

## Summary

Formal serialized eval schemas exist and converge on the same four-part
anatomy: (1) typed case data with gold references, (2) grader choice as an
enumerable typed dimension, (3) metric/aggregation config, and (4)
model-invocation config — kept separate so each varies independently. HELM is
the most fully factored (ScenarioSpec / AdapterSpec / MetricSpec); OpenAI's
Evals API is the purest expectations-as-data design (JSON-Schema-typed items +
typed grader objects with template references); promptfoo is the closest open
analogue to HealthBench-style weighted rubrics (per-assertion weight, per-case
threshold). No standard exists yet for eval *definition* interchange —
standardization efforts (Every Eval Ever, EvalCards, Eval Factsheets) operate
at the results-log and documentation layers only.

Across the domain sweep, the striking negative result is that **no published
vertical benchmark replicates HealthBench's per-case expert-written rubric
pattern**. The field instead uses four recurring grading archetypes —
programmatic environment-verified end-state (τ-bench style), fixed shared
rubric scored by an LLM judge with deterministic aggregation (SmartEval
style), classification/extraction with exact-match or span metrics (LegalBench
/ CUAD style), and checkpoint-graded hybrids mixing deterministic checkers
with rubric judges (TheAgentCompany style). Which archetype a vertical uses
follows almost mechanically from one property: whether the output is
mechanically verifiable. Where experts appear, it is overwhelmingly in
*authoring cases and ground truth* (CUAD's ~$2M of legal annotation,
TaxCalcBench's tax analysts), not in writing per-case grading rubrics —
HealthBench's pattern appears to be a response to medicine's combination of
open-ended outputs and high stakes, and is worth reaching for only under that
combination.

## 1. Eval schemas and ontologies

Six systems define documented, serialized (or serializable) schemas for eval
suites. What follows is what each schema factors out, since the factoring is
itself the design lesson.

### EleutherAI lm-eval-harness: YAML tasks, replication as a design goal

A YAML task config (`dataset_path`, `doc_to_text`, `doc_to_target`,
`num_fewshot`, `metric_list`, `output_type`, `filter_list`) plus a codebase
commit hash is explicitly intended to let another researcher "precisely
replicate the evaluation setup" ([task
guide](https://github.com/EleutherAI/lm-evaluation-harness/blob/main/docs/task_guide.md)).
Two schema facts matter:

- **Grading is programmatic only.** `output_type` is a closed enum —
  `generate_until`, `loglikelihood`, `loglikelihood_rolling`,
  `multiple_choice` — and the schema has no rubric or LLM-judge concept at
  all; judge grading is an open feature request (issues
  [#2233](https://github.com/EleutherAI/lm-evaluation-harness/issues/2233),
  [#1831](https://github.com/EleutherAI/lm-evaluation-harness/issues/1831)).
- **Metrics and aggregation are declarative and separate.** `metric_list`
  names multiple metrics (acc, acc_norm, perplexity, f1, bleu, chrf, ter)
  with auxiliary args; task groups have `aggregate_metric_list` with
  `weight_by_size` choosing micro vs macro averaging (MMLU's 57-subtask
  micro-average uses this).

So extraction (`output_type` + filters) and scoring (metrics + aggregation)
are independently configured dimensions even in the oldest mainstream schema.

### Inspect AI (UK AISI): a typed scorer ontology

Inspect's built-in scorers form a closed, typed menu spanning both grading
families: deterministic — `includes()`, `match()`, `pattern()`, `exact()`,
`answer()`, `f1()`, `choice()`, `math()`, `perplexity()` — and model-graded —
`model_graded_qa()` / `model_graded_fact()`, where a second model judges the
output against grading guidance, with configurable template, instructions,
`grade_pattern` regex, grader model (including majority vote across several
graders), and `partial_credit`
([scorers](https://inspect.aisi.org.uk/scorers.html),
[reference](https://inspect.aisi.org.uk/reference/inspect_ai.scorer.html)).
Nuance: scorers are declared in Python, not YAML — the config serializes into
Inspect's eval-log JSON, but the declaration is code. The lesson is the
ontology itself: grader choice is an enumerable design dimension, and
crucible's `Exactly`/`Predicate`/`Rubric` is already this shape, just with
fewer members.

### promptfoo: the closest open analogue to HealthBench weighting

promptfoo publishes a machine-readable JSON Schema for its whole suite config
([config-schema.json](https://promptfoo.dev/config-schema.json)). Top level
separates `providers` (systems under test), `prompts`, `tests`, `scenarios`
(var-sets × tests), and `defaultTest` (inherited per-case defaults). The
scoring mechanism is structurally HealthBench's weighted checklist:

- each assertion has a numeric `weight` (default 1);
- the test score is the **weighted average** of assertion scores;
- a per-test `threshold` fails the case if the combined score falls below it
  ([reference](https://www.promptfoo.dev/docs/configuration/reference/)).

Model-graded rubrics are first-class assertion types (`llm-rubric`,
`model-graded-*`), with the grader provider and the grading prompt
(`rubricPrompt`) overridable per-assertion, per-test, or suite-wide
([model-graded docs](https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/)).
This is the existing system closest to crucible's `Expectation`/`Score`/
`Verdict` design with weighting bolted on.

### OpenAI: legacy registry and the current Evals API

The legacy open-source framework (now maintenance-mode) separates suite
metadata from case data: a YAML registry entry binds an eval id to a grader
class (`class: evals.elsuite.basic.match:Match`), declared metrics, and a
`samples_jsonl` path; for the deterministic grader templates (Match, Includes,
FuzzyMatch) each JSONL sample must carry an `ideal` key with the reference
answer(s) ([build-eval
docs](https://github.com/openai/evals/blob/main/docs/build-eval.md)).

The current Evals API is the purest **expectations-as-data** schema. An eval
needs exactly two ingredients ([guide](https://developers.openai.com/api/docs/guides/evals),
[API reference](https://developers.openai.com/api/reference/resources/evals/methods/create)):

1. `data_source_config` — the `custom` variant carries an `item_schema` in
   standard JSON Schema typing each test case's fields, plus an
   `include_sample_schema` flag enabling `{{ sample.output_text }}`
   references;
2. `testing_criteria` — an array of typed grader objects (`string_check`,
   `text_similarity`, `label_model`, `score_model`, `python`), serialized as
   data, e.g. `{type: string_check, input: "{{ sample.output_text }}",
   operation: "eq", reference: "{{ item.correct_label }}"}` — templated
   references into both the model sample and the test item
   ([graders](https://developers.openai.com/api/docs/guides/graders)).

Even the `python` grader is a code string inside a typed JSON object.
`score_model` is the API-level home for HealthBench-style model-graded
rubrics.

### Stanford HELM: the most fully factored ontology

HELM separates ([code docs](https://crfm-helm.readthedocs.io/en/latest/code/)):

- **ScenarioSpec** — dataset/task: `Instance`s pairing an input with a set of
  `Reference` outputs (cases and gold references as first-class objects);
- **AdapterSpec** — prompting/model-invocation config (model, temperature,
  few-shot count), so the same scenario reruns under different settings
  without touching data or metrics;
- **MetricSpec** — grading/aggregation: a Metric consumes the run's state and
  emits named Stats, swappable per RunSpec;

plus a codebase-wide three-way taxonomy: user-authored **Specs**,
auto-generated serializable **States**, and non-serialized **Controller**
code, with a Runner driven by RunSpecs — complete runs reconstructible from
declarative spec objects. The AdapterSpec separation is the piece most
frameworks lack and the one crucible would feel first when sweeping models or
temperatures over a fixed suite.

### Standardization efforts: results and reporting, not definitions

- **Every Eval Ever** (EvalEval coalition — Hugging Face, EleutherAI, Univ.
  of Edinburgh, Stanford/HELM; launched Feb 2026): a shared metadata schema
  for evaluation **results** plus a crowdsourced eval database, with working
  converters from HELM, lm-eval-harness, and Inspect logs
  ([launch](https://evalevalai.com/infrastructure/2026/02/17/everyevalever-launch/),
  [repo](https://github.com/evaleval/every_eval_ever), eval.schema.json
  v0.2.2). Notably its `metric_config` makes score semantics explicit:
  `lower_is_better`, `score_type`, `min_score`, `max_score` — directly
  mirrorable in crucible's `Score`. Critical scope caveat: this standardizes
  result *logs* (one-way ingestion), not suite/case/rubric *definitions* —
  there is still no definition-interchange standard.
- **EvalCards** ([arXiv 2511.21695](https://arxiv.org/html/2511.21695), Nov
  2025): a short-form standardized reporting format analogous to Model Cards,
  with structured fields for modalities, languages, a capability-evaluation
  table and a *parallel safety-evaluation table* — capability-vs-safety as a
  first-class schema split.
- **Eval Factsheets** (FAIR at Meta,
  [arXiv 2512.04062](https://arxiv.org/html/2512.04062), Dec 2025): five
  orthogonal documentation dimensions (Context, Scope, Structure, Method,
  Alignment) operationalized as a 27-question questionnaire
  ([repo](https://github.com/facebookresearch/EvalFactsheets)). Its
  motivating gaps double as a design-decision checklist: hidden assumptions,
  non-comparable reporting, undocumented judge selection, contamination
  checks, statistical validation.

Both are months-old proposals, not adopted standards.

## 2. Design decisions in an eval suite

The convergent factoring above *is* the answer at the schema level: every
mature system independently decided that these are the separable decisions —

1. **Case data and gold references** — what a case is, what fields it has,
   what counts as reference truth (OpenAI `ideal`/`item_schema`, HELM
   `Instance`/`Reference`).
2. **Grader choice** — a closed typed enum, deterministic-first, model-graded
   where necessary (Inspect's scorer menu, OpenAI `testing_criteria`,
   lm-eval `output_type`). The companion note's deterministic-first hierarchy
   (`Exactly`/`Predicate` before `Rubric`) matches all of them.
3. **Metric and aggregation** — which numbers, and micro vs macro across
   groups (lm-eval `aggregate_metric_list.weight_by_size`); score semantics
   explicit (Every Eval Ever).
4. **Per-case scoring policy** — weights and thresholds (promptfoo `weight` +
   `threshold`, HealthBench weighted criteria), and weighted-sum vs
   multiplicative gating (§4d, τ²-bench's `reward_basis`).
5. **Model-invocation config** — isolated from data and grading (HELM
   AdapterSpec) so sweeps don't touch cases.
6. **Suite category and disclosure** — capability vs safety as parallel
   tables (EvalCards); judge selection, contamination handling, and
   statistical validation as documented metadata (Eval Factsheets).

Beyond the schema level, practitioner guidance (Anthropic's
[Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents),
single-sourced extraction) adds the suite-lifecycle decisions:

- **Capability vs regression is a property of the suite, with a lifecycle.**
  Capability evals "should start at a low pass rate… giving teams a hill to
  climb"; regression evals "should have a nearly 100% pass rate"; capability
  evals that reach high pass rates "graduate" into the regression suite, and
  a saturated suite means write harder tasks.
- **Sample size: start at 20–50, not hundreds.** "Teams delay building evals
  because they think they need hundreds of tasks. In reality, 20-50 simple
  tasks drawn from real failures is a great start" — early on effect sizes
  are large, so small n suffices. Source tasks from manual pre-release
  checks, the bug tracker, and the support queue.
- **A task is well-posed when two domain experts would independently reach
  the same pass/fail verdict.**
- **Each case should carry a reference solution** — it proves the task is
  solvable and doubles as a test of the graders themselves. Relatedly, "a 0%
  pass rate across many trials… is most often a signal of a broken task."
- **Reliability metrics for agentic suites:** pass@k (at least one of k
  trials passes) for tools where one success matters; pass^k (all k trials
  pass) where consistency matters. τ-bench introduced pass^k and showed
  GPT-4o falling from ~61% pass^1 to ~25% pass^8 on retail — averages hide
  consistency failure.
- **Isolation:** each trial starts from a clean environment, or infra noise
  correlates failures across cases.

Two domain-sweep findings (verified) reinforce specific decisions:

- **Withholding data against contamination is practiced, not just preached:**
  OpsEval releases only 20% of its questions and withholds 80% explicitly
  "preventing unfair evaluations due to data leakage"; ITBench-AA added 19
  newly-created held-out tasks alongside its 40 public ones.
- **n-gram reference metrics misalign with experts on open-ended vertical QA**
  (medium confidence, 2-1 vote): OpsEval's FAE-Score (a composite
  judge/keyword/evidence metric) correlates ~0.92 with expert assessment vs
  BLEU ~0.47 and ROUGE ~−0.45 (negative!) on Ops QA. The safe generalization:
  raw n-gram overlap misaligns; decomposed judge/keyword/rubric graders align
  better. Hamel's FAQ says the same thing bluntly: BERTScore/ROUGE/cosine
  similarity "are not useful for evaluating LLM outputs in most AI
  applications" outside retrieval similarity. Relevant to crucible's `Metric`
  graders: rougeL on open-ended domain answers is a smell.

### Grader failure modes are quantified (the ABC paper)

The strongest verified decision-framework source is the **Agentic Benchmark
Checklist** ([arXiv 2507.02825](https://arxiv.org/abs/2507.02825), Zhu et al.
2025): 40 checks across Task Validity (10), Outcome Validity (17, organized
into a 9-category grader taxonomy — whole-string matching, substring
matching, LLM-as-judge, unit testing, fuzz testing, end-to-end testing, state
modification, answer matching, quality measures), and Benchmark Reporting
(13), with documented failure modes per grader type. The quantified examples
are sobering and all verified:

- τ-bench's env-state grading lets a trivial **empty-response agent score
  38%** on airline (beating a GPT-4o agent) because impossible tasks count an
  unchanged DB as success; and an agent that dumps the whole database passes
  the ~2-4% of tasks whose ground truth is verbatim DB text under substring
  matching.
- SWE-bench Verified's insufficient unit tests make **24% of top-50
  leaderboard positions incorrect** (per UTBoost,
  [arXiv 2506.09289](https://arxiv.org/abs/2506.09289) — strictly, 24.4% of
  entries change rank).
- WebArena's unvalidated LLM judge overestimates by 1.4–5.2%; OSWorld's
  web-dependent evaluators silently broke (13/46 Chrome tasks), causing 28%
  absolute underestimation for one agent.

Implication: **no single grader type is safe**. Substring matching ignores
negation and rewards enumeration; env-state checks need impossible-task
guards and anti-dump checks; LLM judges need validation against human labels;
quality measures are metric-hackable. Layered, composite grading — which
crucible's `[Expectation]` per case already supports — is the published
mitigation.

## 3. Picking an eval design for a use case

No published flowchart maps use-case properties to eval designs; the
prescriptions below are extracted from the main practitioner sources
(single-sourced) and the verified benchmark sweep, then synthesized into a
decision procedure at the end.

### The published prescriptions

**Anthropic** (grader taxonomy: code-based / model-based / human): "choose
deterministic graders where possible, LLM graders where necessary or for
additional flexibility, and use human graders judiciously for additional
validation." Grade **what the agent produced, not the path it took** —
checking exact tool-call sequences "is too rigid and results in overly
brittle tests." Per use case: coding agents → deterministic test suites
first, rubric judges only for code-quality axes; conversational agents →
verifiable end-state outcomes plus rubrics for interaction quality (with a
second LLM simulating the user); research agents → groundedness + coverage +
source-quality checks; computer-use agents → sandboxed environment +
outcome check. Their worked example is explicitly multi-axis: "is the ticket
resolved (state check), did it finish in <10 turns (transcript constraint),
and was the tone appropriate (LLM rubric)?"

**Hamel Husain** ([evals FAQ](https://hamel.dev/blog/posts/evals-faq/)):
code-based assertions for objective, deterministic checks; LLM-as-judge only
for subjective qualities and "failures that persist after fixing your
prompts." Build expensive evaluators only for problems you'll iterate on
repeatedly. Don't write evaluators before features ("you can't anticipate
what will break") — error analysis first, evaluators for discovered errors,
60-80% of effort in error analysis. Judge validation needs ~100+ labeled
examples; a single domain-expert "benevolent dictator" labeler beats
committee labeling. Reference-based + deterministic for CI; reference-free
LLM-judge for production monitoring where gold answers don't exist.

**Eugene Yan** ([task-specific evals](https://eugeneyan.com/writing/evals/),
[LLM-evaluators](https://eugeneyan.com/writing/llm-evaluators/)): a task-type
→ method mapping — classification/extraction → recall/precision/ROC-AUC (and
check probability separation); summarization → binary factual-consistency via
an NLI model plus relevance, skip fluency ("1 in 10k" failures); translation
→ chrF/COMET (BLEU deprecated); copyright → longest-common-subsequence / edit
distance; toxicity → standard prompt sets + classifier. Evaluator-mode
mapping: **direct scoring** for objective checks (faithfulness, toxicity,
instruction-following); **pairwise comparison** only for subjective
preferences (tone, persuasiveness) — more stable there but not a regression
shape; **reference-based** when gold answers exist. Binary outputs preferred;
align the evaluator on ≥20 labeled examples before trusting it.

**Survey on Evaluation of LLM-based Agents**
([arXiv 2503.16416](https://arxiv.org/abs/2503.16416)) contributes the
agentic axes: final-response vs stepwise vs trajectory evaluation (trajectory
splits into reference-based — compare to a gold path — vs reference-free —
LLM judge over the trace); static/cached vs dynamic/live environments (static
is scalable but "fails to capture cascading effects of errors"); and metrics
by domain — "unit testing (SWE), state matching (conversational), answer
matching (reasoning)."

### Synthesized decision procedure

The benchmark sweep (§4) shows working systems follow what the guidance
preaches. As a procedure, ordered by the first question that applies:

1. **Is the output mechanically verifiable** (code that runs, a DB end-state,
   a form with numeric lines, an optimization objective)? → programmatic
   grading: `Predicate` over the executed outcome or end-state. Every
   verifiable vertical chose this (τ-bench, OSWorld, AppWorld, TaxCalcBench,
   ReX, LogiOR). Add ABC's guards: impossible-task handling, anti-gaming
   checks, a reference solution proving solvability.
2. **Can a structured answer be extracted, even from open-ended dialogue?**
   → extract-then-compare (CRMArena's pattern: an LLM *extracts* the final
   answer — extraction, not judging — then exact match on IDs or token F1).
   Keeps the judge out of the verdict path entirely.
3. **Is the output open-ended but the quality criteria enumerable?** →
   checklist rubric: fixed shared rubric if the criteria are stable across
   cases (SmartEval's five weighted dimensions, deterministically
   aggregated), per-case criteria when each case has its own requirements
   (HealthBench; τ²-bench's per-case `nl_assertions`). Judge per criterion,
   binary, weighted sum — the companion note's machinery.
4. **Open-ended, high-stakes, and criteria vary per case?** → that is the
   HealthBench niche: per-case expert-written weighted rubrics. Expensive
   (48.5k criteria from 262 physicians); reach for it only when 1–3 don't
   apply and errors are costly.
5. **Agentic/multi-turn?** → grade the outcome (env-state or extracted
   answer), not the trajectory; add transcript constraints (turn count,
   required communications) as separate expectations; judge-graded axes
   (tone, policy compliance) as diagnostic or secondary expectations; report
   pass^k if consistency matters.
6. **Cross-cutting:** risk level moves you toward more expensive grading
   (human calibration, juries, held-out cases); run frequency moves you
   toward cheaper grading (CI suites want deterministic checks; weekly deep
   reviews can afford judges); data availability decides reference-based
   (gold answers exist) vs reference-free (production monitoring).

## 4. Domain evals by vertical

Classification shorthand per benchmark: **env-state** (τ-bench style
programmatic end-state), **fixed rubric** (shared judge-scored rubric),
**classification** (exact-match/extraction/metric), **checkpoint** (per-case
point-valued milestones, mixed graders).

### (a) Blockchain / web3

The grading split follows verifiability exactly:

- **A1** ([arXiv 2507.05558](https://arxiv.org/abs/2507.05558)) — agentic
  smart-contract exploit generation; "all outputs are concretely validated
  through execution, ensuring only profitable proof-of-concept exploits are
  reported." Pure env-state; no judge anywhere.
- **ReX / Web3-AEG** ([arXiv 2508.01371](https://arxiv.org/html/2508.01371))
  — exploit generation over SmartBugs-Curated (56 synthetic contracts, 8
  vulnerability classes) and Web3-AEG (38 real incidents from audit reports
  and bug bounties, 7 chains). An exploit succeeds only if it compiles under
  Foundry and "deterministically violates at least one class-level safety
  invariant" in a local EVM. Env-state with *class-level* (not per-contract)
  invariants — a reusable-predicate-library design.
- **SmartEval** ([arXiv 2605.09610](https://arxiv.org/html/2605.09610v1),
  May 2026 preprint) — grades LLM-generated Solidity from NL specs (~9,000
  contracts) with a **fixed weighted five-dimension rubric**: Functional
  Completeness 25%, Variable Fidelity 15%, State Machine Correctness 15%,
  Business Logic Fidelity 35%, Code Quality 10%. Per-dimension scoring by an
  evidence-seeking LLM-judge agent; the composite is "deterministically
  recomputed from raw metric scores in post-processing rather than accepted
  from LLM-generated aggregates" — judge scores the parts, code does the
  arithmetic. Alongside programmatic stages (solc compilation, Slither).
  Closest published match to crucible's weighted-checklist plans; note the
  rubric is global, not per-case.
- **CryptoBench** ([arXiv 2512.00417](https://arxiv.org/abs/2512.00417),
  vendor-affiliated) — live benchmark, 50 questions/month written by
  crypto-native professionals, four-quadrant taxonomy (Simple/Complex ×
  Retrieval/Prediction). LLM-judge on a shared 0–3 scale against ground
  truth, ±5% tolerance on market-fluctuating numbers. Fixed rubric (shared
  scale, not per-case criteria); also a working example of a
  *continuously-refreshed* suite as a contamination defence.

### (b) MSP / IT support / PSA

No helpdesk/ticketing/PSA-workflow benchmark surfaced; the vertical's evals
all come from the SRE/AIOps side:

- **ITBench** (IBM, [arXiv 2502.05352](https://arxiv.org/abs/2502.05352),
  ICML 2025) — 94 real-world scenarios across SRE, CISO/compliance, and
  FinOps personas, deployed push-button into live Kubernetes environments;
  scored with interpretable programmatic metrics (resolution, accuracy,
  MTTR). Env-state; designed for community-contributed scenarios.
- **ITBench-AA** (Artificial Analysis + IBM,
  [blog](https://huggingface.co/blog/ibm-research/itbench-aa), May 2026) —
  59 SRE diagnosis tasks (40 public + 19 held-out); agents investigate an
  *offline snapshot* of an incident (logs, traces, metrics, topology) and
  submit structured JSON naming root-cause entities. Grading is recall-gated
  precision: "if a model misses any of the ground-truth root causes, it
  scores 0.0 for that repeat; if it identifies all of them, it is awarded its
  precision." Classification over structured output; all frontier models
  scored <50%.
- **AIOpsLab** (Microsoft,
  [arXiv 2501.06706](https://arxiv.org/abs/2501.06706)) — orchestrator
  deploys real microservice workloads, injects faults, exposes a standard
  agent-cloud interface (get_logs, get_metrics, exec_shell). Four task types;
  mitigation graded by end-state ("are all services up"), the rest against
  injected-fault ground truth; an LLM-judge trajectory review exists but only
  as an optional add-on. Env-state + classification.
- **OpsEval** (Tsinghua NetMan,
  [arXiv 2310.07637](https://arxiv.org/abs/2310.07637), FSE 2025) — static
  bilingual dataset, ~9,070 questions (≈7.2-7.3k multiple-choice + 1,736 open
  QA) over 8 task types and 3 ability levels. MC graded by regex extraction +
  accuracy; open QA by the composite FAE-Score (judge-scored fluency rubric,
  judge-mediated keyword F1 for accuracy, retrieval-grounded evidence). The
  80%-withheld split and the n-gram misalignment finding are in §2.

### (c) Legal / accounting / professional services

- **LegalBench** ([arXiv 2308.11462](https://arxiv.org/abs/2308.11462),
  NeurIPS 2023) — 162 tasks covering six types of legal reasoning,
  collaboratively constructed with legal professionals. The anchor for the
  classification archetype: expert effort goes into task authorship, grading
  is programmatic exact-match.
- **CUAD** ([arXiv 2103.06268](https://arxiv.org/abs/2103.06268),
  single-sourced) — contract review as extractive span prediction: 510
  contracts, 13,000+ expert annotations over 41 clause categories; law-student
  annotators trained 70–100 hours under 100+ pages of standards, each
  annotation verified by three more annotators (estimated value >$2M). Graded
  by AUPR and precision@80%/90%-recall over span overlap. The clearest
  example of where vertical expert money actually goes: into ground-truth
  construction, not per-case rubrics.
- **TaxCalcBench** (Column Tax,
  [arXiv 2507.16126](https://arxiv.org/abs/2507.16126), single-sourced) — 51
  hand-built TY24 federal returns (inputs as structured JSON, expected output
  as MeF XML), authored by tax-analyst experts and verified by a production
  tax engine. Graded line-by-line on Form 1040: strict exact-match and
  lenient (±$5) variants, plus per-line partial credit. Models pass <33% of
  returns strict — "single mistakes cascade throughout the rest of the
  lines." Classification/exact-match with tolerance; a model domain-eval
  shape for any computational professional service (accounting, payroll,
  quotes).
- **LegalAgentBench**
  ([arXiv 2412.17259](https://arxiv.org/abs/2412.17259), single-sourced) —
  300 Chinese legal-agent tasks (1–5-hop + writing) over 17 corpora and 37
  tools. Each case carries `key_answer` keywords (success rate = fraction
  present in the output) and `key_middle` keywords for intermediate steps
  (progress rate = checkpoint-style partial credit). Machine-generated then
  expert-verified. Keyword-checklist grading — per-case criteria, but
  programmatic, an interesting cheap middle ground between exact-match and a
  judge.
- No CPA/audit/accounting benchmark surfaced in any pass.

### (d) Enterprise / B2B SaaS

- **τ-bench** (Sierra, [arXiv 2406.12045](https://arxiv.org/abs/2406.12045))
  — the canonical env-state benchmark: multi-turn conversations between an
  LLM-simulated user and a tool-equipped agent under policy documents (retail
  + airline). Reward is binary and fully programmatic: final-DB-hash equals
  goal-state hash AND required outputs appear (substring) in the agent's
  messages. No judge. Introduced pass^k (§2).
- **τ²-bench** (Sierra, [arXiv 2506.07982](https://arxiv.org/abs/2506.07982))
  — dual-control telecom: both agent and a tool-using user simulator act on
  shared state (Dec-POMDP). Its per-task schema is the richest published
  example of **mixed grading in one case format** — `evaluation_criteria`
  holds four grader types: `actions` (reference tool-call trajectory replayed
  to derive the target DB state), `env_assertions` (programmatic checks on
  the post-simulation environment), `communicate_info` (substring checks on
  what the agent must say), and `nl_assertions` (natural-language assertions
  judged by an LLM, experimental). The final reward is the **product** of the
  components in `reward_basis` (default DB × COMMUNICATE) — a multiplicative
  all-or-nothing gate, with components outside the basis (including
  `nl_assertions`) computed only diagnostically. Also: 2,285 telecom tasks
  are *compositionally generated* from 15 atomic subtask groups (2-1 vote;
  telecom domain only), the opposite end of the authoring spectrum from
  HealthBench.
- **CRMArena / CRMArena-Pro** (Salesforce,
  [arXiv 2411.02305](https://arxiv.org/abs/2411.02305),
  [arXiv 2505.18878](https://arxiv.org/abs/2505.18878)) — CRM tasks inside a
  real sandboxed Salesforce org with synthetic data over 16 interconnected
  CRM objects. CRMArena: 9 task types × 130 instances = 1,170 queries; Pro:
  19 expert-validated tasks across sales/service/CPQ, B2B and B2C contexts,
  4,280 queries. Grading is **not** env-state: a GPT-4o extractor pulls the
  final answer from the dialogue, then exact match on object IDs (8 of 9
  tasks) or token-level F1 (knowledge QA). Pro layers a separate
  **confidentiality-awareness axis graded by a GPT-4o judge** (binary
  refusal/awareness classification) — a clean published example of
  deterministic task-grading and a judge-graded safety axis coexisting on
  different dimensions of the same eval.
- **AppWorld** ([arXiv 2407.18901](https://arxiv.org/abs/2407.18901), ACL
  2024 best resource paper) — 750 day-to-day digital tasks over 9 apps / 457
  APIs requiring rich interactive code; graded by **state-based unit tests**
  over the app ecosystem's DB — assert the specific deltas that should have
  happened, tolerate unrelated changes. A more surgical variant of τ-bench's
  whole-DB hash; env-state.
- **WorkArena** (ServiceNow,
  [arXiv 2403.07718](https://arxiv.org/abs/2403.07718), single-sourced) —
  knowledge-worker tasks on a live ServiceNow instance: L1 = 33 task
  templates × sampled configs (19,912 instances); WorkArena++ = 682
  compositional tasks. Each task ships a programmatic `validate()` function
  *and* an oracle `cheat()` function that proves solvability — the
  reference-solution discipline from §2, shipped as code. Env-state.

### (e) Logistics / infrastructure

The verified answer is mostly a gap: **no mature, dedicated
logistics-operations benchmark exists** (single-sourced gap-check; one survey
notes the supply-chain community lacks an SC-specific LLM benchmarking
environment). What exists at the edges (all single-sourced):

- **OptiGuide** (Microsoft,
  [arXiv 2307.03875](https://arxiv.org/abs/2307.03875)) — LLM answers
  what-if questions over a supply-chain optimizer by writing code; eval set
  of 5 scenarios × template-generated questions, graded by running the
  generated code and comparing the *optimization outcome* (not the code) to
  ground truth. Env-state-style outcome verification.
- **LogiOR / ORThought**
  ([arXiv 2508.14410](https://arxiv.org/abs/2508.14410)) — 92 logistics/SCM
  optimization problems with formulations, Gurobi reference implementations,
  and OR-expert-verified optima; success = matching the ground-truth optimal
  objective value. Classification-by-execution.
- **AIM-Bench** ([arXiv 2508.11416](https://arxiv.org/abs/2508.11416)) — 5
  inventory-management simulation environments (newsvendor, beer game, etc.)
  measuring decision *biases* (pull-to-centre, bullwhip) against analytic
  optima. Programmatic simulator metrics.
- **SupChain-Bench**
  ([arXiv 2602.07342](https://arxiv.org/abs/2602.07342)) — ~100 SOP-grounded
  tool-use tasks plus ~226 knowledge questions; tool traces parsed and graded
  by entity-level precision/recall across normal/cancellation/error flows.
  (Counts from the repo; paper body was unreadable.)
- **NL4Opt** ([arXiv 2303.08233](https://arxiv.org/abs/2303.08233)) — 1,101
  LP word problems (not logistics-specific), graded by NER F1 and
  declaration-level mapping accuracy.

For crucible users in this vertical, the practical implication: there is no
off-the-shelf suite to borrow; build from the archetypes — outcome-verified
optimization (OptiGuide/LogiOR pattern) where the task is computational,
ITBench-style scenario + ground-truth sets where it is operational.

### (f) Internal software tools / internal enterprise agents

- **TheAgentCompany** (CMU,
  [arXiv 2412.14161](https://arxiv.org/abs/2412.14161)) — 175 tasks in a
  simulated software company (SDE 69, PM 28, HR 29, finance 12, …) operated
  through GitLab, OwnCloud, Plane, and RocketChat, with LLM-simulated
  coworkers. The canonical **checkpoint** pattern: tasks decompose into
  point-valued checkpoints; S_full is binary (all checkpoints), S_partial =
  0.5·(points/total) + 0.5·S_full — proportional credit plus a completion
  bonus. Checkpoint evaluators are mostly deterministic Python, but complex
  deliverables use an LLM judge prompted "with predefined rubrics or
  reference outputs." The closest published analogue to crucible's
  weighted-checklist plans: a per-case checklist mixing Predicate checkpoints
  with Rubric checkpoints under one weighted score.
- **OSWorld** ([arXiv 2404.07972](https://arxiv.org/abs/2404.07972), NeurIPS
  2024) — 369 computer-use tasks over real web/desktop apps and OS file I/O.
  Each task ships scripted initial-state setup plus an execution-based
  evaluation script, drawn from a shared library of **134 evaluation
  functions** (getters retrieve post-execution VM state, compared
  programmatically); even the 30 deliberately infeasible tasks are graded
  programmatically (agent must answer FAIL). Env-state with a reusable
  predicate library — direct precedent for crucible shipping shared
  `Predicate` combinators rather than per-case bespoke graders. (OSWorld
  later shipped "OSWorld-Verified" fixing broken evaluators — see the ABC
  failure modes in §2.)
- **SpreadsheetBench**
  ([arXiv 2406.14991](https://arxiv.org/html/2406.14991v2), single-sourced)
  — 912 spreadsheet-manipulation instructions from real Excel forums (35.7%
  multi-table sheets), each with ~3 test instances: same structure, different
  data, including annotator-crafted corner cases, built by 20 Excel
  specialists. **Online-judge-style grading**: run the solution against every
  test instance, compare resulting workbooks cell-by-cell; soft restriction =
  proportional credit, hard restriction = all instances must pass. The
  multiple-instances-per-case idea is an anti-overfitting device crucible
  could express today as one case fanned out over variant inputs.

## 5. Grading archetypes (synthesis)

| Archetype | Exemplars | Grading | crucible mapping |
|---|---|---|---|
| Env-state / execution-verified | τ-bench, τ²-bench, OSWorld, AppWorld, WorkArena, ITBench, AIOpsLab, A1, ReX, OptiGuide, LogiOR | programmatic checks on end-state or executed outcome | `Predicate` over outcome; shared predicate library |
| Extract-then-compare | CRMArena/-Pro, ITBench-AA | LLM extracts structured answer; exact match / F1 / recall-gated precision | `Exactly`/`Predicate` on extracted answer |
| Classification / span metrics | LegalBench, CUAD, OpsEval (MC), NL4Opt, TaxCalcBench | exact match, tolerance match, AUPR, F1 | `Exactly`, `Predicate`, `Metric` |
| Keyword checklist | LegalAgentBench | per-case keyword lists, success + progress rates | `Predicate` per keyword; cheap per-case criteria |
| Fixed shared rubric, judge-scored | SmartEval, CryptoBench, OpsEval (FAE) | LLM judge per dimension, deterministic aggregation | `Checklist [Criterion]` (planned), global rubric |
| Checkpoint hybrid | TheAgentCompany | point-valued milestones, deterministic + judge evaluators, partial credit | weighted checklist mixing `Predicate` and `Rubric` items |
| Per-case expert rubric | HealthBench (only) | expert-written weighted criteria per case, judge-graded | `Checklist` with per-case criteria |

Cross-cutting observations:

- **Mixed grading within one case is normal at the frontier** (τ²-bench's
  four grader types per task; TheAgentCompany's deterministic + judge
  checkpoints; CRMArena-Pro's deterministic task axis + judge safety axis;
  Anthropic's resolved/turns/tone example). Heterogeneous `[Expectation]`
  per case is the right shape.
- **Two aggregation idioms coexist**: weighted sum with threshold
  (promptfoo, HealthBench, TheAgentCompany S_partial) and multiplicative
  gate (τ²-bench reward_basis — any failed gate zeroes the case). Gates are
  for must-hold constraints; weights for graded quality. τ²-bench also shows
  a third state: expectations computed but *excluded from the verdict*
  (diagnostic-only).
- **Experts author ground truth, machines grade.** CUAD, TaxCalcBench,
  SpreadsheetBench, LogiOR all spent expert effort on cases and references,
  then grade programmatically. Per-case expert *rubrics* (HealthBench)
  remain unique to medicine among everything verified here.

## Recommendations for crucible

Roughly ordered by value per line of code; items 1–3 overlap with the
companion note's plan and are reinforced, the rest are new from this sweep.

1. **Weighted checklist with per-case threshold.** Already planned
   (`Checklist [Criterion]`); promptfoo's exact mechanism (weight default 1,
   weighted-average score, case fails under threshold) is the proven shape.
   Add the threshold as part of the case, not the runner.
2. **Gates vs weights vs diagnostics.** From τ²-bench: let an expectation be
   marked as a *gate* (multiplicative — failing it zeroes the case
   regardless of weights; right for safety/format/`communicate_info`-style
   musts) or *diagnostic* (computed and reported, excluded from the
   verdict; right for experimental judge criteria). `passRate`'s all-pass
   semantics already gates everything; this makes the distinction explicit
   per expectation instead.
3. **Score semantics on `Score`/metrics.** Every Eval Ever's
   `lower_is_better`, `score_type`, `min_score`/`max_score` fields — small
   record additions that make reports and future interchange unambiguous.
4. **Serializable suite format (expectations as data).** The OpenAI Evals
   API pattern: a JSON/YAML case file with typed item fields and grader
   objects using templated references (`{{ item.x }}`, `{{ sample.y }}`)
   would let non-Haskell users author crucible suites. `Exactly`/`Rubric`/
   `Checklist`/`Metric` serialize naturally; `Predicate` is the
   deliberately-code member (even OpenAI's `python` grader is a string field
   in a typed object). HELM's lesson: keep model-invocation config
   (interpreter/model/temperature) a separate record from cases and graders
   so `testSkill` sweeps don't touch suite definitions.
5. **Document per-constructor failure modes (ABC).** A manual section
   mapping each Expectation to its known exploits: `Exactly`/substring —
   negation-blind, enumeration-gameable; `Predicate` over env-state —
   impossible-task and dump-the-database guards, ship a reference solution
   per case to prove solvability and test the grader; `Rubric`/judge —
   uncalibrated judges overestimate (WebArena +1.4–5.2%), validate against
   labels (companion note §5's `calibrate`). "A 0% pass rate usually means a
   broken case, not a bad model" belongs here too.
6. **Capability vs regression as suite metadata, with graduation.**
   A suite-level tag (capability | regression | safety, per EvalCards'
   split): capability suites expect low pass rates and are hills to climb;
   regression suites expect ~100% and gate CI; saturated capability cases
   graduate to regression. Cheap field, big reporting clarity.
7. **pass^k / repeat-trial aggregation.** For agentic or nondeterministic
   skills, n independent trials per case with pass^k ("all k pass") alongside
   passRate. Complements the companion note's `judgeN` (which votes the
   *judge*; this repeats the *skill*). τ-bench's 61%→25% pass^1→pass^8 drop
   is the motivating datum.
8. **Variant inputs per case (SpreadsheetBench's OJ idea).** One logical
   case fanned out over k input variants with the same expectations; soft
   (proportional) and hard (all-variants) scoring. Anti-overfitting for
   skills, expressible today by generating cases, but worth a helper.
9. **Manual: the decision procedure (§3) and the archetype table (§5).**
   The "which Expectation for which use case" question now has a defensible
   answer: verifiable → `Predicate`; extractable → extract-then-`Exactly`;
   enumerable quality → `Checklist` (shared rubric before per-case);
   per-case expert rubrics only for open-ended + high-stakes; agents →
   outcome expectations + transcript constraints + diagnostic judge axes.
   Domain pages can point at the exemplars per vertical from §4.

Not recommended: building toward any interchange "standard" (none exists for
definitions; Every Eval Ever is results-only); pairwise-comparison modes
(unchanged from the companion note — wrong shape for regression suites);
waiting for a logistics/PSA reference benchmark to copy (there isn't one —
that's a gap crucible users would fill themselves, and arguably an
opportunity).

## Open questions

- Does any vertical outside medicine adopt per-case expert rubrics as costs
  fall (LLM-drafted, expert-reviewed — the AutoChecklist path from the
  companion note), or does the expert-authors-ground-truth /
  machine-grades pattern stay dominant?
- Will Every Eval Ever (or MLCommons/NIST work) grow a *definition*-layer
  schema? Worth re-checking in 6 months before designing crucible's
  serialized suite format in a vacuum.
- The MSP/PSA gap specifically: nothing covers ticket triage, KB-grounded
  responses, or PSA workflows. ITBench-AA's structured-JSON +
  recall-gated-precision design is the nearest template for a homegrown
  ticket-triage eval.

## Sources

Verified sweeps (3-vote adversarial verification against primary sources):

- https://github.com/EleutherAI/lm-evaluation-harness/blob/main/docs/task_guide.md
- https://inspect.aisi.org.uk/scorers.html
- https://inspect.aisi.org.uk/reference/inspect_ai.scorer.html
- https://www.promptfoo.dev/docs/configuration/reference/
- https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/
- https://promptfoo.dev/config-schema.json
- https://github.com/openai/evals/blob/main/docs/build-eval.md
- https://developers.openai.com/api/docs/guides/evals
- https://developers.openai.com/api/docs/guides/graders
- https://crfm-helm.readthedocs.io/en/latest/code/
- https://evalevalai.com/infrastructure/2026/02/17/everyevalever-launch/
- https://github.com/evaleval/every_eval_ever
- https://arxiv.org/html/2511.21695 (EvalCards)
- https://arxiv.org/html/2512.04062 (Eval Factsheets, FAIR at Meta)
- https://arxiv.org/abs/2507.05558 (A1: smart-contract exploit agent)
- https://arxiv.org/html/2508.01371 (ReX / Web3-AEG)
- https://arxiv.org/html/2605.09610v1 (SmartEval)
- https://arxiv.org/abs/2512.00417 (CryptoBench)
- https://arxiv.org/abs/2502.05352 (ITBench, IBM)
- https://huggingface.co/blog/ibm-research/itbench-aa (ITBench-AA)
- https://arxiv.org/abs/2501.06706 (AIOpsLab, Microsoft)
- https://arxiv.org/abs/2310.07637 (OpsEval)
- https://arxiv.org/abs/2308.11462 (LegalBench)
- https://arxiv.org/abs/2406.12045 (τ-bench, Sierra)
- https://arxiv.org/abs/2506.07982 (τ²-bench)
- https://github.com/sierra-research/tau2-bench
- https://arxiv.org/abs/2411.02305 (CRMArena)
- https://arxiv.org/abs/2505.18878 (CRMArena-Pro)
- https://arxiv.org/abs/2407.18901 (AppWorld)
- https://arxiv.org/abs/2412.14161 (TheAgentCompany, CMU)
- https://arxiv.org/abs/2404.07972 (OSWorld)
- https://arxiv.org/abs/2507.02825 (Agentic Benchmark Checklist)
- https://arxiv.org/abs/2506.09289 (UTBoost)

Single-pass extractions (primary pages, not adversarially verified):

- https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- https://hamel.dev/blog/posts/evals-faq/
- https://eugeneyan.com/writing/evals/
- https://eugeneyan.com/writing/llm-evaluators/
- https://arxiv.org/abs/2503.16416 (Survey on Evaluation of LLM-based Agents)
- https://arxiv.org/abs/2507.16126 + https://github.com/column-tax/tax-calc-bench (TaxCalcBench)
- https://arxiv.org/abs/2103.06268 (CUAD)
- https://arxiv.org/abs/2412.17259 (LegalAgentBench)
- https://arxiv.org/abs/2403.07718 + https://github.com/ServiceNow/WorkArena (WorkArena)
- https://arxiv.org/html/2406.14991v2 (SpreadsheetBench)
- https://arxiv.org/abs/2307.03875 (OptiGuide, Microsoft)
- https://arxiv.org/abs/2508.14410 (LogiOR / ORThought)
- https://arxiv.org/abs/2508.11416 (AIM-Bench)
- https://arxiv.org/abs/2602.07342 (SupChain-Bench)
- https://arxiv.org/abs/2303.08233 (NL4Opt)
