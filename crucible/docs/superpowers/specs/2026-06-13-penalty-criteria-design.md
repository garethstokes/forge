# Penalty Criteria Design Spec

**Date:** 2026-06-13
**Status:** Approved design, pending implementation
**Tracker:** `crucible-nwa`.
**Research basis:** `docs/superpowers/research/2026-06-11-autorubric-review.md` item 5 (penalty criteria, autorubric's clamped formula).
**Scope:** `src/Crucible/Eval.hs` (`checklistScore`, `penalty` constructor, exports); `test/Spec.hs`; `docs/evals.md`.

## Motivation

A checklist can only reward content it expects. Some quality concerns are
the opposite: a failure mode you want to subtract for ("recommends a
specific product"). autorubric models these as negative-weight criteria.
crucible's `Criterion` already carries a `Double` weight, so the change is
the scoring formula plus an ergonomic constructor, not a type change.

## Decisions taken during design

- Adopt autorubric's formula exactly: numerator is the signed sum of
  passed-criterion weights, denominator is the sum of POSITIVE weights
  only, clamped to [0,1]. A perfect response scores 1.0 (penalties are
  not in the denominator); clamping stops penalties going below zero.
- The strict pass rule (every positive criterion holds AND no negative
  fires) needs no code change: `Checklist` already passes through the
  `passes _ v = v >= 1.0` arm, and value == 1.0 holds exactly under those
  two conditions.
- Add `penalty :: Double -> Text -> Criterion` taking a positive
  magnitude and negating it (with `abs` to absorb an already-negative
  argument). `criterion` stays the weight-1 positive helper.
- Penalty-aware rationale lines: `[penalty]` when a negative criterion
  fires, `[clear]` when it does not; positive criteria keep `[pass]` /
  `[fail]`.
- Hard gates stay their own `Checklist` case, never a large negative
  weight (clamping bottoms every penalty out at 0, so a gate expressed as
  a penalty cannot reliably fail the case).

## Design

### Formula (`checklistScore`)

Per-criterion judging is unchanged: every criterion (positive or
negative) is judged with the same "the output must satisfy: `<label>`"
call. For a penalty, the label names the BAD property, so a `true`
verdict means the penalty fired.

```haskell
posTotal = sum [c.weight | c <- cs, c.weight > 0]        -- positive weights only
got      = sum [c.weight | (c, passed, _) <- rs, passed] -- signed: fired penalties subtract
val      = max 0 (min 1 raw)
  where raw | posTotal > 0 = got / posTotal
            | otherwise    = if got < 0 then 0 else 1     -- no positive criteria
```

- A perfect response: every positive passes, no penalty fires, so
  `got == posTotal` and `val == 1.0` (exact: the same Doubles summed).
- A fired penalty subtracts its magnitude from `got`; clamping floors the
  result at 0.
- Degenerate `posTotal <= 0` (a penalty-only or all-zero checklist):
  `got < 0` (a penalty fired) scores 0, otherwise 1.0.
- The empty checklist keeps its short-circuit: `score 1.0 "empty
  checklist"`.

### Pass rule

No change. `Checklist` uses `passes _ v = v >= 1.0`. `val == 1.0` holds
iff every positive criterion passed (numerator reaches `posTotal`) and no
negative fired (nothing subtracted), which is autorubric's strict rule.

### Constructor (`Crucible.Eval`)

```haskell
-- | A penalty criterion: a failure mode to subtract for. Give a positive
-- magnitude; the weight is stored negative. The label names the BAD
-- property ("recommends a specific product"), so the judge fires the
-- penalty when that property is present.
penalty :: Double -> Text -> Criterion
penalty w label = Criterion label (negate (abs w))
```

Exported alongside `criterion`.

### Rationale lines

`checklistScore`'s line renderer becomes weight-aware:

- positive (`weight >= 0`): `[pass]` / `[fail]` as today.
- negative (`weight < 0`): `[penalty]` when the verdict is true (fired),
  `[clear]` when false.
- judge errors keep their `judge error:` tagged line.

## Manual (`docs/evals.md`)

In the checklist material: a criterion may carry a negative weight to
penalize a failure mode, built with `penalty`. State the formula in
words (positive weights set the denominator, penalties subtract, the
score clamps to [0,1], a clean response scores 1.0). Reinforce the
existing "When to split a rubric" hard-gate bullet: a gate stays its own
`Checklist` case, never a large negative weight, because clamping means a
big penalty and a small one both bottom out at 0 and a gate must fail the
case outright. House style: no emdashes, no hype, no manifest mentions.

## Testing (hermetic; scripted verdicts)

- Penalty subtracts and clamps: `[Criterion "helpful" 2 (pass),
  penalty 1 "recommends a product" (fired)]` scores 0.5; a `penalty 5`
  fired against `helpful 2` clamps to 0.0.
- Perfect with penalty present but not fired: `helpful 2 (pass)`,
  `penalty 3 (not fired)` scores 1.0 and the case passes (`passRate`
  1.0), proving penalties stay out of the denominator.
- Strict pass rule: a fired penalty alongside all-positive-passing drops
  the case below 1.0 (excluded from `passRate`); a cleared penalty keeps
  it at 1.0.
- Penalty-only checklist: one `penalty` not fired scores 1.0; fired
  scores 0.0.
- Rationale labels: a fired penalty line contains `[penalty]`, a cleared
  one `[clear]`, a positive criterion still shows `[pass]` / `[fail]`.
- `penalty` constructor: `penalty 2 "x"` builds `Criterion "x" (-2.0)`;
  `penalty (-2) "x"` also yields `-2.0` (the `abs` guard).
- The four existing checklist tests stay green unchanged (regression
  guard): all-positive weights reproduce 2/3, 1.0, 1.0, 0.5.

## Non-goals

- Changing the judge verdict mechanics: penalties reuse the same
  per-criterion call; only the aggregation and rendering change.
- Penalty scaling curves: linear subtraction only, per autorubric.
- Negative weights outside `Checklist`: `Metric`, `Scale`, `Grounded`,
  and the rest are unaffected.
- A distinct penalty report annotation beyond the `[penalty]` / `[clear]`
  line in the existing per-criterion rationale.
