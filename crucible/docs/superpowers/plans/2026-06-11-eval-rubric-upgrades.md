# Eval Rubric Upgrades Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the seven research-backed judge upgrades: why-before-pass verdicts, a hardened judge prompt, validate-and-repair on judge JSON, `judgeN` voting with vote margins and early stopping, `Checklist` expectations with per-criterion judge calls, a `calibrate` helper with Cohen's kappa, and a new `docs/evals.md` manual page.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-11-eval-rubric-upgrades-design.md`. Three modules: `Crucible.Eval.Judge` (verdict, prompt, repair, vote loop), `Crucible.Eval` (types, scoring, report; imports Judge), `Crucible.Eval.Calibrate` (imports Judge). Layering note: the spec lists `judge`/`judgeN` under the Judge section, but they return `Score`, which lives in `Eval`; to keep imports acyclic, Judge exposes `vote`/`VoteOutcome` and `Eval` defines `judge`/`judgeN` on top (existing `import Crucible.Eval (judge)` sites keep working unchanged).

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec, neat-interpolation. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). On exit 137 retry once; second 137 = BLOCKED. Judge success by the zinc exit status or the "1 test suite(s) passed" line, never by a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/eval-rubrics` from master; work in place, no worktrees.
- House style: `DuplicateRecordFields` + `NoFieldSelectors` + `OverloadedRecordDot`; prefix-free fields; prompts via neat-interpolation `[text| |]` (interpolated values must be `Text` identifiers in scope). Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Current `src/Crucible/Eval.hs` is 91 lines: `Expectation (Exactly/Predicate/Rubric)`, `Case {input, name, expect}`, `Score {value, rationale}`, `Result {case', output, score}`, `Report {results, passRate, meanScore}`, `Verdict {pass, why}` + `verdictCodec`, `judge`, `scoreM`, `runEval`, `renderReport`. The judge system prompt is one line and the verdict order is pass-first; both change in this cycle.
- `Crucible.Decode` exports `decodeLLM :: JSONCodec a -> Text -> Either DecodeError a` and `DecodeError (..)` (fields `message`, `raw`).
- `runLLMScripted :: [Text] -> Eff (LLM : es) a -> Eff es a` pops canned replies; an exhausted script returns `""` (check `src/Crucible/LLM.hs` if any test depends on exhaustion; the plan's tests script every reply explicitly).
- `test/Spec.hs` imports `Crucible.Eval (Case(..), Expectation(..), Score(..), Result(..), Report(..), runEval, scoreM, judge, renderReport)`.

---

### Task 1: Judge module + Eval rewrite (atomic green gate)

**Files:**
- Create: `src/Crucible/Eval/Judge.hs`
- Rewrite: `src/Crucible/Eval.hs`
- Modify: `test/Spec.hs` (only what the rewrite breaks: `Score` construction/imports; no new tests yet)

- [ ] **Step 1: create `src/Crucible/Eval/Judge.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | The LLM judge layer: the verdict shape (reason-then-verdict), the
-- hardened grader prompt, validate-and-repair on the judge's own JSON, and
-- the sequential majority-vote loop. 'Crucible.Eval' builds 'Score's on top.
module Crucible.Eval.Judge
  ( Verdict (..)
  , verdictCodec
  , JudgeError (..)
  , judgeOnce
  , VoteOutcome (..)
  , vote
  ) where

import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Effectful
import NeatInterpolation (text)

import Crucible.Codec (JSONCodec, object, field, str, bool)
import Crucible.Decode (DecodeError (..), decodeLLM)
import Crucible.LLM (LLM, Message (..), Role (..), complete)

-- | The judge's structured verdict. Field order is deliberate: the codec
-- encodes and the prompt requests "why" first, so the verdict token is
-- conditioned on the reasoning (the CoT-before-verdict effect). Decoding is
-- order-insensitive; legacy {"pass", "why"} JSON still parses.
data Verdict = Verdict { why :: Text, pass :: Bool } deriving (Eq, Show)

verdictCodec :: JSONCodec Verdict
verdictCodec = object (Verdict <$> field "why"  (.why)  str
                               <*> field "pass" (.pass) bool)

-- | The judge's own reply failed to parse, even after one repair attempt.
newtype JudgeError = JudgeError Text deriving (Eq, Show)

-- | The hardened grader system message, shared by every judge call.
judgeSystem :: Message
judgeSystem = Message System [text|
  You are a strict grader.
  Reason through each rubric requirement in "why" first, quoting the part of
  the output that satisfies or violates it, then give the verdict.
  Length and style are not criteria unless the rubric says so.
  If a requirement is not demonstrably met, fail it.
  Respond ONLY with JSON {"why": <string>, "pass": <bool>}.|]

-- | One judge call with validate-and-repair: on a verdict decode failure,
-- re-prompt once with the raw reply and the parse error (the same idiom as
-- 'Crucible.Skill.call'), then give up with 'JudgeError'.
judgeOnce :: (LLM :> es) => Text -> Text -> Eff es (Either JudgeError Verdict)
judgeOnce rubric graded = do
  let msgs =
        [ judgeSystem
        , Message User [text|Rubric: ${rubric}
Output to grade: ${graded}|]
        ]
  raw <- complete msgs
  case decodeLLM verdictCodec raw of
    Right v -> pure (Right v)
    Left e1 -> do
      let m = e1.message
      raw2 <- complete
        ( msgs
            ++ [ Message Assistant raw
               , Message User [text|Your reply did not parse: ${m}. Respond with valid JSON only.|]
               ]
        )
      case decodeLLM verdictCodec raw2 of
        Right v -> pure (Right v)
        Left e2 -> pure (Left (JudgeError e2.message))

-- | The result of an n-sample majority vote.
data VoteOutcome
  = Decided { pass :: Bool, why :: Text, yes :: Int, no :: Int }
  | AllErrored Text
  deriving (Eq, Show)

-- | Sample the judge up to @n@ times (sequentially) and majority-vote.
-- With early stopping on, the loop ends as soon as one side holds a strict
-- majority of n (at n=3, two agreeing votes settle it). An errored sample
-- consumes an attempt without casting a vote; if every attempt errors, the
-- outcome is 'AllErrored'. A tie on an exhausted budget (possible only via
-- errors) resolves to fail. The rationale kept is the first vote on the
-- winning side. Callers should use odd n; n <= 1 is a single sample.
vote :: (LLM :> es) => Bool -> Int -> Text -> Text -> Eff es VoteOutcome
vote earlyStop n rubric graded = go n' (0, 0) (Nothing, Nothing) ""
  where
    n'   = max 1 n
    need = n' `div` 2 + 1

    go :: (LLM :> es) => Int -> (Int, Int) -> (Maybe Text, Maybe Text) -> Text -> Eff es VoteOutcome
    go 0 (y, f) (firstYes, firstNo) lastErr
      | y == 0 && f == 0 = pure (AllErrored lastErr)
      | y > f            = pure (Decided True  (fromMaybe "" firstYes) y f)
      | otherwise        = pure (Decided False (fromMaybe "" firstNo)  y f)
    go k tally@(y, f) firsts@(firstYes, firstNo) lastErr
      | earlyStop && y >= need = pure (Decided True  (fromMaybe "" firstYes) y f)
      | earlyStop && f >= need = pure (Decided False (fromMaybe "" firstNo)  y f)
      | otherwise = do
          r <- judgeOnce rubric graded
          case r of
            Left (JudgeError m) -> go (k - 1) tally firsts m
            Right v
              | v.pass    -> go (k - 1) (y + 1, f) (firstYes <|> Just v.why, firstNo) lastErr
              | otherwise -> go (k - 1) (y, f + 1) (firstYes, firstNo <|> Just v.why) lastErr
```

(Note `Verdict` and `VoteOutcome` both have `pass`/`why` fields: that is what `DuplicateRecordFields` is for. The local `go` needs the type annotation shown, or none at all if GHC infers it; if the annotated version fails to typecheck because of the `es` scoping, delete the local signature.)

- [ ] **Step 2: rewrite `src/Crucible/Eval.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | Datasets, expectations, and scoring. Deterministic graders first
-- ('Exactly', 'Predicate'); 'Rubric' asks the LLM judge one holistic
-- question; 'Checklist' decomposes a quality goal into weighted binary
-- criteria, each judged with its own call. The judge plumbing (prompt,
-- repair, voting) lives in "Crucible.Eval.Judge".
module Crucible.Eval
  ( Case(..), Expectation(..), Criterion(..), criterion
  , Score(..), score, Verdict(..)
  , Result(..), Report(..)
  , runEval, runEvalN, scoreM, judge, judgeN, renderReport
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful

import Crucible.Eval.Judge (Verdict (..), VoteOutcome (..), vote)
import Crucible.LLM (LLM)

-- | What a case's output is checked against.
data Expectation a
  = Exactly a              -- ^ must equal (needs Eq a)
  | Predicate (a -> Bool)  -- ^ must satisfy
  | Rubric Text            -- ^ LLM-as-judge against this rubric
  | Checklist [Criterion]  -- ^ weighted binary criteria, judged one by one

-- | One checklist item: a concrete, observable requirement and its weight.
-- Write observable criteria ("cites a source URL"), not aspirational ones
-- ("is trustworthy"). Weights affect 'Report.meanScore' only: a checklist
-- case passes (counts in 'Report.passRate') only when every criterion holds.
data Criterion = Criterion { label :: Text, weight :: Double }

-- | A criterion with weight 1.
criterion :: Text -> Criterion
criterion l = Criterion l 1

-- | One dataset row.
data Case i a = Case { input :: i, name :: Text, expect :: Expectation a }

-- | A score in [0,1] with a rationale. For judged scores produced by a vote,
-- 'votes' records the tally (yes, no); both sides nonzero means the judge is
-- uncertain on this case. Deterministic scores carry 'Nothing'.
data Score = Score { value :: Double, rationale :: Text, votes :: Maybe (Int, Int) }
  deriving (Eq, Show)

-- | Score with no vote tally.
score :: Double -> Text -> Score
score v r = Score v r Nothing

data Result i a = Result { case' :: Case i a, output :: a, score :: Score }
data Report i a = Report { results :: [Result i a], passRate :: Double, meanScore :: Double }

-- | LLM-as-judge, single sample (equivalent to @'judgeN' 1@).
judge :: (LLM :> es) => (a -> Text) -> Text -> a -> Eff es Score
judge = judgeN 1

-- | LLM-as-judge with n-sample majority voting (use odd n; the vote stops
-- early once decided, so n=3 typically costs ~2 calls). For n > 1 the tally
-- is recorded in 'votes'; n <= 1 keeps 'votes' = Nothing. An all-errored
-- vote yields the judge-error score (value 0, rationale tagged
-- @judge error: @). Cost note: each sample is one judge call, two if its
-- reply needs the repair re-prompt.
judgeN :: (LLM :> es) => Int -> (a -> Text) -> Text -> a -> Eff es Score
judgeN n render rubric actual =
  voteScore (n <= 1) <$> vote True n rubric (render actual)

-- | Convert a vote outcome to a Score; the Bool suppresses the tally for
-- single-sample judging.
voteScore :: Bool -> VoteOutcome -> Score
voteScore _      (AllErrored m)    = score 0.0 ("judge error: " <> m)
voteScore single (Decided p w y f) =
  Score (if p then 1.0 else 0.0) w (if single then Nothing else Just (y, f))

-- | Score one output against its expectation, single-sample judging.
scoreM :: (Eq a, LLM :> es) => (a -> Text) -> Expectation a -> a -> Eff es Score
scoreM = scoreN 1

-- | 'scoreM' with n-vote judging for 'Rubric' cases and for each
-- 'Checklist' criterion. Pure for Exactly/Predicate.
scoreN :: (Eq a, LLM :> es) => Int -> (a -> Text) -> Expectation a -> a -> Eff es Score
scoreN n render exp_ actual = case exp_ of
  Exactly e     -> pure (score (ind (actual == e)) (if actual == e then "exact match" else "mismatch"))
  Predicate p   -> pure (score (ind (p actual)) (if p actual then "predicate held" else "predicate failed"))
  Rubric r      -> judgeN n render r actual
  Checklist cs  -> checklistScore n render cs actual
  where ind b = if b then 1.0 else 0.0

-- | Judge each criterion with its own binary call; score = passed weight /
-- total weight. value reaches 1.0 only when every criterion passes. A judge
-- error on a criterion fails that criterion with a tagged rationale line.
checklistScore :: (LLM :> es) => Int -> (a -> Text) -> [Criterion] -> a -> Eff es Score
checklistScore _ _ [] _ = pure (score 1.0 "empty checklist")
checklistScore n render cs actual = do
  rs <- mapM judge1 cs
  let total   = sum [c.weight | c <- cs]
      got     = sum [c.weight | (c, passed, _) <- rs, passed]
      allPass = and [p | (_, p, _) <- rs]
      val | total <= 0 = if allPass then 1.0 else 0.0
          | otherwise  = got / total
      ln (c, p, w) = (if p then "[pass] " else "[fail] ") <> c.label <> ": " <> w
  pure (score val (T.intercalate "\n" (map ln rs)))
  where
    judge1 c = do
      out <- vote True n ("the output must satisfy: " <> c.label) (render actual)
      pure $ case out of
        AllErrored m    -> (c, False, "judge error: " <> m)
        Decided p w _ _ -> (c, p, w)

-- | Run a system-under-test over a dataset and aggregate, single-sample
-- judging (equivalent to @'runEvalN' 1@).
runEval :: (Eq a, LLM :> es) => (a -> Text) -> (i -> Eff es a) -> [Case i a] -> Eff es (Report i a)
runEval = runEvalN 1

-- | 'runEval' with n-vote judging for Rubric cases and Checklist criteria.
runEvalN :: (Eq a, LLM :> es) => Int -> (a -> Text) -> (i -> Eff es a) -> [Case i a] -> Eff es (Report i a)
runEvalN n render sut cases = do
  rs <- mapM run1 cases
  let vals = map (\Result{score = s} -> s.value) rs
      len  = length rs
      mean = if len == 0 then 0 else sum vals / fromIntegral len
      pr   = if len == 0 then 0 else fromIntegral (length (filter (>= 1.0) vals)) / fromIntegral len
  pure (Report rs pr mean)
  where
    run1 c@Case{input = i, expect = ex} = do
      out <- sut i
      s   <- scoreN n render ex out
      pure (Result c out s)

-- | A human-readable report: one line per case (with judge-uncertainty and
-- judge-error annotations), then a summary.
renderReport :: Report i a -> Text
renderReport Report{results = rs, passRate = pr, meanScore = ms} =
  T.intercalate "\n" $
  [ caseName <> ": " <> tshow s.value <> " (" <> s.rationale <> ")" <> annot s
  | Result{case' = Case{name = caseName}, score = s} <- rs ]
  ++ [ "", "pass-rate: " <> tshow pr <> "  mean: " <> tshow ms ]
  where
    tshow :: Show x => x -> Text
    tshow = T.pack . show
    annot s = uncertain s <> jerr s
    uncertain s = case s.votes of
      Just (y, f) | y > 0 && f > 0 ->
        "  [judge uncertain " <> tshow y <> "-" <> tshow f <> ": review by hand]"
      _ -> ""
    jerr s = if "judge error: " `T.isInfixOf` s.rationale then "  [judge error]" else ""
```

(The old `judge`, `Verdict`, `verdictCodec`, and the one-line judge prompt are deleted from Eval.hs; `Verdict (..)` is re-exported from Judge via the import + export list. The Codec/Decode/NeatInterpolation imports drop out of Eval.hs.)

- [ ] **Step 3: fix what the rewrite breaks in `test/Spec.hs`.** Run `grep -n 'Score ' test/Spec.hs`: any positional `Score x y` construction gains a third argument `Nothing` (or switches to `score x y` with `score` added to the Eval import). Record-dot reads (`.value`, `.rationale`, `rep.passRate`) are unaffected. Existing scripted verdict replies use the legacy `{"pass", "why"}` order, which still decodes: do NOT rewrite them.

- [ ] **Step 4: build + suite green.**

Run: `nix develop . --command timeout -s KILL 300 zinc build` → exit 0, then `nix develop . --command timeout -s KILL 300 zinc test` → `1 test suite(s) passed`. All existing expectations must hold unchanged (the judge behaviour for valid verdicts is identical; repair only adds calls when a verdict fails to parse, which no existing test does).

- [ ] **Step 5: commit.**

```bash
git add -A
git commit -m "$(printf 'feat(eval)!: judge CoT reorder, hardened prompt, repair, voting core; Checklist + runEvalN\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: judge, checklist, and report tests

**Files:**
- Modify: `test/Spec.hs`

- [ ] **Step 1: extend the Eval imports.**

```haskell
import Crucible.Eval (Case(..), Expectation(..), Criterion(..), criterion, Score(..), score, Result(..), Report(..), runEval, runEvalN, scoreM, judge, judgeN, renderReport)
import Crucible.Eval.Judge (Verdict(..), verdictCodec)
```

(Adjust to the actual current import line; add only what is missing.)

- [ ] **Step 2: add the checks** (after the existing eval tests):

```haskell
  -- eval rubric upgrades: verdict order, repair, voting
  , check "judge verdict: decodes why-first and legacy field order"
      (Right True, Right True)
      ( ( fmap (.pass) (decodeLLM verdictCodec "{\"why\":\"w\",\"pass\":true}")
        , fmap (.pass) (decodeLLM verdictCodec "{\"pass\":true,\"why\":\"w\"}") ) )
  , check "judge: repair recovers from one malformed verdict"
      (1.0, Nothing)
      (let s = runPureEff (runLLMScripted
                 ["not json", "{\"why\":\"ok\",\"pass\":true}"]
                 (judge id "r" ("out" :: Text)))
       in (s.value, s.votes))
  , check "judge: two malformed verdicts -> judge error score"
      (0.0, True)
      (let s = runPureEff (runLLMScripted ["junk", "junk2"] (judge id "r" ("out" :: Text)))
       in (s.value, T.isPrefixOf "judge error: " s.rationale))
  , check "judgeN: unanimous early-stops after two calls"
      (Just (2, 0), "leftover")
      (runPureEff (runLLMScripted
         [ "{\"why\":\"a\",\"pass\":true}", "{\"why\":\"b\",\"pass\":true}", "leftover" ]
         (do s <- judgeN 3 id "r" ("out" :: Text)
             extra <- complete []
             pure (s.votes, extra))))
  , check "judgeN: 2-1 split consumes three and records the tally"
      (1.0, Just (2, 1))
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"a\",\"pass\":true}"
                 , "{\"why\":\"n\",\"pass\":false}"
                 , "{\"why\":\"c\",\"pass\":true}" ]
                 (judgeN 3 id "r" ("out" :: Text)))
       in (s.value, s.votes))
  , check "judgeN: majority why is kept"
      "a"
      ((runPureEff (runLLMScripted
         [ "{\"why\":\"a\",\"pass\":true}", "{\"why\":\"b\",\"pass\":true}" ]
         (judgeN 3 id "r" ("out" :: Text)))).rationale)
  , check "judgeN: errored sample is excluded from the tally"
      (1.0, Just (2, 0))
      (let s = runPureEff (runLLMScripted
                 [ "junk", "junk2"
                 , "{\"why\":\"a\",\"pass\":true}", "{\"why\":\"b\",\"pass\":true}" ]
                 (judgeN 3 id "r" ("out" :: Text)))
       in (s.value, s.votes))
  -- eval rubric upgrades: checklists
  , check "checklist: weighted scoring + per-criterion rationale"
      (True, True)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"has it\",\"pass\":true}", "{\"why\":\"missing\",\"pass\":false}" ]
                 (scoreM id (Checklist [Criterion "cites a source" 2, Criterion "is terse" 1]) ("out" :: Text)))
       in (abs (s.value - 2/3) < 1e-9, T.isInfixOf "[fail] is terse: missing" s.rationale))
  , check "checklist: all pass scores 1.0 and counts in passRate"
      (1.0, 1.0)
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}" ]
                   (runEval id pure
                      [Case ("in" :: Text) "c" (Checklist [criterion "a", criterion "b"])]))
       in (rep.passRate, rep.meanScore))
  , check "checklist: empty list scores 1.0 with no judge calls"
      (1.0, "empty checklist")
      (let s = runPureEff (runLLMScripted []
                 (scoreM id (Checklist []) ("out" :: Text)))
       in (s.value, s.rationale))
  , check "checklist: judge error on a criterion fails that criterion"
      (0.5, True)
      (let s = runPureEff (runLLMScripted
                 [ "junk", "junk2", "{\"why\":\"y\",\"pass\":true}" ]
                 (scoreM id (Checklist [criterion "a", criterion "b"]) ("out" :: Text)))
       in (s.value, T.isInfixOf "judge error: " s.rationale))
  -- eval rubric upgrades: runEvalN + report annotations
  , check "runEvalN: votes thread to rubric cases"
      (Just (2, 0))
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}" ]
                   (runEvalN 3 id pure [Case ("x" :: Text) "c" (Rubric "r")]))
       in (head rep.results).score.votes)
  , check "renderReport: flags contested and judge-error cases"
      (True, True)
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"n\",\"pass\":false}", "{\"why\":\"y\",\"pass\":true}"
                   , "j1", "j2", "j3", "j4", "j5", "j6" ]
                   (runEvalN 3 id pure
                      [ Case ("a" :: Text) "contested" (Rubric "r")
                      , Case ("b" :: Text) "errs" (Rubric "r") ]))
           r = renderReport rep
       in ( T.isInfixOf "[judge uncertain 2-1: review by hand]" r
          , T.isInfixOf "[judge error]" r ))
```

Notes for the implementer: `runEval id pure [...]` uses `pure` as the system-under-test (the case input IS the graded output); the existing eval tests use `(pure . id)`, either form works. The "errs" case consumes six junk replies: three samples, each burning a reply plus its repair reply. If a `(2, 0)` expectation fails because early stopping recorded a different tally, re-read `vote`: at n=3 with two yes votes the third call must NOT be consumed.

- [ ] **Step 3: run the suite.**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: `1 test suite(s) passed`, with all 13 new checks as `ok` lines.

- [ ] **Step 4: commit.**

```bash
git add test/Spec.hs
git commit -m "$(printf 'test(eval): verdict order, repair, voting, checklists, report annotations\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: `Crucible.Eval.Calibrate`

**Files:**
- Create: `src/Crucible/Eval/Calibrate.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: create `src/Crucible/Eval/Calibrate.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeOperators #-}

-- | Calibrating the judge against human labels: run the judge over
-- hand-labelled OUTPUTS (bypassing any skill; this evaluates only the
-- judge) and report agreement, Cohen's kappa, and fail-class
-- precision\/recall. Workflow: label ~30 outputs with critiques, run
-- 'calibrate', iterate the rubric wording until kappa exceeds 0.6, only
-- then trust suite numbers. Spend further labels on 'contested' cases.
module Crucible.Eval.Calibrate
  ( CalibrationReport (..)
  , calibrate
  , renderCalibration
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful

import Crucible.Eval.Judge (VoteOutcome (..), vote)
import Crucible.LLM (LLM)

-- | Judge-vs-human metrics over a labelled set. Judge-error cases are
-- excluded from the four rates and listed in 'judgeErrors'.
data CalibrationReport = CalibrationReport
  { agreement     :: Double  -- ^ raw judge-human agreement over judged cases
  , kappa         :: Double  -- ^ Cohen's kappa (binary); 0 when expected agreement is 1
  , failPrecision :: Double  -- ^ of judge-fails, fraction humans also failed (1 if no judge-fails)
  , failRecall    :: Double  -- ^ of human-fails, fraction the judge caught (1 if no human-fails)
  , contested     :: [Text]  -- ^ case names where the vote split (label these next)
  , judgeErrors   :: [Text]  -- ^ case names where the judge errored out
  }
  deriving (Eq, Show)

-- | Run the judge (full n-sample voting, no early stop, so margins are
-- comparable) over hand-labelled outputs.
calibrate :: (LLM :> es)
          => Int -> (a -> Text) -> Text
          -> [(Text, a, Bool)]
          -> Eff es CalibrationReport
calibrate n render rubric labelled = do
  outcomes <- mapM (\(nm, a, h) -> (nm, h,) <$> vote False n rubric (render a)) labelled
  let errs   = [nm | (nm, _, AllErrored _) <- outcomes]
      judged = [(nm, h, p, y, f) | (nm, h, Decided p _ y f) <- outcomes]
      total  = length judged
      agree  = length [() | (_, h, p, _, _) <- judged, h == p]
      jYes   = length [() | (_, _, True,  _, _) <- judged]
      jNo    = total - jYes
      hYes   = length [() | (_, True,  _, _, _) <- judged]
      hNo    = total - hYes
      po     = ratio agree total 0
      pe     = if total == 0 then 1
               else fromIntegral (jYes * hYes + jNo * hNo) / fromIntegral (total * total)
      kap    = if pe >= 1 then 0 else (po - pe) / (1 - pe)
      jFails = [(h') | (_, h', False, _, _) <- judged]
      fPrec  = ratio (length (filter not jFails)) (length jFails) 1
      hFails = [(p') | (_, False, p', _, _) <- judged]
      fRec   = ratio (length (filter not hFails)) (length hFails) 1
      cont   = [nm | (nm, _, _, y, f) <- judged, y > 0, f > 0]
  pure (CalibrationReport po kap fPrec fRec cont errs)
  where
    ratio :: Int -> Int -> Double -> Double
    ratio _ 0 dflt = dflt
    ratio num den _ = fromIntegral num / fromIntegral den

-- | A short human-readable rendering of a calibration report.
renderCalibration :: CalibrationReport -> Text
renderCalibration r = T.intercalate "\n" $
  [ "agreement:      " <> tshow r.agreement
  , "kappa:          " <> tshow r.kappa
  , "fail precision: " <> tshow r.failPrecision
  , "fail recall:    " <> tshow r.failRecall
  ]
  ++ [ "contested (label these next): " <> T.intercalate ", " r.contested | not (null r.contested) ]
  ++ [ "judge errors: " <> T.intercalate ", " r.judgeErrors | not (null r.judgeErrors) ]
  where tshow = T.pack . show
```

- [ ] **Step 2: build.** `nix develop . --command timeout -s KILL 300 zinc build` → exit 0.

- [ ] **Step 3: add the checks to `test/Spec.hs`** (import `Crucible.Eval.Calibrate (CalibrationReport (..), calibrate, renderCalibration)`):

```haskell
  -- eval rubric upgrades: calibration
  , check "calibrate: agreement/kappa/fail metrics on scripted verdicts"
      (CalibrationReport 0.75 0.5 1.0 0.5 [] [])
      (runPureEff (runLLMScripted
         [ "{\"why\":\"\",\"pass\":true}", "{\"why\":\"\",\"pass\":true}"
         , "{\"why\":\"\",\"pass\":false}", "{\"why\":\"\",\"pass\":true}" ]
         (calibrate 1 id "r"
            [ ("c1", "o" :: Text, True), ("c2", "o", True)
            , ("c3", "o", False), ("c4", "o", False) ])))
  , check "calibrate: degenerate denominators are defined"
      (CalibrationReport 1.0 0 1.0 1.0 [] [])
      (runPureEff (runLLMScripted
         [ "{\"why\":\"\",\"pass\":true}", "{\"why\":\"\",\"pass\":true}" ]
         (calibrate 1 id "r" [("c1", "o" :: Text, True), ("c2", "o", True)])))
  , check "calibrate: contested and judge-error cases listed; errors excluded from stats"
      (["split"], ["broken"], 1.0)
      (let r = runPureEff (runLLMScripted
                 [ "{\"why\":\"\",\"pass\":true}", "{\"why\":\"\",\"pass\":false}", "{\"why\":\"\",\"pass\":true}"
                 , "j1", "j2", "j3", "j4", "j5", "j6" ]
                 (calibrate 3 id "r" [("split", "o" :: Text, True), ("broken", "o", True)]))
       in (r.contested, r.judgeErrors, r.agreement))
```

Hand-derivation of the first check (so a failure is debuggable): humans T,T,F,F; judge T,T,F,T. agreement 3/4 = 0.75. Marginals jYes=3, jNo=1, hYes=2, hNo=2; pe = (3*2 + 1*2)/16 = 0.5; kappa = (0.75-0.5)/(1-0.5) = 0.5. Judge-fails = {c3}, humans also failed c3, precision 1.0. Human-fails = {c3, c4}, judge caught only c3, recall 0.5. The third check: "split" votes 2-1 (full voting consumes all three replies), agreement counts only "split" (judge pass, human pass: 1.0); "broken" burns six junk replies (three samples, each with one repair).

- [ ] **Step 4: run the suite.** `nix develop . --command timeout -s KILL 300 zinc test` → `1 test suite(s) passed`.

- [ ] **Step 5: commit.**

```bash
git add -A
git commit -m "$(printf 'feat(eval): calibrate, Cohen kappa, fail-class precision/recall (Crucible.Eval.Calibrate)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: demo section + live smoke

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: add a live eval section** in `main`, after the chat-cassette block and before the OpenAI section:

```haskell
      -- Eval: a checklist and an n-vote rubric judged live (runEvalN 3).
      evalRep <- runEff (Anthropic.run cfg (runEvalN 3 id pure
        [ Case ("It is 26C and sunny in Brisbane." :: T.Text) "weather-report"
            (Checklist [criterion "mentions a temperature", criterion "mentions a city"])
        , Case "pong" "terse-pong" (Rubric "the output is a single short word")
        ]))
      TIO.putStrLn (renderReport evalRep)
```

Imports to add: `Crucible.Eval (Case (..), Expectation (..), criterion, runEvalN, renderReport)`. The SUT is `pure`: the case input is the output being graded; `id` renders `Text`.

- [ ] **Step 2: build, then live smoke.** (Keys live in `.env`, gitignored; NEVER print them.)

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 300 .zinc/build/crucible-anthropic'
```

Expected: the existing demo output plus a report block: `weather-report: 1.0 ([pass] mentions a temperature: ... )` and `terse-pong: 1.0 (...)` (judged live, values may legitimately differ; what matters is the section runs, renders, and exits 0).

- [ ] **Step 3: commit.**

```bash
git add app/Main.hs
git commit -m "$(printf 'demo: live checklist + n-vote rubric eval section\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 5: manual page `docs/evals.md` + links

**Files:**
- Create: `docs/evals.md`
- Modify: `docs/index.md` (Pages list), `docs/typed-functions.md` (link from the testSkill section)

- [ ] **Step 1: write `docs/evals.md`.** Front-matter: `title: Evals`, `nav_order:` the next free number (run `grep -n nav_order docs/*.md` and pick; do not renumber other pages). Sections, grounded in the REAL code (read `src/Crucible/Eval.hs`, `Eval/Judge.hs`, `Eval/Calibrate.hs` first; mirror signatures exactly):

1. **The grading ladder**: `Exactly`/`Predicate` first (deterministic, free), `Rubric` for one quality concern, `Checklist` for decomposed criteria. Show the `Expectation` type and a small `runEval` example with `renderReport` output.
2. **Writing observable criteria**: good ("cites at least one source URL") vs aspirational ("is trustworthy"); each criterion checkable from the output alone.
3. **Lint your rubric**: coverage (criteria span the failure modes you actually saw), conflation (one criterion testing two things: split it), direction (yes is unambiguously good), redundancy (near-duplicates double-count under weights).
4. **When to split a rubric**: independent failure reasons, hard gates (safety as its own Checklist case; passRate already requires all criteria), more than ~5-7 criteria.
5. **Voting and uncertainty**: `judgeN`/`runEvalN`, the `votes` field, the `[judge uncertain]` flag, early stopping, the cost multiplier, and the temperature limitation (vote diversity rides on provider sampling).
6. **Calibrating the judge**: the workflow (label ~30 outputs with critiques, run `calibrate`, iterate wording until kappa > 0.6, then trust `testSkill` numbers; spend further labels on contested cases), with the `calibrate` signature and a short `renderCalibration` sample.
7. **Judge errors**: the `judge error:` tag means the judge's own reply failed to parse after one repair attempt; distinct from a fail; surfaced by `renderReport` and excluded from calibration stats.

House style: no emdashes, no hype words, no mention of the sibling project manifest, prose in the existing pages' voice.

- [ ] **Step 2: link it.** `docs/index.md` Pages list gains: `- [Evals](evals.md): expectations, checklists, the judge, voting, calibration.` In `docs/typed-functions.md`, at the end of the "Test cases on the skill" section add: `For rubric design, voting, and judge calibration, see [Evals](evals.md).`

- [ ] **Step 3: sweep + commit.** `grep -n '—\|–' docs/evals.md docs/index.md docs/typed-functions.md` must be empty; `grep -rniE 'manifest|simply|seamless|powerful' docs/evals.md` must be empty.

```bash
git add docs/
git commit -m "$(printf 'docs(site): evals manual page (rubrics, checklists, voting, calibration)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 6: final verification + merge + publish

**Files:** none.

- [ ] **Step 1: full suite.** `nix develop . --command timeout -s KILL 300 zinc test` → `1 test suite(s) passed`.

- [ ] **Step 2: merge + push.** Handled by `superpowers:finishing-a-development-branch` (the user historically picks "merge back to master locally"); after merging: run the suite on master, `git push`, and confirm `gh api repos/garethstokes/crucible/pages/builds/latest` shows a fresh build (the new manual page publishes).

- [ ] **Step 3: close the tracker issue.** `bd close <id>` for "Eval upgrades from rubric research (judge CoT, Checklist, judgeN, calibrate)" (find the id with `bd list --status=open`), with a one-line reason.

---

## Self-Review

**1. Spec coverage:** Verdict reorder + legacy decode → Task 1 (Judge) + Task 2 test. Hardened prompt → Task 1 `judgeSystem`. Repair + JudgeError → Task 1 `judgeOnce` + Task 2 tests. Score.votes + smart constructor → Task 1. judgeN early stop, tally semantics, error votes, tie-on-errors → Task 1 `vote` + Task 2 tests. Checklist (per-criterion calls, weights, all-pass gate, rationale lines, empty list, zero weights) → Task 1 `checklistScore` + Task 2 tests (zero-weight case covered by code, not a test: acceptable, the spec defines it and the formula is two lines). runEvalN threading → Task 1 + Task 2 test. renderReport annotations → Task 1 + Task 2 test. Calibrate (full voting, metrics, degenerate denominators, contested, judgeErrors, renderCalibration) → Task 3. Demo live smoke → Task 4. Manual page + links → Task 5. Migration (Score third field, re-exports) → Task 1 Steps 2-3. Non-goals absent. ✅

**2. Placeholder scan:** none. Task 5's manual page gives a section-by-section content brief rather than full prose, which is the established pattern for doc tasks in this repo (the writer reads the real source). ✅

**3. Type consistency:** `vote :: Bool -> Int -> Text -> Text -> Eff es VoteOutcome` used identically in Eval (`vote True n`) and Calibrate (`vote False n`); `VoteOutcome (Decided p w y f | AllErrored m)` pattern-matched consistently; `Score {value, rationale, votes}` + `score` smart constructor consistent across Tasks 1-3; `judgeN n render rubric actual` argument order matches `judge = judgeN 1` and all test call sites; `CalibrationReport` field order in the positional test constructions matches the declaration order (agreement, kappa, failPrecision, failRecall, contested, judgeErrors). ✅
