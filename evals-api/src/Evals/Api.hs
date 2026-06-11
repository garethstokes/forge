{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

-- | The dashboard's JSON wire types. Pure data — this package is compiled
-- into BOTH the native server and the wasm UI, so it depends only on
-- base/text/time/aeson. Entities never cross the wire; the server maps
-- entity -> DTO ("Evals.Dashboard"). Ids are plain Ints (typed ids stay
-- server-side).
module Evals.Api
  ( DatasetDto (..), DatasetVersionDto (..)
  , RunSummaryDto (..), MetricDto (..)
  , RunDetailDto (..), OutputRowDto (..), ScoreDto (..)
  , CompareDto (..), CompareRowDto (..)
  , ApiError (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

data DatasetDto = DatasetDto
  { datasetId :: Int, name :: Text, slug :: Text, versions :: [DatasetVersionDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data DatasetVersionDto = DatasetVersionDto
  { datasetVersionId :: Int, version :: Int, finalizedAt :: Maybe UTCTime, exampleCount :: Int }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data MetricDto = MetricDto
  { graderName :: Text, graderVersion :: Int, mean :: Double, passRate :: Maybe Double, count :: Int }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data RunSummaryDto = RunSummaryDto
  { runId :: Int, datasetVersionId :: Int, datasetName :: Text, datasetVersion :: Int
  , targetName :: Text, targetVersion :: Int, model :: Text
  , status :: Text, startedAt :: Maybe UTCTime, finishedAt :: Maybe UTCTime
  , metrics :: [MetricDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data ScoreDto = ScoreDto
  { graderName :: Text, graderVersion :: Int, value :: Maybe Double
  , passed :: Maybe Bool, scoreError :: Maybe Text, rationale :: Maybe Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data OutputRowDto = OutputRowDto
  { exampleKey :: Text, outputText :: Maybe Text, outputError :: Maybe Text
  , latencyMs :: Maybe Int, scores :: [ScoreDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data RunDetailDto = RunDetailDto
  { run :: RunSummaryDto, outputs :: [OutputRowDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data CompareRowDto = CompareRowDto
  { exampleKey :: Text, outputA :: Maybe Text, outputB :: Maybe Text
  , scoreA :: Maybe Double, scoreB :: Maybe Double, delta :: Maybe Double }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data CompareDto = CompareDto
  { runA :: RunSummaryDto, runB :: RunSummaryDto, rows :: [CompareRowDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

newtype ApiError = ApiError { error :: Text }
  deriving (Eq, Show, Generic)
instance ToJSON ApiError
instance FromJSON ApiError
