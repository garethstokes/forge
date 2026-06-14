{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | A judge gate over a spawned worker's output. 'spawnGated' runs a worker,
-- verifies its decoded output with the existing Eval/Judge vote, and on
-- rejection re-spawns the worker with the critique appended to its instruction,
-- bounded by a retry budget. The gate lives in the orchestrator row (where 'LLM'
-- is available), so the base 'Crucible.Agents.spawn' path stays free of an 'LLM'
-- constraint. The judge is an independent vote (no closed loop): the worker does
-- not grade itself; the critique is retry guidance.
module Crucible.Agents.Gate
  ( Gate (..)
  , gate
  , spawnGated
  ) where

import Data.Text (Text)

import Effectful

import Crucible.Agents (SubAgent (..), AgentFailure (..), Agents, spawn)
import Crucible.LLM (LLM)
import Crucible.Eval.Judge (vote, defaultJudgeOpts, JudgeOpts (..), VoteOutcome (..))

-- | A judge gate over a worker output of type @o@.
data Gate o = Gate
  { rubric  :: Text       -- ^ what a good output looks like, handed to the judge
  , render  :: o -> Text  -- ^ render the worker output for judging
  , votes   :: Int        -- ^ judge sample count (odd; independent majority vote)
  , retries :: Int        -- ^ max worker re-runs on rejection
  }

-- | A gate with @votes = 1@ and @retries = 1@.
gate :: Text -> (o -> Text) -> Gate o
gate r f = Gate r f 1 1

-- | Spawn a worker, then verify its output with the judge; on rejection
-- re-spawn with the critique appended to the worker instruction, bounded by the
-- gate's retries. A spawn failure short-circuits (only @Right o@ is judged).
spawnGated :: (Agents es :> r, LLM :> r)
           => Gate o -> SubAgent es i o -> i -> Eff r (Either AgentFailure o)
spawnGated g sub0 i = loop g.retries sub0
  where
    loop n sub = do
      result <- spawn sub i
      case result of
        Left f  -> pure (Left f)
        Right o -> do
          let opts = (defaultJudgeOpts :: JudgeOpts) { votes = g.votes }
          outcome <- vote True opts g.rubric (g.render o)
          case outcome of
            Decided True _ _ _ _    -> pure (Right o)
            Decided False why _ _ _ -> retryOrReject n sub why
            AllAbstained why        -> retryOrReject n sub why
            AllErrored m            -> pure (Left (GateRejected sub.name ("judge error: " <> m)))

    retryOrReject n sub why
      | n <= 0    = pure (Left (GateRejected sub.name why))
      | otherwise = loop (n - 1) sub { system = augment sub.system why }

    augment s why =
      s <> "\n\nA previous attempt was rejected: " <> why <> "\nAddress this and try again."
