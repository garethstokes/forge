{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeFamilies #-}

-- | The eval-orchestrator entity record types.
--
-- These live in their own module so that 'Evals.Schema' can @import Manifest@
-- with the 'HasRelation' associated type family 'Target' in scope (needed to
-- write @type Target X "rel" = ...@ instance bodies) while the @Target@ ENTITY
-- synonym — which would otherwise clash with that family — stays here, imported
-- qualified by the instances module. See 'Evals.Schema' for the relationships
-- and cascade rules.
module Evals.Schema.Types where

import Data.Aeson (Value)
import Data.Functor.Identity (Identity)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Manifest hiding (Target)
import Evals.Ids

-- Datasets (inputs)

data DatasetT f = Dataset
  { id        :: Field f (Pk DatasetId)
  , org       :: Field f OrgId
  , name      :: Field f Text
  , slug      :: Field f Text
  , createdAt :: Field f UTCTime
  } deriving Generic
type Dataset = DatasetT Identity

data DatasetVersionT f = DatasetVersion
  { id          :: Field f (Pk DatasetVersionId)
  , dataset     :: Field f DatasetId
  , version     :: Field f Int
  , note        :: Field f (Maybe Text)
  , finalizedAt :: Field f (Maybe UTCTime)
  , createdAt   :: Field f UTCTime
  } deriving Generic
type DatasetVersion = DatasetVersionT Identity

data ExampleT f = Example
  { id             :: Field f (Pk ExampleId)
  , datasetVersion :: Field f DatasetVersionId
  , key            :: Field f Text
  , input          :: Field f (Aeson Value)
  , expected       :: Field f (Maybe (Aeson Value))
  , meta           :: Field f (Maybe (Aeson Value))
  } deriving Generic
type Example = ExampleT Identity

-- Targets (system under test)

data TargetT f = Target
  { id        :: Field f (Pk TargetId)
  , org       :: Field f OrgId
  , name      :: Field f Text
  , createdAt :: Field f UTCTime
  } deriving Generic
type Target = TargetT Identity

data TargetVersionT f = TargetVersion
  { id        :: Field f (Pk TargetVersionId)
  , target    :: Field f TargetId
  , version   :: Field f Int
  , model     :: Field f Text
  , prompt    :: Field f Text
  , params    :: Field f (Aeson Value)
  , createdAt :: Field f UTCTime
  } deriving Generic
type TargetVersion = TargetVersionT Identity

-- Graders (reusable judges)

data GraderT f = Grader
  { id        :: Field f (Pk GraderId)
  , org       :: Field f OrgId
  , name      :: Field f Text
  , kind      :: Field f Text
  , createdAt :: Field f UTCTime
  } deriving Generic
type Grader = GraderT Identity

data GraderVersionT f = GraderVersion
  { id        :: Field f (Pk GraderVersionId)
  , grader    :: Field f GraderId
  , version   :: Field f Int
  , config    :: Field f (Aeson Value)
  , createdAt :: Field f UTCTime
  } deriving Generic
type GraderVersion = GraderVersionT Identity

-- Run / Output / Score

data RunT f = Run
  { id             :: Field f (Pk RunId)
  , org            :: Field f OrgId
  , datasetVersion :: Field f DatasetVersionId
  , targetVersion  :: Field f TargetVersionId
  , status         :: Field f Text
  , startedAt      :: Field f (Maybe UTCTime)
  , finishedAt     :: Field f (Maybe UTCTime)
  , meta           :: Field f (Maybe (Aeson Value))
  , createdAt      :: Field f UTCTime
  } deriving Generic
type Run = RunT Identity

data OutputT f = Output
  { id        :: Field f (Pk OutputId)
  , run       :: Field f RunId
  , example   :: Field f ExampleId
  , response  :: Field f (Maybe (Aeson Value))
  , text      :: Field f (Maybe Text)
  , error     :: Field f (Maybe Text)
  , latencyMs :: Field f (Maybe Int)
  , tokens    :: Field f (Maybe (Aeson Value))
  } deriving Generic
type Output = OutputT Identity

data ScoreT f = Score
  { id            :: Field f (Pk ScoreId)
  , output        :: Field f OutputId
  , graderVersion :: Field f GraderVersionId
  , value         :: Field f Double
  , passed        :: Field f (Maybe Bool)
  , detail        :: Field f (Maybe (Aeson Value))
  , createdAt     :: Field f UTCTime
  } deriving Generic
type Score = ScoreT Identity

data RunMetricT f = RunMetric
  { id            :: Field f (Pk RunMetricId)
  , run           :: Field f RunId
  , graderVersion :: Field f GraderVersionId
  , mean          :: Field f Double
  , passRate      :: Field f (Maybe Double)
  , count         :: Field f Int
  , computedAt    :: Field f UTCTime
  } deriving Generic
type RunMetric = RunMetricT Identity
