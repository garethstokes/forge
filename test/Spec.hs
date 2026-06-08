module Main (main) where

import Harness
import qualified CodecSpec
import qualified PostgresSpec
import qualified MetaSpec
import qualified MigrateMetaSpec
import qualified MigrateSqlSpec
import qualified MigrateSpec
import qualified SqlSpec
import qualified SessionSpec
import qualified FlushSpec
import qualified CommandSpec
import qualified EndToEndSpec
import qualified RelationSpec
import qualified EntSpec
import qualified RelationErrorSpec
import qualified RelE2ESpec
import qualified JoinedSpec
import qualified CascadeSpec
import qualified SelfRefSpec
import qualified NestedSpec
import qualified Tutorial.UnitOfWork

main :: IO ()
main = runTests (CodecSpec.tests ++ PostgresSpec.tests ++ MetaSpec.tests ++ MigrateMetaSpec.tests ++ MigrateSqlSpec.tests ++ MigrateSpec.tests ++ SqlSpec.tests ++ SessionSpec.tests ++ FlushSpec.tests ++ CommandSpec.tests ++ EndToEndSpec.tests ++ RelationSpec.tests ++ EntSpec.tests ++ RelationErrorSpec.tests ++ RelE2ESpec.tests ++ JoinedSpec.tests ++ CascadeSpec.tests ++ SelfRefSpec.tests ++ NestedSpec.tests ++ Tutorial.UnitOfWork.tests)
