module Main (main) where

import Harness
import qualified CodecSpec
import qualified PostgresSpec
import qualified MetaSpec

main :: IO ()
main = runTests (CodecSpec.tests ++ PostgresSpec.tests ++ MetaSpec.tests)
