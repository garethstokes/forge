module Main where
import System.Directory (setCurrentDirectory)
import System.Environment (getExecutablePath)
import System.FilePath (takeDirectory)
import qualified ApiSpec
import qualified CalibrationSpec
import qualified ExecuteSpec
import qualified GradeSpec
import qualified HealthBenchSpec
import qualified IngestSpec
import qualified MetaEvalSpec
import qualified SchemaSpec
import qualified TenantSpec
main :: IO ()
-- ApiSpec first: fastest feedback (DTO round-trips fail before any DB spins up).
main = do
  -- Specs read fixtures via paths relative to this package (test/fixtures/*).
  -- Under a zinc workspace the process starts at the workspace root, so anchor
  -- CWD to this member's directory (three levels up from the test binary at
  -- <member>/.zinc/build/spec) before running.
  exe <- getExecutablePath
  setCurrentDirectory (takeDirectory (takeDirectory (takeDirectory exe)))
  CalibrationSpec.main >> HealthBenchSpec.main >> ApiSpec.main >> SchemaSpec.main >> ExecuteSpec.main >> GradeSpec.main >> IngestSpec.main >> MetaEvalSpec.main >> TenantSpec.main
