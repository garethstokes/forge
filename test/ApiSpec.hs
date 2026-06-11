{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
module ApiSpec (main) where

import Control.Monad (unless)
import Data.Aeson (FromJSON, ToJSON, Value, decode, encode, object, (.=))
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Evals.Api

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
  putStrLn "manifest-evals ApiSpec: dto round-trips OK"
