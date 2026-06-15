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
-- execution completed. If the queue is empty it returns 'Nothing'.
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
-- program to completion under replay-to-resume semantics, and mark the
-- execution completed. Returns the claimed execution id, or 'Nothing' if the
-- run_queue is empty.
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
  -> IO (Maybe Int)
runOnce pool who lease def loadInput = do
  mid <- claimExecution pool who lease
  case mid of
    Nothing  -> pure Nothing
    Just eid -> do
      store <- journalStoreManifest pool eid
      j     <- jsLoad store
      i     <- loadInput eid
      _ <- runEff (runErrorNoCallStack (wdProgram def i j store))
      completeExecution pool eid
      pure (Just eid)
