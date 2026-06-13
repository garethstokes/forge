# Cross-Model Judge Panels Design Spec

**Date:** 2026-06-13
**Status:** Approved design (autonomous), pending implementation
**Tracker:** `crucible-ymh`.
**Research basis:** `docs/superpowers/research/2026-06-11-autorubric-review.md` item 2 (cross-model judge panels).

**Autonomous note:** Worked unattended. The design adopts the signature the
research note proposes verbatim (no product fork to resolve); the only
calls made here are mechanical (where the code lives, the tally's
tie/dissent semantics matching `vote`).

**Scope:** `src/Crucible/Eval/Judge.hs` (`tally`, `votePanel`); `test/Spec.hs`; `app/Main.hs`; `docs/evals.md`.

## Motivation

crucible's own docs name the judge weakness twice: with no sampling
temperature, n votes can be n copies of one opinion, and evals rule 13
says to judge with a different model family. A panel of judges across
providers fixes both. The crucible-shaped move keeps the tally pure and
lets the caller run each judge under its own interpreter. Stays
open-loop (each judge sees the original output and rubric verbatim).

## Design (`Crucible.Eval.Judge`)

```haskell
-- | Pure mechanical combination of independent verdicts (no LLM). Same
-- resolution as 'vote' with no early stop: Pass tallies as yes, Fail as
-- no, CannotAssess as an abstain, a JudgeError as an excluded sample.
-- With no yes/no votes the outcome is 'AllAbstained' if any sample
-- abstained, else 'AllErrored'; otherwise the majority decides (a tie
-- resolves to fail, matching 'vote'), 'why' is the first winning-side
-- rationale and 'dissent' the first losing-side one.
tally :: [Either JudgeError Verdict] -> VoteOutcome

-- | Run a panel of judges over one (rubric, output) and combine with
-- 'tally'. Each member is 'judgeOnce' run under its own interpreter,
-- e.g. @\\r g -> runEff (Anthropic.run cfg (judgeOnce exs r g))@ and an
-- OpenAI twin. Monad-general so it is pure-testable with 'Identity'.
votePanel :: Monad m
          => [Text -> Text -> m (Either JudgeError Verdict)]
          -> Text -> Text -> m VoteOutcome
votePanel judges rubric graded =
  tally <$> traverse (\j -> j rubric graded) judges
```

`tally` (derived from `vote`'s terminal resolution):

```haskell
tally rs =
  let verdicts = [v | Right v <- rs]
      yesWhys  = [v.why | v <- verdicts, v.kind == Pass]
      noWhys   = [v.why | v <- verdicts, v.kind == Fail]
      absWhys  = [v.why | v <- verdicts, v.kind == CannotAssess]
      errs     = [m | Left (JudgeError m) <- rs]
      y = length yesWhys
      f = length noWhys
  in if y == 0 && f == 0
       then case absWhys of
              (w : _) -> AllAbstained w
              []      -> AllErrored (if null errs then "" else last errs)
       else if y > f
              then Decided True  (head yesWhys) (listToMaybe noWhys)  y f
              else Decided False (head noWhys)  (listToMaybe yesWhys) y f
```

(`head yesWhys`/`head noWhys` are total in their branches: `y > f`
guarantees a yes, the else guarantees a no since not both zero.
`listToMaybe` from `Data.Maybe`, already imported.)

Both exported from `Crucible.Eval.Judge`. No new dependencies; `traverse`
is Prelude. The panel is not folded into `vote` (vote early-stops within
one interpreter; a panel runs every member, one verdict each, for
cross-family diversity).

## Demo (`app/Main.hs`)

In the OpenAI-key-gated block (both providers wired), a two-member panel
judging one output across families, printing the outcome:

```haskell
panelOut <- votePanel
  [ \r g -> runEff (Anthropic.run cfg (judgeOnce [] r g))
  , \r g -> runEff (OpenAI.run ocfg (judgeOnce [] r g)) ]
  "the output is a friendly greeting" "Hello there, lovely to meet you!"
TIO.putStrLn ("panel: " <> T.pack (show panelOut))
```

## Manual (`docs/evals.md`)

A "Cross-model judge panels" subsection in the voting material: `tally`
(pure) and `votePanel` (Monad-general), the member-building pattern
(`judgeOnce` under each provider's interpreter), why a panel beats n
same-model votes (diversity, per rule 13), that it stays open-loop, and
that the tally's majority/dissent semantics match `vote`. House style: no
emdashes, no hype, no manifest mentions.

## Testing (hermetic; pure via Identity)

- `tally`: all Pass -> Decided True; mixed majority -> the majority side;
  a tie (one Pass, one Fail) -> Decided False (matches `vote`); all
  CannotAssess -> AllAbstained; all JudgeError -> AllErrored; a 2-1 split
  records `yes`/`no` and the first losing-side `dissent`; errors are
  excluded from the tally.
- `votePanel` over `Identity` members: combines their verdicts via `tally`
  (e.g. two Pass members -> Decided True), and each member receives the
  rubric and output passed to `votePanel`.

## Non-goals

- Per-member vote counts (a panel is one verdict per model; repeated
  sampling of one model is what `vote` already does).
- A Score-level `judgePanel` wrapper in `Crucible.Eval` (callers convert
  the `VoteOutcome` with the existing path if needed; add only on demand).
- Weighted or quorum panels beyond majority (unanimous-as-gate already
  falls out of inspecting the tally).
- Closed-loop judging (panels stay open-loop, like `vote`).
