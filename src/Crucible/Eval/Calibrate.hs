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
  , bootstrapKappa
  , bootstrapStdErr
  , reportFromVerdicts
  , calibrateWith
  , calibrate
  , renderCalibration
  ) where

import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Effectful

import Crucible.Eval.Judge (JudgeExample (..), JudgeOpts (..), VoteOutcome (..), balanceBy, defaultJudgeOpts, vote, xorshiftInts)
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
  , exampleCount  :: Int     -- ^ number of examples fed to the judge
  , measured      :: Int     -- ^ number of holdout cases metrics are computed over
  , kappaCI       :: (Double, Double)  -- ^ 95% bootstrap interval for kappa
  , abstained     :: [Text]            -- ^ case names where the judge abstained
  }
  deriving (Eq, Show)

-- | Resamples used for the kappa confidence interval.
bootstrapResamples :: Int
bootstrapResamples = 1000

-- | Cohen's kappa over (human, judge) verdict pairs, with the degenerate
-- rules shared by the headline metric: empty input and expected agreement
-- of 1 both yield 0.
kappaOf :: [(Bool, Bool)] -> Double
kappaOf [] = 0
kappaOf ps =
  let total = length ps
      agree = length [() | (h, j) <- ps, h == j]
      hYes  = length [() | (True, _) <- ps]
      jYes  = length [() | (_, True) <- ps]
      hNo   = total - hYes
      jNo   = total - jYes
      po    = fromIntegral agree / fromIntegral total
      pe    = fromIntegral (jYes * hYes + jNo * hNo)
                / fromIntegral (total * total)
  in if pe >= 1 then 0 else (po - pe) / (1 - pe)

-- | 95% bootstrap confidence interval for kappa: resample the pairs with
-- replacement to the original size, recompute kappa per resample, sort,
-- and take the 2.5th and 97.5th percentile elements. Deterministic for a
-- given seed. Zero or one pair collapses to the point estimate.
bootstrapKappa :: Int -> Int -> [(Bool, Bool)] -> (Double, Double)
bootstrapKappa seed resamples pairs
  | length pairs <= 1 || resamples <= 0 = (k0, k0)
  | otherwise =
      let n     = length pairs
          idxs  = map (\x -> abs x `mod` n) (xorshiftInts seed)
          group r = [pairs !! i | i <- take n (drop (r * n) idxs)]
          ks    = sort [kappaOf (group r) | r <- [0 .. resamples - 1]]
          loIdx = (resamples * 25) `div` 1000
          hiIdx = max loIdx ((resamples * 975) `div` 1000 - 1)
      in (ks !! loIdx, ks !! hiIdx)
  where k0 = kappaOf pairs

-- | Bootstrap standard error of the mean: resample @xs@ with replacement to its
-- own size @resamples@ times, take each resample's mean, return the standard
-- deviation of those means. Deterministic per seed. 0 for <=1 value or
-- resamples<=0 (no spread to estimate).
bootstrapStdErr :: Int -> Int -> [Double] -> Double
bootstrapStdErr seed resamples xs
  | length xs <= 1 || resamples <= 0 = 0
  | otherwise =
      let n       = length xs
          idxs    = map (\x -> abs x `mod` n) (xorshiftInts seed)
          group r = [xs !! i | i <- take n (drop (r * n) idxs)]
          means   = [ sum (group r) / fromIntegral n | r <- [0 .. resamples - 1] ]
          mbar    = sum means / fromIntegral resamples
          var     = sum [ (m - mbar) ** 2 | m <- means ] / fromIntegral resamples
      in sqrt var

-- | Pure metric computation from outcomes + report shape fields.
reportFrom :: Int -> [(Text, Bool, VoteOutcome)] -> Int -> Int -> CalibrationReport
reportFrom seed outcomes exampleCount_ measured_ =
  CalibrationReport po kap fPrec fRec cont errs exampleCount_ measured_ ci abst
  where
    errs   = [nm | (nm, _, AllErrored _) <- outcomes]
    abst   = [nm | (nm, _, AllAbstained _) <- outcomes]
    judged = [(nm, h, p, y, f) | (nm, h, Decided p _ _ y f) <- outcomes]
    pairs  = [(h, p) | (_, h, p, _, _) <- judged]
    total  = length judged
    agree  = length [() | (_, h, p, _, _) <- judged, h == p]
    po     = ratio agree total 0
    kap    = kappaOf pairs
    ci     = bootstrapKappa seed bootstrapResamples pairs
    jFails = [(h') | (_, h', False, _, _) <- judged]
    fPrec  = ratio (length (filter not jFails)) (length jFails) 1
    hFails = [(p') | (_, False, p', _, _) <- judged]
    fRec   = ratio (length (filter not hFails)) (length hFails) 1
    cont   = [nm | (nm, _, _, y, f) <- judged, y > 0, f > 0]
    ratio :: Int -> Int -> Double -> Double
    ratio _ 0 dflt = dflt
    ratio num den _ = fromIntegral num / fromIntegral den

-- | Build a calibration report from externally-acquired verdicts: each case is
-- (name, human, Just judge) or (name, human, Nothing) when the judge errored or
-- was unavailable. For callers that judge OUTSIDE crucible (a transcript-aware
-- grader, or stored verdicts read back from a database). Tally-derived fields
-- ('contested', 'abstained') are empty — a plain verdict carries no vote tally;
-- 'exampleCount' is 0; 'measured' counts the non-errored cases.
reportFromVerdicts :: Int -> [(Text, Bool, Maybe Bool)] -> CalibrationReport
reportFromVerdicts seed cases =
  CalibrationReport po kap fPrec fRec [] errs 0 (length judged) ci []
  where
    errs   = [nm | (nm, _, Nothing) <- cases]
    judged = [(h, j) | (_, h, Just j) <- cases]
    total  = length judged
    agree  = length [() | (h, j) <- judged, h == j]
    po     = ratio agree total 0
    kap    = kappaOf judged
    ci     = bootstrapKappa seed bootstrapResamples judged
    jFails = [h | (h, False) <- judged]   -- judge said not-met
    fPrec  = ratio (length (filter not jFails)) (length jFails) 1
    hFails = [j | (False, j) <- judged]   -- human said not-met
    fRec   = ratio (length (filter not hFails)) (length hFails) 1
    ratio :: Int -> Int -> Double -> Double
    ratio _ 0 dflt = dflt
    ratio num den _ = fromIntegral num / fromIntegral den

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
      opts = defaultJudgeOpts { votes = n, examples = exs }
  outcomes <- mapM (\(nm, a, h) -> (nm, h,) <$> vote False opts rubric (render a)) holdout
  pure (reportFrom seed outcomes (length exs) (length holdout))

-- | Run the judge (full n-sample voting, no early stop, so margins are
-- comparable) over hand-labelled outputs.
calibrate :: (LLM :> es)
          => Int -> (a -> Text) -> Text
          -> [(Text, a, Bool)]
          -> Eff es CalibrationReport
calibrate = calibrateWith 0 0

-- | A short human-readable rendering of a calibration report.
renderCalibration :: CalibrationReport -> Text
renderCalibration r = T.intercalate "\n" $
  [ "agreement:      " <> tshow r.agreement
  , "kappa:          " <> tshow r.kappa
      <> "  [95% CI " <> tshow lo <> ", " <> tshow hi <> "]"
  , "fail precision: " <> tshow r.failPrecision
  , "fail recall:    " <> tshow r.failRecall
  ]
  ++ [ "contested (label these next): " <> T.intercalate ", " r.contested | not (null r.contested) ]
  ++ [ "judge errors: " <> T.intercalate ", " r.judgeErrors | not (null r.judgeErrors) ]
  ++ [ "judge abstained: " <> T.intercalate ", " r.abstained | not (null r.abstained) ]
  ++ [ "examples fed: " <> tshowI r.exampleCount <> "  measured on: " <> tshowI r.measured
     | r.exampleCount > 0 ]
  where
    (lo, hi) = r.kappaCI
    tshow  = T.pack . show
    tshowI = T.pack . show @Int
