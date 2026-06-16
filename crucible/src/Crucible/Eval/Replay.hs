{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeOperators #-}

-- | Replay-to-eval divergence collection and delta-debugging minimizer.
--
-- 'runReplayEval' / 'settle' / 'noteDivergence' form the core of the eval
-- flywheel: a replay interpreter calls 'replayFrom' (or 'replay') to serve
-- each op from a journal, then feeds the 'ReplayOutcome' to 'settle', which
-- records any divergence and passes the value through. 'runReplayEval' runs
-- the accumulated 'State' and returns the divergence list in encounter order.
--
-- 'ddmin' implements Zeller\'s delta-debugging algorithm: given a monadic
-- oracle and a list of inputs, it returns the smallest sub-list for which the
-- oracle still returns 'True'.
module Crucible.Eval.Replay
  ( runReplayEval
  , noteDivergence
  , settle
  , ddmin
  ) where

import Effectful
import Effectful.State.Static.Local (State, runState, modify)
import Crucible.Journal (Divergence, ReplayOutcome (..))

-- | Run a replay-to-eval program, collecting divergences in encounter order.
-- Returns the program's result paired with the list of divergences surfaced
-- during replay (ops that were in the live run but absent from the journal).
runReplayEval :: Eff (State [Divergence] : es) a -> Eff es (a, [Divergence])
runReplayEval m = do
  (a, ds) <- runState [] m
  pure (a, reverse ds)

-- | Record a divergence (prepend to the accumulator; 'runReplayEval' reverses
-- on exit to give encounter order).
noteDivergence :: (State [Divergence] :> es) => Divergence -> Eff es ()
noteDivergence d = modify (d :)

-- | Observe a 'ReplayOutcome': if it is a 'Diverged', record the divergence
-- and return the live value; if 'Replayed', return the recorded value as-is.
-- The typical replay interpreter calls @replayFrom j Signal key dec live >>= settle@.
settle :: (State [Divergence] :> es) => ReplayOutcome a -> Eff es a
settle (Replayed a)   = pure a
settle (Diverged d a) = noteDivergence d >> pure a

-- | Zeller delta-debugging: the smallest sub-list of @xs@ for which @repro@
-- still returns 'True'.  Granularity starts at 2 and doubles when neither
-- subsets nor complements reduce the input; the algorithm terminates when
-- the granularity exceeds the length of the current candidate (1-minimal).
--
-- Empty input is returned unchanged.  The result always satisfies @repro@
-- (assuming the full input did).
ddmin :: Monad m => ([a] -> m Bool) -> [a] -> m [a]
ddmin repro xs0 = go xs0 2
  where
    go xs n
      | length xs < 2 = pure xs
      | otherwise = do
          let k      = max 1 (length xs `div` n)
              chunks = chunksOf k xs
          -- try each chunk as the reduced input
          msub <- firstM repro chunks
          case msub of
            Just sub -> go sub 2                     -- reduce to subset, reset granularity
            Nothing  -> do
              -- try each complement (input minus one chunk)
              let comps = [ concat (deleteAt i chunks) | i <- [0 .. length chunks - 1] ]
              mcomp <- firstM repro comps
              case mcomp of
                Just comp -> go comp (max 2 (n - 1)) -- reduce to complement, decrease granularity
                Nothing
                  | n >= length xs -> pure xs         -- 1-minimal
                  | otherwise      -> go xs (min (length xs) (n * 2))

    chunksOf _ [] = []
    chunksOf k ys = let (a, b) = splitAt k ys in a : chunksOf k b

    deleteAt i ys = [ y | (j, y) <- zip [0 ..] ys, j /= i ]

    firstM _ []       = pure Nothing
    firstM p (y : ys) = do ok <- p y; if ok then pure (Just y) else firstM p ys
