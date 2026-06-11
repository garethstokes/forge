module Main where
import qualified ExecuteSpec
import qualified GradeSpec
import qualified SchemaSpec
main :: IO ()
main = SchemaSpec.main >> ExecuteSpec.main >> GradeSpec.main
