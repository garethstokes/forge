# Scalar Metrics and Ordinal Scales Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two new Eval expectations: `Metric` (code-graded scalar with a pass threshold) and `Scale` (LLM-graded anchored ordinal with a pass level), plus a pure `Crucible.Eval.Metrics` module.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-12-metric-scale-design.md` (tracker `crucible-2zw`). One new pure leaf module (Metrics); ordinal judging (`Rating`, `ratePrompt`, `rate`) joins `Crucible.Eval.Judge`; `Crucible.Eval` gains the constructors, dispatch, and a per-expectation `passes` rule consulted by `runEvalWith`.

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec (via `Crucible.Codec`: `int` exists), neat-interpolation. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). Exit 137 = GHC iserv flake, retry once; second 137 = BLOCKED. Judge success by exit status or the pass line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/metric-scale` from master; work in place, no worktrees.
- House style: DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot, prefix-free fields. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Read first: `src/Crucible/Eval.hs` (Expectation, scoreWith, runEvalWith at line ~166: `pr` currently filters `(>= 1.0)` over score values) and `src/Crucible/Eval/Judge.hs` (Verdict/verdictCodec, judgePrompt, judgeOnce with its repair re-prompt, vote).
- Prompt templates use `[text| |]` from NeatInterpolation; CONDITIONAL or list-assembled blocks use `T.concat` (the quasiquoter does not reliably preserve trailing newlines in interpolations).
- The suite passes with 237 checks.

---

### Task 1: `Crucible.Eval.Metrics` (pure) + tests

**Files:**
- Create: `src/Crucible/Eval/Metrics.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: create `src/Crucible/Eval/Metrics.hs`:**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Pure scalar metrics for 'Crucible.Eval' @Metric@ expectations. Every
-- function takes the REFERENCE first so partial application composes:
-- @Metric 0.4 (rougeL reference . render)@. All results land in [0,1].
module Crucible.Eval.Metrics
  ( normMatch
  , tokenF1
  , rougeL
  ) where

import Data.List (foldl', sort)
import Data.Text (Text)
import qualified Data.Text as T

-- | 1.0 when the two texts are equal after case-folding and whitespace
-- normalization, else 0.0.
normMatch :: Text -> Text -> Double
normMatch ref out = if norm ref == norm out then 1.0 else 0.0
  where norm = T.unwords . T.words . T.toCaseFold

-- | Token-multiset F1 (SQuAD style): case-folded whitespace tokens,
-- harmonic mean of precision and recall. Both empty = 1.0; one empty = 0.0.
tokenF1 :: Text -> Text -> Double
tokenF1 ref out
  | null rt && null ot = 1.0
  | null rt || null ot = 0.0
  | otherwise          = harmonic (c / len ot) (c / len rt)
  where
    rt = tokens ref
    ot = tokens out
    c  = fromIntegral (commonCount rt ot)

-- | ROUGE-L: longest common subsequence over case-folded tokens, reported
-- as the harmonic mean of LCS precision (over the candidate) and recall
-- (over the reference). Both empty = 1.0; one empty = 0.0.
rougeL :: Text -> Text -> Double
rougeL ref out
  | null rt && null ot = 1.0
  | null rt || null ot = 0.0
  | otherwise          = harmonic (l / len ot) (l / len rt)
  where
    rt = tokens ref
    ot = tokens out
    l  = fromIntegral (lcsLen rt ot)

tokens :: Text -> [Text]
tokens = T.words . T.toCaseFold

len :: [Text] -> Double
len = fromIntegral . length

-- | 2pr/(p+r); 0 when both are 0 (possible only with zero overlap).
harmonic :: Double -> Double -> Double
harmonic p r = if p + r == 0 then 0.0 else 2 * p * r / (p + r)

-- | Multiset intersection size via merge over sorted lists.
commonCount :: [Text] -> [Text] -> Int
commonCount xs ys = go (sort xs) (sort ys)
  where
    go aas@(a : as) bbs@(b : bs)
      | a == b    = 1 + go as bs
      | a < b     = go as bbs
      | otherwise = go aas bs
    go _ _ = 0

-- | Classic one-row LCS dynamic programme.
lcsLen :: [Text] -> [Text] -> Int
lcsLen xs ys = last (foldl' step (replicate (length ys + 1) 0) xs)
  where
    step prev x = scanl f 0 (zip3 ys prev (drop 1 prev))
      where f left (y, diag, up) = if x == y then diag + 1 else max left up
```

- [ ] **Step 2: add pure metric checks to `test/Spec.hs`.** Import: `import Crucible.Eval.Metrics (normMatch, tokenF1, rougeL)`. Add after the fallback checks (the harness is one flat list of `check` calls; mirror neighbours):

```haskell
  -- crucible-2zw: scalar metrics
  , check "metrics: normMatch ignores case and whitespace"
      (1.0, 0.0) (normMatch "Hello  World" "hello world", normMatch "hello" "goodbye")
  , check "metrics: tokenF1 on a hand-computed overlap"
      True (abs (tokenF1 "a b c d" "c a b" - 6 / 7) < 1e-9)
  , check "metrics: tokenF1 identical and empty cases pinned"
      (1.0, 1.0, 0.0) (tokenF1 "x y" "x y", tokenF1 "" "", tokenF1 "x" "")
  , check "metrics: rougeL on a hand-computed LCS"
      True (abs (rougeL "a b c d" "c a b" - 4 / 7) < 1e-9)
  , check "metrics: rougeL empty cases pinned"
      (1.0, 0.0) (rougeL "" "", rougeL "" "x")
```

Derivations (for the implementer's confidence, not for weakening): reference tokens `a b c d`, candidate `c a b`. tokenF1: multiset overlap 3, precision 3/3, recall 3/4, F1 = 6/7. rougeL: LCS is `a b` (length 2), precision 2/3, recall 2/4, F = 4/7. If a value differs, the CODE is wrong; fix the code, never the expectation.

- [ ] **Step 3: build + suite.** Build exit 0; `zinc test` shows `1 test suite(s) passed`, 242 ok (237 + 5).

- [ ] **Step 4: commit.**

```bash
git add src/Crucible/Eval/Metrics.hs test/Spec.hs
git commit -m "$(printf 'feat(eval): pure scalar metrics (normMatch, tokenF1, rougeL)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: ordinal judging in `Crucible.Eval.Judge` + prompt test

**Files:**
- Modify: `src/Crucible/Eval/Judge.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: add to Judge.hs.** Extend the export list with `Rating (..), ratingCodec, ratePrompt, rateOnce, RateOutcome (..), rate`. Add `import Data.List (sort)` to the existing Data.List import and `int` to the Crucible.Codec import. Then append (mirroring the Verdict/judgeOnce/vote block):

```haskell
-- | The judge's structured ordinal rating. Same field order rationale as
-- 'Verdict': "why" first so the level is conditioned on the reasoning.
data Rating = Rating { why :: Text, level :: Int } deriving (Eq, Show)

ratingCodec :: JSONCodec Rating
ratingCodec = object (Rating <$> field "why"   (.why)   str
                             <*> field "level" (.level) int)

-- | The rating system message; k is the top level of the scale.
rateSystem :: Int -> Message
rateSystem k =
  let kTxt = T.pack (show k)
  in Message System [text|
  You are a strict grader.
  Reason through the rubric and the level anchors in "why" first, quoting the
  part of the output that determines the level, then give the level.
  Length and style are not criteria unless the rubric says so.
  Respond ONLY with JSON {"why": <string>, "level": <int between 1 and ${kTxt}>}.|]

-- | The rater's messages, pure and testable (mirrors 'judgePrompt').
-- Anchors render in ascending level order; sparse anchoring (ends only)
-- is expected. Assembled by concatenation: list blocks do not belong in
-- quasiquotes.
ratePrompt :: Int -> [(Int, Text)] -> Text -> Text -> [Message]
ratePrompt k anchors rubric graded =
  [ rateSystem k
  , Message User $ T.concat $
      ["Rubric: " <> rubric <> "\nLevels:\n"]
        ++ [ T.pack (show l) <> ": " <> d <> "\n" | (l, d) <- sortOn fst anchors ]
        ++ ["Output to grade: " <> graded]
  ]

-- | One rating call with validate-and-repair: a decode failure OR an
-- out-of-range level re-prompts once with the raw reply and the error,
-- then gives up with 'JudgeError'.
rateOnce :: (LLM :> es) => Int -> [(Int, Text)] -> Text -> Text -> Eff es (Either JudgeError Rating)
rateOnce k anchors rubric graded = do
  let msgs = ratePrompt k anchors rubric graded
  raw <- complete msgs
  case checked raw of
    Right v -> pure (Right v)
    Left m1 -> do
      raw2 <- complete
        ( msgs
            ++ [ Message Assistant raw
               , Message User [text|Your reply did not parse: ${m1}. Respond with valid JSON only.|]
               ]
        )
      case checked raw2 of
        Right v -> pure (Right v)
        Left m2 -> pure (Left (JudgeError m2))
  where
    checked raw = case decodeLLM ratingCodec raw of
      Left e -> Left e.message
      Right r
        | r.level < 1 || r.level > k ->
            Left ("level " <> T.pack (show r.level) <> " outside 1.." <> T.pack (show k))
        | otherwise -> Right r

-- | The result of an n-sample ordinal rating. 'why' is a SAMPLE from the
-- median level (the first one); 'dissent' keeps the first rationale from a
-- sample more than one level away from the median, when one was cast.
data RateOutcome
  = Rated { level :: Int, why :: Text, dissent :: Maybe Text, agree :: Int, others :: Int }
  | RateAllErrored Text
  deriving (Eq, Show)

-- | Sample the rater n times (sequentially, no early stop: the median
-- needs the full sample) and aggregate: median level with ties rounding
-- DOWN (the lower middle of an even split), 'agree' counts samples at the
-- median, 'others' the rest. Errored samples are excluded; all errored
-- yields 'RateAllErrored' with the last error.
rate :: (LLM :> es) => Int -> Int -> [(Int, Text)] -> Text -> Text -> Eff es RateOutcome
rate n k anchors rubric graded = do
  rs <- mapM (const (rateOnce k anchors rubric graded)) [1 .. max 1 n]
  let oks  = [r | Right r <- rs]
      errs = [m | Left (JudgeError m) <- rs]
  pure $ case oks of
    [] -> RateAllErrored (last ("" : errs))
    _  ->
      let levels = sort (map (.level) oks)
          med    = levels !! ((length levels - 1) `div` 2)
          agree  = length (filter (== med) levels)
          dis    = case [r.why | r <- oks, abs (r.level - med) > 1] of
                     (d : _) -> Just d
                     []      -> Nothing
          w      = head [r.why | r <- oks, r.level == med]
      in Rated med w dis agree (length levels - agree)
```

Note: `sortOn` is already imported in Judge.hs (used by `shuffleSeeded`). `head` on the median-why list is total: the median is by construction a sampled level. If GHC warns about `head`/incomplete patterns under the project's warning set, use an explicit case with an `error "unreachable: median is sampled"` fallback and report it.

- [ ] **Step 2: add the prompt check to `test/Spec.hs`.** Extend the Judge import in Spec.hs with `ratePrompt` (find the existing `Crucible.Eval.Judge` import and add it; if Spec.hs imports `judgePrompt` from `Crucible.Eval` re-exports instead, import `ratePrompt` qualified from `Crucible.Eval.Judge` and report the adaptation):

```haskell
  -- crucible-2zw: ordinal rating prompt
  , check "ratePrompt: anchors sort ascending; system states the range"
      ("Rubric: r\nLevels:\n1: bad\n5: good\nOutput to grade: out", True)
      (case ratePrompt 5 [(5, "good"), (1, "bad")] "r" "out" of
         [Message _ sys, Message _ u] -> (u, T.isInfixOf "between 1 and 5" sys)
         _ -> ("wrong shape", False))
```

- [ ] **Step 3: build + suite.** `1 test suite(s) passed`, 243 ok.

- [ ] **Step 4: commit.**

```bash
git add src/Crucible/Eval/Judge.hs test/Spec.hs
git commit -m "$(printf 'feat(eval): ordinal rating judge (Rating, ratePrompt, median rate)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: `Metric` + `Scale` expectations and the pass rule

**Files:**
- Modify: `src/Crucible/Eval.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: extend `Expectation` in Eval.hs:**

```haskell
data Expectation a
  = Exactly a              -- ^ must equal (needs Eq a)
  | Predicate (a -> Bool)  -- ^ must satisfy
  | Rubric Text            -- ^ LLM-as-judge against this rubric
  | Checklist [Criterion]  -- ^ weighted binary criteria, judged one by one
  | Grounded Text          -- ^ every factual claim in the output must be
                           --   supported by this evidence (derived claims)
  | Metric Double (a -> Double)
                           -- ^ pass threshold, scalar metric in [0,1]
                           --   (see "Crucible.Eval.Metrics"); the scalar IS
                           --   the score value, passing at value >= threshold
  | Scale Int Text [(Int, Text)]
                           -- ^ pass level, rubric, anchored levels: an
                           --   LLM-rated ordinal scale (1..k, k = highest
                           --   anchor); value = (level-1)/(k-1), passing at
                           --   the pass level. Anchor at least the ends.
```

- [ ] **Step 2: dispatch in `scoreWith`.** Extend the Judge import line in Eval.hs with `RateOutcome (..), rate`. Add two arms (and extend the Haddock on `scoreWith` to note `Scale`, like `Checklist`/`Grounded`, takes opts.votes but ignores examples):

```haskell
  Metric _ f   -> let v = max 0.0 (min 1.0 (f actual))
                  in pure (score v ("metric = " <> T.pack (show v)))
  Scale _ r as -> scaleScore opts.votes r as (render actual)
```

and the helper (place after `checklistScore`):

```haskell
-- | Rate the rendered output on an anchored 1..k scale; the median level
-- normalizes to (level-1)/(k-1). Single-vote keeps votes/dissent Nothing,
-- like 'judgeWith'. A scale whose anchors do not reach level 2 is a judge
-- error (never a division by zero).
scaleScore :: (LLM :> es) => Int -> Text -> [(Int, Text)] -> Text -> Eff es Score
scaleScore n rubric anchors rendered
  | k <= 1 = pure (score 0.0 "judge error: a scale needs anchors up to level 2 or higher")
  | otherwise = do
      out <- rate n k anchors rubric rendered
      pure $ case out of
        RateAllErrored m -> score 0.0 ("judge error: " <> m)
        Rated lvl w d agree others ->
          Score (fromIntegral (lvl - 1) / fromIntegral (k - 1))
            ("level " <> T.pack (show lvl) <> " of " <> T.pack (show k) <> ": " <> w)
            (if n <= 1 then Nothing else Just (agree, others))
            (if n <= 1 then Nothing else d)
  where k = maximum (0 : map fst anchors)
```

- [ ] **Step 3: the pass rule.** Add near `runEvalWith`:

```haskell
-- | Pass condition per expectation: 'Metric' passes at its threshold,
-- 'Scale' at its pass level, everything else at value 1.0.
passes :: Expectation a -> Double -> Bool
passes (Metric t _) v = v >= t
passes (Scale p _ anchors) v =
  let k = maximum (1 : map fst anchors)
  in k > 1 && v >= fromIntegral (p - 1) / fromIntegral (k - 1)
passes _ v = v >= 1.0
```

and change `runEvalWith`'s aggregation (ONLY the `pr` line changes; `mean` stays on raw values):

```haskell
runEvalWith opts render sut cases = do
  rs <- mapM run1 cases
  let vals   = map (\Result{score = s} -> s.value) rs
      len    = length rs
      mean   = if len == 0 then 0 else sum vals / fromIntegral len
      passed = length [() | Result{case' = Case{expect = ex}, score = s} <- rs, passes ex s.value]
      pr     = if len == 0 then 0 else fromIntegral passed / fromIntegral len
  pure (Report rs pr mean)
```

Also update the `Report`/`passRate`-related Haddock on `Criterion` if it states the value >= 1.0 rule as universal (it says a checklist case "passes ... only when every criterion holds", which remains true; no change needed unless wording conflicts). Update the module header's first sentence to mention deterministic scalar metrics.

- [ ] **Step 4: scripted tests.** Add to `test/Spec.hs` after the metric checks (the `Metric`/`Scale` constructors arrive via the existing `Crucible.Eval` import; extend it if the import list is explicit):

```haskell
  -- crucible-2zw: Metric expectation + pass rule
  , check "metric: scalars land in meanScore; threshold gates passRate"
      (0.5, 0.5)
      (let rep = runPureEff (runLLMScripted []
                   (runEval id pure
                      [ Case ("hello" :: Text) "hit"  (Metric 0.5 (normMatch "Hello "))
                      , Case "bye" "miss" (Metric 0.5 (normMatch "Hello ")) ]))
       in (rep.passRate, rep.meanScore))
  , check "metric: values clamp into [0,1]"
      (1.0, 0.0)
      (let s1 = runPureEff (runLLMScripted [] (scoreM id (Metric 1.0 (const 1.5)) ("x" :: Text)))
           s0 = runPureEff (runLLMScripted [] (scoreM id (Metric 0.0 (const (-0.5))) ("x" :: Text)))
       in (s1.value, s0.value))
  -- crucible-2zw: Scale expectation
  , check "scale: single vote level 4 of 5"
      (0.75, "level 4 of 5: polite", Nothing)
      (let s = runPureEff (runLLMScripted ["{\"why\":\"polite\",\"level\":4}"]
                 (scoreM id (Scale 4 "politeness" [(1, "rude"), (5, "warm")]) ("out" :: Text)))
       in (s.value, s.rationale, s.votes))
  , check "scale: median of (3,4,4) is 4 with tally (2,1), no dissent at spread 1"
      (0.75, Just (2, 1), Nothing)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"meh\",\"level\":3}"
                 , "{\"why\":\"good\",\"level\":4}"
                 , "{\"why\":\"good\",\"level\":4}" ]
                 (scoreN 3 id (Scale 4 "r" [(1, "bad"), (5, "good")]) ("out" :: Text)))
       in (s.value, s.votes, s.dissent))
  , check "scale: spread beyond one level records dissent"
      (Just (2, 1), Just "awful")
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"awful\",\"level\":1}"
                 , "{\"why\":\"good\",\"level\":4}"
                 , "{\"why\":\"good\",\"level\":4}" ]
                 (scoreN 3 id (Scale 4 "r" [(1, "bad"), (5, "good")]) ("out" :: Text)))
       in (s.votes, s.dissent))
  , check "scale: out-of-range level takes the judge-error path"
      (0.0, True)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"x\",\"level\":7}", "{\"why\":\"x\",\"level\":9}" ]
                 (scoreM id (Scale 4 "r" [(1, "bad"), (5, "good")]) ("out" :: Text)))
       in (s.value, T.isInfixOf "judge error: " s.rationale))
  , check "scale: anchors without a top level are a judge error"
      (0.0, True)
      (let s = runPureEff (runLLMScripted []
                 (scoreM id (Scale 1 "r" [(1, "only")]) ("out" :: Text)))
       in (s.value, T.isInfixOf "judge error: " s.rationale))
  -- crucible-2zw: per-expectation pass rule, mixed dataset
  , check "passRate: per-expectation thresholds across a mixed dataset"
      (2 / 3, 2 / 3)
      (let rep = runPureEff (runLLMScripted ["{\"why\":\"mid\",\"level\":3}"]
                   (runEval id pure
                      [ Case ("x" :: Text) "exact" (Exactly "x")
                      , Case "y" "metric-borderline" (Metric 0.5 (const 0.5))
                      , Case "z" "scale-fail" (Scale 4 "r" [(1, "bad"), (5, "good")]) ]))
       in (rep.passRate, rep.meanScore))
```

Semantics behind the expectations: the out-of-range test consumes BOTH scripted replies (parse succeeds, range check fails, repair re-prompt, fails again, sample errors, single vote all-errored). The mixed test: values 1.0 (exact), 0.5 (metric, passes at its 0.5 threshold by `>=`), 0.5 (level 3 of 5, needs level 4 = 0.75, fails); passRate 2/3, mean (1 + 0.5 + 0.5)/3 = 2/3. If a result differs, investigate the CODE; do not weaken an expectation.

- [ ] **Step 5: build + suite.** `1 test suite(s) passed`, 251 ok (243 + 8).

- [ ] **Step 6: commit.**

```bash
git add src/Crucible/Eval.hs test/Spec.hs
git commit -m "$(printf 'feat(eval): Metric and Scale expectations with per-expectation pass rule\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: demo + live smoke + docs

**Files:**
- Modify: `app/Main.hs`
- Modify: `docs/evals.md`

- [ ] **Step 1: demo.** In `app/Main.hs`, after the improveSkill block (the `TIO.putStrLn ("improveSkill: ...` line, ~line 153) and BEFORE the `-- OpenAI:` section, add (adjust indentation to the surrounding `do`; `scoreM` and the `Scale` constructor come from `Crucible.Eval`, extend the import list if explicit):

```haskell
      -- Scale: an anchored 1-to-5 politeness rating, judged live.
      politeness <- runEff (Anthropic.run cfg (scoreM id
        (Scale 4 "Rate how polite this reply is"
           [(1, "rude"), (5, "warm and courteous")])
        ("Thanks so much for waiting, happy to help!" :: T.Text)))
      TIO.putStrLn ("scale: " <> politeness.rationale)
```

- [ ] **Step 2: build + live smoke.** (Keys in `.env`, gitignored; NEVER print, echo, or cat them.)

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: existing demo output plus a line starting `scale: level ` (the model should rate the canned friendly reply 4 or 5 of 5; either is a pass for the smoke; the exact level is not pinned); exit 0.

- [ ] **Step 3: docs.** In `docs/evals.md` (read it first; match its voice and heading depth), add a `## Scalar metrics and ordinal scales` section after the judging/checklist material and before the calibration section, covering:

- The choosing rule as a short ladder: code-graded (`Exactly`, `Predicate`) where rules suffice; `Metric` where the DEGREE of match is the signal; `Rubric` for holistic pass/fail judgement; `Scale` where quality is subjective and graded by degree.
- `Metric threshold f`: the scalar is the score value (so `meanScore` tracks it across runs), the case passes at `value >= threshold`, mirroring how success criteria are stated ("F1 of at least 0.85"). The three shipped metrics with one-line definitions (`normMatch`, `tokenF1`, `rougeL`, reference-first for partial application), each pure and offline.
- `Scale passLevel rubric anchors`: anchors are structured `(level, description)` pairs the judge sees as lines, not prose; anchor at least the ends; k is the highest anchor level; value normalizes as (level-1)/(k-1); with votes the median level wins and a sample more than one level out lands in `dissent`; pass at the pass level.
- One code example using both in a dataset (reuse the mixed-dataset shape from the tests, with `rougeL` in the Metric).
- Limits: scales ignore few-shot examples for now; `calibrate` stays binary (weighted kappa for ordinals is future work); no BLEU (corpus-level, misleading per case); embeddings/cosine similarity tracked separately.

House style is STRICT: no emdashes/endashes (`grep -n $'—\|–' docs/evals.md` must stay empty), no hype words, never mention a project called "manifest".

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/evals.md
git commit -m "$(printf 'docs(site)+demo: Metric and Scale graders, scale rating proven live\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 5: merge + publish + close

**Files:** none.

- [ ] **Step 1: full suite.** `... zinc test` shows `1 test suite(s) passed`, 251 ok.
- [ ] **Step 2: merge + push.** Via `superpowers:finishing-a-development-branch` (the user historically picks "merge back to master locally"); after merge: suite on master, `git push`, Pages build reaches `built`.
- [ ] **Step 3: close the bead.**

```bash
bd close crucible-2zw --reason="Shipped: Metric and Scale expectations with in-expectation pass thresholds, per-expectation passRate rule, Crucible.Eval.Metrics (normMatch/tokenF1/rougeL), ordinal median-vote rating in Eval.Judge, 14 hermetic tests, live scale rating proof, evals.md section."
```

---

## Self-Review

**1. Spec coverage:** Expectation constructors -> Task 3 Step 1 (signatures match the spec exactly). Metric pure scoring with clamp -> Task 3 Step 2. Scale via `rate` with median/ties-down/dissent-beyond-one-level, no early stop, votes-as-(agree, others) -> Task 2 Step 1 + Task 3 Step 2. Pass rule in `passes` consulted by `runEvalWith`, mean unchanged -> Task 3 Step 3. Degenerate k <= 1 guard -> `scaleScore` first clause + test. Metrics module with the three functions, reference-first, base+text only -> Task 1. Out-of-range = repair-then-error path -> `rateOnce` `checked` + test. Scale ignores examples (it never reads `opts.examples`) -> by construction, noted in the scoreWith Haddock update. Demo + live smoke -> Task 4 Steps 1-2. Docs incl. limits -> Task 4 Step 3. Non-goals absent from all tasks. ✅

**2. Placeholder scan:** none. Every code step shows complete code; the docs step enumerates its content rather than deferring it. ✅

**3. Type consistency:** `rate :: Int -> Int -> [(Int, Text)] -> Text -> Text -> Eff es RateOutcome` (votes, k, anchors, rubric, rendered) matches the `scaleScore` call `rate n k anchors rubric rendered`; `Rated lvl w dis agree others` field order matches the constructor; `ratingCodec` uses `int` which `Crucible.Codec` exports; `ratePrompt 5 [(5, "good"), (1, "bad")] "r" "out"` in the test matches `ratePrompt :: Int -> [(Int, Text)] -> Text -> Text -> [Message]`; `Metric Double (a -> Double)` arms use `Metric _ f` in scoreWith and `Metric t _` in passes; check counts: 237 + 5 (Task 1) + 1 (Task 2) + 8 (Task 3) = 251. ✅ (The bead close message says 14 tests: 5 + 1 + 8 = 14.) ✅
