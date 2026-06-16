# Research Grounding-Gated Writes Design Spec

**Date:** 2026-06-15
**Status:** Approved design, pending implementation
**Tracker:** `crucible-nkq` (follow-on to `crucible-1z4`, the Research foundation; from `docs/superpowers/research/2026-06-11-llm-wiki.md` rec 4).
**Goal:** Commit a Research page only when its body's claims are supported by its source trace, by grounding the body with `Crucible.Eval.Grounding` before the write.

**Scope:** new `src/Crucible/Research/Grounded.hs`; `test/Spec.hs`; `app/Main.hs`; `docs/research.md` (a "Grounding-gated writes" section, and remove the item from "planned follow-on work"). No change to `Crucible.Research` or `Crucible.Eval.Grounding`.

## What problem this solves

A knowledge base is only as trustworthy as the writes that fill it. When an agent
ingests sources and writes a synthesis page, nothing stops it from adding a claim
the sources do not support, and once that claim is on a page the next read treats
it as known. Every shipped system that worried about this gates writes with a
human: a review queue, an approve/reject step, a supervised training period.
Automated claim-level verification at write time does not exist in any surveyed
wiki. crucible already has the machinery for it: `Crucible.Eval.Grounding`
decomposes text into atomic claims and judges each against evidence. Applied as a
write gate, it makes verified ingest the default: a page lands only if its body's
claims are supported by the source trace it was built from, and an edit with
unsupported claims is rejected with the offending claims named, instead of
silently becoming part of what the agent "knows." The gate is opt-in per write,
so unverified writes (plain `writePage`) stay available; what changes is that
verifying a write is now one call, not a manual step.

## Decisions taken during design

- **Orchestration-level combinator, not an effect change.** `writeGrounded` is a
  function in a row that has both `Research meta` and `LLM`; the `Research`
  effect and plain `writePage` are untouched. New module
  `Crucible.Research.Grounded` so `Crucible.Research` stays free of the `Eval`
  dependency (mirrors `Crucible.Agents.Gate`).
- **Caller-controlled NoClaims policy.** Whether a body that makes no factual
  claims commits or is rejected is the caller's choice (`onNoClaims`), not
  hardcoded.
- **A verifier breakdown never commits.** `DecomposeFailed` (the grounding
  decomposer/verifier broke) rejects: the gate could not verify, so it does not
  commit unverified.
- **Threshold knob.** `threshold` is the minimum fraction of claims that must be
  supported to commit; the default is `1.0` (all claims supported).
- **Evidence is caller-supplied `Text`.** The source trace is a parameter; the
  gate does not prescribe where it comes from (raw traces or concatenated source
  pages).
- **Body only.** The gate grounds `page.body` (the content); title and links are
  not grounded.

## Design (`Crucible.Research.Grounded`)

```haskell
data NoClaimsPolicy = CommitNoClaims | RejectNoClaims
  deriving (Eq, Show)

data GroundGate = GroundGate
  { threshold  :: Double          -- ^ min fraction of claims supported to commit (1.0 = all)
  , votes      :: Int             -- ^ judge votes per claim (odd; <=1 means one judge call)
  , onNoClaims :: NoClaimsPolicy  -- ^ commit or reject when the body makes no claims
  }

-- | threshold 1.0, votes 1, CommitNoClaims.
defaultGroundGate :: GroundGate

-- | Ground a page's body against the evidence; commit via 'writePage' only if it
-- passes the gate. 'Right' '()' means committed; 'Left' carries the
-- 'GroundingOutcome' explaining why it was not (unsupported claims, a no-claims
-- rejection, or a verifier breakdown).
writeGrounded :: (Research meta :> es, LLM :> es)
              => GroundGate -> Text -> Page meta -> Eff es (Either GroundingOutcome ())
```

`GroundingOutcome` is re-exported from this module (from
`Crucible.Eval.Grounding`) so callers can pattern-match the `Left` without a
second import.

### `writeGrounded` semantics

```
out <- groundingOutcome gate.votes evidence page.body
case out of
  NoClaims              -> case gate.onNoClaims of
                             CommitNoClaims -> writePage page >> pure (Right ())
                             RejectNoClaims -> pure (Left NoClaims)
  DecomposeFailed _     -> pure (Left out)
  GroundingOutcome s t _
    | t == 0            -> writePage page >> pure (Right ())   -- defensive; NoClaims covers empty
    | passes s t        -> writePage page >> pure (Right ())
    | otherwise         -> pure (Left out)
  where passes s t = fromIntegral s / fromIntegral t >= gate.threshold
```

The page is written with the existing `writePage` (so it overwrites by slug as
usual) only on the commit branches. On any `Left`, nothing is written.

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block, under a temp `runResearchDir` plus
`Anthropic.run` (for `LLM`): define an evidence string, then
`writeGrounded defaultGroundGate evidence` on (a) a page whose body restates the
evidence (expect `Right ()`, then `readPage` shows it) and (b) a page whose body
adds an unsupported claim (expect `Left`, and `readPage` shows it absent). Print
both results. Shows verified ingest accepting a grounded page and rejecting an
ungrounded one, live. Stack:
`runEff (Anthropic.run cfg (runResearchDir str dir program))`.

## Manual (`docs/research.md`)

Add a "Grounding-gated writes" section: the `GroundGate` config
(`threshold`/`votes`/`onNoClaims`), `defaultGroundGate`, `writeGrounded` (commit
only if the body's claims are supported by the evidence; `Right ()` committed,
`Left outcome` rejected), the NoClaims and DecomposeFailed policies, and that
flag-mode (always write, record the outcome) is caller-composable from
`groundingOutcome` + `writePage` + `appendLog`. Remove "grounding-gated writes"
from the "planned follow-on work" list. House style: no emdashes/endashes, no
hype words, no manifest mentions.

## Testing (hermetic)

Compose `runResearchState` (pure pages) with `runLLMScripted` (canned grounding
replies: the decompose reply, then one verdict per claim). The program row has
`Research meta` and `LLM`; discharge `Research` then `LLM` then `runPureEff`. The
exact decompose reply format and per-claim verdict format come from the existing
grounding tests in `test/Spec.hs` (`groundingCheck`/`groundingOutcome`); copy
them.

- **All supported -> committed:** decompose yields two claims, both verdicts
  pass; `writeGrounded defaultGroundGate evidence page` returns `Right ()` and the
  page is in the final dump.
- **One unsupported at threshold 1.0 -> rejected:** two claims, one fails;
  returns `Left (GroundingOutcome 1 2 _)` and the page is absent from the dump.
- **Threshold 0.5 with 1/2 supported -> committed:** same replies as above but
  `gate { threshold = 0.5 }`; returns `Right ()`, page present.
- **NoClaims under each policy:** decompose yields no claims;
  `CommitNoClaims` returns `Right ()` (page present); `RejectNoClaims` returns
  `Left NoClaims` (page absent).
- **DecomposeFailed -> rejected:** an unparseable decompose reply yields
  `DecomposeFailed`; returns `Left` and the page is absent.
- **`defaultGroundGate`** has `threshold == 1.0`, `votes == 1`,
  `onNoClaims == CommitNoClaims`.

Live: the demo grounded write before merge (gated on the Anthropic key).

## Non-goals

- Flag-mode as a built-in (always-write-and-record); it is caller-composable
  from the public building blocks.
- Auto-assembling evidence from source pages (the caller supplies the evidence
  text).
- Grounding the title or links (body only).
- Changing the `Research` effect or `Crucible.Eval.Grounding`.
- A per-claim threshold or per-link-type policy (one body-level supported
  fraction).
