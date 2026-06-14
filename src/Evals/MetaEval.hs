{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Meta-eval reporting: gather (caseKey, human, Maybe judge) verdict tuples
-- for a labelled run and feed crucible's 'Cal.reportFromVerdicts'. Two modes:
-- 'Live' re-judges each labelled (output, criterion) with our real
-- 'CriterionJudge' (same transcript path as pointed scoring); 'Stored' reads
-- the per-criterion @met@ from an existing run's 'Score.detail'.
module Evals.MetaEval
  ( MetaMode (..)
  , metaReport
  , saveMetaEval
  ) where

import Data.Aeson (Value (..), toJSON)
import qualified Data.Aeson.Types as AT
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Time (getCurrentTime)

import qualified Crucible.Eval.Calibrate as Cal
import Manifest
import Manifest.Postgres (Pool)

import Evals.Grade (Criterion' (..), CriterionJudge, CriterionVerdict (..), criteriaFromExpected, transcript)
import Evals.Ids
import Evals.Schema

-- | How to obtain the judge verdict for each labelled case.
data MetaMode
  = Live CriterionJudge   -- ^ re-judge with our real judge
  | Stored                -- ^ read from the run's Score.detail (for the gv)

-- | Build a calibration report for a labelled run under one grader version.
-- Returns Left on a missing run / grader version.
metaReport :: Pool -> Int -> MetaMode -> RunId -> GraderVersionId -> IO (Either Text Cal.CalibrationReport)
metaReport pool seed mode runId gvId = do
  loaded <- withSession pool $ do
    mgv <- get @GraderVersion (Key gvId)
    mr  <- get @Run (Key runId)
    case (mgv, mr) of
      (Nothing, _)        -> pure (Left "grader version not found")
      (_, Nothing)        -> pure (Left "run not found")
      (Just gv, Just run) -> do
        mtv  <- get @TargetVersion (Key run.targetVersion)
        outs <- selectWhere [ #run ==. runId ] :: Db [Output]
        rows <- mapM (\o -> do
                  me  <- get @Example (Key o.example)
                  lbs <- selectWhere [ #output ==. o.id ] :: Db [CriterionLabel]
                  scs <- selectWhere [ #output ==. o.id, #graderVersion ==. gvId ] :: Db [Score]
                  pure (o, me, lbs, listToMaybe scs)) outs
        pure (Right (gv, mtv, rows))
  case loaded of
    Left e -> pure (Left e)
    Right (gv, mtv, rows) -> do
      tuples <- concat <$> mapM (caseTuples mode gv mtv) rows
      pure (Right (Cal.reportFromVerdicts seed tuples))

-- | The verdict tuples for one output's labels.
caseTuples
  :: MetaMode -> GraderVersion -> Maybe TargetVersion
  -> (Output, Maybe Example, [CriterionLabel], Maybe Score)
  -> IO [(Text, Bool, Maybe Bool)]
caseTuples mode gv mtv (out, mExample, lbls, mScore) = mapM one lbls
  where
    sysPrompt = maybe "" (\tv -> tv.prompt) mtv
    one lbl = do
      let caseKey = maybe lbl.criterion (\e -> e.key <> ":" <> lbl.criterion) mExample
      judged <- verdict lbl
      pure (caseKey, lbl.human, judged)
    verdict lbl = case mode of
      Stored -> pure (mScore >>= \s -> aesonV s.detail >>= storedMet lbl.criterion)
      Live judge -> case mExample of
        Nothing -> pure Nothing
        Just e  -> case findCriterion lbl.criterion e of
          Nothing -> pure Nothing
          Just c  ->
            -- NB meta-eval is lenient vs scoreRun: a missing transcript/system
            -- prompt or output text yields "" here rather than erroring the case.
            case transcript sysPrompt (aesonOrNull e.input) (fromMaybe "" out.text) of
              Left _   -> pure Nothing
              Right tx -> either (const Nothing) (Just . (\v -> v.met)) <$> judge gv tx c

-- | Persist a calibration report as a 'MetaEval' row (append/history).
saveMetaEval :: Pool -> RunId -> GraderVersionId -> Text -> Int
             -> Cal.CalibrationReport -> IO MetaEval
saveMetaEval pool rid gvid modeT seed rep = do
  now <- getCurrentTime
  withSession pool $ add (MetaEval
    { id = MetaEvalId 0, run = rid, graderVersion = gvid, mode = modeT, seed = seed
    , agreement = rep.agreement, kappa = rep.kappa
    , kappaLow = fst rep.kappaCI, kappaHigh = snd rep.kappaCI
    , failPrecision = rep.failPrecision, failRecall = rep.failRecall
    , passF1 = rep.passF1, failF1 = rep.failF1, balancedF1 = rep.balancedF1
    , measured = rep.measured, judgeErrors = Aeson (toJSON rep.judgeErrors)
    , computedAt = now } :: MetaEval)

aesonV :: Maybe (Aeson Value) -> Maybe Value
aesonV = fmap (\(Aeson x) -> x)

aesonOrNull :: Aeson Value -> Value
aesonOrNull (Aeson x) = x

findCriterion :: Text -> Example -> Maybe Criterion'
findCriterion name e = case criteriaFromExpected e.expected of
  Right cs -> listToMaybe [ c | c <- cs, c.criterion == name ]
  Left _   -> Nothing

storedMet :: Text -> Value -> Maybe Bool
storedMet name v = AT.parseMaybe p v >>= lookup name
  where p = AT.withObject "detail" $ \o -> do
              arr <- o AT..: "criteria"
              mapM (AT.withObject "c" $ \c -> (,) <$> c AT..: "criterion" <*> c AT..: "met") (arr :: [Value])
