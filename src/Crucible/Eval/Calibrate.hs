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
