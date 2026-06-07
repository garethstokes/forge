module Main (main) where

import Harness
import qualified CodecSpec
import qualified PostgresSpec
import qualified MetaSpec
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

main :: IO ()
main = runTests (CodecSpec.tests ++ PostgresSpec.tests ++ MetaSpec.tests ++ SqlSpec.tests ++ SessionSpec.tests ++ FlushSpec.tests ++ CommandSpec.tests ++ EndToEndSpec.tests ++ RelationSpec.tests ++ EntSpec.tests ++ RelationErrorSpec.tests ++ RelE2ESpec.tests ++ JoinedSpec.tests ++ CascadeSpec.tests)
