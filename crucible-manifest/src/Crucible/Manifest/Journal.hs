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
  , createChildExecution
  , journalStoreManifest
  , claimExecution
  , heartbeat
  , completeExecution
  , completeExecutionWith
  , executionStatus
  , executionInput
  , listReadyExecutions
  , suspendTimer
  , fireDueTimers
  , suspendSignal
  , suspendChild
  , deliverSignal
  , pendingIntents
  ) where

import Control.Monad (forM)
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
  , ActivityKind (..)
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
  , exParentExec  :: Field f (Maybe Int)   -- parent execution id (for child executions)
  , exParentKey   :: Field f (Maybe Text)  -- base64-encoded parent cassette key
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
  , jeStatus :: Field f Text    -- "result" | "intent"
  , jeKind   :: Field f Text    -- "" | "idempotent" | "keyable" | "unkeyable"
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
  , rqWaitKey    :: Field f (Maybe Text)   -- base64 cassette key of the suspended prim
  , rqWaitKind   :: Field f (Maybe Text)   -- "timer" | "signal" (this cycle)
  , rqWakeAt     :: Field f (Maybe Text)   -- ISO-8601 wake time
  , rqWaitName   :: Field f (Maybe Text)   -- signal name (for "signal" wait kind)
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
               Nothing
               Nothing
             :: ExecutionRow)
  let eid = ex.exId
  _ <- add (RunQueueRow eid "ready" Nothing Nothing Nothing Nothing Nothing Nothing :: RunQueueRow)
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
-- | Text representation of an 'ActivityKind' for database storage.
kindText :: ActivityKind -> Text
kindText Idempotent = "idempotent"
kindText Keyable    = "keyable"
kindText Unkeyable  = "unkeyable"

-- | Parse an 'ActivityKind' from its stored text; defaults to 'Unkeyable'
-- for unknown values (conservative: unknown = must not assume safe retry).
kindOf :: Text -> ActivityKind
kindOf "idempotent" = Idempotent
kindOf "keyable"    = Keyable
kindOf _            = Unkeyable

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
          -- Only rebuild the journal from result rows; intent rows are
          -- observability metadata and must not appear in replay.
          resultRows = filter (\r -> r.jeStatus == "result") es
          sorted = sortOn (.jeSeq) resultRows
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
      _  <- add (JournalEntryRow 0 eid (length es) (b64 k) op (b64 bs) "result" "" :: JournalEntryRow)
      pure ()

  , jsIntent = \(CassetteKey k) op kind -> withSession pool $ do
      es <- selectWhere [#jeExec ==. eid] :: Db [JournalEntryRow]
      _  <- add (JournalEntryRow 0 eid (length es) (b64 k) op (b64 "") "intent" (kindText kind) :: JournalEntryRow)
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

-- | Create a child execution linked to a parent, with a run_queue row in
-- 'ready' state. Returns the assigned serial child execution id.
createChildExecution :: Pool -> JournalIdentity -> Int -> CassetteKey -> IO Int
createChildExecution pool ident parentEid (CassetteKey pkey) = withSession pool $ withTransaction $ do
  ex <- add (ExecutionRow
               0
               (jiWorkflowType ident)
               (b64 (jiInput ident))
               (jiAppVersion ident)
               (jiCapturedAt ident)
               "running"
               (Just parentEid)
               (Just (b64 pkey))
             :: ExecutionRow)
  let eid = ex.exId
  _ <- add (RunQueueRow eid "ready" Nothing Nothing Nothing Nothing Nothing Nothing :: RunQueueRow)
  pure eid

-- | Park an execution as waiting-on-child: set @run_queue.rq_state = 'waiting'@,
-- store the cassette key (base64-encoded) with kind 'child', and clear the claimant.
-- The execution will not appear in 'listReadyExecutions' until 'completeExecutionWith'
-- re-queues it upon child completion.
suspendChild :: Pool -> Int -> CassetteKey -> IO ()
suspendChild pool eid (CassetteKey k) = withSession pool $ do
  _ <- execDb
    "UPDATE run_queue SET rq_state='waiting', rq_wait_key=$1, rq_wait_kind='child', rq_claimant=NULL WHERE rq_exec=$2"
    [ encode (b64 k)
    , encode eid
    ]
  pure ()

-- | Read the stored input bytes for an execution.
executionInput :: Pool -> Int -> IO ByteString
executionInput pool eid = withSession pool $ do
  exs <- selectWhere [#exId ==. eid] :: Db [ExecutionRow]
  pure (case exs of (e:_) -> unb64 (exInput e); [] -> "")

-- | Complete an execution with its output bytes. If the execution is a child
-- (has a parent link), atomically appends the output into the parent's journal
-- under the stored parent key (op "child", status "result") and readies the parent.
-- If no parent, just marks the execution completed. Runs in a single transaction.
completeExecutionWith :: Pool -> Int -> ByteString -> IO ()
completeExecutionWith pool eid out = withSession pool $ withTransaction $ do
  exs <- selectWhere [#exId ==. eid] :: Db [ExecutionRow]
  _ <- execDb
    "UPDATE workflow_execution SET ex_status='completed' WHERE ex_id=$1"
    [ encode eid ]
  _ <- execDb
    "UPDATE run_queue SET rq_state='done' WHERE rq_exec=$1"
    [ encode eid ]
  case exs of
    (e:_) | Just pexec <- exParentExec e, Just pkeyB64 <- exParentKey e -> do
      pes <- selectWhere [#jeExec ==. pexec] :: Db [JournalEntryRow]
      _   <- add (JournalEntryRow 0 pexec (length pes) pkeyB64 "child" (b64 out) "result" "" :: JournalEntryRow)
      _   <- execDb
               "UPDATE run_queue SET rq_state='ready', rq_wait_key=NULL, rq_wait_kind=NULL WHERE rq_exec=$1"
               [ encode pexec ]
      pure ()
    _ -> pure ()

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

-- ---------------------------------------------------------------------------
-- Durable timer suspend / fire
-- ---------------------------------------------------------------------------

-- | Park an execution as waiting-on-timer: set @run_queue.rq_state = 'waiting'@,
-- store the cassette key (base64-encoded) and wake-at timestamp, and clear the
-- claimant. The execution will not appear in 'listReadyExecutions' until
-- 'fireDueTimers' re-queues it.
suspendTimer :: Pool -> Int -> CassetteKey -> Text -> IO ()
suspendTimer pool eid (CassetteKey k) wakeAt = withSession pool $ do
  _ <- execDb
    "UPDATE run_queue SET rq_state='waiting', rq_wait_key=$1, rq_wait_kind='timer', rq_wake_at=$2, rq_claimant=NULL WHERE rq_exec=$3"
    [ encode (b64 k)
    , encode wakeAt
    , encode eid
    ]
  pure ()

-- | Fire all due timers: for each @waiting@ execution whose @rq_wake_at <= nowT@
-- (lexical ISO-8601 comparison), append a @sleep@ journal entry under its stored
-- key and set the execution back to @ready@ (clearing the wait fields).
-- Returns the list of fired execution ids. Runs in a single transaction.
fireDueTimers :: Pool -> Text -> IO [Int]
fireDueTimers pool nowT = withSession pool $ withTransaction $ do
  rows <- selectWhere [#rqState ==. ("waiting" :: Text)] :: Db [RunQueueRow]
  let due = [ r | r <- rows
                , rqWaitKind r == Just "timer"
                , maybe False (<= nowT) (rqWakeAt r) ]
  forM due $ \r -> do
    let eid    = rqExec r
        keyB64 = maybe "" id (rqWaitKey r)   -- already base64 of the cassette key bytes
    es <- selectWhere [#jeExec ==. eid] :: Db [JournalEntryRow]
    _  <- add (JournalEntryRow 0 eid (length es) keyB64 "sleep" (b64 "") "result" "" :: JournalEntryRow)
    _  <- execDb
            "UPDATE run_queue SET rq_state='ready', rq_wait_key=NULL, rq_wait_kind=NULL, rq_wake_at=NULL WHERE rq_exec=$1"
            [ encode eid ]
    pure eid

-- ---------------------------------------------------------------------------
-- Durable signal suspend / deliver
-- ---------------------------------------------------------------------------

-- | Park an execution as waiting-on-signal: set @run_queue.rq_state = 'waiting'@,
-- store the cassette key (base64-encoded), the wait kind 'signal', the signal
-- name, and clear the claimant. The execution will not appear in
-- 'listReadyExecutions' until 'deliverSignal' re-queues it.
suspendSignal :: Pool -> Int -> CassetteKey -> Text -> IO ()
suspendSignal pool eid (CassetteKey k) name = withSession pool $ do
  _ <- execDb
    "UPDATE run_queue SET rq_state='waiting', rq_wait_key=$1, rq_wait_kind='signal', rq_wait_name=$2, rq_claimant=NULL WHERE rq_exec=$3"
    [ encode (b64 k)
    , encode name
    , encode eid
    ]
  pure ()

-- | Deliver a signal to an execution waiting on the given name. If the
-- execution is in @waiting@ state with @rq_wait_kind='signal'@ and
-- @rq_wait_name = name@, append the payload under the stored wait key
-- (status=result, op=signal) and set the execution back to @ready@.
-- Returns 'True' iff delivered, 'False' if no matching waiting execution.
deliverSignal :: Pool -> Int -> Text -> ByteString -> IO Bool
deliverSignal pool eid name payload = withSession pool $ withTransaction $ do
  rows <- selectWhere [#rqExec ==. eid] :: Db [RunQueueRow]
  case [ r | r <- rows, rqState r == "waiting", rqWaitKind r == Just "signal", rqWaitName r == Just name ] of
    (r:_) -> do
      es <- selectWhere [#jeExec ==. eid] :: Db [JournalEntryRow]
      let keyB64 = maybe "" id (rqWaitKey r)
      _ <- add (JournalEntryRow 0 eid (length es) keyB64 "signal" (b64 payload) "result" "" :: JournalEntryRow)
      _ <- execDb
             "UPDATE run_queue SET rq_state='ready', rq_wait_key=NULL, rq_wait_kind=NULL, rq_wait_name=NULL WHERE rq_exec=$1"
             [ encode eid ]
      pure True
    [] -> pure False

-- | Return keys that have an intent row but no result row for the given
-- execution. These represent activities that started (intent recorded) but
-- whose result was never persisted — i.e. potential crash-mid-flight sites.
pendingIntents :: Pool -> Int -> IO [(CassetteKey, ActivityKind)]
pendingIntents pool eid = withSession pool $ do
  rs <- selectWhere [#jeExec ==. eid] :: Db [JournalEntryRow]
  let resultKeys = [ r.jeKey | r <- rs, r.jeStatus == "result" ]
  pure [ (CassetteKey (unb64 (r.jeKey)), kindOf (r.jeKind))
       | r <- rs, r.jeStatus == "intent", r.jeKey `notElem` resultKeys ]
