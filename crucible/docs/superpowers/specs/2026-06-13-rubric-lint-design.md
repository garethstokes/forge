# Executable Rubric Lint Design Spec

**Date:** 2026-06-13
**Status:** Approved design, pending implementation
**Tracker:** `crucible-ic0`.
**Research basis:** `docs/superpowers/research/2026-06-11-autorubric-review.md` item 6 (executable rubric lint); the four-check walk in `docs/evals.md` "Lint your rubric".
**Scope:** new `src/Crucible/Eval/Lint.hs`; `src/Crucible/Eval.hs` (re-export types, define `lintChecklist`); `test/Spec.hs`; `app/Main.hs`; `docs/evals.md`.

## Motivation

The "Lint your rubric" walk in the evals manual is prose: a reader is told
to check a checklist for conflation, direction ambiguity, and redundancy by
hand. Autorubric shows the same anti-pattern checks run as an LLM call.
Making them executable turns the discipline into something a suite can run,
while staying advisory: the linter never gates, it surfaces findings.

## Decisions taken during design

- Return a structured `[LintFinding]`, not the bead's original `[Text]`:
  per-criterion attribution and a typed issue kind make findings
  filterable and renderable. This refines the bead signature; everything
  else in the bead holds.
- A leaf module `Crucible.Eval.Lint` doing one judge call with codec + one
  repair, mirroring `Crucible.Eval.Grounding`. `Crucible.Eval` re-exports
  the types and defines `lintChecklist` over `Criterion` labels.
- Four checks only: conflation, direction, redundancy, vague wording.
  Coverage is not lintable from labels alone (it needs the failure modes
  the author has observed), so it stays a manual step.
- High precision: flag only clear violations; a clean checklist returns
  `[]`. A noisy linter gets ignored.
- On an unparseable reply after one repair, return a single
  `LintUnavailable` finding, distinguishable from a clean `[]`; never
  throw.
- One call, no voting. Advisory and cheap.

## Design

### 1. `Crucible.Eval.Lint` (new leaf module)

```haskell
-- | The four documented checklist anti-patterns (docs/evals.md
-- "Lint your rubric"). Coverage is absent: it needs the author's
-- observed failure modes, not the labels, so it stays manual.
data LintIssue = Conflation | Direction | Redundancy | Vague
  deriving (Eq, Show)

-- | One advisory finding, or the tool's own failure. 'LintUnavailable'
-- is returned (never thrown) when the lint reply will not parse after
-- one repair, so a caller can tell "no problems" from "lint did not run".
data LintFinding
  = Finding
      { issue     :: LintIssue
      , criterion :: Text       -- ^ the offending criterion label
      , note      :: Text       -- ^ the advisory message
      }
  | LintUnavailable Text
  deriving (Eq, Show)

-- | The lint messages, pure and testable (mirrors 'judgePrompt' /
-- 'ratePrompt'). Lists every label and asks for only clear violations
-- of the four anti-patterns, conservative by instruction.
lintPrompt :: [Text] -> [Message]

-- | Lint a list of criterion labels with one holistic judge call
-- (redundancy is cross-criterion, so the judge sees the whole set) plus
-- one repair. An empty list short-circuits to [] with no call.
lintLabels :: (LLM :> es) => [Text] -> Eff es [LintFinding]
```

The module imports only `Crucible.Codec`, `Crucible.Decode`,
`Crucible.LLM`, NeatInterpolation, and base/text. It does NOT import
`Crucible.Eval` (no `Score`/`Criterion` dependency), keeping the module
graph acyclic exactly as `Grounding` does.

JSON contract: the reply is a list of `{issue, criterion, note}` objects;
`issue` is one of `"conflation" | "direction" | "redundancy" | "vague"`
via `Crucible.Codec.enum`. `LintUnavailable` is never emitted by the
model; it is constructed locally on parse failure. The repair re-prompt
is the same idiom as `groundingOutcome`'s decompose and `judgeOnce`:
re-send the raw reply and the parse error once, then give up with
`LintUnavailable`.

### 2. `lintChecklist` in `Crucible.Eval`

```haskell
-- | Advisory lint over a checklist's criterion labels: run the four
-- documented anti-pattern checks (conflation, direction, redundancy,
-- vague wording) as one judge call. Advisory only, never a gate. A clean
-- checklist returns []. Coverage is not checked (it needs your observed
-- failure modes, not the labels).
lintChecklist :: (LLM :> es) => [Criterion] -> Eff es [LintFinding]
lintChecklist = lintLabels . map (.label)
```

`Crucible.Eval` re-exports `LintIssue (..)` and `LintFinding (..)` from
`Crucible.Eval.Lint`, matching how it re-exports `groundingCheck`'s
neighbourhood.

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block, lint a deliberately flawed checklist
and print one line per finding:

```haskell
findings <- runEff (Anthropic.run cfg (lintChecklist
  [ criterion "mentions the city and the temperature"  -- conflation
  , criterion "uses appropriate language"               -- direction
  ]))
mapM_ (\f -> TIO.putStrLn ("lint: " <> renderFinding f)) findings
```

where the demo renders a `Finding` as `<kind> '<criterion>': <note>` and
a `LintUnavailable` as `unavailable: <msg>`. Proves the four-check prompt
works live; one call.

## Manual (`docs/evals.md`)

In "Lint your rubric": keep the four conceptual bullets, and add that the
walk is now executable via `lintChecklist`, showing the signature and the
`LintFinding` / `LintIssue` types. State it is advisory and never a gate,
note the high-precision stance (a clean checklist returns `[]`), and keep
coverage as the one check it cannot automate: it needs the failures you
have actually seen, not the labels. House style: no emdashes, no hype, no
manifest mentions.

## Testing (hermetic; scripted judge replies)

- `lintPrompt ["a", "b"]` renders both labels, the four issue-kind names,
  and the high-precision directive (pure check, like `judgePrompt`).
- A scripted reply with two findings decodes to two `Finding`s with the
  right `issue` kinds, offending labels, and notes.
- A scripted `[]` reply gives `[]` (clean checklist).
- `lintChecklist []` returns `[]` under `runLLMScripted []` (short-circuit
  proven: no reply consumed).
- `lintChecklist [Criterion "x and y" 2, ...]` feeds labels (not weights)
  to the worker, asserted via a scripted finding echoing the label.
- A scripted `"junk"` then `"junk2"` (reply plus failed repair) gives
  `[LintUnavailable m]` with `m` carrying the parse error.
- The `LintIssue` codec decodes each of the four tags and rejects an
  unknown tag (drives the repair path).
- Live: the demo lint lines before merge.

## Non-goals

- Coverage checking: needs the author's observed failure modes, not the
  labels, so it cannot run from the checklist alone.
- The held-out `improve_rubric` revision loop: deferred per the bead;
  `calibrate` with a human in the loop covers rubric iteration until
  labelled sets are large.
- Gating / CI-fail behavior: the linter is advisory; turning findings into
  a build failure is the caller's choice, not the function's.
- Linting a raw `Rubric Text` string: a possible future `lintRubric`;
  this cycle is checklist labels only.
- Voting / multi-sample: one advisory call; cost stays minimal.
