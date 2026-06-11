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
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)

-- server spec imports
import Network.HTTP.Client (defaultManagerSettings, httpLbs, newManager, parseRequest, responseBody, responseHeaders, responseStatus)
import Network.HTTP.Types (hContentType)
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
  rt "ChangeDto" (ChangeDto { table = "outputs", key = Just "42" })
  rt "ChangeDto pk-less" (ChangeDto { table = "scores", key = Nothing })
  expect "ChangeDto wire keys"
    ((decode (encode (ChangeDto "runs" (Just "7"))) :: Maybe Value)
       == Just (object ["table" .= ("runs" :: Text), "key" .= ("7" :: Text)]))
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
  compareSpec
  putStrLn "manifest-evals ApiSpec: dto round-trips + api + compare OK"

serverSpec :: IO ()
serverSpec = withEphemeralDb $ \pool -> do
  _ <- withSession pool migrateAll
  now <- getCurrentTime
  -- Set up temp static directory for static-route coverage tests
  let staticDir = "test-static"
  createDirectoryIfMissing True staticDir
  writeFile (staticDir <> "/probe.css") "body { color: red; }"
  -- Seed the database: insert e2 BEFORE e1 so heap order != key order,
  -- ensuring the sort-by-key in the handler is actually exercised.
  (runId_, dvId) <- withSession pool $ do
    -- Seed "zeta" dataset FIRST (alphabetically after "demo") to verify
    -- /api/datasets returns results in name order, not insertion order.
    dz <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "zeta", slug = "zeta", createdAt = now } :: Dataset)
    _  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = dz.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "demo", slug = "demo", createdAt = now } :: Dataset)
    v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    -- Insert e2 first so DB heap order is e2, e1 — the handler must sort by key.
    e2 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e2", input = Aeson (object ["q" .= ("2" :: Text)]), expected = Nothing, meta = Nothing } :: Example)
    e1 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e1", input = Aeson (object ["q" .= ("1" :: Text)]), expected = Nothing, meta = Nothing } :: Example)
    t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "tgt", createdAt = now } :: Target)
    tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "claude-x", prompt = "SYS", params = Aeson (object []), createdAt = now } :: TargetVersion)
    r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "succeeded", startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
    -- Insert o2 first (matching e2 which was inserted first).
    _  <- add (Output { id = OutputId 0, run = r.id, example = e2.id, response = Nothing, text = Nothing, error = Just "llm: boom", latencyMs = Nothing, tokens = Nothing } :: Output)
    o1 <- add (Output { id = OutputId 0, run = r.id, example = e1.id, response = Nothing, text = Just "hello", error = Nothing, latencyMs = Just 42, tokens = Nothing } :: Output)
    g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "exactness", kind = "exact", createdAt = now } :: Grader)
    gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
    _  <- add (Score { id = ScoreId 0, output = o1.id, graderVersion = gv.id, value = Just 1.0, passed = Just True, detail = Just (Aeson (object ["rationale" .= ("exact match" :: Text)])), error = Nothing, createdAt = now } :: Score)
    -- o2 has no score (errored output)
    _  <- add (RunMetric { id = RunMetricId 0, run = r.id, graderVersion = gv.id, mean = 1.0, passRate = Just 1.0, count = 1, computedAt = now } :: RunMetric)
    pure (r.id, v.id)
  mgr <- newManager defaultManagerSettings
  testWithApplication (pure (dashboardApp pool staticDir)) $ \port -> do
    let getReq path = parseRequest ("http://localhost:" <> show port <> path) >>= flip httpLbs mgr
    -- /api/datasets: 2 datasets, returned in name order (demo < zeta)
    r1 <- getReq "/api/datasets"
    expect "datasets 200" (statusCode (responseStatus r1) == 200)
    expect "datasets shape" (case decode (responseBody r1) :: Maybe [DatasetDto] of
      Just [d1, d2] -> d1.name == "demo"
                         && length d1.versions == 1
                         && (head d1.versions).exampleCount == 2
                         && d2.name == "zeta"
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
    -- run detail: outputs must be ordered by key (e1 < e2) even though
    -- they were inserted in reverse order (e2 first).
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
    -- static file: known file -> 200 text/css with correct body
    r7 <- getReq "/probe.css"
    expect "static probe.css 200" (statusCode (responseStatus r7) == 200)
    expect "static probe.css content-type" $
      lookup hContentType (responseHeaders r7) == Just "text/css"
    expect "static probe.css body" (responseBody r7 == "body { color: red; }")
    -- static file: missing file -> 404
    r8 <- getReq "/missing.css"
    expect "static missing.css 404" (statusCode (responseStatus r8) == 404)
  -- Clean up temp static directory
  removeDirectoryRecursive staticDir

compareSpec :: IO ()
compareSpec = withEphemeralDb $ \pool -> do
  _ <- withSession pool migrateAll
  now <- getCurrentTime
  -- Seed entities for the compare endpoint tests.
  -- dataset "cmp" version 1, four examples: c0 (no output in either run),
  -- c1, c2, c3 (c3 has output only in run A).
  -- c2 inserted FIRST to test sort order.
  (runAId, runBId, runCId) <- withSession pool $ do
    d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "cmp", slug = "cmp", createdAt = now } :: Dataset)
    v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    -- Insert c2 first — heap order != key order, so sort must be exercised.
    c2 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c2", input = Aeson (object []), expected = Nothing, meta = Nothing } :: Example)
    c1 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c1", input = Aeson (object []), expected = Nothing, meta = Nothing } :: Example)
    -- c3: between c2 and c1 in insertion order; has output only in run A.
    c3 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c3", input = Aeson (object []), expected = Nothing, meta = Nothing } :: Example)
    -- c0: no output in either run (tests example-driven alignment).
    _  <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c0", input = Aeson (object []), expected = Nothing, meta = Nothing } :: Example)
    t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "tgt-cmp", createdAt = now } :: Target)
    tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "model-x", prompt = "SYS", params = Aeson (object []), createdAt = now } :: TargetVersion)
    -- Grader "g" (scores both runs) — must be chosen over "h".
    g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "g", kind = "exact", createdAt = now } :: Grader)
    gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
    -- Grader "h" (scores only run A's c1 output) — must NOT be chosen.
    h  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "h", kind = "exact", createdAt = now } :: Grader)
    hv <- add (GraderVersion { id = GraderVersionId 0, grader = h.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
    -- Run A
    rA  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "succeeded", startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
    oA1 <- add (Output { id = OutputId 0, run = rA.id, example = c1.id, response = Nothing, text = Just "a1", error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
    oA2 <- add (Output { id = OutputId 0, run = rA.id, example = c2.id, response = Nothing, text = Just "a2", error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
    _   <- add (Output { id = OutputId 0, run = rA.id, example = c3.id, response = Nothing, text = Just "a3", error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
    -- c0 intentionally has NO output in run A.
    _   <- add (Score { id = ScoreId 0, output = oA1.id, graderVersion = gv.id, value = Just 1.0, passed = Just True,  detail = Nothing, error = Nothing, createdAt = now } :: Score)
    _   <- add (Score { id = ScoreId 0, output = oA2.id, graderVersion = gv.id, value = Just 0.0, passed = Just False, detail = Nothing, error = Nothing, createdAt = now } :: Score)
    -- h scores ONLY oA1 (run A, c1); must not affect grader choice.
    _   <- add (Score { id = ScoreId 0, output = oA1.id, graderVersion = hv.id, value = Just 0.25, passed = Just False, detail = Nothing, error = Nothing, createdAt = now } :: Score)
    _   <- add (RunMetric { id = RunMetricId 0, run = rA.id, graderVersion = gv.id, mean = 0.5, passRate = Just 0.5, count = 2, computedAt = now } :: RunMetric)
    -- Run B (same dataset version, reversed scores; c3 and c0 have no output)
    rB  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "succeeded", startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
    oB1 <- add (Output { id = OutputId 0, run = rB.id, example = c1.id, response = Nothing, text = Just "b1", error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
    oB2 <- add (Output { id = OutputId 0, run = rB.id, example = c2.id, response = Nothing, text = Just "b2", error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
    -- c3 and c0 intentionally have NO output in run B.
    _   <- add (Score { id = ScoreId 0, output = oB1.id, graderVersion = gv.id, value = Just 0.0, passed = Just False, detail = Nothing, error = Nothing, createdAt = now } :: Score)
    _   <- add (Score { id = ScoreId 0, output = oB2.id, graderVersion = gv.id, value = Just 1.0, passed = Just True,  detail = Nothing, error = Nothing, createdAt = now } :: Score)
    _   <- add (RunMetric { id = RunMetricId 0, run = rB.id, graderVersion = gv.id, mean = 0.5, passRate = Just 0.5, count = 2, computedAt = now } :: RunMetric)
    -- Run C: different dataset version (separate dataset, one example, no scores)
    d2 <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "other", slug = "other", createdAt = now } :: Dataset)
    v2 <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d2.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    cx <- add (Example { id = ExampleId 0, datasetVersion = v2.id, key = "cx", input = Aeson (object []), expected = Nothing, meta = Nothing } :: Example)
    rC <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v2.id, targetVersion = tv.id, status = "succeeded", startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
    _  <- add (Output { id = OutputId 0, run = rC.id, example = cx.id, response = Nothing, text = Just "cx1", error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
    pure (rA.id, rB.id, rC.id)
  mgr <- newManager defaultManagerSettings
  testWithApplication (pure (dashboardApp pool "test-static")) $ \port -> do
    let getReq path = parseRequest ("http://localhost:" <> show port <> path) >>= flip httpLbs mgr
        RunId aInt = runAId
        RunId bInt = runBId
        RunId cInt = runCId
    -- Happy path: A vs B
    rAB <- getReq ("/api/compare?a=" <> show aInt <> "&b=" <> show bInt)
    expect "compare AB 200" (statusCode (responseStatus rAB) == 200)
    expect "compare AB shape" $ case decode (responseBody rAB) :: Maybe CompareDto of
      Nothing  -> False
      Just dto ->
        dto.runA.runId == aInt
        && dto.runB.runId == bInt
        && not (null dto.runA.metrics)
        && not (null dto.runB.metrics)
        -- intersection-first: g scored both runs; h only scored run A — must pick g.
        && dto.graderName    == Just "g"
        && dto.graderVersion == Just 1
        -- 4 rows: c0, c1, c2, c3 ordered by example key.
        && length dto.rows == 4
        && let r0 = dto.rows !! 0   -- c0: no output in either run
               r1 = dto.rows !! 1   -- c1
               r2 = dto.rows !! 2   -- c2
               r3 = dto.rows !! 3   -- c3: output only in run A
           -- c0: all-Nothing sides (pins example-driven alignment).
           in r0.exampleKey == "c0"
              && r0.outputA  == Nothing
              && r0.outputB  == Nothing
              && r0.scoreA   == Nothing
              && r0.scoreB   == Nothing
              && r0.delta    == Nothing
              -- c1: g's score (1.0), NOT h's score (0.25).
              && r1.exampleKey == "c1"
              && r1.outputA  == Just "a1"
              && r1.outputB  == Just "b1"
              && r1.scoreA   == Just 1.0
              && r1.scoreB   == Just 0.0
              && r1.passedA  == Just True
              && r1.passedB  == Just False
              && r1.delta    == Just 1.0
              -- c2
              && r2.exampleKey == "c2"
              && r2.outputA  == Just "a2"
              && r2.outputB  == Just "b2"
              && r2.scoreA   == Just 0.0
              && r2.scoreB   == Just 1.0
              && r2.passedA  == Just False
              && r2.passedB  == Just True
              && r2.delta    == Just (-1.0)
              -- c3: output only in run A; no score from g (g only scored c1/c2).
              && r3.exampleKey == "c3"
              && r3.outputA  == Just "a3"
              && r3.outputB  == Nothing
              && r3.scoreA   == Nothing
              && r3.delta    == Nothing
    -- Mismatch: A vs C (different dataset versions) -> 400 + ApiError
    rAC <- getReq ("/api/compare?a=" <> show aInt <> "&b=" <> show cInt)
    expect "compare AC 400" (statusCode (responseStatus rAC) == 400)
    expect "compare AC ApiError" ((decode (responseBody rAC) :: Maybe ApiError) /= Nothing)
    -- Missing parameter -> 400
    rMiss <- getReq "/api/compare?a=1"
    expect "compare missing b 400" (statusCode (responseStatus rMiss) == 400)
    -- Garbage parameter -> 400
    rGarb <- getReq "/api/compare?a=notanint&b=1"
    expect "compare garbage a 400" (statusCode (responseStatus rGarb) == 400)
    -- Unknown id -> 404
    rUnk <- getReq ("/api/compare?a=999999&b=" <> show bInt)
    expect "compare unknown id 404" (statusCode (responseStatus rUnk) == 404)
