{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeOperators #-}

-- | Live-only latency measurement for skills and eval calls. 'timed' wraps any
-- effectful action and reports its wall-clock duration in milliseconds using a
-- monotonic clock. It requires @IOE :> es@, so it runs only under live
-- interpreters: the scripted and pure interpreters have no 'IOE', and a
-- near-zero scripted latency would be meaningless anyway. The 'IOE' constraint
-- is the live-only marker. 'withinMs' and 'maxLatencyMs' are pure budget
-- predicates a test asserts. Latency is orthogonal to the content score and is
-- deliberately kept out of 'Crucible.Eval' and 'Report'.
module Crucible.Eval.Latency
  ( Timed (..)
  , timed
  , timeEach
  , withinMs
  , maxLatencyMs
  ) where

import GHC.Clock (getMonotonicTimeNSec)

import Effectful

-- | A value paired with the wall-clock milliseconds its production took.
data Timed a = Timed { value :: a, latencyMs :: Int }
  deriving (Eq, Show, Functor)

-- | Measure wall-clock milliseconds around an effectful action.
timed :: (IOE :> es) => Eff es a -> Eff es (Timed a)
timed act = do
  t0 <- liftIO getMonotonicTimeNSec
  a  <- act
  t1 <- liftIO getMonotonicTimeNSec
  pure (Timed a (fromIntegral ((t1 - t0) `div` 1000000)))

-- | Time an action over each input of a dataset, in order.
timeEach :: (IOE :> es) => (i -> Eff es a) -> [i] -> Eff es [Timed a]
timeEach f = mapM (timed . f)

-- | A single result met its budget (latencyMs <= budget).
withinMs :: Int -> Timed a -> Bool
withinMs budget t = t.latencyMs <= budget

-- | The largest latency in a batch (0 for an empty batch).
maxLatencyMs :: [Timed a] -> Int
maxLatencyMs ts = maximum (0 : map ((.latencyMs) :: Timed a -> Int) ts)
