{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Eval
  ( Case(..), Expectation(..), Score(..), Verdict(..)
  , Result(..), Report(..)
  , runEval, scoreM, judge, renderReport
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import Crucible.LLM (LLM, complete, Message(..), Role(..))
import Crucible.Codec (JSONCodec, object, field, str, bool)
import Crucible.SAP (decodeLLM)

-- | What a case's output is checked against.
data Expectation a
  = Exactly a              -- ^ must equal (needs Eq a)
  | Predicate (a -> Bool)  -- ^ must satisfy
  | Rubric Text            -- ^ LLM-as-judge against this rubric

-- | One dataset row.
data Case i a = Case { caseInput :: i, caseName :: Text, expect :: Expectation a }

-- | A score in [0,1] with a rationale.
data Score = Score { scoreValue :: Double, rationale :: Text } deriving (Eq, Show)

data Result i a = Result { resCase :: Case i a, resOutput :: a, resScore :: Score }
data Report i a = Report { results :: [Result i a], passRate :: Double, meanScore :: Double }

-- | The judge's structured verdict.
data Verdict = Verdict { vPass :: Bool, vWhy :: Text } deriving (Eq, Show)

verdictCodec :: JSONCodec Verdict
verdictCodec = object (Verdict <$> field "vPass" vPass bool <*> field "vWhy" vWhy str)

-- | LLM-as-judge: a Codec-backed prompt grading an output against a rubric.
judge :: (LLM :> es) => (a -> Text) -> Text -> a -> Eff es Score
judge render rubric actual = do
  raw <- complete
    [ Message System "You are a strict grader. Respond ONLY with JSON {\"vPass\": <bool>, \"vWhy\": <string>}."
    , Message User ("Rubric: " <> rubric <> "\nOutput to grade: " <> render actual) ]
  pure $ case decodeLLM verdictCodec raw of
    Right v -> Score (if vPass v then 1.0 else 0.0) (vWhy v)
    Left e  -> Score 0.0 ("judge parse error: " <> T.pack e)

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
  let vals = map (scoreValue . resScore) rs
      n    = length rs
      mean = if n == 0 then 0 else sum vals / fromIntegral n
      pass = if n == 0 then 0 else fromIntegral (length (filter (>= 1.0) vals)) / fromIntegral n
  pure (Report rs pass mean)
  where
    run1 c = do
      out <- sut (caseInput c)
      s   <- scoreM render (expect c) out
      pure (Result c out s)

-- | A human-readable report: one line per case, then a summary.
renderReport :: Report i a -> Text
renderReport rep = T.intercalate "\n" $
  [ caseName (resCase r) <> ": " <> tshow (scoreValue (resScore r)) <> " (" <> rationale (resScore r) <> ")"
  | r <- results rep ]
  ++ [ "", "pass-rate: " <> tshow (passRate rep) <> "  mean: " <> tshow (meanScore rep) ]
  where tshow = T.pack . show
