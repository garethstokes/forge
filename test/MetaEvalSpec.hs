{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module MetaEvalSpec (main) where

import Control.Monad (unless)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)

import Manifest
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)

import qualified Crucible.Eval.Calibrate as Cal
import Data.Aeson (Value, object, toJSON, (.=))
import Evals.Grade (Criterion' (..), CriterionJudge, CriterionVerdict (..))
import Evals.MetaEval (metaReport, MetaMode (..), saveMetaEval)

import Evals.Ids
import Evals.Migrate (migrateAll)
import Evals.Schema
import Evals.MetaEval.Ingest

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = withEphemeralDb $ \pool -> do
  _ <- withSession pool migrateAll
  ingestSpec pool
  now <- getCurrentTime
  storedSpec pool now
  liveSpec pool now
  persistSpec pool now
  putStrLn "manifest-evals MetaEvalSpec: ingest + stored + live + persist OK"

seedRun :: Pool -> UTCTime -> IO (RunId, GraderVersionId, OutputId)
seedRun pool now = withSession pool $ do
  d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "d", slug = "seed-x", createdAt = now } :: Dataset)
  v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  e  <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "k1"
                     , input = Aeson (object ["messages" .= ([] :: [Value])])
                     , expected = Just (Aeson (toJSON
                         [ object ["criterion" .= ("c-good"::Text), "points" .= (5::Double), "tags" .= ([]::[Text])]
                         , object ["criterion" .= ("c-bad"::Text),  "points" .= (5::Double), "tags" .= ([]::[Text])] ]))
                     , meta = Nothing } :: Example)
  t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
  tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "", params = Aeson (object []), createdAt = now } :: TargetVersion)
  r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "succeeded", startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
  o  <- add (Output { id = OutputId 0, run = r.id, example = e.id, response = Nothing, text = Just "ans", error = Nothing, latencyMs = Just 1, tokens = Nothing } :: Output)
  g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "pg", kind = "pointed", createdAt = now } :: Grader)
  gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
  _  <- add (CriterionLabel { id = CriterionLabelId 0, output = o.id, criterion = "c-good", human = True,  source = Nothing, createdAt = now } :: CriterionLabel)
  _  <- add (CriterionLabel { id = CriterionLabelId 0, output = o.id, criterion = "c-bad",  human = False, source = Nothing, createdAt = now } :: CriterionLabel)
  pure (r.id, gv.id, o.id)

storedSpec :: Pool -> UTCTime -> IO ()
storedSpec pool now = do
  (rid, gvid, oid) <- seedRun pool now
  _ <- withSession pool $ add (Score
        { id = ScoreId 0, output = oid, graderVersion = gvid
        , value = Just 0.5, passed = Nothing
        , detail = Just (Aeson (object
            [ "criteria" .= [ object ["criterion" .= ("c-good"::Text), "met" .= True]
                            , object ["criterion" .= ("c-bad"::Text),  "met" .= True] ] ]))
        , error = Nothing, createdAt = now } :: Score)
  rep <- metaReport pool 0 Stored rid gvid
  case rep of
    Left e  -> expect ("stored metaReport: " <> T.unpack e) False
    Right r -> do
      expect "stored: agreement 0.5 (c-bad judge≠human)" (r.agreement == 0.5)
      expect "stored: measured 2"    (r.measured == 2)
      expect "stored: no judge errors" (null r.judgeErrors)

liveSpec :: Pool -> UTCTime -> IO ()
liveSpec pool now = do
  (rid, gvid, _) <- seedRun pool now
  let judge :: CriterionJudge
      judge _ _ _ = pure (Right (CriterionVerdict { met = True, explanation = "" }))
  rep <- metaReport pool 0 (Live judge) rid gvid
  case rep of
    Left e  -> expect ("live metaReport: " <> T.unpack e) False
    Right r -> do
      expect "live: agreement 0.5 (always-met judge vs mixed labels)" (r.agreement == 0.5)
      expect "live: measured 2"    (r.measured == 2)

persistSpec :: Pool -> UTCTime -> IO ()
persistSpec pool now = do
  (rid, gvid, oid) <- seedRun pool now
  _ <- withSession pool $ add (Score
        { id = ScoreId 0, output = oid, graderVersion = gvid
        , value = Just 0.5, passed = Nothing
        , detail = Just (Aeson (object
            [ "criteria" .= [ object ["criterion" .= ("c-good"::Text), "met" .= True]
                            , object ["criterion" .= ("c-bad"::Text),  "met" .= True] ] ]))
        , error = Nothing, createdAt = now } :: Score)
  rep <- metaReport pool 0 Stored rid gvid
  case rep of
    Left e  -> expect ("persist metaReport: " <> T.unpack e) False
    Right r -> do
      _ <- saveMetaEval pool rid gvid "stored" 0 r
      rows <- withSession pool (selectWhere [ #run ==. rid ]) :: IO [MetaEval]
      expect "persist: one row" (length rows == 1)
      case rows of
        [m] -> do
          expect "persist: agreement matches" (m.agreement == r.agreement)
          expect "persist: kappa matches"     (m.kappa == r.kappa)
          expect "persist: measured matches"  (m.measured == r.measured)
          expect "persist: mode/seed"         (m.mode == "stored" && m.seed == 0)
        _ -> expect "persist: exactly one" False
      _ <- saveMetaEval pool rid gvid "stored" 0 r
      rows2 <- withSession pool (selectWhere [ #run ==. rid ]) :: IO [MetaEval]
      expect "persist: append -> two rows" (length rows2 == 2)

opts :: Bool -> MetaLoadOpts
opts skip = MetaLoadOpts
  { file = "test/fixtures/metaeval.jsonl", name = "Meta", slug = "meta"
  , version = 1, format = "generic", skipBad = skip, force = False }

ingestSpec :: Pool -> IO ()
ingestSpec pool = do
  bad <- metaLoad pool (opts False)
  expect "metaLoad refuses unknown-criterion row"
    (case bad of Left (NoSuchCriterion 3 _) -> True; _ -> False)
  good <- metaLoad pool (opts True)
  case good of
    Left e -> expect ("metaLoad --skip-bad should succeed: " <> show e) False
    Right r -> do
      expect "metaLoad seeded 2 examples"  (r.examples == 2)
      expect "metaLoad seeded 3 labels"    (r.labels == 3)
      expect "metaLoad skipped 1 bad row"  (r.skipped == 1)
      outs <- withSession pool (selectWhere [ #run ==. r.runId ]) :: IO [Output]
      expect "metaLoad seeded 2 outputs under the run" (length outs == 2)
      lbls <- withSession pool (selectWhere ([] :: [Cond CriterionLabel])) :: IO [CriterionLabel]
      expect "metaLoad seeded 3 labels total" (length lbls == 3)
      expect "metaLoad output carries the completion text"
        (any (\o -> o.text == Just "4") outs)
      -- re-loading the same slug+version is refused; --force is still refused
      -- because metaLoad always seeds a synthetic Run (DatasetVersion->Run is Restrict).
      again <- metaLoad pool (opts True)
      expect "metaLoad refuses an existing version"
        (case again of Left (AlreadyExists "meta" 1) -> True; _ -> False)
      forced <- metaLoad pool (MetaLoadOpts
        { file = "test/fixtures/metaeval.jsonl", name = "Meta", slug = "meta"
        , version = 1, format = "generic", skipBad = True, force = True })
      case forced of
        Left e   -> expect ("metaLoad --force should replace, got: " <> show e) False
        Right r2 -> do
          expect "force: replaced run id differs from the original" (r2.runId /= r.runId)
          expect "force: examples replaced (2, not 4)" (r2.examples == 2)
          lbls2 <- withSession pool (selectWhere ([] :: [Cond CriterionLabel])) :: IO [CriterionLabel]
          expect "force: labels replaced not accumulated (3, not 6)" (length lbls2 == 3)
