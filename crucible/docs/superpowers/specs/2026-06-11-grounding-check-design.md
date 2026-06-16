# groundingCheck: Derived Claim Checklist Design Spec

**Date:** 2026-06-11
**Status:** Approved design, pending implementation
**Tracker:** `crucible-mo3`.
**Research basis:** `docs/superpowers/research/2026-06-11-reasoning-trap.md` (SFS, the open-system requirement, decomposer invariance) and `docs/superpowers/research/2026-06-11-evaluation-rubrics.md` (Checklist machinery, vote loop).
**Scope:** new `src/Crucible/Eval/Grounding.hs`, `src/Crucible/Eval.hs` (`Grounded` expectation + dispatch), `test/Spec.hs`, `docs/evals.md`, `app/Main.hs` (demo case).

## Motivation

Authored checklist criteria catch missing expected content; nothing catches
invented content. A skill that reasons over provided material can keep its
verdicts accurate while its stated facts drift from the evidence, and an
answer-level rubric never notices. The SFS recipe closes the gap: decompose
the output into atomic factual claims, verify each claim against the
provided evidence with a binary judge call, score = supported over total.
The paper de-risks the decomposition step: condition rankings were invariant
to the choice of decomposer (Spearman rho = 1.0).

## Decisions taken during design

- API shape: BOTH a standalone `groundingCheck` and a `Grounded Text`
  constructor on `Expectation` (evidence is per-case and known when the case
  is written); the constructor delegates to the function.
- Pass bar: strict. value = supported/total, so a `Grounded` case counts in
  `passRate` only when every claim is supported (any hallucinated claim
  fails the case), consistent with `Checklist`. No threshold variant now.
- Decomposer: hand-rolled in the Eval layer (one `complete`, tolerant decode
  against `list' str`, one schema-restating repair, then give up). The
  original choice to reuse `Skill.call` was reversed when it surfaced an
  import cycle (`Eval -> Grounding -> Skill -> Eval`); restructuring the
  layering or dropping the `Grounded` constructor were both judged worse
  than fifteen lines of local plumbing with the same repair semantics.
- Claim cap: prompt-guided soft cap (the decomposer instruction asks for at
  most 20 atomic claims, merging trivia); no hard truncation in code.

## Design

### 1. `Crucible.Eval.Grounding`

Imports: `Crucible.Eval.Judge (VoteOutcome (..), vote)`, `Crucible.Codec`
(`JSONCodec, list', str, schemaText`), `Crucible.Decode (decodeLLM,
DecodeError (..))`, `Crucible.LLM`. It does NOT import `Crucible.Skill` or
`Crucible.Eval` (the Score is built by the caller in `Eval`; see layering
below).

Layering note: to keep the module graph acyclic AND let `Eval.scoreN`
dispatch `Grounded`, the module exposes an outcome type rather than `Score`
(which lives in `Eval`):

```haskell
-- | The outcome of a grounding check, before Score conversion.
data GroundingOutcome
  = GroundingOutcome
      { supported :: Int
      , total     :: Int
      , lines'    :: [Text]   -- one "[supported]/[unsupported] <claim>: <why>" per claim
      }
  | NoClaims                  -- decompose returned []
  | DecomposeFailed Text      -- decode failure after one repair

groundingOutcome :: (LLM :> es)
                 => Int      -- votes per claim (odd; <=1 means one judge call)
                 -> Text     -- evidence
                 -> Text     -- rendered output
                 -> Eff es GroundingOutcome
```

`Crucible.Eval` converts to `Score` (section 2) and re-exports the
user-facing API, so users import everything from `Crucible.Eval`:

```haskell
groundingCheck :: (LLM :> es) => Int -> (o -> Text) -> Text -> o -> Eff es Score
```

**Stage 1: decompose.** One `complete` with:

- System: `Respond ONLY with JSON matching this schema:` + `schemaText
  (list' str)` (the same contract idiom as `Skill.prompt`).
- User: instruction + the rendered output:

  ```
  List the atomic factual claims made by the text below as a JSON array of
  strings. Atomic means one verifiable fact per claim. Each claim must be
  self-contained (no pronouns that depend on other claims). Merge trivial
  variations; list at most 20 claims. Output only the JSON array.

  Text:
  <rendered output>
  ```

Decode with `decodeLLM (list' str)`. On failure, repair once (append the
raw reply as Assistant plus a User message with the parse error and the
restated schema, the `call` idiom); a second failure yields
`DecomposeFailed e.message`. An empty array yields `NoClaims`.

**Stage 2: verify.** For each claim, in order, one `vote True n` call (early
stopping on, same as checklist criteria) with:

- rubric: `the claim is supported by the evidence`
- graded text (the judge's "output to grade"), carrying the ORIGINAL
  evidence verbatim plus the single claim:

  ```
  Evidence:
  <evidence>

  Claim:
  <claim>
  ```

A `Decided` outcome marks the claim supported/unsupported with its `why`;
an `AllErrored` outcome marks the claim unsupported with the line
`[unsupported] <claim>: judge error: <msg>`.

**No-closed-loop compliance** (documented in the module haddock and the
manual): every verification call receives the original evidence verbatim;
the claim is the SUBJECT of the judgement, not a derived substitute for the
evidence. Decomposition quality is the metric's own degree of freedom, and
rankings are empirically invariant to the decomposer choice.

### 2. `Crucible.Eval` integration

```haskell
data Expectation a
  = Exactly a
  | Predicate (a -> Bool)
  | Rubric Text
  | Checklist [Criterion]
  | Grounded Text             -- new: evidence the output must be grounded in
```

`scoreN n render exp_ actual` gains:

```haskell
  Grounded ev -> groundingScore <$> groundingOutcome n ev (render actual)
```

with the conversion:

- `GroundingOutcome s t ls` -> `score (fromIntegral s / fromIntegral t)
  (T.intercalate "\n" ls)`. value reaches 1.0 only when s == t, so the
  strict pass bar falls out of the existing `passRate >= 1.0` rule.
- `NoClaims` -> `score 1.0 "no factual claims"` (vacuous truth, mirrors the
  empty checklist; consumes no verification calls).
- `DecomposeFailed m` -> `score 0.0 ("judge error: claim decomposition
  failed: " <> m)`. Reusing the `judge error: ` tag means `renderReport`'s
  `[judge error]` flag and downstream tooling work unchanged.

`groundingCheck n render ev o = groundingScore <$> groundingOutcome n ev
(render o)` is defined and exported from `Crucible.Eval` (alongside a
re-export of nothing else from Grounding; `GroundingOutcome` stays
internal-ish, exported from its own module for tests).

`Score.votes` and `Score.dissent` remain `Nothing` for grounding scores:
per-claim tallies do not aggregate into one pair. Per-claim uncertainty
surfacing is future work.

Edge semantics, fixed:

- Empty evidence is NOT special-cased: every factual claim is then
  unsupported by definition (the judge sees empty evidence). Documented.
- Claims are verified in decomposition order; rationale lines preserve it.
- `runEvalN n` threads its n into claim verification exactly as it does for
  `Checklist` criteria; `runEval`/`testSkill` use n = 1.

## Manual: `docs/evals.md`

A `### Derived claims: groundingCheck` subsection inside (or directly after)
"Grounding criteria for context-receiving skills":

- Authored criteria catch MISSING expected content; derived claims catch
  INVENTED content. They complement each other; use both for
  context-receiving skills.
- The two-stage pipeline, the `Grounded` expectation, and the standalone
  signature.
- Cost note: one decompose call (two if repaired) plus claims x votes judge
  calls; the decomposer is asked for at most 20 atomic claims.
- Strict pass semantics: one unsupported claim fails the case; the
  fractional value feeds `meanScore` as the diagnostic.
- The no-closed-loop justification paragraph (evidence re-injected verbatim
  into every verification call).
- At-a-glance checklist: extend rule 6's grounding entry with a pointer to
  derived claims (no renumbering).

House style: no emdashes, no hype, no manifest mentions.

## Demo (`app/Main.hs`)

The existing eval section gains one `Grounded` case over the fixed weather
sentence, e.g.:

```haskell
, Case "It is 26C and sunny in Brisbane." "grounded-weather"
    (Grounded "Brisbane forecast: sunny, 26 degrees, light winds.")
```

Expected live: decompose finds 2-3 claims, all supported, case scores 1.0.

## Testing (hermetic via runLLMScripted)

- Happy path: scripted decompose reply `["the temperature is 26C","the city
  is Brisbane"]` plus two supporting verdicts -> value 1.0, both
  `[supported]` lines in order.
- One unsupported claim: second verdict fails -> value 0.5, the
  `[unsupported]` line names the claim and carries the judge's why.
- Empty array: `[]` -> 1.0, rationale "no factual claims"; a leftover-reply
  check proves zero verification calls were made.
- Decompose failure: junk then junk -> value 0.0, rationale prefixed
  `judge error: claim decomposition failed:`; renderReport shows
  `[judge error]`.
- Decompose repair: junk then a valid array then verdicts -> works (repair
  consumed one extra reply).
- Claim verification all-errors: decompose ok, then 2x junk for the claim's
  single vote -> claim counts unsupported with the tagged line; value
  reflects it.
- `runEvalN 3` over a `Grounded` case: votes thread (call counting: a
  unanimous claim consumes 2 verdicts).
- `Grounded` end-to-end through `runEval` with `pure` as the SUT.
- Live smoke via the demo before merge.

## Non-goals

- Threshold pass variant (`GroundedAtLeast`); revisit if real suites need it.
- Hard claim-count truncation in code.
- Per-claim vote tallies / uncertainty surfacing on the aggregate Score.
- Weighted claims (all claims weigh equally; weights are an authored-rubric
  concept).
- Reusing `Skill.call` for the decomposer (import cycle; see Decisions).
