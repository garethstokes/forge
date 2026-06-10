{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Eval-orchestrator schema: 'Entity' instances (with cascade rules) and the
-- 'HasRelation' graph wiring the entities together.
--
-- The record types live in "Evals.Schema.Types"; this module re-exports them so
-- downstream code keeps importing just @Evals.Schema@. We @import Manifest@ in
-- full here (unlike the types module) so the 'HasRelation' associated type
-- family 'Target' is in scope for the @type Target X "rel" = ...@ instance
-- bodies. Because that family clashes with the @Target@ ENTITY synonym, the
-- entity is imported qualified as @T.Target@ (and @T.TargetVersion@ alongside).
module Evals.Schema
  ( module Evals.Schema.Types
  ) where

import Data.Proxy (Proxy(..))
import Manifest
import Evals.Schema.Types
import qualified Evals.Schema.Types as T

-- Datasets --------------------------------------------------------------------

instance Entity Dataset where
  tableMeta    = genericTableMeta @DatasetT "datasets"
  cascadeRules = [ cascade (Proxy @DatasetVersion) (Proxy @"dataset") Cascade ]

instance HasRelation Dataset "versions" where
  type Target      Dataset "versions" = [DatasetVersion]
  type Cardinality Dataset "versions" = 'Many
  relSpec = hasMany (Proxy @"dataset")

instance Entity DatasetVersion where
  tableMeta    = genericTableMeta @DatasetVersionT "dataset_versions"
  cascadeRules = [ cascade (Proxy @Example) (Proxy @"datasetVersion") Cascade
                 , cascade (Proxy @Run)     (Proxy @"datasetVersion") Restrict ]
  indexes      = [ unique [#dataset, #version] ]

instance HasRelation DatasetVersion "examples" where
  type Target      DatasetVersion "examples" = [Example]
  type Cardinality DatasetVersion "examples" = 'Many
  relSpec = hasMany (Proxy @"datasetVersion")

instance Entity Example where
  tableMeta = genericTableMeta @ExampleT "examples"
  indexes   = [ gin #input, btree #datasetVersion ]

-- Targets ---------------------------------------------------------------------

instance Entity T.Target where
  tableMeta    = genericTableMeta @TargetT "targets"
  cascadeRules = [ cascade (Proxy @TargetVersion) (Proxy @"target") Cascade ]

instance HasRelation T.Target "versions" where
  type Target      T.Target "versions" = [TargetVersion]
  type Cardinality T.Target "versions" = 'Many
  relSpec = hasMany (Proxy @"target")

instance Entity T.TargetVersion where
  tableMeta    = genericTableMeta @TargetVersionT "target_versions"
  cascadeRules = [ cascade (Proxy @Run) (Proxy @"targetVersion") Restrict ]
  indexes      = [ unique [#target, #version] ]

-- Graders ---------------------------------------------------------------------

instance Entity Grader where
  tableMeta    = genericTableMeta @GraderT "graders"
  cascadeRules = [ cascade (Proxy @GraderVersion) (Proxy @"grader") Cascade ]

instance HasRelation Grader "versions" where
  type Target      Grader "versions" = [GraderVersion]
  type Cardinality Grader "versions" = 'Many
  relSpec = hasMany (Proxy @"grader")

instance Entity GraderVersion where
  tableMeta    = genericTableMeta @GraderVersionT "grader_versions"
  cascadeRules = [ cascade (Proxy @Score) (Proxy @"graderVersion") Restrict ]
  indexes      = [ unique [#grader, #version] ]

-- Run / Output / Score --------------------------------------------------------

instance Entity Run where
  tableMeta    = genericTableMeta @RunT "runs"
  cascadeRules = [ cascade (Proxy @Output)    (Proxy @"run") Cascade
                 , cascade (Proxy @RunMetric) (Proxy @"run") Cascade ]
  indexes      = [ gin #meta, btree #datasetVersion, btree #targetVersion ]

instance HasRelation Run "outputs" where
  type Target      Run "outputs" = [Output]
  type Cardinality Run "outputs" = 'Many
  relSpec = hasMany (Proxy @"run")

instance HasRelation Run "metrics" where
  type Target      Run "metrics" = [RunMetric]
  type Cardinality Run "metrics" = 'Many
  relSpec = hasMany (Proxy @"run")

instance HasRelation Run "datasetVersion" where
  type Target      Run "datasetVersion" = DatasetVersion
  type Cardinality Run "datasetVersion" = 'One
  relSpec = belongsTo (Proxy @"datasetVersion")

instance Entity Output where
  tableMeta    = genericTableMeta @OutputT "outputs"
  cascadeRules = [ cascade (Proxy @Score) (Proxy @"output") Cascade ]
  indexes      = [ gin #response, btree #run ]

instance HasRelation Output "scores" where
  type Target      Output "scores" = [Score]
  type Cardinality Output "scores" = 'Many
  relSpec = hasMany (Proxy @"output")

instance HasRelation Output "run" where
  type Target      Output "run" = Run
  type Cardinality Output "run" = 'One
  relSpec = belongsTo (Proxy @"run")

instance HasRelation Output "example" where
  type Target      Output "example" = Example
  type Cardinality Output "example" = 'One
  relSpec = belongsTo (Proxy @"example")

instance Entity Score where
  tableMeta = genericTableMeta @ScoreT "scores"
  indexes   = [ btree #output ]

instance HasRelation Score "grader" where
  type Target      Score "grader" = GraderVersion
  type Cardinality Score "grader" = 'One
  relSpec = belongsTo (Proxy @"graderVersion")

deriving via (Table "run_metrics" RunMetricT) instance Entity RunMetric
