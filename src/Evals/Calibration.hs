{-# LANGUAGE OverloadedStrings #-}

-- | Pure calibration verdict helpers. The κ trust threshold and the
-- Landis–Koch qualitative band live here so they have exactly one home,
-- shared by the dashboard server (which bakes the results into the wire DTOs)
-- and the test suite. The headline verdict is driven by the κ 95%-CI lower
-- bound vs 'kappaTrustThreshold' — sample-size aware, unlike the band.
module Evals.Calibration
  ( kappaTrustThreshold
  , bandOf
  , trustedBy
  ) where

import Data.Text (Text)

-- | A grader is "trustworthy" when the 95% CI lower bound of its Cohen's κ
-- clears this bar (the conventional "substantial" floor). A single constant so
-- it is easy to find and tune.
kappaTrustThreshold :: Double
kappaTrustThreshold = 0.6

-- | True when the κ CI lower bound clears the trust threshold.
trustedBy :: Double -> Bool
trustedBy kappaLow = kappaLow >= kappaTrustThreshold

-- | Landis–Koch qualitative label for a κ value. Demoted to a teaching aid in
-- the UI (the cut-points are admittedly arbitrary); never the verdict.
bandOf :: Double -> Text
bandOf k
  | k < 0.2   = "slight"
  | k < 0.4   = "fair"
  | k < 0.6   = "moderate"
  | k < 0.8   = "substantial"
  | otherwise = "almost perfect"
