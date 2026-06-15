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
  , RunSummaryDto (..), MetricDto (..), TagMetricDto (..), RubricCriterionDto (..)
  , RunDetailDto (..), OutputRowDto (..), ScoreDto (..)
  , CompareDto (..), CompareRowDto (..)
  , PromptMsgDto (..), CriterionVerdictDto (..), GradeDto (..), ExampleDetailDto (..)
  , MetaEvalDto (..), CalibrationSeriesDto (..), TrendPointDto (..)
  , ApiError (..)
  , ChangeDto (..)
  ) where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

data DatasetDto = DatasetDto
  { datasetId :: Int, name :: Text, slug :: Text, versions :: [DatasetVersionDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data DatasetVersionDto = DatasetVersionDto
  { datasetVersionId :: Int, version :: Int, finalizedAt :: Maybe UTCTime, exampleCount :: Int }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data TagMetricDto = TagMetricDto
  { tag :: Text, mean :: Double, stderr :: Maybe Double, count :: Int }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data RubricCriterionDto = RubricCriterionDto
  { criterion :: Text, points :: Double, tags :: [Text] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data MetricDto = MetricDto
  { graderName :: Text, graderVersion :: Int, graderKind :: Text
  , mean :: Double, passRate :: Maybe Double, count :: Int
  , stderr :: Maybe Double
  , breakdowns :: [TagMetricDto]
  , criteria :: [RubricCriterionDto]
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

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
  , latencyMs :: Maybe Int, tokens :: Maybe Value, scores :: [ScoreDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data RunDetailDto = RunDetailDto
  { run          :: RunSummaryDto
  , outputs      :: [OutputRowDto]          -- the requested page
  , totalOutputs :: Int                     -- full row count for the run
  , calibration  :: [CalibrationSeriesDto]
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data CompareRowDto = CompareRowDto
  { exampleKey :: Text, outputA :: Maybe Text, outputB :: Maybe Text
  , errorA :: Maybe Text, errorB :: Maybe Text
  , scoreA :: Maybe Double, scoreB :: Maybe Double
  , passedA :: Maybe Bool, passedB :: Maybe Bool, delta :: Maybe Double }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | graderName/graderVersion: the single grader whose scores the v1 compare
-- shows (Nothing when no scores exist on either side).
data CompareDto = CompareDto
  { runA :: RunSummaryDto, runB :: RunSummaryDto
  , graderName :: Maybe Text, graderVersion :: Maybe Int
  , rows :: [CompareRowDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data PromptMsgDto = PromptMsgDto { role :: Text, content :: Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data CriterionVerdictDto = CriterionVerdictDto
  { criterion :: Text, points :: Double, tags :: [Text], met :: Bool, explanation :: Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data GradeDto = GradeDto
  { graderName :: Text, graderVersion :: Int, graderKind :: Text
  , value :: Maybe Double, passed :: Maybe Bool, rationale :: Maybe Text
  , gradeError :: Maybe Text, criteria :: [CriterionVerdictDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data ExampleDetailDto = ExampleDetailDto
  { runId :: Int, exampleKey :: Text
  , input :: Value, prompt :: [PromptMsgDto]
  , responseText :: Maybe Text, responseError :: Maybe Text
  , grades :: [GradeDto]
  , prevKey :: Maybe Text, nextKey :: Maybe Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | One persisted calibration report, denormalised with grader identity and
-- the server-computed verdict ('trusted' = κ CI lower bound ≥ threshold) and
-- 'band' (Landis–Koch). 'judgeErrors' is a count (the stored array's length).
data MetaEvalDto = MetaEvalDto
  { graderName    :: Text
  , graderVersion :: Int
  , graderKind    :: Text
  , mode          :: Text
  , agreement     :: Double
  , kappa         :: Double
  , kappaLow      :: Double
  , kappaHigh     :: Double
  , failPrecision :: Double
  , failRecall    :: Double
  , passF1        :: Double
  , failF1        :: Double
  , balancedF1    :: Double
  , measured      :: Int
  , judgeErrors   :: Int
  , computedAt    :: Text
  , trusted       :: Bool
  , band          :: Text
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | One point on a grader version's κ-over-time trend. 'isCurrent' marks the
-- run being viewed (run-detail only; always False in the cross-run view).
data TrendPointDto = TrendPointDto
  { runId      :: Int
  , kappa      :: Double
  , kappaLow   :: Double
  , kappaHigh  :: Double
  , computedAt :: Text
  , isCurrent  :: Bool
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | A grader version's calibration history under one mode: the latest report
-- plus the κ trend (chronological, oldest → newest).
data CalibrationSeriesDto = CalibrationSeriesDto
  { graderName    :: Text
  , graderVersion :: Int
  , graderKind    :: Text
  , mode          :: Text
  , latest        :: MetaEvalDto
  , trend         :: [TrendPointDto]
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

newtype ApiError = ApiError { error :: Text }
  deriving (Eq, Show, Generic)
instance ToJSON ApiError
instance FromJSON ApiError

-- | One change-feed wake-up forwarded over SSE: current state for 'table'
-- moved (key = the row pk as text, when known). A hint to refetch — never data.
data ChangeDto = ChangeDto
  { table :: Text, key :: Maybe Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)
