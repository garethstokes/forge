# groundingCheck Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SFS-style derived claim checking: decompose a skill output into atomic factual claims, verify each against provided evidence with binary judge votes, Score = supported/total, exposed as both `groundingCheck` and a `Grounded` expectation.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-11-grounding-check-design.md` (tracker `crucible-mo3`). New leaf module `Crucible.Eval.Grounding` returns a `GroundingOutcome` (no `Score` dependency, keeping the module graph acyclic); `Crucible.Eval` converts to `Score`, adds the `Grounded` ctor to `Expectation`, and exports `groundingCheck`.

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec, neat-interpolation. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). On exit 137 retry once; second 137 = BLOCKED. Judge success by exit status or the "1 test suite(s) passed" line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/grounding-check` from master; work in place, no worktrees.
- House style: prefix-free fields, `OverloadedRecordDot`, prompts via `[text| |]` (QuasiQuotes; interpolated values must be `Text` identifiers in scope). Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `Crucible.Eval.Judge` exports `VoteOutcome (Decided {pass, why, dissent, yes, no} | AllErrored Text)` (Decided is 5-ary: `Decided p w d y f`) and `vote :: (LLM :> es) => Bool -> Int -> Text -> Text -> Eff es VoteOutcome` (args: earlyStop, n, rubric, graded text).
- `Crucible.Eval` has `Score {value, rationale, votes, dissent}` + `score v r` smart ctor (fills both `Nothing`), `Expectation (Exactly | Predicate | Rubric | Checklist)`, `scoreN`, `runEvalN`. `Crucible.Codec` exports `list', str, schemaText`. `Crucible.Decode` exports `decodeLLM`, `DecodeError (..)` (fields `message`, `raw`).
- Do NOT import `Crucible.Skill` from the new module (the spec records the import-cycle reversal).
- Suite currently passes with 195 ok lines.

---

### Task 1: Grounding module + Eval integration + tests

**Files:**
- Create: `src/Crucible/Eval/Grounding.hs`
- Modify: `src/Crucible/Eval.hs` (Grounded ctor, dispatch, groundingScore, groundingCheck, exports)
- Modify: `test/Spec.hs` (seven checks)

- [ ] **Step 1: create `src/Crucible/Eval/Grounding.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | Derived claim checking (the SFS recipe): decompose a rendered output
-- into atomic factual claims, then verify each claim against the provided
-- evidence with a binary judge vote. Authored checklist criteria catch
-- missing expected content; derived claims catch invented content.
--
-- No-closed-loop compliance: every verification call receives the original
-- evidence verbatim; the claim is the SUBJECT of the judgement, not a
-- derived substitute for the evidence. Decomposition quality is the
-- metric's own degree of freedom, and condition rankings are empirically
-- invariant to the decomposer choice.
--
-- This module deliberately does not depend on 'Crucible.Eval' (it returns
-- a 'GroundingOutcome', which Eval converts to a Score) or on
-- 'Crucible.Skill' (the decomposer is local plumbing with the same repair
-- semantics 'Crucible.Skill.call' would provide; reusing call would create
-- an import cycle).
module Crucible.Eval.Grounding
  ( GroundingOutcome (..)
  , groundingOutcome
  ) where

import Data.Text (Text)
import Effectful
import NeatInterpolation (text)

import Crucible.Codec (JSONCodec, list', schemaText, str)
import Crucible.Decode (DecodeError (..), decodeLLM)
import Crucible.Eval.Judge (VoteOutcome (..), vote)
import Crucible.LLM (LLM, Message (..), Role (..), complete)

-- | The outcome of a grounding check, before Score conversion (which lives
-- in "Crucible.Eval", keeping this module free of the Score type).
data GroundingOutcome
  = GroundingOutcome
      { supported :: Int
      , total     :: Int
      , lines'    :: [Text]  -- ^ one [supported]\/[unsupported] line per claim, in order
      }
  | NoClaims                 -- ^ the decomposer found no factual claims
  | DecomposeFailed Text     -- ^ decompose reply unusable after one repair
  deriving (Eq, Show)

-- | Decompose the rendered output into atomic claims, verify each against
-- the evidence with @vote True n@ (early stopping, like checklist
-- criteria), and tally. A claim whose vote all-errors counts unsupported
-- with a tagged line.
groundingOutcome :: (LLM :> es)
                 => Int      -- ^ votes per claim (odd; <=1 means one judge call)
                 -> Text     -- ^ evidence the output must be grounded in
                 -> Text     -- ^ rendered output
                 -> Eff es GroundingOutcome
groundingOutcome n evidence rendered = do
  claims <- decompose rendered
  case claims of
    Left m   -> pure (DecomposeFailed m)
    Right [] -> pure NoClaims
    Right cs -> do
      rs <- mapM verify cs
      pure (GroundingOutcome
              (length [() | (_, p, _) <- rs, p])
              (length rs)
              (map line rs))
  where
    verify claim = do
      out <- vote True n "the claim is supported by the evidence" [text|
        Evidence:
        ${evidence}

        Claim:
        ${claim}|]
      pure $ case out of
        Decided p w _ _ _ -> (claim, p, w)
        AllErrored m      -> (claim, False, "judge error: " <> m)
    line (c, p, w) =
      (if p then "[supported] " else "[unsupported] ") <> c <> ": " <> w

-- | One decompose call with the Skill-style schema contract and one
-- schema-restating repair on a malformed reply.
decompose :: (LLM :> es) => Text -> Eff es (Either Text [Text])
decompose rendered = do
  raw <- complete msgs
  case decodeLLM claimsCodec raw of
    Right cs -> pure (Right cs)
    Left e1 -> do
      let m = e1.message
      raw2 <- complete
        ( msgs
            ++ [ Message Assistant raw
               , Message User [text|
                   Your reply did not parse: ${m}.
                   Respond ONLY with valid JSON matching this schema:
                   ${schema}|]
               ]
        )
      case decodeLLM claimsCodec raw2 of
        Right cs -> pure (Right cs)
        Left e2  -> pure (Left e2.message)
  where
    claimsCodec :: JSONCodec [Text]
    claimsCodec = list' str
    schema = schemaText claimsCodec
    msgs =
      [ Message System [text|
          Respond ONLY with JSON matching this schema:
          ${schema}|]
      , Message User [text|
          List the atomic factual claims made by the text below as a JSON array of
          strings. Atomic means one verifiable fact per claim. Each claim must be
          self-contained (no pronouns that depend on other claims). Merge trivial
          variations; list at most 20 claims. Output only the JSON array.

          Text:
          ${rendered}|]
      ]
```

- [ ] **Step 2: integrate in `src/Crucible/Eval.hs`.**

(a) Import: `import Crucible.Eval.Grounding (GroundingOutcome (..), groundingOutcome)`.

(b) `Expectation` gains the ctor (and its haddock):

```haskell
data Expectation a
  = Exactly a              -- ^ must equal (needs Eq a)
  | Predicate (a -> Bool)  -- ^ must satisfy
  | Rubric Text            -- ^ LLM-as-judge against this rubric
  | Checklist [Criterion]  -- ^ weighted binary criteria, judged one by one
  | Grounded Text          -- ^ every factual claim in the output must be
                           --   supported by this evidence (derived claims)
```

(c) `scoreN` gains the case (after `Checklist`):

```haskell
  Grounded ev   -> groundingScore <$> groundingOutcome n ev (render actual)
```

(d) Add the conversion and the standalone (near `checklistScore`), and export `groundingCheck` from the module header:

```haskell
-- | Check that every factual claim in an output is supported by the given
-- evidence: decompose into atomic claims (at most 20, one decompose call
-- plus one repair attempt), verify each with an n-vote judge call, and
-- score supported over total. value reaches 1.0 only when every claim is
-- supported, so a 'Grounded' case passes only with zero unsupported
-- claims. A decompose failure scores 0 with a @judge error: @ tagged
-- rationale; 'votes'\/'dissent' stay Nothing (per-claim tallies do not
-- aggregate). Cost: 1-2 decompose calls plus claims x votes judge calls.
groundingCheck :: (LLM :> es) => Int -> (o -> Text) -> Text -> o -> Eff es Score
groundingCheck n render ev o = groundingScore <$> groundingOutcome n ev (render o)

-- | Convert a grounding outcome to a Score.
groundingScore :: GroundingOutcome -> Score
groundingScore (GroundingOutcome s t ls) =
  score (fromIntegral s / fromIntegral t) (T.intercalate "\n" ls)
groundingScore NoClaims =
  score 1.0 "no factual claims"
groundingScore (DecomposeFailed m) =
  score 0.0 ("judge error: claim decomposition failed: " <> m)
```

- [ ] **Step 3: build.** `nix develop . --command timeout -s KILL 300 zinc build` → exit 0. (zinc auto-discovers the new module.)

- [ ] **Step 4: add seven checks to `test/Spec.hs`** (extend the Crucible.Eval import with `groundingCheck`; `Grounded` arrives via the existing `Expectation(..)`; insert after the calibrate checks):

```haskell
  -- crucible-mo3: derived claim grounding
  , check "groundingCheck: all claims supported -> 1.0 with lines in order"
      (1.0, True)
      (let s = runPureEff (runLLMScripted
                 [ "[\"the temperature is 26C\",\"the city is Brisbane\"]"
                 , "{\"why\":\"evidence says 26 degrees\",\"pass\":true}"
                 , "{\"why\":\"evidence names Brisbane\",\"pass\":true}" ]
                 (groundingCheck 1 id "Brisbane forecast: sunny, 26 degrees." ("It is 26C in Brisbane." :: Text)))
       in ( s.value
          , T.isInfixOf "[supported] the temperature is 26C: evidence says 26 degrees" s.rationale
              && T.isInfixOf "[supported] the city is Brisbane: evidence names Brisbane" s.rationale ))
  , check "groundingCheck: unsupported claim halves the score and is named"
      (0.5, True)
      (let s = runPureEff (runLLMScripted
                 [ "[\"the temperature is 26C\",\"it is raining\"]"
                 , "{\"why\":\"supported\",\"pass\":true}"
                 , "{\"why\":\"evidence says sunny\",\"pass\":false}" ]
                 (groundingCheck 1 id "sunny, 26 degrees" ("out" :: Text)))
       in (s.value, T.isInfixOf "[unsupported] it is raining: evidence says sunny" s.rationale))
  , check "groundingCheck: no claims -> vacuous 1.0, zero verification calls"
      (1.0, "no factual claims", "leftover")
      (runPureEff (runLLMScripted ["[]", "leftover"]
        (do s <- groundingCheck 1 id "ev" ("out" :: Text)
            extra <- complete []
            pure (s.value, s.rationale, extra))))
  , check "groundingCheck: decompose failure -> tagged judge error"
      (0.0, True)
      (let s = runPureEff (runLLMScripted ["junk", "junk2"]
                 (groundingCheck 1 id "ev" ("out" :: Text)))
       in (s.value, T.isPrefixOf "judge error: claim decomposition failed:" s.rationale))
  , check "groundingCheck: decompose repair recovers"
      1.0
      ((runPureEff (runLLMScripted
         [ "junk", "[\"a claim\"]", "{\"why\":\"yes\",\"pass\":true}" ]
         (groundingCheck 1 id "ev" ("out" :: Text)))).value)
  , check "groundingCheck: claim vote all-errors counts unsupported"
      (0.0, True)
      (let s = runPureEff (runLLMScripted
                 [ "[\"a claim\"]", "junk", "junk2" ]
                 (groundingCheck 1 id "ev" ("out" :: Text)))
       in (s.value, T.isInfixOf "[unsupported] a claim: judge error:" s.rationale))
  , check "Grounded: threads votes through runEvalN"
      (1.0, "leftover")
      (runPureEff (runLLMScripted
         [ "[\"one claim\"]"
         , "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}"
         , "leftover" ]
         (do rep <- runEvalN 3 id pure [Case ("text" :: Text) "g" (Grounded "ev")]
             extra <- complete []
             pure (rep.passRate, extra))))
```

(The last check proves both the `Grounded` dispatch and early stopping: at n = 3 the unanimous claim consumes exactly two verdicts, leaving "leftover" for the trailing `complete`.)

- [ ] **Step 5: run the suite.** `nix develop . --command timeout -s KILL 300 zinc test` → `1 test suite(s) passed`, 202 ok lines. If an expectation fails, recheck the scripted-reply accounting against the Background facts (decompose repair consumes one extra reply; a vote sample with junk consumes two replies via the verdict repair) before changing anything; report plan/behaviour mismatches as DONE_WITH_CONCERNS rather than silently adjusting.

- [ ] **Step 6: commit.**

```bash
git add src/Crucible/Eval/Grounding.hs src/Crucible/Eval.hs test/Spec.hs
git commit -m "$(printf 'feat(eval): groundingCheck + Grounded expectation (derived claim checklist)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: manual subsection + demo case + live smoke

**Files:**
- Modify: `docs/evals.md` (Derived claims subsection + at-a-glance rule 6 pointer)
- Modify: `app/Main.hs` (one `Grounded` case in the eval demo)

- [ ] **Step 1: docs.** Read `src/Crucible/Eval/Grounding.hs` and the Eval additions first; mirror signatures exactly. In `docs/evals.md`, add a `### Derived claims: groundingCheck` subsection at the END of the "Grounding criteria for context-receiving skills" section, covering: authored criteria catch missing expected content while derived claims catch invented content (use both); the two-stage pipeline (decompose to at most 20 atomic claims, verify each against the evidence re-injected verbatim, which is what keeps the protocol open-loop per the page's no-closed-loop rule); the `Grounded Text` expectation and the `groundingCheck :: Int -> (o -> Text) -> Text -> o -> Eff es Score` signature; strict pass semantics (one unsupported claim fails the case; the fractional value feeds `meanScore`); the cost note (1-2 decompose calls plus claims x votes); decompose failures surface as `judge error:` tagged scores. Then extend at-a-glance rule 6 with a final sentence: `Add a Grounded case to catch invented content the authored criteria cannot anticipate.` (no renumbering). House style: no emdashes/endashes, no hype words, no manifest mentions; `grep -n '—\|–' docs/evals.md` must stay empty.

- [ ] **Step 2: demo.** In `app/Main.hs`, add a third case to the existing `runEvalN 3` eval list:

```haskell
        , Case "It is 26C and sunny in Brisbane." "grounded-weather"
            (Grounded "Brisbane forecast: sunny, 26 degrees, light winds.")
```

(`Grounded` arrives via the existing `Expectation (..)` import in Main's Eval import line; check and extend the import if Expectation is imported with an explicit ctor list.)

- [ ] **Step 3: build + live smoke.** (Keys in `.env`, gitignored; NEVER print them.)

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 300 .zinc/build/crucible-anthropic'
```

Expected: the report block gains a `grounded-weather: 1.0 ([supported] ...)` line (live judgements; the exact claim split may vary, what matters is the case runs, scores, and the binary exits 0).

- [ ] **Step 4: commit.**

```bash
git add docs/evals.md app/Main.hs
git commit -m "$(printf 'docs(site)+demo: derived claims (groundingCheck) documented and smoke-tested live\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: merge + publish + close

**Files:** none.

- [ ] **Step 1: full suite.** `nix develop . --command timeout -s KILL 300 zinc test` → `1 test suite(s) passed`.
- [ ] **Step 2: merge + push.** Handled by `superpowers:finishing-a-development-branch` (the user historically picks "merge back to master locally"); after merge: suite on master, `git push`, confirm the Pages build reaches `built`.
- [ ] **Step 3: close the tracker issue.**

```bash
bd close crucible-mo3 --reason="Shipped: Crucible.Eval.Grounding (decompose + per-claim votes), Grounded expectation + groundingCheck in Eval, 7 hermetic tests, evals.md derived-claims subsection, live-verified demo case."
```

---

## Self-Review

**1. Spec coverage:** GroundingOutcome + groundingOutcome + decomposer (prompt, soft cap 20, repair, NoClaims) → Task 1 Step 1. Verification framing (evidence re-injected, claim as subject, AllErrored handling) → Step 1 `verify`. Grounded ctor + scoreN dispatch + groundingScore conversions (fraction / vacuous 1.0 / tagged failure) + groundingCheck export → Step 2. votes/dissent Nothing → falls out of the `score` smart ctor (stated in groundingCheck's haddock). All eight spec test bullets → Step 4's seven checks plus Task 2's live smoke (the spec's `runEval`-end-to-end bullet is subsumed by the `runEvalN` check, which exercises the same dispatch path with vote threading on top). Manual + demo → Task 2. Non-goals absent. ✅

**2. Placeholder scan:** none; the docs step is a content brief with the established read-the-source instruction, all code steps carry complete code. ✅

**3. Type consistency:** `groundingOutcome n evidence rendered` argument order matches the spec and both call sites (`scoreN`, `groundingCheck`); `Decided p w _ _ _` matches the current 5-ary constructor; `GroundingOutcome s t ls` field order (supported, total, lines') consistent between module and conversion; `groundingCheck :: Int -> (o -> Text) -> Text -> o -> Eff es Score` matches spec, tests, and docs brief. ✅
