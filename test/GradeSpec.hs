{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module GradeSpec (main) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)

import qualified Crucible.Eval as Eval
import Manifest
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)

import Evals.Execute (ExecError (..))
import Evals.Grade
import Evals.Ids
import Evals.Migrate (migrateAll)
import Evals.Schema

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = do
  configSpec
  exactSpec
  withEphemeralDb $ \pool -> do
    _ <- withSession pool migrateAll
    now <- getCurrentTime
    engineSpec pool now
    errorRowSpec pool now
    resumeSpec pool now
    metricSpec pool now
  putStrLn "manifest-evals GradeSpec: config + exact + engine + resume + metrics OK"

configSpec :: IO ()
configSpec = do
  expect "votes default 1" (votesFrom (object []) == 1)
  expect "votes read" (votesFrom (object ["votes" .= (3 :: Int)]) == 3)
  expect "rubric read"
    (fmap (const ()) (rubricFrom (object ["rubric" .= ("be kind" :: Text)])) == Right ())
  expect "rubric missing is an error" (isLeft (rubricFrom (object [])))
  let cs = criteriaFrom (object ["criteria" .=
            [ object ["label" .= ("cites a URL" :: Text)]
            , object ["label" .= ("polite" :: Text), "weight" .= (2.5 :: Double)] ]])
  expect "criteria labels+weights (weight defaults 1)"
    (fmap (map (\c -> (c.label, c.weight))) cs
       == Right [("cites a URL", 1), ("polite", 2.5)])
  expect "criteria missing is an error" (isLeft (criteriaFrom (object [])))
  expect "criteria empty is an error" (isLeft (criteriaFrom (object ["criteria" .= ([] :: [Value])])))

exactSpec :: IO ()
exactSpec = do
  let val = fmap (.value)
  expect "exact string pass"
    (val (gradeExact (Just (Aeson (toJSON ("4" :: Text)))) (Just " 4\n")) == Right 1.0)
  expect "exact string fail"
    (val (gradeExact (Just (Aeson (toJSON ("4" :: Text)))) (Just "5")) == Right 0.0)
  expect "exact structural pass"
    (val (gradeExact (Just (Aeson (object ["a" .= (1 :: Int)]))) (Just "{\"a\": 1}")) == Right 1.0)
  expect "exact unparseable output is a FAIL, not an error"
    (val (gradeExact (Just (Aeson (object []))) (Just "not json")) == Right 0.0)
  expect "missing expected is an error" (isLeft (gradeExact Nothing (Just "x")))
  expect "missing output text is an error" (isLeft (gradeExact (Just (Aeson (toJSON ("x" :: Text)))) Nothing))
  expect "judge-error score detected"
    (isJudgeError (Eval.score 0.0 "judge error: all samples failed"))
  expect "ordinary zero score is not a judge error"
    (isJudgeError (Eval.score 0.0 "mismatch") == False)

-- Seeding -----------------------------------------------------------------

data SeededG = SeededG
  { runId :: RunId, outputIds :: [OutputId], gvId :: GraderVersionId }

-- One run with two GOOD outputs ("out-a" with expected "out-a", "out-b" with
-- expected "nope") + one ERRORED output, and one grader of the given kind.
seedScoring :: Pool -> UTCTime -> Text -> Value -> IO SeededG
seedScoring pool now kind config = withSession pool $ do
  d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "g", slug = "g", createdAt = now } :: Dataset)
  v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  e1 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e1"
                     , input = Aeson (toJSON ("q1" :: Text)), expected = Just (Aeson (toJSON ("out-a" :: Text))), meta = Nothing } :: Example)
  e2 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e2"
                     , input = Aeson (toJSON ("q2" :: Text)), expected = Just (Aeson (toJSON ("nope" :: Text))), meta = Nothing } :: Example)
  e3 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e3"
                     , input = Aeson (toJSON ("q3" :: Text)), expected = Nothing, meta = Nothing } :: Example)
  t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
  tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "SYS"
                           , params = Aeson (object []), createdAt = now } :: TargetVersion)
  r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "succeeded"
                 , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
  o1 <- add (Output { id = OutputId 0, run = r.id, example = e1.id, response = Nothing, text = Just "out-a"
                    , error = Nothing, latencyMs = Just 1, tokens = Nothing } :: Output)
  o2 <- add (Output { id = OutputId 0, run = r.id, example = e2.id, response = Nothing, text = Just "out-b"
                    , error = Nothing, latencyMs = Just 1, tokens = Nothing } :: Output)
  o3 <- add (Output { id = OutputId 0, run = r.id, example = e3.id, response = Nothing, text = Nothing
                    , error = Just "llm: boom", latencyMs = Just 1, tokens = Nothing } :: Output)
  g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "g", kind = kind, createdAt = now } :: Grader)
  gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson config, createdAt = now } :: GraderVersion)
  pure SeededG { runId = r.id, outputIds = [o1.id, o2.id, o3.id], gvId = gv.id }

scoresFor :: Pool -> GraderVersionId -> IO [Score]
scoresFor pool gv = withSession pool (selectWhere [ #graderVersion ==. gv ])

noRunner :: GradeRunner
noRunner _ _ _ = ioError (userError "runner must not be called for exact")

-- Scenarios ----------------------------------------------------------------

-- exact end-to-end: no runner call; pass + fail rows; errored output skipped.
engineSpec :: Pool -> UTCTime -> IO ()
engineSpec pool now = do
  sd <- seedScoring pool now "exact" (object [])
  outcome <- scoreRun pool 2 noRunner sd.runId [sd.gvId]
  expect "exact: outcome" (outcome == ScoreOutcome { total = 3, scored = 2, errored = 0, skipped = 1 })
  ss <- scoresFor pool sd.gvId
  expect "exact: one pass one fail"
    (sort (map (.value) ss) == [Just 0.0, Just 1.0])
  expect "exact: passed mirrors value"
    (sort (map (.passed) ss) == [Just False, Just True])
  expect "exact: details carry rationales" (all (isJust . (.detail)) ss)

-- rubric: recording runner sees the expectation+text; canned scores persist
-- with votes in detail; a judge-error canned score becomes an error row.
errorRowSpec :: Pool -> UTCTime -> IO ()
errorRowSpec pool now = do
  sd <- seedScoring pool now "rubric" (object ["rubric" .= ("be right" :: Text), "votes" .= (3 :: Int)])
  ref <- newIORef ([] :: [Text])
  let runner gv expn t = do
        case expn of
          Eval.Rubric r -> do
            let Aeson c = gv.config
            atomicModifyIORef' ref (\acc -> (acc ++ [r <> "|" <> t <> "|" <> T.pack (show (votesFrom c))], ()))
          _ -> ioError (userError "expected a Rubric expectation")
        pure $ if t == "out-a"
          then Right (Eval.Score { value = 1.0, rationale = "good", votes = Just (2, 1) })
          else Right (Eval.score 0.0 "judge error: all samples failed")
  outcome <- scoreRun pool 1 runner sd.runId [sd.gvId]
  expect "rubric: outcome" (outcome == ScoreOutcome { total = 3, scored = 1, errored = 1, skipped = 1 })
  calls <- readIORef ref
  expect "rubric: runner saw config rubric + text + votes"
    (sort calls == ["be right|out-a|3", "be right|out-b|3"])
  ss <- scoresFor pool sd.gvId
  let good = [ s | s <- ss, isNothing s.error ]
      bad  = [ s | s <- ss, isJust s.error ]
  expect "rubric: one graded row with votes in detail"
    (map (.value) good == [Just 1.0]
       && map (.detail) good == [Just (Aeson (object ["rationale" .= ("good" :: Text), "votes" .= [2 :: Int, 1]]))])
  expect "rubric: judge error became an error row (value NULL)"
    (map (.value) bad == [Nothing] && all (isNothing . (.passed)) bad)

-- resume: good rows skipped; errored rows deleted + re-graded once.
resumeSpec :: Pool -> UTCTime -> IO ()
resumeSpec pool now = do
  sd <- seedScoring pool now "exact" (object [])
  _ <- scoreRun pool 1 noRunner sd.runId [sd.gvId]
  outcome2 <- scoreRun pool 1 noRunner sd.runId [sd.gvId]
  expect "resume: all good pairs skipped on re-run"
    (outcome2 == ScoreOutcome { total = 3, scored = 0, errored = 0, skipped = 3 })
  ss <- scoresFor pool sd.gvId
  expect "resume: no duplicate rows" (length ss == 2)
  withSession pool $ update @Score (Key (head [ s.id | s <- ss ]))
    [ #value =. (Nothing :: Maybe Double), #passed =. (Nothing :: Maybe Bool)
    , #detail =. (Nothing :: Maybe (Aeson Value)), #error =. Just "llm: transient" ]
  outcome3 <- scoreRun pool 1 noRunner sd.runId [sd.gvId]
  expect "resume: errored pair re-graded"
    (outcome3 == ScoreOutcome { total = 3, scored = 1, errored = 0, skipped = 2 })
  ss2 <- scoresFor pool sd.gvId
  expect "resume: still two rows, none errored"
    (length ss2 == 2 && all (isNothing . (.error)) ss2)

-- metrics: AVG ignores error rows; recompute replaces.
metricSpec :: Pool -> UTCTime -> IO ()
metricSpec pool now = do
  sd <- seedScoring pool now "rubric" (object ["rubric" .= ("r" :: Text)])
  let runner _ _ t = pure $ if t == "out-a"
        then Right (Eval.score 1.0 "good")
        else Left (LlmError "transient")
  _ <- scoreRun pool 1 runner sd.runId [sd.gvId]
  ms <- withSession pool (selectWhere [ #graderVersion ==. sd.gvId ]) :: IO [RunMetric]
  expect "metric: one row, mean over graded only, count 1"
    (map (\m -> (m.mean, m.passRate, m.count)) ms == [(1.0, Just 1.0, 1)])
  let runner2 _ _ _ = pure (Right (Eval.score 0.0 "bad"))
  _ <- scoreRun pool 1 runner2 sd.runId [sd.gvId]
  ms2 <- withSession pool (selectWhere [ #graderVersion ==. sd.gvId ]) :: IO [RunMetric]
  expect "metric: replaced, now over two graded rows"
    (map (\m -> (m.mean, m.passRate, m.count)) ms2 == [(0.5, Just 0.5, 2)])
