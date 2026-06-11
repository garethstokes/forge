{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeApplications #-}
module ApiSpec (main) where

import Control.Monad (unless)
import Data.Aeson (FromJSON, ToJSON, Value, decode, encode, object, (.=))
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import Evals.Api

-- server spec imports
import Network.HTTP.Client (defaultManagerSettings, httpLbs, newManager, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Network.Wai.Handler.Warp (testWithApplication)

import Manifest (Aeson (..), add, withSession)
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)

import Evals.Dashboard (dashboardApp)
import Evals.Ids
import Evals.Migrate (migrateAll)
import Evals.Schema

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

rt :: (Eq a, Show a, ToJSON a, FromJSON a) => String -> a -> IO ()
rt msg x = expect (msg <> ": " <> show x) (decode (encode x) == Just x)

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 11) 0

main :: IO ()
main = do
  rt "MetricDto" MetricDto
    { graderName = "exact-match"
    , graderVersion = 1
    , mean = 0.85
    , passRate = Just 0.9
    , count = 100
    }
  rt "ScoreDto" ScoreDto
    { graderName = "exact-match"
    , graderVersion = 1
    , value = Just 1.0
    , passed = Just True
    , scoreError = Nothing
    , rationale = Just "correct answer"
    }
  rt "OutputRowDto" OutputRowDto
    { exampleKey = "row-001"
    , outputText = Just "the answer"
    , outputError = Nothing
    , latencyMs = Just 312
    , tokens = Just (object ["input" .= (412 :: Int), "output" .= (96 :: Int)])
    , scores =
        [ ScoreDto
            { graderName = "exact-match"
            , graderVersion = 1
            , value = Just 1.0
            , passed = Just True
            , scoreError = Nothing
            , rationale = Nothing
            }
        ]
    }
  rt "DatasetVersionDto" DatasetVersionDto
    { datasetVersionId = 7
    , version = 2
    , finalizedAt = Just t0
    , exampleCount = 50
    }
  rt "DatasetDto" DatasetDto
    { datasetId = 3
    , name = "MMLU Subset"
    , slug = "mmlu-subset"
    , versions =
        [ DatasetVersionDto
            { datasetVersionId = 7
            , version = 2
            , finalizedAt = Just t0
            , exampleCount = 50
            }
        ]
    }
  rt "RunSummaryDto" RunSummaryDto
    { runId = 42
    , datasetVersionId = 7
    , datasetName = "MMLU Subset"
    , datasetVersion = 2
    , targetName = "gpt-4o-harness"
    , targetVersion = 1
    , model = "gpt-4o"
    , status = "finished"
    , startedAt = Just t0
    , finishedAt = Just t0
    , metrics =
        [ MetricDto
            { graderName = "exact-match"
            , graderVersion = 1
            , mean = 0.85
            , passRate = Just 0.9
            , count = 100
            }
        ]
    }
  rt "RunDetailDto" RunDetailDto
    { run = RunSummaryDto
        { runId = 42
        , datasetVersionId = 7
        , datasetName = "MMLU Subset"
        , datasetVersion = 2
        , targetName = "gpt-4o-harness"
        , targetVersion = 1
        , model = "gpt-4o"
        , status = "running"
        , startedAt = Nothing
        , finishedAt = Nothing
        , metrics = []
        }
    , outputs =
        [ OutputRowDto
            { exampleKey = "row-001"
            , outputText = Just "the answer"
            , outputError = Nothing
            , latencyMs = Just 312
            , tokens = Nothing
            , scores = []
            }
        ]
    }
  rt "CompareRowDto" CompareRowDto
    { exampleKey = "row-001"
    , outputA = Just "answer A"
    , outputB = Just "answer B"
    , errorA = Nothing
    , errorB = Nothing
    , scoreA = Just 1.0
    , scoreB = Just 0.0
    , passedA = Just True
    , passedB = Just False
    , delta = Just 1.0
    }
  rt "CompareDto" CompareDto
    { runA = RunSummaryDto
        { runId = 42
        , datasetVersionId = 7
        , datasetName = "MMLU Subset"
        , datasetVersion = 2
        , targetName = "gpt-4o-harness"
        , targetVersion = 1
        , model = "gpt-4o"
        , status = "finished"
        , startedAt = Just t0
        , finishedAt = Just t0
        , metrics = []
        }
    , runB = RunSummaryDto
        { runId = 43
        , datasetVersionId = 7
        , datasetName = "MMLU Subset"
        , datasetVersion = 2
        , targetName = "claude-harness"
        , targetVersion = 1
        , model = "claude-3-5-sonnet"
        , status = "finished"
        , startedAt = Just t0
        , finishedAt = Just t0
        , metrics = []
        }
    , graderName = Just "exact-match"
    , graderVersion = Just 1
    , rows =
        [ CompareRowDto
            { exampleKey = "row-001"
            , outputA = Just "answer A"
            , outputB = Just "answer B"
            , errorA = Nothing
            , errorB = Nothing
            , scoreA = Just 1.0
            , scoreB = Just 0.0
            , passedA = Just True
            , passedB = Just False
            , delta = Just 1.0
            }
        , CompareRowDto
            { exampleKey = "row-002"
            , outputA = Nothing
            , outputB = Just "answer B"
            , errorA = Just "target timed out"
            , errorB = Nothing
            , scoreA = Nothing
            , scoreB = Just 1.0
            , passedA = Nothing
            , passedB = Just True
            , delta = Nothing
            }
        ]
    }
  -- A compare with no scores on either side: the grader is unnamed.
  rt "CompareDto (no grader)" CompareDto
    { runA = RunSummaryDto
        { runId = 44
        , datasetVersionId = 7
        , datasetName = "MMLU Subset"
        , datasetVersion = 2
        , targetName = "gpt-4o-harness"
        , targetVersion = 1
        , model = "gpt-4o"
        , status = "finished"
        , startedAt = Just t0
        , finishedAt = Just t0
        , metrics = []
        }
    , runB = RunSummaryDto
        { runId = 45
        , datasetVersionId = 7
        , datasetName = "MMLU Subset"
        , datasetVersion = 2
        , targetName = "claude-harness"
        , targetVersion = 1
        , model = "claude-3-5-sonnet"
        , status = "finished"
        , startedAt = Just t0
        , finishedAt = Just t0
        , metrics = []
        }
    , graderName = Nothing
    , graderVersion = Nothing
    , rows = []
    }
  rt "ApiError" ApiError { error = "not found" }
  -- Golden wire assertions: pin the exact JSON shape, not just the round-trip.
  expect "ApiError wire shape" $
    (decode (encode (ApiError "x")) :: Maybe Value)
      == Just (object ["error" .= ("x" :: Text)])
  expect "MetricDto wire key set" $
    ( decode
        ( encode
            MetricDto
              { graderName = "exact-match"
              , graderVersion = 1
              , mean = 0.85
              , passRate = Just 0.9
              , count = 100
              }
        )
        :: Maybe Value
    )
      == Just
        ( object
            [ "graderName" .= ("exact-match" :: Text)
            , "graderVersion" .= (1 :: Int)
            , "mean" .= (0.85 :: Double)
            , "passRate" .= (0.9 :: Double)
            , "count" .= (100 :: Int)
            ]
        )
  serverSpec
  putStrLn "manifest-evals ApiSpec: dto round-trips + api OK"

serverSpec :: IO ()
serverSpec = withEphemeralDb $ \pool -> do
  _ <- withSession pool migrateAll
  now <- getCurrentTime
  -- Seed the database
  (runId_, dvId) <- withSession pool $ do
    d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "demo", slug = "demo", createdAt = now } :: Dataset)
    v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    e1 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e1", input = Aeson (object ["q" .= ("1" :: Text)]), expected = Nothing, meta = Nothing } :: Example)
    e2 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e2", input = Aeson (object ["q" .= ("2" :: Text)]), expected = Nothing, meta = Nothing } :: Example)
    t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "tgt", createdAt = now } :: Target)
    tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "claude-x", prompt = "SYS", params = Aeson (object []), createdAt = now } :: TargetVersion)
    r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "succeeded", startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
    o1 <- add (Output { id = OutputId 0, run = r.id, example = e1.id, response = Nothing, text = Just "hello", error = Nothing, latencyMs = Just 42, tokens = Nothing } :: Output)
    o2 <- add (Output { id = OutputId 0, run = r.id, example = e2.id, response = Nothing, text = Nothing, error = Just "llm: boom", latencyMs = Nothing, tokens = Nothing } :: Output)
    g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "exactness", kind = "exact", createdAt = now } :: Grader)
    gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
    _  <- add (Score { id = ScoreId 0, output = o1.id, graderVersion = gv.id, value = Just 1.0, passed = Just True, detail = Just (Aeson (object ["rationale" .= ("exact match" :: Text)])), error = Nothing, createdAt = now } :: Score)
    -- o2 has no score (errored output)
    _  <- add (RunMetric { id = RunMetricId 0, run = r.id, graderVersion = gv.id, mean = 1.0, passRate = Just 1.0, count = 1, computedAt = now } :: RunMetric)
    pure (r.id, v.id)
  mgr <- newManager defaultManagerSettings
  testWithApplication (pure (dashboardApp pool "static")) $ \port -> do
    let getReq path = parseRequest ("http://localhost:" <> show port <> path) >>= flip httpLbs mgr
    -- /api/datasets
    r1 <- getReq "/api/datasets"
    expect "datasets 200" (statusCode (responseStatus r1) == 200)
    expect "datasets shape" (case decode (responseBody r1) :: Maybe [DatasetDto] of
      Just [d] -> d.name == "demo" && length d.versions == 1
                    && (head d.versions).exampleCount == 2
      _ -> False)
    -- /api/runs
    r2 <- getReq "/api/runs"
    expect "runs shape" (case decode (responseBody r2) :: Maybe [RunSummaryDto] of
      Just [r] -> r.status == "succeeded" && r.model == "claude-x"
                    && r.datasetName == "demo"
                    && (case r.metrics of [m] -> m.graderName == "exactness" && m.mean == 1.0; _ -> False)
      _ -> False)
    -- filter by datasetVersion: bogus id yields []
    r2b <- getReq "/api/runs?datasetVersion=999999"
    expect "runs filter" (decode (responseBody r2b) == Just ([] :: [RunSummaryDto]))
    -- run detail
    let RunId runIdInt = runId_
    r3 <- getReq ("/api/runs/" <> show runIdInt)
    expect "detail 200" (statusCode (responseStatus r3) == 200)
    expect "detail outputs ordered by key" (case decode (responseBody r3) :: Maybe RunDetailDto of
      Just rd ->
        let outs = rd.outputs
        in length outs == 2
           && (head outs).exampleKey == "e1"
           && (head outs).outputText == Just "hello"
           && (head outs).latencyMs == Just 42
           && (case (head outs).scores of
                 [s] -> s.value == Just 1.0
                         && s.passed == Just True
                         && s.rationale == Just "exact match"
                 _ -> False)
           && (outs !! 1).exampleKey == "e2"
           && (outs !! 1).outputError == Just "llm: boom"
           && null (outs !! 1).scores
      _ -> False)
    -- unknown run -> 404 + ApiError
    r4 <- getReq "/api/runs/999999"
    expect "unknown run 404" (statusCode (responseStatus r4) == 404)
    expect "unknown run ApiError" ((decode (responseBody r4) :: Maybe ApiError) /= Nothing)
    -- unknown api route -> 404
    r5 <- getReq "/api/nope"
    expect "unknown api route 404" (statusCode (responseStatus r5) == 404)
    -- filter by datasetVersion with the real id
    let DatasetVersionId dvInt = dvId
    r6 <- getReq ("/api/runs?datasetVersion=" <> show dvInt)
    expect "runs filter real dvId" (case decode (responseBody r6) :: Maybe [RunSummaryDto] of
      Just [_] -> True
      _ -> False)
