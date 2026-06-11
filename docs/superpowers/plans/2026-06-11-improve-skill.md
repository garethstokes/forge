# Structured Instructions + improveSkill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the opaque instruction with `Instruction i {preamble, task, constraints}`, land the three deferred prompt tweaks, and ship `improveSkill`, a testSkill-driven hill-climb that revises the two slots via a reflector skill.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-11-improve-skill-design.md`. Task 1 reworks `Crucible.Skill` (type + assembly + tweaks) behind the unchanged `skill` builder; Task 2 adds the leaf module `Crucible.Skill.Improve`; Task 3 is docs + demo + live smoke; Task 4 merges.

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec, neat-interpolation. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). On exit 137 retry once; second 137 = BLOCKED. Judge success by exit status or the "1 test suite(s) passed" line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/improve-skill` from master; work in place, no worktrees.
- House style: prefix-free fields, `OverloadedRecordDot`, `NoFieldSelectors` (record UPDATE syntax still works; only selector functions are suppressed), prompts via `[text| |]`. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Current `src/Crucible/Skill.hs`: `Skill {name, instruction :: i -> Text, input, output, retries, tests, examples}`; `skill`, `skillWith` does NOT exist yet; `withRetries/withTests/withExamples/examplesFromTests/withReasoning`; `prompt` renders System + example pairs + live User message; `call` (retry restates schema); `testSkill`.
- `testSkill render sk :: Eff es (Report i (Either DecodeError o))`; `Report {results, passRate, meanScore}`; `Result {case', output, score}`; `Case {input, name, expect}`; `Score {value, rationale, votes, dissent}`. `DecodeError` has `message`/`raw`.
- `Crucible.Codec.Generic` gives `HasCodec(codec)`/`genericCodec`; a `Maybe`-free two-Text record derives an object codec with both fields required.
- Chained record-dot then application needs parens for clarity: write `(sk.instruction.task) i'`.
- test/Spec.hs has `classifyFn = skill "classify" C.str C.str (\s -> "Classify the sentiment of: " <> s)` and prompt checks that assert by `T.isPrefixOf`/`T.isInfixOf` (they survive the tweaks); the few-shot pair check asserts message COUNT and infix content (survives).

---

### Task 1: Instruction type, slots, prompt tweaks

**Files:**
- Modify: `src/Crucible/Skill.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: the type and builders.** In `src/Crucible/Skill.hs`, add `Instruction (..)`, `skillWith`, `withPreamble`, `withConstraints` to the export list (after `skill`). Replace the record/builder section:

```haskell
-- | A skill's instruction, structured so tooling can revise the prompt
-- around a fixed task. 'preamble' renders before the task; 'constraints'
-- renders after the input (instructions near the end are followed most
-- reliably). Both default to empty and are the slots 'Crucible.Skill.Improve.improveSkill'
-- mutates; 'task' is the core instruction and is never machine-edited.
data Instruction i = Instruction
  { preamble    :: Text
  , task        :: i -> Text
  , constraints :: Text
  }

data Skill i o = Skill
  { name        :: Text          -- ^ for introspection / evals
  , instruction :: Instruction i -- ^ preamble + task + constraints
  , input       :: JSONCodec i   -- ^ used to render the input value into the prompt
  , output      :: JSONCodec o   -- ^ schema injection + tolerant decode
  , retries     :: Int           -- ^ decode-failure retries
  , tests       :: [Case i o]    -- ^ attached test cases; run with 'testSkill'
  , examples    :: [(i, o)]      -- ^ few-shot exchanges rendered into the prompt
  }

-- | Construct a 'Skill' from a bare task function (empty preamble and
-- constraints); @retries@ defaults to 2, @tests@ and @examples@ to none.
skill :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> Skill i o
skill n inC outC instr = skillWith n inC outC (Instruction "" instr "")

-- | 'skill' with all three instruction parts declared.
skillWith :: Text -> JSONCodec i -> JSONCodec o -> Instruction i -> Skill i o
skillWith n inC outC ins =
  Skill { name = n, instruction = ins, input = inC, output = outC
        , retries = 2, tests = [], examples = [] }

-- | Replace the instruction's preamble (rendered before the task).
withPreamble :: Text -> Skill i o -> Skill i o
withPreamble p fn = let ins = fn.instruction in fn { instruction = ins { preamble = p } }

-- | Replace the instruction's constraints (rendered after the input).
withConstraints :: Text -> Skill i o -> Skill i o
withConstraints c fn = let ins = fn.instruction in fn { instruction = ins { constraints = c } }
```

- [ ] **Step 2: prompt assembly with the tweaks.** Replace `prompt`'s `systemMsg`/`userMsg` (the surrounding structure, `pair`, and `call` stay as they are):

```haskell
    systemMsg = Message System [text|
      Respond ONLY with JSON matching this schema:
      ${schema}
      Your reply is parsed by a machine; any text outside the JSON is an error.|]
    userMsg i' =
      let pre      = block sk.instruction.preamble
          task'    = (sk.instruction.task) i'
          rendered = jsonText (toJSONVia sk.input i')
          cons     = block sk.instruction.constraints
      in Message User [text|
      ${pre}${task'}

      <input>
      ${rendered}
      </input>

      ${cons}Respond with JSON only; your reply is parsed by a machine.|]
    block t = if T.null t then "" else t <> "\n\n"
```

(`block` gives empty slots zero residue: the line `${pre}${task'}` renders as just the task when the preamble is empty, and `${cons}Respond ...` as just the reminder when constraints are empty.)

- [ ] **Step 3: build.** `nix develop . --command timeout -s KILL 300 zinc build` → exit 0. The only other reader of `instruction` is `prompt` itself; `app/Main.hs` and all fixtures construct via `skill`, which is signature-stable.

- [ ] **Step 4: tests.** In `test/Spec.hs`, extend the Crucible.Skill import with `Instruction (..), skillWith, withPreamble, withConstraints`. Add after the existing prompt checks:

```haskell
  -- improve-skill cycle: structured instruction + prompt tweaks
  , check "prompt: slot-less user message has the exact tweaked shape"
      (Just ("Classify the sentiment of: hi\n\n<input>\n\"hi\"\n</input>\n\nRespond with JSON only; your reply is parsed by a machine."))
      (case prompt classifyFn "hi" of
         [_, Message User u] -> Just u
         _                   -> Nothing)
  , check "prompt: system message keeps its first line and gains the machine line"
      (True, True)
      (case prompt classifyFn "hi" of
         (Message System s : _) ->
           ( T.isPrefixOf "Respond ONLY with JSON matching this schema:" s
           , T.isInfixOf "Your reply is parsed by a machine; any text outside the JSON is an error." s )
         _ -> (False, False))
  , check "prompt: preamble renders first, constraints render after the input"
      True
      (case prompt (withPreamble "Be terse." (withConstraints "One word only." classifyFn)) "hi" of
         [_, Message User u] ->
           T.isPrefixOf "Be terse.\n\nClassify the sentiment of: hi" u
             && T.isInfixOf "</input>\n\nOne word only.\n\nRespond with JSON only" u
         _ -> False)
  , check "skillWith: carries all three instruction parts"
      True
      (case prompt (skillWith "s" C.str C.str (Instruction "P" ("Task: " <>) "C")) "x" of
         [_, Message User u] ->
           T.isPrefixOf "P\n\nTask: x" u && T.isInfixOf "\nC\n\nRespond with JSON only" u
         _ -> False)
  , check "prompt: few-shot pairs inherit the tweaked template"
      True
      (case prompt (withExamples [("I love it", "positive")] classifyFn) "meh" of
         (_ : Message User u : _) -> T.isInfixOf "<input>\n\"I love it\"\n</input>" u
         _ -> False)
```

- [ ] **Step 5: run the suite.** `nix develop . --command timeout -s KILL 300 zinc test` → `1 test suite(s) passed` (all existing prefix/infix prompt checks must still pass; only these five are new).

- [ ] **Step 6: commit.**

```bash
git add src/Crucible/Skill.hs test/Spec.hs
git commit -m "$(printf 'feat(skill)!: structured Instruction (preamble/task/constraints) + prompt tweaks\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: `Crucible.Skill.Improve`

**Files:**
- Create: `src/Crucible/Skill/Improve.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: create `src/Crucible/Skill/Improve.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | A testSkill-driven instruction optimizer (a GEPA-lite hill-climb): each
-- round, a reflector skill reads the failing cases (full original prompts,
-- outputs, and score rationales, re-injected every round) and proposes
-- revised preamble and constraints; the candidate is kept only on a strict
-- meanScore improvement over the attached test cases.
--
-- Honesty rails, not optional: optimizing against an LLM judge is Goodhart
-- territory. Calibrate the judge ('Crucible.Eval.Calibrate.calibrate',
-- kappa above 0.6) BEFORE trusting the optimizer's gains; keep held-out
-- cases OUT of the skill's tests and verify the winner against them by
-- hand ('improveSkill' does no splitting); and review the accepted slots
-- before shipping them, because they are text the reflector wrote.
--
-- Cost per round: one full 'testSkill' run (cases x judge calls, doubled
-- by verdict repairs) plus one reflection call.
module Crucible.Skill.Improve
  ( ImproveStep (..)
  , improveSkill
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import GHC.Generics (Generic)
import NeatInterpolation (text)

import Crucible.Codec (str)
import Crucible.Codec.Generic (HasCodec (codec), genericCodec)
import Crucible.Decode (DecodeError (..))
import Crucible.Eval (Case (..), Report (..), Result (..), Score (..))
import Crucible.LLM (LLM, Message (..), Role (..))
import Crucible.Skill
  ( Instruction (..), Skill (..), call, prompt, skill, testSkill
  , withConstraints, withPreamble )

-- | The reflector's proposal: new values for the two mutable slots.
data Revision = Revision { preamble :: Text, constraints :: Text }
  deriving (Show, Generic)

instance HasCodec Revision where codec = genericCodec

-- | One optimizer round's record: what was proposed, what it scored, and
-- whether it was kept. A reflector decode failure records a rejected step
-- carrying the CURRENT slots and scores (there is no proposal to show).
data ImproveStep = ImproveStep
  { round'      :: Int
  , accepted    :: Bool
  , passRate    :: Double
  , meanScore   :: Double
  , preamble    :: Text
  , constraints :: Text
  }
  deriving (Eq, Show)

-- | The internal revision-proposing skill.
reflector :: Skill Text Revision
reflector = skill "reflect-instruction" str codec $ \digest -> [text|
  You are revising the prompt of an LLM skill whose test cases are failing.
  You may ONLY rewrite the skill's preamble (text rendered before the task)
  and constraints (text rendered after the input). The task itself is fixed
  and shown inside each failing prompt below.
  Study the failures, then propose a revised preamble and constraints that
  make the failing cases pass without contradicting the task.

  ${digest}|]

-- | Hill-climb the skill's preamble and constraints against its attached
-- test cases for up to @rounds@ reflection attempts. Returns the best
-- skill found and the chronological step history. Stops early when every
-- case passes. An empty test list returns immediately.
improveSkill :: (Eq o, LLM :> es)
             => Int -> (o -> Text) -> Skill i o -> Eff es (Skill i o, [ImproveStep])
improveSkill rounds render sk0
  | null sk0.tests = pure (sk0, [])
  | otherwise = do
      rep0 <- testSkill render sk0
      go 1 sk0 rep0.meanScore rep0.passRate (failuresOf rep0) []
  where
    go k best bestMean bestPass fails steps
      | k > rounds || null fails = pure (best, reverse steps)
      | otherwise = do
          r <- call reflector (digest best fails)
          case r of
            Left _ ->
              go (k + 1) best bestMean bestPass fails
                (ImproveStep k False bestPass bestMean
                   best.instruction.preamble best.instruction.constraints
                 : steps)
            Right rev -> do
              let cand = withPreamble rev.preamble (withConstraints rev.constraints best)
              repC <- testSkill render cand
              let step acc = ImproveStep k acc repC.passRate repC.meanScore
                               rev.preamble rev.constraints
              if repC.meanScore > bestMean
                then go (k + 1) cand repC.meanScore repC.passRate
                       (failuresOf repC) (step True : steps)
                else go (k + 1) best bestMean bestPass fails (step False : steps)

    failuresOf rep =
      [ (c, out, sc)
      | Result{case' = c, output = out, score = sc} <- rep.results
      , sc.value < 1.0
      ]

    digest best fails = T.intercalate "\n\n" $
      [ "Current preamble (may be empty):\n" <> best.instruction.preamble
      , "Current constraints (may be empty):\n" <> best.instruction.constraints
      ]
        ++ concat
          [ [ "Failing case: " <> c.name
            , "Prompt sent:\n" <> renderMsgs (prompt best c.input)
            , "Output:\n" <> either (\e -> "decode error: " <> e.message) render out
            , "Score rationale:\n" <> sc.rationale
            ]
          | (c, out, sc) <- fails
          ]

    renderMsgs ms =
      T.intercalate "\n" [roleLabel r <> ": " <> c | Message r c <- ms]
    roleLabel System    = "System"
    roleLabel User      = "User"
    roleLabel Assistant = "Assistant"
    roleLabel Tool      = "Tool"
```

- [ ] **Step 2: build.** `nix develop . --command timeout -s KILL 300 zinc build` → exit 0.

- [ ] **Step 3: tests.** Add to `test/Spec.hs` (`import Crucible.Skill.Improve (ImproveStep (..), improveSkill)`). The reflector is built with `skill`, so its retries default to 2 (a junk reflection burns 3 replies). The Revision JSON keys are `preamble`/`constraints`; both required.

```haskell
  -- improveSkill (hermetic hill-climb)
  , check "improveSkill: accepted revision returns improved skill + step"
      (True, [ImproveStep 1 True 1.0 1.0 "Always answer GOOD." "Reply with GOOD only."])
      (let sk = withTests [Case ("in" :: Text) "c" (Exactly ("GOOD" :: Text))]
                  (withRetries 0 (skill "s" C.str C.str ("Echo: " <>)))
           (best, steps) = runPureEff (runLLMScripted
             [ "\"BAD\""                                                        -- baseline fails
             , "{\"preamble\":\"Always answer GOOD.\",\"constraints\":\"Reply with GOOD only.\"}"
             , "\"GOOD\""                                                       -- candidate passes
             ]
             (improveSkill 1 id sk))
       in (best.instruction.preamble == "Always answer GOOD.", steps))
  , check "improveSkill: no improvement -> rejected, original slots kept"
      (True, [False])
      (let sk = withTests [Case ("in" :: Text) "c" (Exactly ("GOOD" :: Text))]
                  (withRetries 0 (skill "s" C.str C.str ("Echo: " <>)))
           (best, steps) = runPureEff (runLLMScripted
             [ "\"BAD\""
             , "{\"preamble\":\"P\",\"constraints\":\"C\"}"
             , "\"BAD\""                                                        -- candidate also fails
             ]
             (improveSkill 1 id sk))
       in (best.instruction.preamble == "", map (.accepted) steps))
  , check "improveSkill: reflector junk burns the round, loop survives"
      [False]
      (let sk = withTests [Case ("in" :: Text) "c" (Exactly ("GOOD" :: Text))]
                  (withRetries 0 (skill "s" C.str C.str ("Echo: " <>)))
           (_, steps) = runPureEff (runLLMScripted
             [ "\"BAD\"", "j1", "j2", "j3" ]                                    -- reflector retries 2 = 3 replies
             (improveSkill 1 id sk))
       in map (.accepted) steps)
  , check "improveSkill: empty tests -> immediate return, zero calls"
      (True, "leftover")
      (runPureEff (runLLMScripted ["leftover"]
        (do (_, steps) <- improveSkill 3 id (skill "s" C.str (C.str :: JSONCodec Text) ("Echo: " <>))
            extra <- complete []
            pure (null steps, extra))))
  , check "improveSkill: all-passing baseline -> no reflection call"
      (True, "leftover")
      (runPureEff (runLLMScripted ["\"GOOD\"", "leftover"]
        (do (_, steps) <- improveSkill 3 id
              (withTests [Case ("in" :: Text) "c" (Exactly ("GOOD" :: Text))]
                 (withRetries 0 (skill "s" C.str C.str ("Echo: " <>))))
            extra <- complete []
            pure (null steps, extra))))
```

- [ ] **Step 4: run the suite.** `... zinc test` → `1 test suite(s) passed` (five new ok lines). If the first check's `ImproveStep` equality fails on Double comparison, the values are exact (0.0 and 1.0 in binary); recheck reply accounting before touching expectations, and report plan/behaviour mismatches as DONE_WITH_CONCERNS.

- [ ] **Step 5: commit.**

```bash
git add src/Crucible/Skill/Improve.hs test/Spec.hs
git commit -m "$(printf 'feat(skill): improveSkill, a testSkill-driven instruction hill-climb\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: docs + demo + live smoke

**Files:**
- Modify: `docs/typed-functions.md`
- Modify: `app/Main.hs`

- [ ] **Step 1: docs.** Read the final `src/Crucible/Skill.hs` and `Skill/Improve.hs` first; mirror signatures exactly. In `docs/typed-functions.md`:
  - "Skill and skill": introduce `Instruction {preamble, task, constraints}`, note `skill` wraps a bare function with empty slots, show `skillWith`/`withPreamble`/`withConstraints`.
  - "Calling a typed skill" + "Schema injection": update the described prompt shape for the System machine line, the `<input>` delimiters, and the trailing reminder.
  - "Composing prompts": one added sentence noting transformers still wrap the task function; the slots are the machine-editable layer around it.
  - New section "Improving a skill" (after "Test cases on the skill"): the `improveSkill` signature, the loop in three sentences, the per-round cost, and the honesty rails verbatim in spirit: calibrate the judge first (kappa above 0.6), keep holdouts out of `tests` and check the winner against them by hand, review accepted slots before shipping.
  - House style: no emdashes/endashes, no hype words, no manifest mentions; `grep -n '—\|–' docs/typed-functions.md` empty.

- [ ] **Step 2: demo.** In `app/Main.hs` (imports: `Crucible.Skill.Improve (improveSkill)`; `Crucible.Eval` import already carries `Case (..)`/`Expectation (..)`), after the eval section:

```haskell
      -- improveSkill: one live reflection round over a deliberately weak skill.
      let weak = withTests [Case ("the meeting is at 3pm tomorrow" :: T.Text) "extracts-time" (Exactly ("3pm" :: T.Text))]
                   (skill "extract-time" str str (\s -> [text|What time? ${s}|]))
      (_, improveSteps) <- runEff (Anthropic.run cfg (improveSkill 1 id weak))
      TIO.putStrLn ("improveSkill: " <> T.pack (show (length improveSteps)) <> " step(s) "
                    <> T.pack (show [s.accepted | s <- improveSteps]))
```

(`withTests` is already imported in Main? Check; add to the Crucible.Skill import if not. Live nondeterminism is fine: zero steps means the weak skill passed its case at baseline; one step either way proves the reflector round-trips.)

- [ ] **Step 3: build + live smoke.** (Keys in `.env`, gitignored; NEVER print them.)

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 300 .zinc/build/crucible-anthropic'
```

Expected: existing demo output unchanged in substance (the prompt tweaks ride along invisibly), plus one `improveSkill: ...` line; exit 0.

- [ ] **Step 4: commit.**

```bash
git add docs/typed-functions.md app/Main.hs
git commit -m "$(printf 'docs(site)+demo: structured instructions and improveSkill\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: merge + publish

**Files:** none.

- [ ] **Step 1: full suite.** `... zinc test` → `1 test suite(s) passed`.
- [ ] **Step 2: merge + push.** Via `superpowers:finishing-a-development-branch` (the user historically picks "merge back to master locally"); after merge: suite on master, `git push`, Pages build reaches `built`. Update the tracker: the deferred remainder of the prompt-performance research is now done except schema field docs (note why on whatever issue tracks it, or `bd remember`).

---

## Self-Review

**1. Spec coverage:** Instruction + skill/skillWith/withPreamble/withConstraints → Task 1 Step 1. Prompt assembly + three tweaks + empty-slot no-residue + examples inheriting → Step 2 + checks. Improve module (Revision via genericCodec, reflector via `skill`, digest with originals re-injected, strict meanScore acceptance, decode-failure round semantics, budget/early-stop/empty-tests) → Task 2 with five hermetic checks covering every spec test bullet (exact-shape User text, system lines, slot order, builder compat via skillWith check, accepted/rejected/junk/empty/all-passing). Honesty rails in module haddock (Task 2 Step 1) + manual (Task 3). Demo + live smoke → Task 3. Non-goals absent. ✅

**2. Placeholder scan:** none; docs step is the established content-brief pattern, all code steps complete. ✅

**3. Type consistency:** `Instruction i {preamble, task, constraints}` consistent across Tasks 1-3; `improveSkill :: Int -> (o -> Text) -> Skill i o -> Eff es (Skill i o, [ImproveStep])` matches spec/tests/demo; `ImproveStep` field order (round', accepted, passRate, meanScore, preamble, constraints) matches the positional construction in the first Task 2 check; reflector retries default (2) matches the junk test's 3-reply accounting; `(sk.instruction.task) i'` parenthesization consistent. ✅
