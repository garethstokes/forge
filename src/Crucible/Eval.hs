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
