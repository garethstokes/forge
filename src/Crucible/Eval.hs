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
  , JudgeExample (..), JudgeOpts (..), defaultJudgeOpts
  , judgeWith, runEvalWith, scoreWith
  , runEval, runEvalN, scoreM, scoreN, judge, judgeN, renderReport
  , groundingCheck
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful

import Crucible.Eval.Grounding (GroundingOutcome (..), groundingOutcome)
import Crucible.Eval.Judge (JudgeExample (..), JudgeOpts (..), Verdict (..), VoteOutcome (..), defaultJudgeOpts, vote)
import Crucible.LLM (LLM)

-- | What a case's output is checked against.
data Expectation a
  = Exactly a              -- ^ must equal (needs Eq a)
  | Predicate (a -> Bool)  -- ^ must satisfy
  | Rubric Text            -- ^ LLM-as-judge against this rubric
  | Checklist [Criterion]  -- ^ weighted binary criteria, judged one by one
  | Grounded Text          -- ^ every factual claim in the output must be
                           --   supported by this evidence (derived claims)

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
-- uncertain on this case, and 'dissent' carries the first losing-side
-- rationale. The rationale of a voted score is a SAMPLE from the majority
-- side, not the reason the vote went that way. Deterministic scores carry
-- 'Nothing' for both.
data Score = Score
  { value     :: Double
  , rationale :: Text
  , votes     :: Maybe (Int, Int)
  , dissent   :: Maybe Text
  }
  deriving (Eq, Show)

-- | Score with no vote tally.
score :: Double -> Text -> Score
score v r = Score v r Nothing Nothing

data Result i a = Result { case' :: Case i a, output :: a, score :: Score }
data Report i a = Report { results :: [Result i a], passRate :: Double, meanScore :: Double }

-- | LLM-as-judge with explicit options (votes, few-shot examples).
judgeWith :: (LLM :> es) => JudgeOpts -> (a -> Text) -> Text -> a -> Eff es Score
judgeWith opts render rubric actual =
  voteScore (opts.votes <= 1) <$> vote True opts rubric (render actual)

-- | LLM-as-judge, single sample (equivalent to @'judgeN' 1@).
judge :: (LLM :> es) => (a -> Text) -> Text -> a -> Eff es Score
judge = judgeWith defaultJudgeOpts

-- | LLM-as-judge with n-sample majority voting (use odd n; the vote stops
-- early once decided, so n=3 typically costs ~2 calls). For n > 1 the tally
-- is recorded in 'votes'; n <= 1 keeps 'votes' = Nothing. An all-errored
-- vote yields the judge-error score (value 0, rationale tagged
-- @judge error: @). Cost note: each sample is one judge call, two if its
-- reply needs the repair re-prompt.
judgeN :: (LLM :> es) => Int -> (a -> Text) -> Text -> a -> Eff es Score
judgeN n = judgeWith defaultJudgeOpts { votes = n }

-- | Convert a vote outcome to a Score; the Bool suppresses the tally for
-- single-sample judging.
voteScore :: Bool -> VoteOutcome -> Score
voteScore _      (AllErrored m)      = score 0.0 ("judge error: " <> m)
voteScore single (Decided p w d y f) =
  Score (if p then 1.0 else 0.0) w
    (if single then Nothing else Just (y, f))
    (if single then Nothing else d)

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

-- | Score one output against its expectation, single-sample judging.
scoreM :: (Eq a, LLM :> es) => (a -> Text) -> Expectation a -> a -> Eff es Score
scoreM = scoreWith defaultJudgeOpts

-- | 'scoreM' with n-vote judging for 'Rubric' cases and for each
-- 'Checklist' criterion. Pure for Exactly/Predicate.
scoreN :: (Eq a, LLM :> es) => Int -> (a -> Text) -> Expectation a -> a -> Eff es Score
scoreN n = scoreWith defaultJudgeOpts { votes = n }

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
      out <- vote True defaultJudgeOpts { votes = n } ("the output must satisfy: " <> c.label) (render actual)
      pure $ case out of
        AllErrored m      -> (c, False, "judge error: " <> m)
        Decided p w _ _ _ -> (c, p, w)

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

-- | 'runEval' with n-vote judging for Rubric cases and Checklist criteria.
runEvalWith :: (Eq a, LLM :> es)
            => JudgeOpts -> (a -> Text) -> (i -> Eff es a) -> [Case i a]
            -> Eff es (Report i a)
runEvalWith opts render sut cases = do
  rs <- mapM run1 cases
  let vals = map (\Result{score = s} -> s.value) rs
      len  = length rs
      mean = if len == 0 then 0 else sum vals / fromIntegral len
      pr   = if len == 0 then 0 else fromIntegral (length (filter (>= 1.0) vals)) / fromIntegral len
  pure (Report rs pr mean)
  where
    run1 c@Case{input = i, expect = ex} = do
      out <- sut i
      s   <- scoreWith opts render ex out
      pure (Result c out s)

-- | Run a system-under-test over a dataset and aggregate, single-sample
-- judging (equivalent to @'runEvalN' 1@).
runEval :: (Eq a, LLM :> es) => (a -> Text) -> (i -> Eff es a) -> [Case i a] -> Eff es (Report i a)
runEval = runEvalWith defaultJudgeOpts

-- | 'runEval' with n-vote judging for Rubric cases and Checklist criteria.
runEvalN :: (Eq a, LLM :> es) => Int -> (a -> Text) -> (i -> Eff es a) -> [Case i a] -> Eff es (Report i a)
runEvalN n = runEvalWith defaultJudgeOpts { votes = n }

-- | A human-readable report: one line per case, then a summary. Voted
-- scores show the tally and label their rationale as majority-side (a
-- sample from the winning votes, not the reason the vote went that way);
-- contested cases are flagged with the dissenting rationale shown, and
-- judge errors are called out.
renderReport :: Report i a -> Text
renderReport Report{results = rs, passRate = pr, meanScore = ms} =
  T.intercalate "\n" $
  [ caseName <> ": " <> tshow s.value <> " (" <> body s <> ")" <> annot s
  | Result{case' = Case{name = caseName}, score = s} <- rs ]
  ++ [ "", "pass-rate: " <> tshow pr <> "  mean: " <> tshow ms ]
  where
    tshow :: Show x => x -> Text
    tshow = T.pack . show
    body s = case s.votes of
      Just _  -> "majority-side rationale: " <> s.rationale
      Nothing -> s.rationale
    annot s = tally s <> uncertain s <> jerr s
    tally s = case s.votes of
      Just (y, f) -> "  [votes " <> tshow y <> "-" <> tshow f <> "]"
      Nothing     -> ""
    uncertain s = case s.votes of
      Just (y, f) | y > 0 && f > 0 ->
        "  [judge uncertain: review by hand"
          <> maybe "" ("; dissent: " <>) s.dissent
          <> "]"
      _ -> ""
    jerr s = if "judge error: " `T.isInfixOf` s.rationale then "  [judge error]" else ""
