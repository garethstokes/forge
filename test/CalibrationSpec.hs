{-# LANGUAGE OverloadedStrings #-}

-- | Unit tests for the pure calibration verdict helpers. Uses the same tiny
-- 'expect' harness as the other specs (the suite does not depend on hspec).
module CalibrationSpec (main) where

import Control.Monad (unless)
import Data.Text (Text)
import Evals.Calibration (bandOf, kappaTrustThreshold, trustedBy)

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

bandEq :: String -> Double -> Text -> IO ()
bandEq msg k want = expect (msg <> " (got " <> show (bandOf k) <> ")") (bandOf k == want)

main :: IO ()
main = do
  expect "kappaTrustThreshold is 0.6" (kappaTrustThreshold == 0.6)

  -- Landis–Koch band boundaries (lower edges belong to the higher band)
  bandEq "bandOf 0.1 slight"          0.1  "slight"
  bandEq "bandOf 0.2 fair"            0.2  "fair"
  bandEq "bandOf 0.4 moderate"        0.4  "moderate"
  bandEq "bandOf 0.6 substantial"     0.6  "substantial"
  bandEq "bandOf 0.8 almost perfect"  0.8  "almost perfect"
  bandEq "bandOf 0.95 almost perfect" 0.95 "almost perfect"

  -- trust = κ CI lower bound clears the threshold
  expect "trustedBy 0.64 is True"  (trustedBy 0.64 == True)
  expect "trustedBy 0.6 is True"   (trustedBy 0.6  == True)
  expect "trustedBy 0.38 is False" (trustedBy 0.38 == False)

  putStrLn "manifest-evals CalibrationSpec: threshold + band + trust OK"
