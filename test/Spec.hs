module Main where
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
main = CalibrationSpec.main >> HealthBenchSpec.main >> ApiSpec.main >> SchemaSpec.main >> ExecuteSpec.main >> GradeSpec.main >> IngestSpec.main >> MetaEvalSpec.main >> TenantSpec.main
