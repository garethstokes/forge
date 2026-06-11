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
  , calibrateWith
  , calibrate
  , renderCalibration
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful

import Crucible.Eval.Judge (JudgeExample (..), JudgeOpts (..), VoteOutcome (..), balanceBy, defaultJudgeOpts, vote)
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
  }
  deriving (Eq, Show)

-- | Pure metric computation from outcomes + report shape fields.
reportFrom :: [(Text, Bool, VoteOutcome)] -> Int -> Int -> CalibrationReport
reportFrom outcomes exampleCount_ measured_ =
  CalibrationReport po kap fPrec fRec cont errs exampleCount_ measured_
  where
    errs   = [nm | (nm, _, AllErrored _) <- outcomes]
    judged = [(nm, h, p, y, f) | (nm, h, Decided p _ _ y f) <- outcomes]
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
      opts = JudgeOpts { votes = n, examples = exs }
  outcomes <- mapM (\(nm, a, h) -> (nm, h,) <$> vote False opts rubric (render a)) holdout
  pure (reportFrom outcomes (length exs) (length holdout))

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
  , "fail precision: " <> tshow r.failPrecision
  , "fail recall:    " <> tshow r.failRecall
  ]
  ++ [ "contested (label these next): " <> T.intercalate ", " r.contested | not (null r.contested) ]
  ++ [ "judge errors: " <> T.intercalate ", " r.judgeErrors | not (null r.judgeErrors) ]
  ++ [ "examples fed: " <> tshowI r.exampleCount <> "  measured on: " <> tshowI r.measured
     | r.exampleCount > 0 ]
  where
    tshow  = T.pack . show
    tshowI = T.pack . show @Int
