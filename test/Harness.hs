module Harness (check, runChecks) where

import System.Exit (exitFailure, exitSuccess)

-- | Assert equality; report (don't abort) so every failure is shown.
check :: (Eq a, Show a) => String -> a -> a -> IO Bool
check name expected actual
  | expected == actual = putStrLn ("ok   " ++ name) >> pure True
  | otherwise = do
      putStrLn ("FAIL " ++ name)
      putStrLn ("  expected: " ++ show expected)
      putStrLn ("  actual:   " ++ show actual)
      pure False

runChecks :: [IO Bool] -> IO ()
runChecks cs = do
  rs <- sequence cs
  if and rs then putStrLn "ALL PASS" >> exitSuccess
            else putStrLn "FAILURES" >> exitFailure
