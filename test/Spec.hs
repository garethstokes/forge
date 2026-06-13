module Main where
import qualified ApiSpec
import qualified ExecuteSpec
import qualified GradeSpec
import qualified IngestSpec
import qualified MetaEvalSpec
import qualified SchemaSpec
main :: IO ()
-- ApiSpec first: fastest feedback (DTO round-trips fail before any DB spins up).
main = ApiSpec.main >> SchemaSpec.main >> ExecuteSpec.main >> GradeSpec.main >> IngestSpec.main >> MetaEvalSpec.main
