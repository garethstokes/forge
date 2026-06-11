{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
module ApiSpec (main) where

import Control.Monad (unless)
import Data.Aeson (FromJSON, ToJSON, decode, encode)
import Data.Time (UTCTime (..), fromGregorian)
import Evals.Api

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

rt :: (Eq a, Show a, ToJSON a, FromJSON a) => String -> a -> IO ()
rt msg x = expect msg (decode (encode x) == Just x)

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
        , status = "finished"
        , startedAt = Just t0
        , finishedAt = Just t0
        , metrics = []
        }
    , outputs =
        [ OutputRowDto
            { exampleKey = "row-001"
            , outputText = Just "the answer"
            , outputError = Nothing
            , latencyMs = Just 312
            , scores = []
            }
        ]
    }
  rt "CompareRowDto" CompareRowDto
    { exampleKey = "row-001"
    , outputA = Just "answer A"
    , outputB = Just "answer B"
    , scoreA = Just 1.0
    , scoreB = Just 0.0
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
    , rows =
        [ CompareRowDto
            { exampleKey = "row-001"
            , outputA = Just "answer A"
            , outputB = Just "answer B"
            , scoreA = Just 1.0
            , scoreB = Just 0.0
            , delta = Just 1.0
            }
        ]
    }
  rt "ApiError" ApiError { error = "not found" }
  putStrLn "manifest-evals ApiSpec: dto round-trips OK"
