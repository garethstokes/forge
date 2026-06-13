# Executable Rubric Lint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `lintChecklist :: (LLM :> es) => [Criterion] -> Eff es [LintFinding]`, an advisory LLM pass that runs the four documented checklist anti-pattern checks over criterion labels and returns structured findings.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-13-rubric-lint-design.md` (tracker `crucible-ic0`). A new leaf module `Crucible.Eval.Lint` (one judge call, codec + one repair, no `Score`/`Eval` dependency, mirroring `Crucible.Eval.Grounding`); `Crucible.Eval` re-exports the types and defines `lintChecklist`. Advisory only, never a gate.

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec (via `Crucible.Codec`), neat-interpolation. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). Exit 137 = GHC iserv flake, retry once; second 137 = BLOCKED. Judge success by exit status or the pass line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/rubric-lint` from master; work in place, no worktrees.
- House style: DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot, prefix-free fields. With NoFieldSelectors there are no selector functions, so `(.field)` sections work via HasField but only resolve when the record type is fixed; construct findings positionally to avoid any ambiguity. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Read first: `src/Crucible/Eval/Grounding.hs` (the structural template: a leaf module doing `complete` + `decodeLLM codec` + one schema-restating repair, returning a structured outcome; `Crucible.Eval` wraps it). `src/Crucible/Codec.hs` exports `enum :: Eq a => [(Text, a)] -> JSONCodec a`, `object`, `field :: Text -> (o -> f) -> JSONCodec f -> ObjectCodec o f`, `list'`, `str`, `schemaText`. `src/Crucible/Eval/Judge.hs` `judgePrompt`/`ratePrompt` show the pure-prompt-builder idiom the tests use.
- `Crucible.Eval` exports list ends `, groundingCheck )`; it imports Grounding as `import Crucible.Eval.Grounding (GroundingOutcome (..), groundingOutcome)`. Mirror both for Lint.
- The suite passes with 273 checks.
- API keys live in `.env` (gitignored). NEVER print, echo, or cat `.env` or any key value.

---

### Task 1: `Crucible.Eval.Lint` + `lintChecklist` + tests

**Files:**
- Create: `src/Crucible/Eval/Lint.hs`
- Modify: `src/Crucible/Eval.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: create `src/Crucible/Eval/Lint.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | Advisory rubric lint: run the four documented checklist anti-pattern
-- checks (docs/evals.md "Lint your rubric") as one judge call over
-- criterion labels. Advisory only, never a gate; a clean checklist
-- yields no findings. Coverage is absent because it needs the author's
-- observed failure modes, not the labels.
--
-- Like "Crucible.Eval.Grounding", this module does not depend on
-- 'Crucible.Eval' (it returns 'LintFinding', and Eval wraps it as
-- 'lintChecklist'); the prompt + repair are local plumbing with the same
-- semantics 'Crucible.Skill.call' would provide.
module Crucible.Eval.Lint
  ( LintIssue (..)
  , LintFinding (..)
  , lintPrompt
  , lintLabels
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import NeatInterpolation (text)

import Crucible.Codec (JSONCodec, enum, field, list', object, schemaText, str)
import Crucible.Decode (DecodeError (..), decodeLLM)
import Crucible.LLM (LLM, Message (..), Role (..), complete)

-- | The four checklist anti-patterns.
data LintIssue = Conflation | Direction | Redundancy | Vague
  deriving (Eq, Show)

-- | One advisory finding, or the tool's own failure. 'LintUnavailable'
-- is returned (never thrown) when the reply will not parse after one
-- repair, so a caller can tell "no problems" from "lint did not run".
data LintFinding
  = Finding
      { issue     :: LintIssue
      , criterion :: Text
      , note      :: Text
      }
  | LintUnavailable Text
  deriving (Eq, Show)

-- | Internal wire shape: a single-constructor record so the codec getters
-- are total (a sum type has no total per-field getter). Decoded then
-- mapped to 'Finding'.
data RawFinding = RawFinding
  { issue     :: LintIssue
  , criterion :: Text
  , note      :: Text
  }

issueCodec :: JSONCodec LintIssue
issueCodec = enum
  [ ("conflation", Conflation)
  , ("direction",  Direction)
  , ("redundancy", Redundancy)
  , ("vague",      Vague)
  ]

lintCodec :: JSONCodec [RawFinding]
lintCodec = list' $ object
  (RawFinding <$> field "issue"     (.issue)     issueCodec
              <*> field "criterion" (.criterion) str
              <*> field "note"      (.note)      str)

toFinding :: RawFinding -> LintFinding
toFinding r = Finding r.issue r.criterion r.note

-- | The lint messages, pure and testable (mirrors 'judgePrompt'). Lists
-- every label and asks for only clear violations of the four
-- anti-patterns; conservative by instruction.
lintPrompt :: [Text] -> [Message]
lintPrompt labels =
  [ Message System [text|
      You are a strict rubric linter. Report ONLY clear violations of the
      four checklist anti-patterns below. If a criterion is fine, say
      nothing about it; a clean checklist yields an empty array. Do not
      flag borderline cases.
      Respond ONLY with JSON matching this schema:
      ${schema}|]
  , Message User [text|
      Check each labelled criterion for these issues:
      - conflation: the criterion tests two things joined by "and"; split it.
      - direction: "yes" is not unambiguously the good outcome; rephrase.
      - redundancy: it is a near-duplicate of another criterion, so one
        failure double-counts under weights; merge them.
      - vague: the wording is unfalsifiable; nobody could agree on yes/no.

      Criteria:
      ${rendered}

      Output a JSON array of {"issue", "criterion", "note"} objects, one
      per clear violation. "criterion" is the offending label verbatim.|]
  ]
  where
    schema   = schemaText lintCodec
    rendered = T.intercalate "\n" [ "- " <> l | l <- labels ]

-- | Lint criterion labels with one holistic judge call (redundancy is
-- cross-criterion, so the judge sees the whole set) plus one repair. An
-- empty list short-circuits to [] with no call.
lintLabels :: (LLM :> es) => [Text] -> Eff es [LintFinding]
lintLabels [] = pure []
lintLabels labels = do
  raw <- complete msgs
  case decodeLLM lintCodec raw of
    Right fs -> pure (map toFinding fs)
    Left e1  -> do
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
      case decodeLLM lintCodec raw2 of
        Right fs -> pure (map toFinding fs)
        Left e2  -> pure [LintUnavailable e2.message]
  where
    schema = schemaText lintCodec
    msgs   = lintPrompt labels
```

Note: `RawFinding` and `Finding` share field labels under DuplicateRecordFields; the `(.issue)`/`(.criterion)`/`(.note)` getter sections resolve to `RawFinding` because the `object` applicative fixes that type. If GHC reports ambiguity, annotate the getters (`(.issue) :: RawFinding -> LintIssue`) and report.

- [ ] **Step 2: wire `Crucible.Eval`.** Add to the import block:

```haskell
import Crucible.Eval.Lint (LintFinding (..), LintIssue (..), lintLabels)
```

Add to the export list (after `groundingCheck`): `LintIssue (..)`, `LintFinding (..)`, `lintChecklist`. Define (near `groundingCheck`):

```haskell
-- | Advisory lint over a checklist's criterion labels: run the four
-- documented anti-pattern checks (conflation, direction, redundancy,
-- vague wording) as one judge call. Advisory only, never a gate. A clean
-- checklist returns []. Coverage is not checked (it needs your observed
-- failure modes, not the labels).
lintChecklist :: (LLM :> es) => [Criterion] -> Eff es [LintFinding]
lintChecklist = lintLabels . map (.label)
```

(`(.label)` on `Criterion` resolves because `lintChecklist`'s signature fixes the element type; `OverloadedRecordDot` is already enabled in Eval.hs.)

- [ ] **Step 3: tests in `test/Spec.hs`.** Add imports `import Crucible.Eval.Lint (LintIssue (..), LintFinding (..), lintPrompt)` and add `lintChecklist` to the existing `import Crucible.Eval (...)` list. Add after the calllog checks (end of the list):

```haskell
  -- crucible-ic0: rubric lint
  , check "lintPrompt: lists labels, the four checks, and the precision rule"
      (True, True, True, True, True, True)
      (case lintPrompt ["a and b", "clear one"] of
         [Message _ sys, Message _ usr] ->
           let hay = sys <> "\n" <> usr
           in ( T.isInfixOf "a and b" hay
              , T.isInfixOf "conflation" hay
              , T.isInfixOf "direction" hay
              , T.isInfixOf "redundancy" hay
              , T.isInfixOf "vague" hay
              , T.isInfixOf "clear violations" sys )
         _ -> (False, False, False, False, False, False))
  , check "lint: a reply with findings decodes to typed findings"
      [ Finding Conflation "mentions city and temp" "tests two things"
      , Finding Vague "good" "unfalsifiable" ]
      (runPureEff (runLLMScripted
        [ "[{\"issue\":\"conflation\",\"criterion\":\"mentions city and temp\",\"note\":\"tests two things\"},{\"issue\":\"vague\",\"criterion\":\"good\",\"note\":\"unfalsifiable\"}]" ]
        (lintChecklist [criterion "mentions city and temp", criterion "good"])))
  , check "lint: a clean checklist yields no findings"
      ([] :: [LintFinding])
      (runPureEff (runLLMScripted ["[]"] (lintChecklist [criterion "avoids jargon"])))
  , check "lint: empty checklist short-circuits with no judge call"
      ([] :: [LintFinding])
      (runPureEff (runLLMScripted [] (lintChecklist [])))
  , check "lint: feeds labels not weights to the prompt"
      (True, False)
      (case lintPrompt (map (.label) [Criterion "alpha" 7]) of
         [_, Message _ usr] -> (T.isInfixOf "alpha" usr, T.isInfixOf "7" usr)
         _ -> (False, True))
  , check "lint: unparseable reply after repair returns LintUnavailable"
      True
      (case runPureEff (runLLMScripted ["junk", "junk2"] (lintChecklist [criterion "x"])) of
         [LintUnavailable m] -> not (T.null m)
         _                   -> False)
  , check "lint: an unknown issue tag drives the repair re-prompt"
      [Finding Direction "x" "fixed"]
      (runPureEff (runLLMScripted
        [ "[{\"issue\":\"bogus\",\"criterion\":\"x\",\"note\":\"n\"}]"
        , "[{\"issue\":\"direction\",\"criterion\":\"x\",\"note\":\"fixed\"}]" ]
        (lintChecklist [criterion "x"])))
```

Notes: `criterion` (the smart constructor, weight 1) and `Criterion "alpha" 7` both come from the existing `Crucible.Eval` import. The "feeds labels not weights" check relies on the weight `7` not appearing in any label text (it does not) and the rendered `7.0` not being present. If `7` somehow renders (it should not; only labels are interpolated), the check fails honestly; investigate rather than weaken it.

- [ ] **Step 4: build + suite.** Build exit 0; `1 test suite(s) passed`, 280 ok (273 + 7).

- [ ] **Step 5: commit.**

```bash
git add src/Crucible/Eval/Lint.hs src/Crucible/Eval.hs test/Spec.hs
git commit -m "$(printf 'feat(eval): executable rubric lint (lintChecklist)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: demo + live smoke + docs

**Files:**
- Modify: `app/Main.hs`
- Modify: `docs/evals.md`

- [ ] **Step 1: demo.** Add `lintChecklist`, `LintFinding (..)`, `LintIssue (..)` to the existing `import Crucible.Eval (...)` list in `app/Main.hs`. In the Anthropic-key-gated block, after the eval report demo (the `TIO.putStrLn (renderReport evalRep)` line), add:

```haskell
      -- Rubric lint: an advisory pass over a deliberately flawed checklist.
      let renderFinding (Finding i c n) = T.pack (show i) <> " '" <> c <> "': " <> n
          renderFinding (LintUnavailable m) = "unavailable: " <> m
      findings <- runEff (Anthropic.run cfg (lintChecklist
        [ criterion "mentions the city and the temperature"
        , criterion "uses appropriate language"
        ]))
      mapM_ (\f -> TIO.putStrLn ("lint: " <> renderFinding f)) findings
```

(Adapt indentation to the surrounding block; `cfg`, `criterion`, `TIO`, and `T` are already in scope there.)

- [ ] **Step 2: build + live smoke.**

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: the existing demo output plus one or more `lint: ` lines, including a `lint: Conflation 'mentions the city and the temperature': ...` and a `lint: Direction 'uses appropriate language': ...` (the model should flag both; either alone still proves the path); exit 0. One judge call.

- [ ] **Step 3: docs.** In `docs/evals.md` "## Lint your rubric" (line ~188), keep the four conceptual bullets, then add an executable subsection after them:

- State the walk is now executable via `lintChecklist`, advisory only, never a gate; a clean checklist returns `[]`.
- Show the signature and the types:

```haskell
lintChecklist :: (LLM :> es) => [Criterion] -> Eff es [LintFinding]

data LintIssue = Conflation | Direction | Redundancy | Vague
data LintFinding
  = Finding { issue :: LintIssue, criterion :: Text, note :: Text }
  | LintUnavailable Text
```

- Note the high-precision stance (only clear violations are flagged) and that `LintUnavailable` distinguishes a failed lint call from a clean checklist.
- Keep coverage as the one check it cannot automate: it needs the failures you have actually observed, not the labels, so it stays a manual step.

House style STRICT: `grep -n $'—\|–' docs/evals.md` must stay empty; no hype words; never mention a project called "manifest".

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/evals.md
git commit -m "$(printf 'docs(site)+demo: lintChecklist, proven live\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: merge + publish + close

**Files:** none.

- [ ] **Step 1: full suite.** `... zinc test` shows `1 test suite(s) passed`, 280 ok.
- [ ] **Step 2: merge + push.** Via `superpowers:finishing-a-development-branch` (the user historically picks "merge back to master locally"); after merge: suite on master, `git push`, Pages build reaches `built`.
- [ ] **Step 3: close the bead.**

```bash
bd close crucible-ic0 --reason="Shipped: Crucible.Eval.Lint (LintIssue/LintFinding, lintPrompt, lintLabels) + lintChecklist in Eval, the four-check advisory walk (conflation/direction/redundancy/vague) as one judge call with codec+repair, high-precision, LintUnavailable on parse failure, 7 hermetic tests, live flawed-checklist proof, evals.md executable-lint subsection. Coverage check and improve_rubric loop remain non-goals."
```

---

## Self-Review

**1. Spec coverage:** Leaf module with LintIssue/LintFinding/lintPrompt/lintLabels, one call + repair, no Eval dependency -> Task 1 Step 1 (mirrors Grounding). lintChecklist = lintLabels . map (.label) + re-exports -> Step 2. Four checks only, coverage excluded, high precision, empty short-circuit, LintUnavailable on failure -> encoded in the prompt + lintLabels + tests. Tests map one-to-one onto the spec's testing list (pure prompt, findings decode, clean [], empty short-circuit, labels-not-weights, unavailable, unknown-tag-repair) -> Step 3. Demo over a flawed checklist -> Task 2 Steps 1-2. Docs executable subsection keeping the four bullets and coverage-stays-manual -> Task 2 Step 3. Non-goals absent everywhere. ✅

**2. Placeholder scan:** none; the demo's `renderFinding` is defined inline, every code step is complete. ✅

**3. Type consistency:** `lintLabels :: [Text] -> Eff es [LintFinding]` matches `lintChecklist = lintLabels . map (.label)` over `[Criterion]`; `Finding` constructed positionally everywhere (demo, tests) so no field-selector ambiguity; `RawFinding` is internal and decode-only, `toFinding` bridges it to `Finding`; `issueCodec` enum tags (`conflation`/`direction`/`redundancy`/`vague`) match the JSON in the decode tests; `LintUnavailable` constructed only on repair failure, matched in the unavailable test. Check counts: 273 + 7 = 280; the close message says 7 tests. ✅
