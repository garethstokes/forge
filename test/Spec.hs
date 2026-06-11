module Main where
import qualified ApiSpec
import qualified ExecuteSpec
import qualified GradeSpec
import qualified SchemaSpec
main :: IO ()
-- ApiSpec first: it is the only DB-free spec, so a Postgres hiccup in the
-- others can't mask a DTO regression.
main = ApiSpec.main >> SchemaSpec.main >> ExecuteSpec.main >> GradeSpec.main
