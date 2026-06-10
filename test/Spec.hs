module Main where
import qualified ExecuteSpec
import qualified SchemaSpec
main :: IO ()
main = SchemaSpec.main >> ExecuteSpec.main
