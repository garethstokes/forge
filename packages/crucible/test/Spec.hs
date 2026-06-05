module Main (main) where
import Harness (check, runChecks)

main :: IO ()
main = runChecks [ check "harness self-test" (2 + 2 :: Int) 4 ]
