{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | The eval-orchestrator schema: the entity record types, their 'Entity'
-- instances (with cascade rules), and the 'HasRelation' graph wiring them
-- together. One module — since manifest renamed the relation family to
-- 'Related' (manifest-jkq), the @Target@ ENTITY no longer clashes with it,
-- so no module split or @hiding@ imports are needed.
module Evals.Schema where

import Data.Aeson (Value)
import Data.Functor.Identity (Identity)
import Data.Proxy (Proxy(..))
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Manifest
import Evals.Ids

-- Datasets (inputs) -------------------------------------------------------------

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

-- Targets (system under test) ---------------------------------------------------

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

-- Graders (reusable judges) -----------------------------------------------------

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

-- Run / Output / Score ------------------------------------------------------------

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

-- Datasets: instances -------------------------------------------------------------

instance Entity Dataset where
  tableMeta    = genericTableMeta @DatasetT "datasets"
  cascadeRules = [ cascade (Proxy @DatasetVersion) (Proxy @"dataset") Cascade ]

instance HasRelation Dataset "versions" where
  type Related     Dataset "versions" = [DatasetVersion]
  type Cardinality Dataset "versions" = 'Many
  relSpec = hasMany (Proxy @"dataset")

instance Entity DatasetVersion where
  tableMeta    = genericTableMeta @DatasetVersionT "dataset_versions"
  cascadeRules = [ cascade (Proxy @Example) (Proxy @"datasetVersion") Cascade
                 , cascade (Proxy @Run)     (Proxy @"datasetVersion") Restrict ]
  indexes      = [ unique [#dataset, #version] ]

instance HasRelation DatasetVersion "examples" where
  type Related     DatasetVersion "examples" = [Example]
  type Cardinality DatasetVersion "examples" = 'Many
  relSpec = hasMany (Proxy @"datasetVersion")

instance Entity Example where
  tableMeta = genericTableMeta @ExampleT "examples"
  indexes   = [ gin #input, btree #datasetVersion ]

-- Targets: instances ----------------------------------------------------------------

instance Entity Target where
  tableMeta    = genericTableMeta @TargetT "targets"
  cascadeRules = [ cascade (Proxy @TargetVersion) (Proxy @"target") Cascade ]

instance HasRelation Target "versions" where
  type Related     Target "versions" = [TargetVersion]
  type Cardinality Target "versions" = 'Many
  relSpec = hasMany (Proxy @"target")

instance Entity TargetVersion where
  tableMeta    = genericTableMeta @TargetVersionT "target_versions"
  cascadeRules = [ cascade (Proxy @Run) (Proxy @"targetVersion") Restrict ]
  indexes      = [ unique [#target, #version] ]

-- Graders: instances ----------------------------------------------------------------

instance Entity Grader where
  tableMeta    = genericTableMeta @GraderT "graders"
  cascadeRules = [ cascade (Proxy @GraderVersion) (Proxy @"grader") Cascade ]

instance HasRelation Grader "versions" where
  type Related     Grader "versions" = [GraderVersion]
  type Cardinality Grader "versions" = 'Many
  relSpec = hasMany (Proxy @"grader")

instance Entity GraderVersion where
  tableMeta    = genericTableMeta @GraderVersionT "grader_versions"
  cascadeRules = [ cascade (Proxy @Score) (Proxy @"graderVersion") Restrict ]
  indexes      = [ unique [#grader, #version] ]

-- Run / Output / Score: instances -----------------------------------------------------

instance Entity Run where
  tableMeta    = genericTableMeta @RunT "runs"
  cascadeRules = [ cascade (Proxy @Output)    (Proxy @"run") Cascade
                 , cascade (Proxy @RunMetric) (Proxy @"run") Cascade ]
  indexes      = [ gin #meta, btree #datasetVersion, btree #targetVersion ]

instance HasRelation Run "outputs" where
  type Related     Run "outputs" = [Output]
  type Cardinality Run "outputs" = 'Many
  relSpec = hasMany (Proxy @"run")

instance HasRelation Run "metrics" where
  type Related     Run "metrics" = [RunMetric]
  type Cardinality Run "metrics" = 'Many
  relSpec = hasMany (Proxy @"run")

instance HasRelation Run "datasetVersion" where
  type Related     Run "datasetVersion" = DatasetVersion
  type Cardinality Run "datasetVersion" = 'One
  relSpec = belongsTo (Proxy @"datasetVersion")

instance Entity Output where
  tableMeta    = genericTableMeta @OutputT "outputs"
  cascadeRules = [ cascade (Proxy @Score) (Proxy @"output") Cascade ]
  indexes      = [ gin #response, btree #run ]

instance HasRelation Output "scores" where
  type Related     Output "scores" = [Score]
  type Cardinality Output "scores" = 'Many
  relSpec = hasMany (Proxy @"output")

instance HasRelation Output "run" where
  type Related     Output "run" = Run
  type Cardinality Output "run" = 'One
  relSpec = belongsTo (Proxy @"run")

instance HasRelation Output "example" where
  type Related     Output "example" = Example
  type Cardinality Output "example" = 'One
  relSpec = belongsTo (Proxy @"example")

instance Entity Score where
  tableMeta = genericTableMeta @ScoreT "scores"
  indexes   = [ btree #output ]

instance HasRelation Score "grader" where
  type Related     Score "grader" = GraderVersion
  type Cardinality Score "grader" = 'One
  relSpec = belongsTo (Proxy @"graderVersion")

deriving via (Table "run_metrics" RunMetricT) instance Entity RunMetric
