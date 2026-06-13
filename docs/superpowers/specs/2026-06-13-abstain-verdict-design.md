# Abstain Verdict Design Spec

**Date:** 2026-06-13
**Status:** Approved design, pending implementation
**Tracker:** `crucible-0xl`.
**Research basis:** `docs/superpowers/research/2026-06-11-autorubric-review.md` item 3 (CANNOT_ASSESS + resolution policy).
**Scope:** `src/Crucible/Codec.hs` (optional-field combinator); `src/Crucible/Eval/Judge.hs` (verdict kind, codec, prompt, vote); `src/Crucible/Eval.hs` (policy on JudgeOpts, score consumption, rendering); `src/Crucible/Eval/Grounding.hs` (handle the new outcome); `src/Crucible/Eval/Calibrate.hs` (count abstentions); `test/Spec.hs`; `app/Main.hs`; `docs/evals.md`.

## Motivation

A judge that cannot tell is forced to guess, and the guess is
indistinguishable from a considered verdict. A three-way verdict (Pass,
Fail, CannotAssess) plus an explicit resolution policy lets the judge
abstain honestly, and the abstention is rendered and counted distinctly
from a judge error.

## Decisions taken during design

- Verdict becomes `Verdict { why, kind }` with `kind :: VerdictKind = Pass
  | Fail | CannotAssess`. The codec still parses legacy `{"why","pass"}`.
- `AbstainPolicy = AbstainFails | AbstainSkips`, on `JudgeOpts`, default
  `AbstainFails`. Consumed only by `checklistScore`.
- An abstain consumes a vote attempt without casting yes/no, exactly like a
  judge error but labelled honestly. `VoteOutcome` gains `AllAbstained`.
- Standalone Rubric (and Scale) all-abstain scores 0 with a `judge
  abstained:` rationale regardless of policy (nothing to skip without a
  denominator). [Q3]
- Under `AbstainFails`, CannotAssess maps to the Fail verdict uniformly: a
  positive criterion is not met (stays in the denominator); a penalty's
  Fail is the bad property absent, so the penalty clears. [Q4]
- Rendering: a `[judge abstained]` annotation distinct from `[judge
  error]`. Calibration lists abstained cases separately and excludes them
  from agreement/kappa.

## Design

### 1. Optional-field combinator (`Crucible.Codec`)

```haskell
-- | An optional object field (crucible's old optional field), on autodocodec.
optField :: Text -> (o -> Maybe f) -> JSONCodec f -> ObjectCodec o (Maybe f)
optField k getter c = optionalFieldWith' k c .= getter
```

Exported alongside `field`.

### 2. Verdict kind, codec, prompt (`Crucible.Eval.Judge`)

```haskell
data VerdictKind = Pass | Fail | CannotAssess  deriving (Eq, Show)
data Verdict     = Verdict { why :: Text, kind :: VerdictKind }  deriving (Eq, Show)
```

Codec is decode-tolerant via an intermediate that carries both shapes:

```haskell
data RawVerdict = RawVerdict
  { why     :: Text
  , verdict :: Maybe VerdictKind   -- new shape
  , pass    :: Maybe Bool          -- legacy shape
  }

kindCodec :: JSONCodec VerdictKind
kindCodec = enum [("pass", Pass), ("fail", Fail), ("cannot_assess", CannotAssess)]

rawVerdictCodec :: JSONCodec RawVerdict
rawVerdictCodec = object (RawVerdict <$> field    "why"     (.why)     str
                                     <*> optField "verdict" (.verdict) kindCodec
                                     <*> optField "pass"    (.pass)    bool)

verdictCodec :: JSONCodec Verdict      -- decode-only in practice
-- decode: resolve verdict first, else pass (True->Pass, False->Fail); both
-- absent -> a decode failure, which drives the existing repair re-prompt.
```

`verdictCodec`'s decoder maps `RawVerdict` to `Verdict`; resolution is
`verdict` then `fmap boolKind pass`, failing when both are absent (so a
malformed reply still repairs). Cassettes store raw reply text, so the
verdict codec never needs to re-encode prettily.

`judgeSystem` asks for the three-way verdict and one guard line:

```text
Respond ONLY with JSON {"why": <string>, "verdict": "pass" | "fail" | "cannot_assess"}.
Use "cannot_assess" only when the output genuinely lacks the information to
judge the criterion, never to avoid a hard call.
```

### 3. Vote loop (`Crucible.Eval.Judge`)

```haskell
data VoteOutcome
  = Decided { pass :: Bool, why :: Text, dissent :: Maybe Text, yes :: Int, no :: Int }
  | AllErrored   Text
  | AllAbstained Text   -- no yes/no cast and at least one abstain
```

`vote` tallies `Pass`->yes, `Fail`->no, and `CannotAssess`->an abstain
counter (consuming the attempt, recording the first abstain rationale), a
judge error->an error consuming the attempt. Early stop counts only
yes/no. On exhaustion with no yes/no votes: `AllAbstained` if any abstain
happened, else `AllErrored`. A reached majority is still `Decided`, with
abstains and errors ignored in the tally.

`AbstainPolicy` and the `JudgeOpts` field:

```haskell
data AbstainPolicy = AbstainFails | AbstainSkips  deriving (Eq, Show)

data JudgeOpts = JudgeOpts
  { votes    :: Int
  , examples :: [JudgeExample]
  , abstain  :: AbstainPolicy   -- new; defaultJudgeOpts = AbstainFails
  }
```

### 4. Score consumption (`Crucible.Eval`)

`scoreWith`/`scoreM`/`scoreN`/`runEval*` keep their signatures; the policy
rides on `JudgeOpts`.

- `voteScore` (standalone Rubric): `AllAbstained m` -> `score 0.0 ("judge
  abstained: " <> m)`, policy-independent. `AllErrored` keeps `"judge
  error: "`. `Decided` unchanged.
- `checklistScore.judge1` resolves each criterion to an internal
  `(met :: Maybe Bool, line :: Text)`:
  - `Decided p` -> `met = Just p`; line `[pass]`/`[fail]` (positive) or
    `[penalty]`/`[clear]` (negative weight), as the penalty cycle set.
  - `AllErrored m` -> `met = Just False`; line keeps `judge error:`.
  - `AllAbstained m`, `AbstainFails` -> `met = Just False`; line `[abstain]
    ... judge abstained: m` (positive fails / penalty clears).
  - `AllAbstained m`, `AbstainSkips` -> `met = Nothing`; line `[skip] ...
    judge abstained: m`.
  Aggregation: `posTotal` and `got` skip `met = Nothing` criteria
  (dropped from both denominator and numerator); clamp formula otherwise
  unchanged. Empty or all-skipped checklist keeps the `1.0` short-circuit.
- `scaleScore` is untouched (the level path has no verdict kind).

### 5. Grounding (`Crucible.Eval.Grounding`)

`groundingOutcome` adds a case for `AllAbstained`: the claim counts as
unsupported with a `judge abstained:` line (no policy; derived claims have
no weights to skip). Minimal, just enough to stay total.

### 6. Rendering (`Crucible.Eval.renderReport`)

A `[judge abstained]` case annotation when the rationale contains `judge
abstained:`, distinct from the existing `[judge error]` annotation.

### 7. Calibration (`Crucible.Eval.Calibrate`)

`CalibrationReport` gains a final field `abstained :: [Text]` (case names,
matching the `contested`/`judgeErrors` list style). An `AllAbstained`
calibration case is excluded from agreement/kappa (no verdict to agree
with) and listed in `abstained`; judge errors stay in `judgeErrors`.
`renderCalibration` prints the abstention count.

## Demo (`app/Main.hs`)

If a stable live abstain can be provoked (a Rubric whose criterion asks
about a property the output says nothing about), add one case and print
its `[judge abstained]` line. If a live abstain proves unreliable, keep
the feature hermetic-only and note it; the plan decides after a live
check.

## Manual (`docs/evals.md`)

Document the three-way verdict (`cannot_assess`), the `AbstainPolicy`
(fail by default; skip drops the criterion from the checklist
denominator), that a standalone Rubric/Scale abstain fails, that a penalty
abstain clears under `AbstainFails`, that abstention renders as `[judge
abstained]` distinct from `[judge error]`, and that `calibrate` counts
abstentions separately. House style: no emdashes, no hype, no manifest
mentions.

## Testing (hermetic; scripted verdicts)

- Codec: decodes the new `verdict` enum (pass/fail/cannot_assess), the
  legacy `pass` bool (true->Pass, false->Fail), and fails when both are
  absent (driving repair).
- Vote: all samples `cannot_assess` -> `AllAbstained`; a yes/no majority
  amid abstains stays `Decided`; all errored stays `AllErrored`.
- Standalone Rubric: an abstain scores 0.0 with `judge abstained:` in the
  rationale; `votes` unaffected.
- Checklist under `AbstainFails`: an abstained positive criterion fails
  and stays in the denominator (e.g. one pass weight 1 + one abstain
  weight 1 -> 0.5).
- Checklist under `AbstainSkips`: the abstained criterion drops from the
  denominator (one pass weight 1 + one abstain-skip weight 1 -> 1.0).
- Penalty abstain under `AbstainFails`: the penalty clears (does not
  subtract).
- `renderReport`: a `[judge abstained]` annotation appears, distinct from
  `[judge error]`.
- `calibrate`: an abstained case is listed in `abstained` and excluded
  from kappa/agreement; an errored case stays in `judgeErrors`.
- Migration: existing verdict-codec, vote, checklist, runEvalN, and
  calibrate tests move to the new shape (the `JudgeOpts` third field, the
  `CalibrationReport` final field, and `verdict`-shaped scripted replies).
- Live: the demo abstain line before merge, if provokable.

## Non-goals

- Abstain for `Scale` ratings: the level path keeps its current
  parse-or-judge-error behavior; there is no `cannot_assess` level.
- Per-claim abstain policy in grounding: derived claims have no authored
  weights to skip, so an abstained claim is simply unsupported.
- Pessimistic-penalty abstain: `AbstainFails` maps cannot-assess to the
  Fail verdict uniformly, so a penalty abstain clears; a worst-case
  "abstain fires the penalty" mode is future work. [Q4]
- Excluding standalone abstained cases from the report: a standalone
  abstain scores 0 rather than dropping out of `passRate`/`meanScore`,
  which would need a Score-level "no score". [Q3]
