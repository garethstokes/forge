# The Reasoning Trap: implications for crucible's judge machinery (research notes)

Date: 2026-06-11. In-repo notes on "The Reasoning Trap: An
Information-Theoretic Bound on Closed-System Multi-Step LLM Reasoning"
([arXiv 2605.01704](https://arxiv.org/abs/2605.01704), May 2026, v2, under
review). Companion to `2026-06-11-evaluation-rubrics.md`; intersects its §5
(vote margin) and recommendations 3-4 (judgeN, judge prompt hardening).
Not published.

## Summary

The paper proves and measures a failure mode in iterated LLM reasoning:
in any *closed* reasoning system — evidence shown once, every later step
derived only from the previous step — the connection between the evidence
and the output can only decay as steps accumulate (a Data Processing
Inequality bound). The multi-agent version is the **Debate Trap**: models
debating each other keep the answer accurate while the reasoning quietly
detaches from the evidence (88% accuracy retained, 43% faithfulness lost;
majority-vote debate collapsed faithfulness to 1.7% of baseline). The fix is
structural, not behavioural: re-inject the evidence at every step
(their EGSR protocol recovers 98% of baseline faithfulness). A side-study
found human raters of reasoning faithfulness agree at chance level
(Fleiss kappa <= 0.018), so "calibrate the faithfulness metric against
humans" is itself unreliable.

For crucible: our independent-vote jury design is *not* a debate and
escapes the trap; the actionable consequences are a design rule (no
closed-loop judge protocols), an honesty fix (majority-side rationale is
not an explanation), and a rubric ingredient (grounding criteria for
reasoning-heavy skills, because accuracy-only evals hide this failure).

## The paper in detail

### The Reasoning Trap (general form)

A reasoning system is **closed** when four conditions hold: shared model
parameters across all steps; evidence E provided only at t=0 and never
re-injected; each step depending only on the previous step plus parameters;
symmetric aggregation across agents. Under these conditions the process is
a Markov chain E -> O_0 -> O_1 -> ... -> O_T, and the Data Processing
Inequality gives E[I(E; O_{t+1})] <= E[I(E; O_t)]: mutual information
between evidence and output is non-increasing. Iteration can redistribute
and compress information already present; it cannot create grounding.

This covers standard multi-agent debate, long single-agent chain-of-thought,
Reflexion-style self-critique, and linear tree-of-thought. Longer chains
sharpen rather than escape the bound: the only information about E available
at step T is what survived every intermediate transformation.

### The Debate Trap (multi-agent instantiation)

Across 16 conditions on SciFact (300 claims) and FEVER (1,000 claims),
measured with their faithfulness metric (SFS, below):

- Reasoning degradation: SocraSynth-style debate, -39% faithfulness.
- The trap proper: DebateCV-style debate, 88% accuracy retained while
  faithfulness drops 43% — the answer survives, the reasoning detaches.
- Reasoning elimination: majority-vote multi-agent debate, faithfulness
  collapses to 1.7% of baseline (p < 1e-6, Cohen's d = -0.96).

Mechanism: identical models debating produce diverse *rewordings of shared
biases*, not diverse perspectives — DeGroot's 1974 consensus result (iterated
averaging among informationally isolated agents converges to their initial
weighted opinions, not to external truth) replayed with LLMs. Heterogeneous
model families slow the erosion but do not stop it while the system stays
closed. Prior debate literature measured only accuracy, which is exactly the
quantity the trap preserves.

### SFS: Supported Faithfulness Score

Decompose a rationale into atomic claims (LLM decomposer), verify each claim
against the provided evidence, score = supported claims / total claims.
Condition-level rankings were invariant to the choice of decomposer
(Spearman rho = 1.0). Deliberately *not* calibrated against human judgement,
because of the R6 finding below.

### EGSR: the open-system fix

Evidence-Grounded Socratic Reasoning replaces adversarial argumentation with
structured inquiry where the evidence is re-injected at every round and a
running verdict accumulates claims verified directly against E. This breaks
the closed-system condition; their Theorem 2 shows faithfulness becomes a
sub-martingale (can recover) instead of monotone-decreasing. Empirically EGSR
recovers 98% of no-debate baseline faithfulness at comparable accuracy. The
fix is structural (what the protocol can see), not behavioural (how the
agents are prompted to argue).

### R6: triple failure of human reliability

Cross-language, cross-domain human evaluation of reasoning faithfulness
(10 Korean raters x 30 FEVER items; 3 English raters x 200 SciFact items;
2 raters in both):

1. Inter-rater agreement at chance level (Fleiss kappa <= +0.018).
2. The same raters drifted 0.8-1.4 Likert points on identical items across
   language/domain context.
3. Therefore the "human gold standard" usually used to calibrate
   faithfulness metrics is itself unstable for this kind of judgement.

Scope note: this is about humans rating *reasoning faithfulness on Likert
scales* — not about binary task-level pass/fail labels, where the
evaluation-rubrics notes already require measured inter-annotator agreement
before trusting labels.

## What transfers to crucible

### Validated, no change needed

- **A jury is not a debate.** PoLL-style juries (independent judges, single
  calls, evidence in context, one vote each) have no iterated chain — the
  DPI bound does not apply. The trap bites only when judges *transform each
  other's outputs*. Our judgeN and jury recommendations survive intact.
- **Binary criteria over Likert, reinforced.** The human-reliability failure
  was on Likert ratings of a vague quality — the instrument the rubrics
  notes already reject. Same lesson from a new direction.
- **Quote-grounding in the judge prompt** (rubrics rec 4) is a lightweight
  SFS: forcing the judge to cite the span that satisfies or violates each
  criterion keeps the rationale tethered to the artifact.

### Design rule: no closed-loop judging

Any future multi-step judge protocol (judge critiques judge, judges iterate
to consensus, self-refining verdicts) must re-inject the original output and
rubric verbatim at every step. Summaries or quotations of the artifact by a
previous step do not count — that is the closed system. If a protocol cannot
re-inject the originals, prefer one-shot independent judges plus a vote.

### Honesty fix: the majority-side rationale is not an explanation

The trap's core paradox — verdict survives, reasoning detaches — means a
rationale attached to a vote outcome is not necessarily why the votes went
that way. judgeN keeping the `why` from the majority side is fine for
reporting, but it should be labelled as a sample ("majority-side rationale"),
and calibration review should not treat it as causal.

### Rubric ingredient: grounding criteria for reasoning-heavy skills

Accuracy-only evals hide the trap (88% accuracy / -43% faithfulness). For
skills that produce multi-step reasoning over provided context, checklists
should include explicit grounding criteria ("each factual claim is supported
by the provided context", "quotes the source for X") rather than judging
final-answer correctness alone.

### Future feature: SFS as a derived Checklist

SFS composes out of machinery already in the rubrics notes: decompose the
output's claims (auto-derived checklist, rubrics §5) + verify each claim
against provided evidence with per-criterion binary judge calls (Checklist).
A `groundingCheck :: evidence -> output -> Eff es Score` is a natural later
addition once Checklist exists.

## Caveats

- One month old, v2, under review; bold claims, single empirical domain.
- Empirical base is fact verification (SciFact/FEVER) where grounding is
  crisply measurable; the theorem is general but effect sizes may not
  transfer to open-ended generation.
- Accuracy-vs-faithfulness cuts both ways for evals: a pure regression gate
  cares about verdict accuracy, which the trap preserves; faithfulness
  matters for diagnostics, calibration review, and trusting the `why`.

## Team discussion points

1. Adopt "no closed-loop judging" as a hard design rule?
   **Decision (2026-06-11): adopted as a hard rule.** Every LLM call in a
   judge protocol must receive the original output and rubric verbatim;
   protocols that can't re-inject use independent one-shot judges plus a
   mechanical vote. To be documented in the evals manual.
2. Label judgeN's rationale as "majority-side rationale" in renderReport?
   **Decision (2026-06-11): yes.** renderReport shows the vote tally
   (`pass 2/3`, same line of code as the §5 uncertainty flag), labels the
   rationale "majority-side rationale (1 of 2)", and keeps dissenting
   rationales in verbose output — dissent is the most useful artifact on
   contested cases. n=1 rationales keep their causal framing (CoT-first
   verdict is conditioned on them); only aggregated rationales get the
   sample label.
3. Grounding criteria as a standard rubric ingredient now, SFS-style derived
   checklist as a roadmap item?
   **Decision (2026-06-11): both.** (a) Manual guidance now: skills that
   receive context get grounding criteria in their rubric ("every claim
   supported by provided context", "quotes the source span", negative form
   "no facts absent from context"); skills without context skip them.
   (b) `groundingCheck` (decompose output into atomic claims, verify each
   against evidence, score = supported/total) as a roadmap item blocked on
   Checklist. Decomposer choice is low-risk (paper: rankings invariant,
   rho = 1.0); open design questions are claim granularity, all-claims-pass
   default, and constructor-vs-function shape.
4. Any planned Likert-style "rate the reasoning" human labels to kill?
   (Calibration should stay binary and task-level.)
   **Decision (2026-06-11): confirmed, nothing to kill.** Human calibration
   labels are binary and task-level only — `calibrate`'s `Bool` label is a
   design commitment, not a shortcut; resist widening it to a score. Human
   critique text is qualitative context (few-shot examples for the judge
   prompt), never a numeric calibration target. If human signal on
   reasoning quality is ever needed, decompose it into observable binary
   proxies ("is the cited span present in the context?") rather than
   Likert-rating "faithfulness". One guardrail line to be added to the
   calibrate documentation.

## Sources

- https://arxiv.org/abs/2605.01704 (The Reasoning Trap, May 2026)
- https://arxiv.org/html/2605.01704v2 (full text)
- ../2026-06-11-evaluation-rubrics.md (companion notes: judgeN, juries,
  vote margin, quote-grounding, calibration workflow)
