{-# LANGUAGE TypeApplications #-}

-- | The managed schema for the eval orchestrator and the migration entry point.
module Evals.Migrate (schema, migrateAll) where

import Data.Proxy (Proxy(..))
import Manifest
import Manifest.Session (execDb)
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
migrateAll = do
  plan <- migrateUp schema
  _ <- execDb "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='evals_tenant') THEN CREATE ROLE evals_tenant NOLOGIN; END IF; END $$" []
  _ <- execDb "GRANT USAGE ON SCHEMA public TO evals_tenant" []
  _ <- execDb "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO evals_tenant" []
  _ <- execDb "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO evals_tenant" []
  pure plan
