# Scalar Metrics and Ordinal Scales Design Spec

**Date:** 2026-06-12
**Status:** Approved design, pending implementation
**Tracker:** `crucible-2zw`.
**Research basis:** Anthropic develop-tests guidance (platform.claude.com/docs/en/test-and-evaluate/develop-tests): quantitative metrics (F1, ROUGE-L) and qualitative scales (anchored Likert/ordinal, LLM-graded).
**Scope:** `src/Crucible/Eval.hs`, `src/Crucible/Eval/Judge.hs`, new `src/Crucible/Eval/Metrics.hs`, `test/Spec.hs`, `app/Main.hs` (one live scale proof), `docs/evals.md`.

## Motivation

The Eval stack grades pass/fail: `Exactly`, `Predicate`, `Rubric`,
`Checklist`, `Grounded` all resolve to a Score whose pass condition is
value >= 1.0. Two grading shapes from standard eval practice are missing:

- Code-graded scalar metrics (token F1, ROUGE-L) where the DEGREE of match
  is the signal. Today a user must threshold inside a `Predicate`, which
  throws away the scalar; mean ROUGE cannot be watched across iterations.
- LLM-graded ordinal scales (anchored 1-to-5 ratings) for subjective
  dimensions like tone. Voting on a binary `Rubric` measures judge
  disagreement about pass/fail, not degree of quality.

Embeddings and cosine-similarity evals are explicitly out of scope
(tracked as `crucible-d4w`, blocked on this work).

## Decisions taken during design

- Pass thresholds live IN the expectation (`Metric 0.85 ...`,
  `Scale 4 ...`), mirroring how success criteria are stated ("F1 of at
  least 0.85"). No global threshold knob; no mean-only scoring.
- Shipped metrics: `normMatch`, `tokenF1`, `rougeL`. No BLEU (corpus-level
  by design, misleading per case).
- Scale anchors are a structured list `[(Int, Text)]`; sparse anchoring is
  allowed (ends-only is fine). Level count k = maximum anchor level.
- Multi-vote scale aggregation: median level, ties round down; `votes`
  records (agreeing-with-median, rest); `dissent` populated when the
  sample spread exceeds one level.

## Design

### 1. Expectation constructors (`Crucible.Eval`)

```haskell
| Metric Double (a -> Double)     -- ^ pass threshold, scalar metric in [0,1]
| Scale Int Text [(Int, Text)]    -- ^ pass level, rubric, anchored levels
```

Usage reads: `Metric 0.85 (rougeL refSummary . render)` and
`Scale 4 "Rate how empathetic this response is"
[(1, "dismissive"), (5, "fully acknowledges the customer's frustration")]`.

`scoreWith` dispatch:

- `Metric t f`: pure. `value = clamp [0,1] (f actual)` (defensive clamp;
  the shipped metrics already land in range), rationale
  `"metric = <value>"`. No LLM call.
- `Scale p rubric anchors`: delegates to a new `rate` in
  `Crucible.Eval.Judge` (below). Takes `opts.votes`; IGNORES
  `opts.examples` this cycle, like `Checklist` and `Grounded`
  (ordinal few-shot needs a level field on `JudgeExample`; follow-on).

### 2. Pass rule (`Crucible.Eval`)

No changes to `Score` or `Result`. `runEvalWith` gains a pure helper:

```haskell
passes :: Expectation a -> Double -> Bool
passes (Metric t _) v        = v >= t
passes (Scale p _ anchors) v = v >= passValue   -- (p - 1) / (k - 1)
passes _ v                   = v >= 1.0
```

where `k = maximum (map fst anchors)`. `passRate` counts cases via
`passes`; `meanScore` is unchanged (the scalar IS the value).
Degenerate guard: `k <= 1` (empty or single-anchor list) makes the case a
judge error at scoring time, never a division by zero.

### 3. Ordinal judging (`Crucible.Eval.Judge`)

New `rate`: prompt renders the rubric, the anchor lines in ascending
order (`"1: dismissive"`), the inclusive level range, and asks for
reasoning first then a single level, following the existing judge prompt
idiom (machine line, input delimiters, trailing reminder). Parsing
accepts a bare integer in 1..k; out-of-range or unparseable replies take
the existing retry-then-judge-error path.

With n votes: all n samples are taken (no early stop; the median needs
the full sample), median level wins with ties rounding DOWN
(conservative), `votes = (count at median, n - count at median)`,
`dissent` carries a rationale from a sample more than one level from the
median when one exists. `value = (median - 1) / (k - 1)`; the rationale
states the level explicitly ("level 4 of 5: ...").

### 4. `Crucible.Eval.Metrics` (new pure leaf module)

All `Text -> Text -> Double`, reference first so partial application
composes with `Metric`:

- `normMatch ref out`: 1.0 when equal after case-folding and whitespace
  normalization, else 0.0.
- `tokenF1 ref out`: SQuAD-style token-multiset F1 (whitespace tokenize,
  case-fold; harmonic mean of precision and recall; both-empty = 1.0,
  one-empty = 0.0).
- `rougeL ref out`: LCS over tokens, F-measure as the harmonic mean of
  LCS precision (against candidate length) and recall (against reference
  length); empty cases as in `tokenF1`.

No dependencies beyond text and base.

## Demo (`app/Main.hs`)

One live proof in the Anthropic section: rate a canned friendly reply on
a 1-to-5 politeness scale via a `Scale` expectation (or `rate` directly),
printing `scale: level N of 5`. Cost: one judge call. Proves prompt
rendering, level parsing, and normalization against a real model.

## Manual (`docs/evals.md`)

A "Scalar metrics and ordinal scales" section: when to choose `Metric`
vs `Rubric` vs `Scale` (code-graded where rules suffice, scalar where
degree matters, anchored scales where quality is subjective); the three
shipped metrics with one-line definitions; anchoring advice (anchor at
least the ends; the judge sees anchors structurally, not as prose); pass
threshold semantics (`Metric 0.85`, `Scale 4`); the limits (scales ignore
few-shot examples; calibration stays binary until weighted kappa lands).
House style: no emdashes, no hype, no manifest mentions.

## Testing (hermetic; pure plus scripted judge)

- Metrics, hand-derived: `normMatch` hit (case/whitespace variance) and
  miss; `tokenF1` on a hand-computed overlap (e.g. precision 2/3, recall
  1/2, F1 4/7); `rougeL` with a known LCS; empty-text degenerates pinned;
  `tokenF1 a a == 1.0`.
- Metric expectation: `runEval` with `Metric 0.5` cases above and below
  threshold; `meanScore` carries the scalars; `passRate` counts only the
  above-threshold case; `>=` boundary (exactly at threshold passes).
- Scale, scripted judge replies: single vote level 4 of 5 gives value
  0.75 and "level 4 of 5" in the rationale; 3-vote (3, 4, 4) takes
  median 4 with votes (2, 1); spread > 1 level populates dissent;
  out-of-range reply follows the judge-error path; `Scale 4` passes at
  median 4 and fails at median 3.
- Pass-rule integration: one mixed dataset (an `Exactly` pass, a
  borderline `Metric` pass, a `Scale` fail) pinning `passRate` exactly.
- Live: the demo scale line before merge.

## Non-goals

- Embeddings / cosine-similarity evals (`crucible-d4w`): crucible has no
  embedding capability at all, so this needs its own design cycle for an
  Embed effect and provider endpoints rather than riding along here.
- BLEU: it is a corpus-level statistic whose per-case values are noisy
  and misleading, and per-case scoring is exactly how `Metric` is used.
- Weighted-kappa calibration for ordinal scales: binary kappa would
  punish a judge that rates 4 where the human rated 5 as a full
  disagreement, so doing it properly means weighted kappa plus an ordinal
  labelling workflow, which is a calibration cycle of its own.
- Ordinal few-shot examples (level field on `JudgeExample`): the example
  machinery is built around a Bool pass field shared by rendering,
  balancing, and calibration, and extending all three for levels is not
  worth it before anchored scales prove they need the help.
- Global or per-report pass thresholds: one knob across a dataset is
  wrong whenever cases have different acceptable floors, and the
  in-expectation threshold already covers every case individually.
