{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | The crucible-worker claim/run/resume engine.
--
-- 'WorkflowDef' describes a workflow program the worker can execute.
-- 'runOnce' claims one ready execution from the run_queue, loads its durable
-- journal, runs the program under replay-to-resume semantics, and marks the
-- execution completed only if it succeeds. If the queue is empty it returns
-- 'Nothing'.
module Crucible.Worker
  ( WorkflowDef (..)
  , runOnce
  ) where

import Data.Text (Text)

import Effectful (Eff, IOE, runEff, liftIO)
import Effectful.Error.Static (Error, runErrorNoCallStack)

import Manifest.Postgres (Pool)

import Crucible.Journal
  ( Journal
  , JournalStore (..)
  , JournalError
  )

import Crucible.Manifest.Journal
  ( claimExecution
  , journalStoreManifest
  , completeExecution
  )

-- | A workflow definition the worker can run.
--
-- 'wdProgram' receives the workflow input, a pre-loaded 'Journal' (the replay
-- source for already-completed activities), and a 'JournalStore' (to
-- 'recordTo' live activities past the journal head). It runs under
-- @'Eff' '[ 'Error' 'JournalError', 'IOE']@, the minimal effect stack needed
-- for replay-to-resume: 'replayFrom' requires both 'Error' and 'IOE'.
data WorkflowDef i o = WorkflowDef
  { wdType    :: Text
  , wdProgram :: i -> Journal -> JournalStore -> Eff '[Error JournalError, IOE] o
  }

-- | Claim one ready (or lease-expired) execution, load its journal, run the
-- program under replay-to-resume semantics, and mark the execution completed
-- __only if it succeeds__. Returns:
--
--   * 'Nothing' — the run_queue was empty (nothing claimed).
--   * @'Just' ('Left' e)@ — an execution was claimed and ran, but the program
--     returned a 'JournalError'. The execution is __not__ completed: the
--     run_queue row is left @claimed@ so its lease expiry makes it reclaimable
--     for a retry. (Marking it completed here would silently lose the failure.)
--   * @'Just' ('Right' o)@ — the program succeeded; the execution is completed.
--
-- A Haskell exception thrown by 'wdProgram' (rather than a 'Left') propagates
-- out of 'runOnce' and likewise skips 'completeExecution' — the execution stays
-- @claimed@ and is reclaimable once its lease expires. This is acceptable for
-- Phase 1.
--
-- The lease string is an ISO-8601 UTC timestamp; callers pass a far-future
-- value for Phase 1 (e.g. "2099-01-01T00:00:00Z"). A real heartbeat loop
-- extending the lease is a Phase 2 concern.
runOnce
  :: Pool
  -> Text                  -- ^ claimant identity
  -> Text                  -- ^ lease deadline (ISO-8601 UTC)
  -> WorkflowDef i o
  -> (Int -> IO i)         -- ^ load the workflow input given its execution id
  -> IO (Maybe (Either JournalError o))
runOnce pool who lease def loadInput = do
  mid <- claimExecution pool who lease
  case mid of
    Nothing  -> pure Nothing
    Just eid -> do
      store <- journalStoreManifest pool eid
      j     <- jsLoad store
      i     <- loadInput eid
      res   <- runEff (runErrorNoCallStack (wdProgram def i j store))
      case res of
        Right _ -> completeExecution pool eid   -- only commit success
        Left _  -> pure ()                      -- leave claimed; lease expiry → reclaim for retry
      pure (Just res)
