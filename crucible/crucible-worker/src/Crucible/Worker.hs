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
-- suspend/resume via 'Workflow' + 'DurableSleep'/'AwaitSignal'), and marks the
-- execution completed only if it succeeds. If the queue is empty it returns
-- 'Nothing'.
--
-- 'drainOnce' calls 'runOnce' repeatedly until no more ready executions remain.
-- 'pollRounds' fires due timers then drains, repeating up to @n@ rounds — a
-- test-friendly driver for the full timer→drain loop.
module Crucible.Worker
  ( WorkflowDef (..)
  , RunResult (..)
  , runOnce
  , drainOnce
  , pollRounds
  , unkeyablePending
  ) where

import Control.Monad (replicateM_)
import Data.ByteString (ByteString)
import Data.Text (Text)

import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)

import Manifest.Postgres (Pool)

import Crucible.Journal
  ( Journal
  , JournalStore (..)
  , JournalError
  , JournalIdentity (..)
  , CassetteKey (..)
  , ActivityKind (..)
  )

import Crucible.Workflow
  ( Workflow
  , WorkflowEnv (..)
  , WaitSpec (..)
  , Suspended (..)
  , runWorkflow
  )

import Crucible.Manifest.Journal
  ( claimExecution
  , journalStoreManifest
  , completeExecutionWith
  , createChildExecution
  , suspendChild
  , suspendTimer
  , suspendSignal
  , fireDueTimers
  , pendingIntents
  )

-- | A workflow definition the worker can run.
--
-- 'wdProgram' receives the workflow input, a pre-loaded 'Journal' (the replay
-- source for already-completed activities), and a 'JournalStore' (to
-- 'recordTo' live activities past the journal head). It runs under the full
-- Workflow effect stack including 'Workflow', 'Error' 'JournalError', and
-- 'Error' 'Suspended', so programs can call 'now', 'durableSleep', 'recordTo',
-- 'replayFrom', etc.
--
-- 'wdEncodeOutput' converts the program's output value to 'ByteString' so the
-- worker can persist it (via 'completeExecutionWith') and propagate it to a
-- waiting parent execution when this is a child.
--
-- REPLAY-SAFETY: any domain activity that can execute *before* a suspend point
-- (a 'durableSleep'/'awaitSignal'/'executeChild') MUST be wrapped in 'replayFrom'
-- so that on resume it is served from the journal instead of re-run. Bare
-- 'recordTo' is unconditionally live (it always runs its action and appends), so
-- it is replay-safe ONLY for steps strictly after the last suspend. ('now'/'newId'
-- are journaled by the interpreter and are always replay-safe.)
data WorkflowDef i o = WorkflowDef
  { wdType         :: Text
  , wdProgram      :: i -> Journal -> JournalStore -> Eff '[Workflow, Error JournalError, Error Suspended, IOE] o
  , wdEncodeOutput :: o -> ByteString
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
        Left (Suspended (WaitSignal k name)) -> do
          suspendSignal pool eid k name
          pure (Just (SuspendedRun (WaitSignal k name)))
        Left (Suspended (WaitChild k ctype cinput)) -> do
          capAt <- weNow env
          let childIdent = JournalIdentity ctype cinput "v1" capAt
          _ <- createChildExecution pool childIdent eid k
          suspendChild pool eid k
          pure (Just (SuspendedRun (WaitChild k ctype cinput)))
        Right (Left e) ->
          pure (Just (Errored e))   -- leave claimed; lease expiry → reclaim for retry
        Right (Right o) -> do
          completeExecutionWith pool eid (wdEncodeOutput def o)
          pure (Just (Completed o))

-- | Run every currently-ready execution once (to completion or suspension),
-- collecting the results. Stops when the run_queue has no more ready entries
-- (i.e. when 'runOnce' returns 'Nothing').
drainOnce
  :: Pool
  -> Text                  -- ^ claimant identity
  -> Text                  -- ^ lease deadline (ISO-8601 UTC)
  -> WorkflowEnv           -- ^ injectable non-determinism sources
  -> WorkflowDef i o
  -> (Int -> IO i)         -- ^ load the workflow input given its execution id
  -> IO [RunResult o]
drainOnce pool who lease env def loadInput = go []
  where
    go acc = do
      m <- runOnce pool who lease env def loadInput
      case m of
        Nothing -> pure (reverse acc)
        Just r  -> go (r : acc)

-- | Fire due timers (at the env's current time) then drain all ready
-- executions; repeat up to @n@ rounds.  A test-friendly driver for the full
-- timer-fire → drain loop.
pollRounds
  :: Pool
  -> Text                  -- ^ claimant identity
  -> WorkflowEnv           -- ^ injectable non-determinism sources (weNow drives timer firing)
  -> Int                   -- ^ number of rounds (clamped to 0 minimum)
  -> WorkflowDef i o
  -> (Int -> IO i)         -- ^ load the workflow input given its execution id
  -> IO ()
pollRounds pool who env n def loadInput = replicateM_ (max 0 n) $ do
  t     <- weNow env
  _     <- fireDueTimers pool t
  let lease = "2099-01-01T00:00:00Z"   -- far-future lease for poll-loop claims
  _     <- drainOnce pool who lease env def loadInput
  pure ()

-- | Return the 'CassetteKey's of activities that recorded an intent but no
-- result AND are 'Unkeyable' — i.e. they cannot be made exactly-once.
--
-- These represent crashed-mid-flight side effects that cannot be safely
-- retried (no deterministic idempotency key). 'Keyable' and 'Idempotent'
-- pending intents are omitted because they are safe to re-run (the idem key
-- deduplicates / the op is inherently idempotent).
--
-- Callers can surface this list to an alert sink; the exact alerting strategy
-- is out of scope for the worker itself.
unkeyablePending :: Pool -> Int -> IO [CassetteKey]
unkeyablePending pool eid = do
  ps <- pendingIntents pool eid
  pure [ k | (k, Unkeyable) <- ps ]
