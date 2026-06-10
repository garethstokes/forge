{-# LANGUAGE TypeApplications #-}

-- | The managed schema for the eval orchestrator and the migration entry point.
--
-- @Manifest@ is imported @hiding (Target)@ so the @Target@ ENTITY (re-exported
-- from "Evals.Schema") is unambiguous here — this module writes no @type Target@
-- family instances, so the family is not needed.
module Evals.Migrate (schema, migrateAll) where

import Data.Proxy (Proxy(..))
import Manifest hiding (Target)
import Evals.Schema

schema :: [ManagedTable]
schema =
  [ managed (Proxy @Dataset), managed (Proxy @DatasetVersion), managed (Proxy @Example)
  , managed (Proxy @Target),  managed (Proxy @TargetVersion)
  , managed (Proxy @Grader),  managed (Proxy @GraderVersion)
  , managed (Proxy @Run),     managed (Proxy @Output), managed (Proxy @Score), managed (Proxy @RunMetric) ]

migrateAll :: Db MigrationPlan
migrateAll = migrateUp schema
