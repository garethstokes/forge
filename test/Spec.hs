module Main (main) where

import Harness

main :: IO ()
main = runTests $
  group "scaffold"
    [ test "the harness runs" $ assertEqual "arithmetic" (2 :: Int) (1 + 1)
    ]
