{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Postgres-backed 'JournalStore' via manifest. Provides
-- 'journalStoreManifest', 'migrateJournal', 'createExecution',
-- 'claimExecution', 'heartbeat', 'completeExecution', and
-- 'listReadyExecutions'.
--
-- All @ByteString@ columns are stored as base64-encoded @Text@ to avoid
-- needing a @bytea@ 'DbType'. The claim-with-lease uses a single
-- @UPDATE … RETURNING@ CAS, relying on ISO-8601 lexical ordering for
-- @lease_until@ comparisons (documented assumption: callers pass UTC
-- timestamps in ISO-8601 format so string comparison equals temporal ordering).
module Crucible.Manifest.Journal
  ( migrateJournal
  , createExecution
  , journalStoreManifest
  , claimExecution
  , heartbeat
  , completeExecution
  , executionStatus
  , listReadyExecutions
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Base64 as B64
import Data.Functor.Identity (Identity)
import Data.List (foldl', sortOn)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import Text.Read (readMaybe)

import Manifest
  ( Entity (..), Table (..)
  , withSession, withTransaction
  , add, selectWhere
  , managed, migrateUp
  , encode
  , (==.)
  , Field, Pk, PrimaryKey
  , Db
  )
import Manifest.Session (execDb)
import Manifest.Postgres (Pool)

import Crucible.Journal
  ( JournalStore (..)
  , JournalIdentity (..)
  , Journal (..)
  , Entry (..)
  , CassetteKey (..)
  , emptyJournal
  , insertEntry
  )

-- ---------------------------------------------------------------------------
-- Base64 helpers
-- ---------------------------------------------------------------------------

b64 :: ByteString -> Text
b64 = TE.decodeUtf8 . B64.encode

unb64 :: Text -> ByteString
unb64 = either (const "") id . B64.decode . TE.encodeUtf8

-- ---------------------------------------------------------------------------
-- Entities
-- ---------------------------------------------------------------------------

data ExecutionRowT f = ExecutionRow
  { exId          :: Field f (Pk Int)
  , exType        :: Field f Text
  , exInput       :: Field f Text      -- base64-encoded jiInput
  , exAppVersion  :: Field f Text
  , exCapturedAt  :: Field f Text
  , exStatus      :: Field f Text
  } deriving Generic

type ExecutionRow = ExecutionRowT Identity

deriving via (Table "workflow_execution" ExecutionRowT) instance Entity ExecutionRow

data JournalEntryRowT f = JournalEntryRow
  { jeId     :: Field f (Pk Int)
  , jeExec   :: Field f Int
  , jeSeq    :: Field f Int
  , jeKey    :: Field f Text    -- base64-encoded CassetteKey bytes
  , jeOp     :: Field f Text
  , jeResult :: Field f Text    -- base64-encoded result bytes
  } deriving Generic

type JournalEntryRow = JournalEntryRowT Identity

deriving via (Table "journal_entry" JournalEntryRowT) instance Entity JournalEntryRow

-- RunQueueRow uses PrimaryKey Int (not Pk Int = PrimaryKey (Serial Int))
-- so we can INSERT a supplied exec id rather than having the DB auto-assign it.
-- PrimaryKey without Serial = natural/supplied PK, mirroring Research's PrimaryKey Text.
data RunQueueRowT f = RunQueueRow
  { rqExec       :: Field f (PrimaryKey Int)
  , rqState      :: Field f Text
  , rqClaimant   :: Field f (Maybe Text)
  , rqLeaseUntil :: Field f (Maybe Text)
  } deriving Generic

type RunQueueRow = RunQueueRowT Identity

deriving via (Table "run_queue" RunQueueRowT) instance Entity RunQueueRow

-- ---------------------------------------------------------------------------
-- Migration
-- ---------------------------------------------------------------------------

migrateJournal :: Pool -> IO ()
migrateJournal pool =
  withSession pool $ do
    _ <- migrateUp
           [ managed (Proxy @ExecutionRow)
           , managed (Proxy @JournalEntryRow)
           , managed (Proxy @RunQueueRow)
           ]
    pure ()

-- ---------------------------------------------------------------------------
-- Execution lifecycle
-- ---------------------------------------------------------------------------

-- | Create a new execution row (status = 'running') and a corresponding
-- 'ready' run_queue row. Returns the assigned serial execution id.
createExecution :: Pool -> JournalIdentity -> IO Int
createExecution pool ident = withSession pool $ withTransaction $ do
  ex <- add (ExecutionRow
               0
               (jiWorkflowType ident)
               (b64 (jiInput ident))
               (jiAppVersion ident)
               (jiCapturedAt ident)
               "running"
             :: ExecutionRow)
  let eid = ex.exId
  _ <- add (RunQueueRow eid "ready" Nothing Nothing :: RunQueueRow)
  pure eid

-- | Build a durable 'JournalStore' for one execution (identified by its id).
--
-- * 'jsLoad'   — reconstructs the 'Journal' from the execution row + ordered
--                journal_entry rows; base64-decodes all byte columns.
-- * 'jsAppend' — inserts a journal_entry row (next seq = current count); the
--                @op@ argument is stored in @je_op@; result is base64-encoded.
--
-- Each call runs in its own 'withSession' (autocommit). For Phase 1's
-- single-workflow slice this is acceptable; wrap in 'withTransaction' if you
-- need atomic append + queue-state advance in a future phase.
journalStoreManifest :: Pool -> Int -> IO JournalStore
journalStoreManifest pool eid = pure JournalStore
  { jsLoad = withSession pool $ do
      exs <- selectWhere [#exId ==. eid] :: Db [ExecutionRow]
      es  <- selectWhere [#jeExec ==. eid] :: Db [JournalEntryRow]
      let ident = case exs of
            (e:_) -> JournalIdentity
                       (e.exType)
                       (unb64 (e.exInput))
                       (e.exAppVersion)
                       (e.exCapturedAt)
            []    -> JournalIdentity "" "" "" ""
          sorted = sortOn (.jeSeq) es
          -- foldl' over rows in ascending seq order; insertEntry appends each
          -- entry and assigns a fresh seq (length-based), reproducing the
          -- original 0,1,2,... seq assignment.
          entries = foldl' (\j r ->
                      insertEntry
                        (CassetteKey (unb64 (r.jeKey)))
                        (unb64 (r.jeResult))
                        j)
                    (emptyJournal ident)
                    sorted
      pure entries

  , jsAppend = \(CassetteKey k) op bs -> withSession pool $ do
      es <- selectWhere [#jeExec ==. eid] :: Db [JournalEntryRow]
      _  <- add (JournalEntryRow 0 eid (length es) (b64 k) op (b64 bs) :: JournalEntryRow)
      pure ()
  }

-- ---------------------------------------------------------------------------
-- Run queue: claim-with-lease (CAS via UPDATE … RETURNING)
-- ---------------------------------------------------------------------------

-- | Atomically claim one ready (or lease-expired) execution for the given
-- claimant with the given lease deadline (ISO-8601 string). Returns the
-- claimed execution id, or 'Nothing' if the queue was empty / all claimed.
--
-- The WHERE combines @state = 'ready'@ with @(state = 'claimed' AND
-- lease_until < $2)@ so an expired lease is atomically reclaimable. String
-- comparison of ISO-8601 UTC timestamps is equivalent to temporal ordering
-- (documented assumption: callers pass valid UTC ISO-8601 strings).
claimExecution :: Pool -> Text -> Text -> IO (Maybe Int)
claimExecution pool who lease = withSession pool $ do
  rows <- execDb
    "UPDATE run_queue \
    \SET rq_state = 'claimed', rq_claimant = $1, rq_lease_until = $2 \
    \WHERE rq_exec IN ( \
    \  SELECT rq_exec FROM run_queue \
    \  WHERE rq_state = 'ready' OR (rq_state = 'claimed' AND rq_lease_until < $2) \
    \  LIMIT 1 \
    \) \
    \RETURNING rq_exec"
    [ encode who
    , encode lease
    ]
  pure $ case rows of
    ([Just bs] : _) -> readMaybe (BC.unpack bs)
    _               -> Nothing

-- | Extend the lease for an already-claimed execution.
heartbeat :: Pool -> Int -> Text -> IO ()
heartbeat pool eid newLease = withSession pool $ do
  _ <- execDb
    "UPDATE run_queue SET rq_lease_until = $1 WHERE rq_exec = $2"
    [ encode newLease
    , encode eid
    ]
  pure ()

-- | Mark an execution as completed: set @workflow_execution.ex_status =
-- 'completed'@ and @run_queue.rq_state = 'done'@. Runs in a single
-- transaction for atomicity.
completeExecution :: Pool -> Int -> IO ()
completeExecution pool eid = withSession pool $ withTransaction $ do
  _ <- execDb
    "UPDATE workflow_execution SET ex_status = 'completed' WHERE ex_id = $1"
    [ encode eid ]
  _ <- execDb
    "UPDATE run_queue SET rq_state = 'done' WHERE rq_exec = $1"
    [ encode eid ]
  pure ()

-- | The status of an execution ('running'/'completed'/'failed'), or Nothing if absent.
executionStatus :: Pool -> Int -> IO (Maybe Text)
executionStatus pool eid = withSession pool $ do
  exs <- selectWhere [#exId ==. eid] :: Db [ExecutionRow]
  pure (case exs of (e:_) -> Just (exStatus e); [] -> Nothing)

-- | List execution ids currently in the 'ready' state (for polling / tests).
listReadyExecutions :: Pool -> IO [Int]
listReadyExecutions pool = withSession pool $ do
  rows <- selectWhere [#rqState ==. ("ready" :: Text)] :: Db [RunQueueRow]
  pure (map (.rqExec) rows)
