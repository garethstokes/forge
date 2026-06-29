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
import qualified RecursiveCascadeSpec
import qualified SelfRefSpec
import qualified NestedSpec
import qualified QueryBuilderSpec
import qualified Tutorial.UnitOfWork
import qualified Tutorial.Relationships
import qualified Tutorial.Cascades
import qualified RlsSpec
import qualified TypedFieldsSpec
import qualified JsonSpec
import qualified IndexSpec
import qualified NotifySpec
import qualified ProjectionSpec
import qualified AssignSpec
import qualified UpdateSpec
import qualified TouchedSpec
import qualified ReferencesSpec

main :: IO ()
main = runTests (CodecSpec.tests ++ PostgresSpec.tests ++ MetaSpec.tests ++ MigrateMetaSpec.tests ++ MigrateSqlSpec.tests ++ MigrateSpec.tests ++ SqlSpec.tests ++ SessionSpec.tests ++ FlushSpec.tests ++ CommandSpec.tests ++ EndToEndSpec.tests ++ RelationSpec.tests ++ EntSpec.tests ++ RelationErrorSpec.tests ++ RelE2ESpec.tests ++ JoinedSpec.tests ++ CascadeSpec.tests ++ RecursiveCascadeSpec.tests ++ SelfRefSpec.tests ++ NestedSpec.tests ++ QueryBuilderSpec.tests ++ Tutorial.UnitOfWork.tests ++ Tutorial.Relationships.tests ++ Tutorial.Cascades.tests ++ RlsSpec.tests ++ TypedFieldsSpec.tests ++ JsonSpec.tests ++ IndexSpec.tests ++ NotifySpec.tests ++ ProjectionSpec.tests ++ AssignSpec.tests ++ UpdateSpec.tests ++ TouchedSpec.tests ++ ReferencesSpec.tests)
