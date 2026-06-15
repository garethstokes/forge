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
-- journal, runs the program under replay-to-resume semantics (including
-- suspend/resume via 'Workflow' + 'DurableSleep'), and marks the execution
-- completed only if it succeeds. If the queue is empty it returns 'Nothing'.
module Crucible.Worker
  ( WorkflowDef (..)
  , RunResult (..)
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

import Crucible.Workflow
  ( Workflow
  , WorkflowEnv
  , WaitSpec (..)
  , Suspended (..)
  , runWorkflow
  )

import Crucible.Manifest.Journal
  ( claimExecution
  , journalStoreManifest
  , completeExecution
  , suspendTimer
  )

-- | A workflow definition the worker can run.
--
-- 'wdProgram' receives the workflow input, a pre-loaded 'Journal' (the replay
-- source for already-completed activities), and a 'JournalStore' (to
-- 'recordTo' live activities past the journal head). It runs under the full
-- Workflow effect stack including 'Workflow', 'Error' 'JournalError', and
-- 'Error' 'Suspended', so programs can call 'now', 'durableSleep', 'recordTo',
-- 'replayFrom', etc.
data WorkflowDef i o = WorkflowDef
  { wdType    :: Text
  , wdProgram :: i -> Journal -> JournalStore -> Eff '[Workflow, Error JournalError, Error Suspended, IOE] o
  }

-- | The outcome of a single 'runOnce' call for a claimed execution.
data RunResult o
  = Completed o          -- ^ program ran to completion
  | SuspendedRun WaitSpec  -- ^ program suspended at a durable timer
  | Errored JournalError   -- ^ program returned a JournalError
  deriving (Show)

-- | Claim one ready (or lease-expired) execution, load its journal, run the
-- program under the Workflow interpreter + replay-to-resume semantics, and
-- branch on the outcome:
--
--   * 'Nothing'          — the run_queue was empty (nothing claimed).
--   * @'Just' ('Completed' o)@ — the program succeeded; the execution is completed.
--   * @'Just' ('SuspendedRun' spec)@ — the program hit a 'DurableSleep' with no
--     journal entry; the execution is parked as @waiting@ until the timer fires.
--   * @'Just' ('Errored' e)@ — the program returned a 'JournalError'. The
--     execution is __not__ completed: the run_queue row is left @claimed@ so its
--     lease expiry makes it reclaimable for a retry.
--
-- The discharge order is:
-- @runEff (runErrorNoCallStack \@Suspended (runErrorNoCallStack \@JournalError (runWorkflow env …)))@
-- yielding @Either Suspended (Either JournalError o)@.
runOnce
  :: Pool
  -> Text                  -- ^ claimant identity
  -> Text                  -- ^ lease deadline (ISO-8601 UTC)
  -> WorkflowEnv           -- ^ injectable non-determinism sources
  -> WorkflowDef i o
  -> (Int -> IO i)         -- ^ load the workflow input given its execution id
  -> IO (Maybe (RunResult o))
runOnce pool who lease env def loadInput = do
  mid <- claimExecution pool who lease
  case mid of
    Nothing  -> pure Nothing
    Just eid -> do
      store <- journalStoreManifest pool eid
      j     <- jsLoad store
      i     <- loadInput eid
      res   <- runEff
                 (runErrorNoCallStack @Suspended
                   (runErrorNoCallStack @JournalError
                     (runWorkflow env store j (wdProgram def i j store))))
      case res of
        Left (Suspended (WaitTimer k wakeAt)) -> do
          suspendTimer pool eid k wakeAt
          pure (Just (SuspendedRun (WaitTimer k wakeAt)))
        Right (Left e) ->
          pure (Just (Errored e))   -- leave claimed; lease expiry → reclaim for retry
        Right (Right o) -> do
          completeExecution pool eid
          pure (Just (Completed o))
