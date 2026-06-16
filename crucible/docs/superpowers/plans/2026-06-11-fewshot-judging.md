# Few-Shot Calibrated Judging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feed verdict-balanced labelled examples into the judge prompt (`JudgeOpts`/`JudgeExample`/`balanceExamples`/`judgePrompt`), generalize the eval entry points to `judgeWith`/`runEvalWith`, and add `calibrateWith` with a structural holdout split.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-11-fewshot-judging-design.md` (tracker `crucible-tfu`). Task 1 is the atomic green gate (Judge plumbing + Eval generalization + Calibrate report fields + caller updates); Task 2 adds the new tests; Task 3 is docs; Task 4 merges. No demo change.

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). On exit 137 retry once; second 137 = BLOCKED. Judge success by exit status or the "1 test suite(s) passed" line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/fewshot-judging` from master; work in place, no worktrees.
- House style: prefix-free fields, `OverloadedRecordDot`, `DuplicateRecordFields`, `NoFieldSelectors` (record update syntax still works). Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Current shapes you will touch:
  - `src/Crucible/Eval/Judge.hs`: `judgeOnce :: Text -> Text -> Eff es (Either JudgeError Verdict)` builds its messages inline with `[text| |]` (`Rubric: ${rubric}` newline `Output to grade: ${graded}`); `vote :: Bool -> Int -> Text -> Text -> Eff es VoteOutcome`.
  - `src/Crucible/Eval.hs`: `judgeN n render rubric actual = voteScore (n <= 1) <$> vote True n rubric (render actual)`; `scoreN` dispatches Rubric/Checklist/Grounded; `checklistScore n` calls `vote True n` per criterion; `runEvalN n` threads n.
  - `src/Crucible/Eval/Grounding.hs`: `groundingOutcome` calls `vote True n` per claim.
  - `src/Crucible/Eval/Calibrate.hs`: `calibrate n ...` calls `vote False n` per labelled case; `CalibrationReport` has six fields ending in `judgeErrors`; three Spec.hs checks construct it positionally.
- The suite passes with 212 checks.

---

### Task 1: Judge plumbing + Eval generalization + report fields (atomic green gate)

**Files:**
- Modify: `src/Crucible/Eval/Judge.hs`
- Modify: `src/Crucible/Eval.hs`
- Modify: `src/Crucible/Eval/Grounding.hs` (one call site)
- Modify: `src/Crucible/Eval/Calibrate.hs`
- Modify: `test/Spec.hs` (ONLY the existing CalibrationReport constructions; no new tests yet)

- [ ] **Step 1: new types and helpers in `src/Crucible/Eval/Judge.hs`.** Add to the export list: `JudgeExample (..), JudgeOpts (..), defaultJudgeOpts, balanceExamples, balanceBy, judgePrompt`. Add imports `Data.Bits (shiftL, shiftR, xor)`, `Data.List (partition, sortOn)`. Add:

```haskell
-- | A labelled output shown to the judge as a worked example for the
-- rubric under test. Verdicts always render; the critique renders only
-- when present.
data JudgeExample = JudgeExample
  { rendered :: Text
  , pass     :: Bool
  , why      :: Maybe Text
  }
  deriving (Eq, Show)

-- | Knobs for a judged evaluation. Future judge options (abstain policy,
-- panels) extend this record rather than adding function variants.
data JudgeOpts = JudgeOpts
  { votes    :: Int             -- ^ samples per judgement (odd; 1 = single call)
  , examples :: [JudgeExample]  -- ^ few-shot examples for Rubric judging
  }
  deriving (Eq, Show)

defaultJudgeOpts :: JudgeOpts
defaultJudgeOpts = JudgeOpts { votes = 1, examples = [] }

-- | Deterministic seeded shuffle (xorshift keys; no extra dependencies).
shuffleSeeded :: Int -> [a] -> [a]
shuffleSeeded seed xs = map snd (sortOn fst (zip keys xs))
  where
    keys = take (length xs) (drop 1 (iterate step (step (seed * 2654435761 + 1))))
    step x = let a = x `xor` (x `shiftL` 13)
                 b = a `xor` (a `shiftR` 7)
             in b `xor` (b `shiftL` 17)

-- | Pick n items, roughly balanced between the two classes of the
-- predicate, deterministically for a given seed: shuffle each class, then
-- alternate picks (predicate-true first); when one class runs out, fill
-- from the other. n over supply returns everything (balanced-first order);
-- n <= 0 returns [].
balanceBy :: (x -> Bool) -> Int -> Int -> [x] -> [x]
balanceBy p seed n xs = take (max 0 n) (interleave yes' no')
  where
    (yes, no) = partition p xs
    yes' = shuffleSeeded seed yes
    no'  = shuffleSeeded (seed + 1) no
    interleave (a : as) (b : bs) = a : b : interleave as bs
    interleave as []             = as
    interleave [] bs             = bs

-- | 'balanceBy' on the example's verdict: roughly equal pass and fail
-- examples, so the judge cannot infer a base-rate prior.
balanceExamples :: Int -> Int -> [JudgeExample] -> [JudgeExample]
balanceExamples = balanceBy (.pass)

-- | The judge's messages, pure and testable (mirrors 'Crucible.Skill.prompt').
-- With no examples the user message is byte-identical to the plain
-- two-line form. Assembled by concatenation: conditional blocks do not
-- belong in quasiquotes.
judgePrompt :: [JudgeExample] -> Text -> Text -> [Message]
judgePrompt exs rubric graded =
  [ judgeSystem
  , Message User $ T.concat $
      ["Rubric: " <> rubric <> "\n"]
        ++ exampleBlock
        ++ ["Output to grade: " <> graded]
  ]
  where
    exampleBlock
      | null exs = []
      | otherwise =
          "\nExamples of past verdicts for this rubric:\n\n"
            : map one exs
    one e =
      "Example output:\n" <> e.rendered
        <> "\nVerdict: " <> (if e.pass then "pass" else "fail")
        <> maybe "" ("\nWhy: " <>) e.why
        <> "\n\n"
```

- [ ] **Step 2: thread examples through `judgeOnce` and `vote`.** `judgeOnce` gains the example list and builds its messages with `judgePrompt` (the repair re-prompt is unchanged: it appends to `msgs`):

```haskell
judgeOnce :: (LLM :> es) => [JudgeExample] -> Text -> Text -> Eff es (Either JudgeError Verdict)
judgeOnce exs rubric graded = do
  let msgs = judgePrompt exs rubric graded
  ...   -- body unchanged from today except msgs comes from judgePrompt
```

`vote` takes the opts record (early-stop flag unchanged):

```haskell
vote :: (LLM :> es) => Bool -> JudgeOpts -> Text -> Text -> Eff es VoteOutcome
vote earlyStop opts rubric graded = go n' (0, 0) (Nothing, Nothing) ""
  where
    n' = max 1 opts.votes
    ...  -- body unchanged except the judgeOnce call becomes:
    --   r <- judgeOnce opts.examples rubric graded
```

(The old `[text| |]` user-message construction in `judgeOnce` is deleted; `judgeSystem` stays exactly as it is and is used by `judgePrompt`.)

- [ ] **Step 3: generalize `src/Crucible/Eval.hs`.** Import and re-export `JudgeExample (..), JudgeOpts (..), defaultJudgeOpts` from Judge (add all three to Eval's import and export lists). Add `judgeWith`/`runEvalWith`/`scoreWith`; redefine the existing functions as specializations:

```haskell
-- | LLM-as-judge with explicit options (votes, few-shot examples).
judgeWith :: (LLM :> es) => JudgeOpts -> (a -> Text) -> Text -> a -> Eff es Score
judgeWith opts render rubric actual =
  voteScore (opts.votes <= 1) <$> vote True opts rubric (render actual)

judge :: (LLM :> es) => (a -> Text) -> Text -> a -> Eff es Score
judge = judgeWith defaultJudgeOpts

judgeN :: (LLM :> es) => Int -> (a -> Text) -> Text -> a -> Eff es Score
judgeN n = judgeWith defaultJudgeOpts { votes = n }

-- | Score one output with explicit judge options. Examples feed 'Rubric'
-- judging only; 'Checklist' criteria and 'Grounded' claims take the vote
-- count but ignore examples (each is its own micro-rubric).
scoreWith :: (Eq a, LLM :> es) => JudgeOpts -> (a -> Text) -> Expectation a -> a -> Eff es Score
scoreWith opts render exp_ actual = case exp_ of
  Exactly e    -> pure (score (ind (actual == e)) (if actual == e then "exact match" else "mismatch"))
  Predicate p  -> pure (score (ind (p actual)) (if p actual then "predicate held" else "predicate failed"))
  Rubric r     -> judgeWith opts render r actual
  Checklist cs -> checklistScore opts.votes render cs actual
  Grounded ev  -> groundingScore <$> groundingOutcome opts.votes ev (render actual)
  where ind b = if b then 1.0 else 0.0

scoreM :: (Eq a, LLM :> es) => (a -> Text) -> Expectation a -> a -> Eff es Score
scoreM = scoreWith defaultJudgeOpts

scoreN :: (Eq a, LLM :> es) => Int -> (a -> Text) -> Expectation a -> a -> Eff es Score
scoreN n = scoreWith defaultJudgeOpts { votes = n }

runEvalWith :: (Eq a, LLM :> es)
            => JudgeOpts -> (a -> Text) -> (i -> Eff es a) -> [Case i a]
            -> Eff es (Report i a)
-- body of today's runEvalN with `scoreN n` replaced by `scoreWith opts`

runEval :: (Eq a, LLM :> es) => (a -> Text) -> (i -> Eff es a) -> [Case i a] -> Eff es (Report i a)
runEval = runEvalWith defaultJudgeOpts

runEvalN :: (Eq a, LLM :> es) => Int -> (a -> Text) -> (i -> Eff es a) -> [Case i a] -> Eff es (Report i a)
runEvalN n = runEvalWith defaultJudgeOpts { votes = n }
```

`checklistScore` keeps its `Int` first argument; inside, its per-criterion call becomes `vote True defaultJudgeOpts { votes = n } ...`. Export `judgeWith`, `runEvalWith` (and keep every existing export).

- [ ] **Step 4: update the other `vote` callers.** `src/Crucible/Eval/Grounding.hs`: import `defaultJudgeOpts`/`JudgeOpts (..)` from Judge; its per-claim call becomes `vote True defaultJudgeOpts { votes = n } ...`. `src/Crucible/Eval/Calibrate.hs`: see Step 5 (it is rewritten anyway).

- [ ] **Step 5: `calibrateWith` and the report fields in `src/Crucible/Eval/Calibrate.hs`.** Add `exampleCount :: Int` and `measured :: Int` as the LAST two fields of `CalibrationReport`. Add `calibrateWith` to the exports; import `JudgeExample (..), JudgeOpts (..), balanceBy` from Judge.

```haskell
-- | 'calibrate' with few-shot examples and a structural holdout: a
-- verdict-balanced subset of the labelled cases (chosen by seed) is fed to
-- the judge as examples, and every metric is computed only on the
-- remaining holdout cases, so agreement is never measured on examples the
-- judge saw. nExamples is clamped so at least one measurement case
-- remains. Candidate examples carry no critique (the labelled triple has
-- no critique field). Examples cost prompt tokens, not extra judge calls.
calibrateWith :: (LLM :> es)
              => Int -> Int -> Int
              -> (a -> Text) -> Text
              -> [(Text, a, Bool)]
              -> Eff es CalibrationReport
calibrateWith seed nExamples n render rubric labelled = do
  let n' = max 0 (min nExamples (length labelled - 1))
      indexed = zip [0 :: Int ..] labelled
      chosen = balanceBy (\(_, (_, _, h)) -> h) seed n' indexed
      chosenIdx = [i | (i, _) <- chosen]
      exs = [JudgeExample (render a) h Nothing | (_, (_, a, h)) <- chosen]
      holdout = [t | (i, t) <- indexed, i `notElem` chosenIdx]
      opts = JudgeOpts { votes = n, examples = exs }
  outcomes <- mapM (\(nm, a, h) -> (nm, h,) <$> vote False opts rubric (render a)) holdout
  pure (reportFrom outcomes (length exs) (length holdout))

calibrate :: (LLM :> es)
          => Int -> (a -> Text) -> Text -> [(Text, a, Bool)] -> Eff es CalibrationReport
calibrate = calibrateWith 0 0
```

Refactor today's metric computation out of `calibrate` into the pure `reportFrom outcomes exampleCount measured` (identical math, two extra fields filled in). `renderCalibration` appends, only when `r.exampleCount > 0`:

```haskell
  ++ [ "examples fed: " <> tshow r.exampleCount <> "  measured on: " <> tshow r.measured
     | r.exampleCount > 0 ]
```

- [ ] **Step 6: fix the existing Spec.hs constructions.** The three calibrate checks construct `CalibrationReport` positionally; each gains `0 <measured>` at the end: the agreement/kappa check becomes `CalibrationReport 0.75 0.5 1.0 0.5 [] [] 0 4`; the degenerate check `CalibrationReport 1.0 0 1.0 1.0 [] [] 0 2`; the contested check reads fields via record-dot and needs no change. No other existing test touches the changed signatures (they all go through `judge`/`judgeN`/`runEval*`/`calibrate`, which are behaviour-identical).

- [ ] **Step 7: build + suite green.** `... zinc build` → exit 0; `... zinc test` → `1 test suite(s) passed`, 212 ok lines (no new tests yet; every existing expectation must hold).

- [ ] **Step 8: commit.**

```bash
git add -A src test
git commit -m "$(printf 'feat(eval)!: JudgeOpts + few-shot examples in the judge; calibrateWith holdout\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: tests

**Files:**
- Modify: `test/Spec.hs`

- [ ] **Step 1: imports.** Extend the `Crucible.Eval.Judge` import with `JudgeExample (..), JudgeOpts (..), defaultJudgeOpts, balanceExamples, judgePrompt`; the `Crucible.Eval` import with `judgeWith, runEvalWith`; the `Crucible.Eval.Calibrate` import with `calibrateWith`.

- [ ] **Step 2: add the checks** (after the calibrate checks):

```haskell
  -- crucible-tfu: few-shot calibrated judging
  , check "balanceExamples: deterministic and balanced"
      (True, [True, False, True, False])
      (let exs = [JudgeExample (T.pack (show i)) (odd i) Nothing | i <- [1 .. 8 :: Int]]
           a = balanceExamples 42 4 exs
           b = balanceExamples 42 4 exs
       in (a == b, map (.pass) a))
  , check "balanceExamples: surplus side fills after the short side runs out"
      [True, False, True, True]
      (map (.pass)
        (balanceExamples 7 4
          (JudgeExample "f" False Nothing
             : [JudgeExample (T.pack (show i)) True Nothing | i <- [1 .. 6 :: Int]])))
  , check "balanceExamples: n over supply returns all; n zero returns none"
      (3, 0)
      (let exs = [ JudgeExample "a" True Nothing
                 , JudgeExample "b" False Nothing
                 , JudgeExample "c" True Nothing ]
       in (length (balanceExamples 1 10 exs), length (balanceExamples 1 0 exs)))
  , check "judgePrompt: zero examples keeps the plain two-line user message"
      (Just "Rubric: r\nOutput to grade: out")
      (case judgePrompt [] "r" "out" of
         [_, Message User u] -> Just u
         _                   -> Nothing)
  , check "judgePrompt: examples render verdicts and optional why"
      (True, True, True)
      (case judgePrompt [ JudgeExample "good one" True (Just "matches rubric")
                        , JudgeExample "bad one" False Nothing ] "r" "out" of
         [_, Message User u] ->
           ( T.isInfixOf "Examples of past verdicts for this rubric:" u
           , T.isInfixOf "Example output:\ngood one\nVerdict: pass\nWhy: matches rubric" u
           , T.isInfixOf "Example output:\nbad one\nVerdict: fail\n" u
               && T.isSuffixOf "Output to grade: out" u )
         _ -> (False, False, False))
  , check "judgeWith: examples change no call accounting"
      (1.0, "leftover")
      (runPureEff (runLLMScripted ["{\"why\":\"y\",\"pass\":true}", "leftover"]
        (do s <- judgeWith defaultJudgeOpts { examples = [JudgeExample "e" True Nothing] }
                   id "r" ("out" :: Text)
            extra <- complete []
            pure (s.value, extra))))
  , check "runEvalWith: rubric and checklist both score under example opts"
      1.0
      ((runPureEff (runLLMScripted
         [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}" ]
         (runEvalWith defaultJudgeOpts { examples = [JudgeExample "e" True Nothing] } id pure
            [ Case ("x" :: Text) "rub" (Rubric "r")
            , Case "y" "chk" (Checklist [criterion "c"]) ]))).passRate)
  , check "calibrateWith: examples held out of measurement"
      (CalibrationReport 1.0 0 1.0 1.0 [] [] 2 2, "leftover")
      (runPureEff (runLLMScripted
        [ "{\"why\":\"\",\"pass\":true}", "{\"why\":\"\",\"pass\":true}", "leftover" ]
        (do r <- calibrateWith 42 2 1 id "rubric"
                   [ ("a", "o1" :: Text, True), ("b", "o2", True)
                   , ("c", "o3", True), ("d", "o4", True) ]
            extra <- complete []
            pure (r, extra))))
  , check "calibrateWith: clamps so one measurement case remains"
      (2, 1)
      (let r = runPureEff (runLLMScripted ["{\"why\":\"\",\"pass\":true}"]
                 (calibrateWith 1 10 1 id "r"
                    [("a", "o" :: Text, True), ("b", "o2", True), ("c", "o3", True)]))
       in (r.exampleCount, r.measured))
  , check "renderCalibration: examples line only when used"
      (True, False)
      (let withEx    = CalibrationReport 1 0 1 1 [] [] 2 2
           withoutEx = CalibrationReport 1 0 1 1 [] [] 0 4
       in ( T.isInfixOf "examples fed: 2" (renderCalibration withEx)
          , T.isInfixOf "examples fed" (renderCalibration withoutEx)))
```

(The calibrateWith main check is seed-independent by construction: all four labels are pass, so any two chosen examples leave two all-pass holdout cases and the metrics are identical whatever the shuffle picks.)

- [ ] **Step 3: run the suite.** `... zinc test` → `1 test suite(s) passed`, 222 ok lines. If a balanceExamples expectation fails, verify the interleave order (pass first) and the surplus rule before touching expectations; report genuine divergences as DONE_WITH_CONCERNS.

- [ ] **Step 4: commit.**

```bash
git add test/Spec.hs
git commit -m "$(printf 'test(eval): few-shot judging coverage (balance, prompt, holdout calibrate)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: docs

**Files:**
- Modify: `docs/evals.md`

- [ ] **Step 1: edits.** Read the final `src/Crucible/Eval/Judge.hs` and `Calibrate.hs` first; mirror signatures exactly.
  - "Voting and uncertainty": introduce `JudgeOpts` (votes + examples) and the `judgeWith`/`runEvalWith` general forms; describe `judge`/`judgeN`/`runEval`/`runEvalN` as specializations; one sentence on the Rubric-only scope of examples (checklist criteria and grounded claims are their own micro-rubrics).
  - "Calibrating the judge": add the forward-feeding step to the numbered workflow (once kappa is healthy, feed the labels forward with `calibrateWith` and reuse the same example set via `runEvalWith` in the production suite); show the `calibrateWith` signature; state the holdout rule plainly (metrics are computed only on cases the judge never saw as examples; the function makes the wrong thing inexpressible); note the new report fields and render line.
  - "Rubric rules at a glance", "Trusting the numbers" group: one new rule with a link to Calibrating the judge: labels trusted for calibration can be fed forward as judge examples; never measure on examples the judge saw. Renumber the trailing rules.
  - House style: no emdashes/endashes, no hype words, no manifest mentions; `grep -n '—\|–' docs/evals.md` empty.

- [ ] **Step 2: commit.**

```bash
git add docs/evals.md
git commit -m "$(printf 'docs(site): few-shot calibrated judging on the evals page\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: merge + publish + close

**Files:** none.

- [ ] **Step 1: full suite.** `... zinc test` → `1 test suite(s) passed`.
- [ ] **Step 2: merge + push.** Via `superpowers:finishing-a-development-branch` (the user historically picks "merge back to master locally"); after merge: suite on master, `git push`, Pages build reaches `built`.
- [ ] **Step 3: close the bead.**

```bash
bd close crucible-tfu --reason="Shipped: JudgeOpts/JudgeExample/balanceExamples/judgePrompt, judgeWith/runEvalWith generalizations, calibrateWith structural holdout (exampleCount/measured on the report), 10 hermetic tests, evals.md workflow updated."
```

---

## Self-Review

**1. Spec coverage:** JudgeExample/JudgeOpts/defaultJudgeOpts → Task 1 Step 1. balanceExamples semantics (seeded shuffle, pass-first interleave, surplus fill, n edge cases) → Step 1 + Task 2 checks 1-3. judgePrompt purity, zero-example byte-identity, example block format with optional why → Step 1 + checks 4-5. judgeOnce/vote threading with unchanged repair → Step 2. judgeWith/runEvalWith/scoreWith + specializations + Rubric-only example scope → Step 3 + checks 6-7. Grounding/checklist callers votes-only → Steps 3-4. calibrateWith (clamp, balanced index split, holdout-only metrics, no extra calls, report fields, render line, calibrate = zero-example redefinition) → Step 5 + checks 8-10 + Step 6 migrations. Docs (three places incl. at-a-glance rule) → Task 3. No demo per spec. Non-goals absent. ✅

**2. Placeholder scan:** Step 2 and the runEvalWith body say "body unchanged except ..." with the exact replacement shown, which is a diff instruction against code the implementer has open, not a placeholder. Everything else carries complete code. ✅

**3. Type consistency:** `vote :: Bool -> JudgeOpts -> Text -> Text -> Eff es VoteOutcome` used identically in Eval (`vote True opts`), checklist/grounding (`vote True defaultJudgeOpts { votes = n }`), and Calibrate (`vote False opts`); `balanceBy` predicate shapes match both call sites (`(.pass)` and the indexed-triple lambda); `CalibrationReport` field order (… judgeErrors, exampleCount, measured) matches every positional construction in Tasks 1-2; `judgePrompt [] "r" "out"` expected text matches the current `[text| |]` two-line output. ✅
