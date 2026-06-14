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

-- Orgs (tenant registry) -------------------------------------------------------

data OrgT f = Org
  { id        :: Field f (Pk OrgId)
  , slug      :: Field f Text
  , name      :: Field f Text
  , createdAt :: Field f UTCTime
  } deriving Generic
type Org = OrgT Identity

instance Entity Org where
  tableMeta = genericTableMeta @OrgT "orgs"
  indexes   = [ unique [#slug] ]
  -- intentionally NO rlsPolicies: the tenant registry is readable so the app
  -- can resolve a slug -> org id before setting tenant context.

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
  , org         :: Field f OrgId
  , dataset     :: Field f DatasetId
  , version     :: Field f Int
  , note        :: Field f (Maybe Text)
  , finalizedAt :: Field f (Maybe UTCTime)
  , createdAt   :: Field f UTCTime
  } deriving Generic
type DatasetVersion = DatasetVersionT Identity

data ExampleT f = Example
  { id             :: Field f (Pk ExampleId)
  , org            :: Field f OrgId
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
  , org       :: Field f OrgId
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
  , org       :: Field f OrgId
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
  , org       :: Field f OrgId
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
  , org           :: Field f OrgId
  , output        :: Field f OutputId
  , graderVersion :: Field f GraderVersionId
  , value         :: Field f (Maybe Double)  -- NULL = errored, excluded from aggregates
  , passed        :: Field f (Maybe Bool)
  , detail        :: Field f (Maybe (Aeson Value))
  , error         :: Field f (Maybe Text)    -- grading failure; row is retried on re-score
  , createdAt     :: Field f UTCTime
  } deriving Generic
type Score = ScoreT Identity

data RunMetricT f = RunMetric
  { id            :: Field f (Pk RunMetricId)
  , org           :: Field f OrgId
  , run           :: Field f RunId
  , graderVersion :: Field f GraderVersionId
  , mean          :: Field f Double
  , passRate      :: Field f (Maybe Double)
  , count         :: Field f Int
  , computedAt    :: Field f UTCTime
  , tag           :: Field f (Maybe Text)   -- Nothing = overall; Just t = a per-tag breakdown
  , stderr        :: Field f (Maybe Double)  -- bootstrap standard error of the metric's mean
  } deriving Generic
type RunMetric = RunMetricT Identity

data CriterionLabelT f = CriterionLabel
  { id        :: Field f (Pk CriterionLabelId)
  , org       :: Field f OrgId
  , output    :: Field f OutputId       -- the candidate response this labels
  , criterion :: Field f Text           -- rubric criterion text (matches Score.detail's criterion)
  , human     :: Field f Bool           -- the gold verdict (met / not-met)
  , source    :: Field f (Maybe Text)   -- labeller / provenance
  , createdAt :: Field f UTCTime
  } deriving Generic
type CriterionLabel = CriterionLabelT Identity

data MetaEvalT f = MetaEval
  { id            :: Field f (Pk MetaEvalId)
  , org           :: Field f OrgId
  , run           :: Field f RunId
  , graderVersion :: Field f GraderVersionId
  , mode          :: Field f Text          -- "live" | "stored"
  , seed          :: Field f Int
  , agreement     :: Field f Double
  , kappa         :: Field f Double
  , kappaLow      :: Field f Double
  , kappaHigh     :: Field f Double
  , failPrecision :: Field f Double
  , failRecall    :: Field f Double
  , passF1        :: Field f Double
  , failF1        :: Field f Double
  , balancedF1    :: Field f Double
  , measured      :: Field f Int
  , judgeErrors   :: Field f (Aeson Value)
  , computedAt    :: Field f UTCTime
  } deriving Generic
type MetaEval = MetaEvalT Identity

-- Datasets: instances -------------------------------------------------------------

instance Entity Dataset where
  tableMeta    = genericTableMeta @DatasetT "datasets"
  cascadeRules = [ cascade (Proxy @DatasetVersion) (Proxy @"dataset") Cascade ]
  rlsPolicies  =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

instance HasRelation Dataset "versions" where
  type Related     Dataset "versions" = [DatasetVersion]
  type Cardinality Dataset "versions" = 'Many
  relSpec = hasMany (Proxy @"dataset")

instance Entity DatasetVersion where
  tableMeta    = genericTableMeta @DatasetVersionT "dataset_versions"
  cascadeRules = [ cascade (Proxy @Example) (Proxy @"datasetVersion") Cascade
                 , cascade (Proxy @Run)     (Proxy @"datasetVersion") Restrict ]
  indexes      = [ unique [#dataset, #version] ]
  rlsPolicies  =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

instance HasRelation DatasetVersion "examples" where
  type Related     DatasetVersion "examples" = [Example]
  type Cardinality DatasetVersion "examples" = 'Many
  relSpec = hasMany (Proxy @"datasetVersion")

instance Entity Example where
  tableMeta   = genericTableMeta @ExampleT "examples"
  indexes     = [ gin #input, btree #datasetVersion ]
  rlsPolicies =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

-- Targets: instances ----------------------------------------------------------------

instance Entity Target where
  tableMeta    = genericTableMeta @TargetT "targets"
  cascadeRules = [ cascade (Proxy @TargetVersion) (Proxy @"target") Cascade ]
  rlsPolicies  =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

instance HasRelation Target "versions" where
  type Related     Target "versions" = [TargetVersion]
  type Cardinality Target "versions" = 'Many
  relSpec = hasMany (Proxy @"target")

instance Entity TargetVersion where
  tableMeta    = genericTableMeta @TargetVersionT "target_versions"
  cascadeRules = [ cascade (Proxy @Run) (Proxy @"targetVersion") Restrict ]
  indexes      = [ unique [#target, #version] ]
  rlsPolicies  =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

-- Graders: instances ----------------------------------------------------------------

instance Entity Grader where
  tableMeta    = genericTableMeta @GraderT "graders"
  cascadeRules = [ cascade (Proxy @GraderVersion) (Proxy @"grader") Cascade ]
  rlsPolicies  =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

instance HasRelation Grader "versions" where
  type Related     Grader "versions" = [GraderVersion]
  type Cardinality Grader "versions" = 'Many
  relSpec = hasMany (Proxy @"grader")

instance Entity GraderVersion where
  tableMeta    = genericTableMeta @GraderVersionT "grader_versions"
  cascadeRules = [ cascade (Proxy @Score) (Proxy @"graderVersion") Restrict ]
  indexes      = [ unique [#grader, #version] ]
  rlsPolicies  =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

-- Run / Output / Score: instances -----------------------------------------------------

instance Entity Run where
  tableMeta     = genericTableMeta @RunT "runs"
  cascadeRules  = [ cascade (Proxy @Output)    (Proxy @"run") Cascade
                  , cascade (Proxy @RunMetric) (Proxy @"run") Cascade ]
  indexes       = [ gin #meta, btree #datasetVersion, btree #targetVersion ]
  notifyChanges = True
  rlsPolicies   =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

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
  tableMeta     = genericTableMeta @OutputT "outputs"
  cascadeRules  = [ cascade (Proxy @Score) (Proxy @"output") Cascade
                  , cascade (Proxy @CriterionLabel) (Proxy @"output") Cascade ]
  indexes       = [ gin #response, btree #run ]
  notifyChanges = True
  rlsPolicies   =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

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
  tableMeta     = genericTableMeta @ScoreT "scores"
  indexes       = [ unique [#output, #graderVersion] ]  -- also serves output lookups (leading column)
  notifyChanges = True
  rlsPolicies   =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

instance HasRelation Score "grader" where
  type Related     Score "grader" = GraderVersion
  type Cardinality Score "grader" = 'One
  relSpec = belongsTo (Proxy @"graderVersion")

instance Entity RunMetric where
  tableMeta     = genericTableMeta @RunMetricT "run_metrics"
  notifyChanges = True
  rlsPolicies   =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

instance Entity CriterionLabel where
  tableMeta   = genericTableMeta @CriterionLabelT "criterion_labels"
  indexes     = [ unique [#output, #criterion] ]  -- leading column also serves output lookups
  rlsPolicies =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]

instance Entity MetaEval where
  tableMeta   = genericTableMeta @MetaEvalT "meta_evals"
  indexes     = [ btree #run ]
  rlsPolicies =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]
