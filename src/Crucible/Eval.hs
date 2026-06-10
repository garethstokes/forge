{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

module Crucible.Eval
  ( Case(..), Expectation(..), Score(..), Verdict(..)
  , Result(..), Report(..)
  , runEval, scoreM, judge, renderReport
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import NeatInterpolation (text)
import Crucible.LLM (LLM, complete, Message(..), Role(..))
import Crucible.Codec (JSONCodec, object, field, str, bool)
import Crucible.SAP (decodeLLM)

-- | What a case's output is checked against.
data Expectation a
  = Exactly a              -- ^ must equal (needs Eq a)
  | Predicate (a -> Bool)  -- ^ must satisfy
  | Rubric Text            -- ^ LLM-as-judge against this rubric

-- | One dataset row.
data Case i a = Case { input :: i, name :: Text, expect :: Expectation a }

-- | A score in [0,1] with a rationale.
data Score = Score { value :: Double, rationale :: Text } deriving (Eq, Show)

data Result i a = Result { case' :: Case i a, output :: a, score :: Score }
data Report i a = Report { results :: [Result i a], passRate :: Double, meanScore :: Double }

-- | The judge's structured verdict.
data Verdict = Verdict { pass :: Bool, why :: Text } deriving (Eq, Show)

verdictCodec :: JSONCodec Verdict
verdictCodec = object (Verdict <$> field "pass" (\Verdict{pass = p} -> p) bool
                               <*> field "why"  (\Verdict{why  = w} -> w) str)

-- | LLM-as-judge: a Codec-backed prompt grading an output against a rubric.
judge :: (LLM :> es) => (a -> Text) -> Text -> a -> Eff es Score
judge render rubric actual = do
  raw <- complete
    [ Message System [text|You are a strict grader. Respond ONLY with JSON {"pass": <bool>, "why": <string>}.|]
    , Message User [text|Rubric: ${rubric}
Output to grade: ${graded}|] ]
  pure $ case decodeLLM verdictCodec raw of
    Right Verdict{pass = vp, why = vw} -> Score (if vp then 1.0 else 0.0) vw
    Left e                              -> Score 0.0 ("judge parse error: " <> T.pack e)
  where graded = render actual

-- | Score one output against its expectation. Pure for Exactly/Predicate; the
-- model is consulted only for Rubric.
scoreM :: (Eq a, LLM :> es) => (a -> Text) -> Expectation a -> a -> Eff es Score
scoreM render exp_ actual = case exp_ of
  Exactly e   -> pure (Score (ind (actual == e)) (if actual == e then "exact match" else "mismatch"))
  Predicate p -> pure (Score (ind (p actual)) (if p actual then "predicate held" else "predicate failed"))
  Rubric r    -> judge render r actual
  where ind b = if b then 1.0 else 0.0

-- | Run a system-under-test over a dataset and aggregate.
runEval :: (Eq a, LLM :> es) => (a -> Text) -> (i -> Eff es a) -> [Case i a] -> Eff es (Report i a)
runEval render sut cases = do
  rs <- mapM run1 cases
  let vals = map (\Result{score = Score{value = v}} -> v) rs
      n    = length rs
      mean = if n == 0 then 0 else sum vals / fromIntegral n
      pass = if n == 0 then 0 else fromIntegral (length (filter (>= 1.0) vals)) / fromIntegral n
  pure (Report rs pass mean)
  where
    run1 c@Case{input = i, expect = ex} = do
      out <- sut i
      s   <- scoreM render ex out
      pure (Result c out s)

-- | A human-readable report: one line per case, then a summary.
renderReport :: Report i a -> Text
renderReport Report{results = rs, passRate = pr, meanScore = ms} =
  T.intercalate "\n" $
  [ caseName <> ": " <> tshow scoreVal <> " (" <> scoreRat <> ")"
  | Result{case' = Case{name = caseName}, score = Score{value = scoreVal, rationale = scoreRat}} <- rs ]
  ++ [ "", "pass-rate: " <> tshow pr <> "  mean: " <> tshow ms ]
  where tshow = T.pack . show
