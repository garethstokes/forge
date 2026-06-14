{-# LANGUAGE TypeApplications #-}

-- | The managed schema for the eval orchestrator and the migration entry point.
module Evals.Migrate (schema, migrateAll) where

import Data.Proxy (Proxy(..))
import Manifest
import Evals.Schema

schema :: [ManagedTable]
schema =
  [ managed (Proxy @Org)
  , managed (Proxy @Dataset), managed (Proxy @DatasetVersion), managed (Proxy @Example)
  , managed (Proxy @Target),  managed (Proxy @TargetVersion)
  , managed (Proxy @Grader),  managed (Proxy @GraderVersion)
  , managed (Proxy @Run),     managed (Proxy @Output), managed (Proxy @Score), managed (Proxy @RunMetric)
  , managed (Proxy @CriterionLabel), managed (Proxy @MetaEval) ]

migrateAll :: Db MigrationPlan
migrateAll = migrateUp schema
