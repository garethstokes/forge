{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
import Control.Exception (SomeException, bracket, catch)
import Data.ByteString (ByteString)
import Data.IORef (newIORef)
import System.Directory
  ( createDirectoryIfMissing
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)

import Manifest (withEphemeralDb)
import Data.Text (Text)
import qualified Crucible.Codec as C

import Crucible.Memory
  ( MemoryDraft (..)
  , MemoryId (..)
  , MemoryItem
  , MemoryItemT (..)
  , MemoryKind (..)
  , MemoryStore (..)
  , Provenance (..)
  , Query (..)
  , memoryStoreFile
  , newMemoryStorePure
  )
import Crucible.Manifest.Memory (memoryStoreManifest, migrateMemory)

import Crucible.Ledger
  ( LedgerStore (..)
  , WorkId (..)
  , WorkItem
  , WorkItemT (..)
  , WorkState (..)
  , ledgerStoreFile
  , newLedgerStorePure
  )
import Crucible.Manifest.Ledger (ledgerStoreManifest, migrateLedger)

import Crucible.Research
  ( ResearchStore (..)
  , researchStoreDir
  , researchStoreState
  )
import Crucible.Manifest.Research (researchStoreManifest, migrateResearch)

import Crucible.Journal
  ( JournalStore (..)
  , JournalIdentity (..)
  , Entry (..)
  , CassetteKey (..)
  , Journal (..)
  , ActivityKind (..)
  , lookupEntry
  )
import Crucible.Manifest.Journal
  ( migrateJournal
  , createExecution
  , journalStoreManifest
  , claimExecution
  , completeExecution
  , executionStatus
  , listReadyExecutions
  , suspendTimer
  , fireDueTimers
  , suspendSignal
  , deliverSignal
  , pendingIntents
  )

import Conformance
  ( Test (..)
  , assertEq
  , ledgerConformance
  , memoryConformance
  , researchConformance
  , runTests
  )

-- ---------------------------------------------------------------------------
-- Temp helpers
-- ---------------------------------------------------------------------------

withTempFile :: (FilePath -> IO a) -> IO a
withTempFile act = do
  tmp <- getTemporaryDirectory
  bracket
    (do (p, h) <- openTempFile tmp "conf.jsonl"; hClose h; pure p)
    removeFile
    act

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir act = do
  tmp <- getTemporaryDirectory
  let d = tmp </> "conf-research"
  bracket
    (do removeDirectoryRecursive d `catch` \(_ :: SomeException) -> pure ()
        createDirectoryIfMissing True d
        pure d)
    (\_ -> removeDirectoryRecursive d `catch` \(_ :: SomeException) -> pure ())
    act

-- ---------------------------------------------------------------------------
-- Backend brackets
-- ---------------------------------------------------------------------------

withMemFile :: (MemoryStore -> IO a) -> IO a
withMemFile k = withTempFile (\p -> k (memoryStoreFile p))

withLedgerFile :: (LedgerStore -> IO a) -> IO a
withLedgerFile k = withTempFile (\p -> k (ledgerStoreFile p))

withResearchDir :: (ResearchStore Text -> IO a) -> IO a
withResearchDir k = withTempDir (\d -> k (researchStoreDir C.str d))

-- ---------------------------------------------------------------------------
-- Backend-specific extras (not covered by conformance suite)
-- ---------------------------------------------------------------------------

memorySpecific :: [Test]
memorySpecific =
  [ Test "memory[manifest]: recalled createdAt mirrors the assigned id" $
      withEphemeralDb $ \pool -> do
        migrateMemory pool
        let s = memoryStoreManifest pool
        _ <- s.doRemember (MemoryDraft Semantic "a" ["t"] Curated)
        _ <- s.doRemember (MemoryDraft Episodic "b" ["t"] Curated)
        _ <- s.doRemember (MemoryDraft Semantic "c" ["t"] Curated)
        rc <- s.doRecall (Query "" ["t"] 1)
        case rc of
          (it : _) -> do
            let mid = (it.memId   :: MemoryId)
                ca  = (it.createdAt :: Int)
            assertEq "createdAt mirrors id" mid (MemoryId ca)
          [] -> ioError (userError "expected at least one recalled item")
  ]

ledgerSpecific :: [Test]
ledgerSpecific =
  [ Test "ledger[manifest]: record returns distinct increasing ids" $
      withEphemeralDb $ \pool -> do
        migrateLedger pool
        let s = ledgerStoreManifest pool
        i1 <- s.doRecord "A"
        i2 <- s.doRecord "B"
        i3 <- s.doRecord "C"
        if i1 < i2 && i2 < i3
          then pure ()
          else ioError (userError ("ids not strictly increasing: " <> show (i1, i2, i3)))
  ]

-- ---------------------------------------------------------------------------
-- Journal-specific tests
-- ---------------------------------------------------------------------------

ident0 :: JournalIdentity
ident0 = JournalIdentity "test-workflow" "input-bytes" "v1" "2026-06-15T00:00:00Z"

journalSpecific :: [Test]
journalSpecific =
  [ Test "journal[manifest]: append+load round-trips two entries in seq order" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid <- createExecution pool ident0
        st  <- journalStoreManifest pool eid
        let k1 = CassetteKey "key-one"
            k2 = CassetteKey "key-two"
        jsAppend st k1 "op1" "result-one"
        jsAppend st k2 "op2" "result-two"
        j <- jsLoad st
        let e1 = lookupEntry k1 j
            e2 = lookupEntry k2 j
        case (e1, e2) of
          (Just r1, Just r2) -> do
            assertEq "entry 1 result bytes" ("result-one" :: ByteString) (r1.eResult)
            assertEq "entry 2 result bytes" ("result-two" :: ByteString) (r2.eResult)
            assertEq "entry 1 seq" 0 r1.eSeq
            assertEq "entry 2 seq" 1 r2.eSeq
          _ -> ioError (userError ("expected 2 entries, got: " <> show (e1, e2)))

  , Test "journal[manifest]: claim CAS second claim returns Nothing" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid <- createExecution pool ident0
        let lease1 = "2099-01-01T00:00:00Z"
        mc1 <- claimExecution pool "worker-1" lease1
        assertEq "first claim returns the exec id" (Just eid) mc1
        mc2 <- claimExecution pool "worker-2" lease1
        assertEq "second claim returns Nothing (lease not expired)" Nothing mc2

  , Test "journal[manifest]: expired lease is reclaimable" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid <- createExecution pool ident0
        -- claim with a lease already in the past
        let pastLease = "2000-01-01T00:00:00Z"
            nowLease  = "2099-01-01T00:00:00Z"
        mc1 <- claimExecution pool "worker-1" pastLease
        assertEq "initial claim succeeds" (Just eid) mc1
        -- reclaim: pastLease < nowLease, so the expired-lease branch fires
        mc2 <- claimExecution pool "worker-2" nowLease
        assertEq "reclaim of expired lease returns the exec id" (Just eid) mc2

  , Test "journal[manifest]: completeExecution removes from ready list" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid1 <- createExecution pool ident0
        eid2 <- createExecution pool ident0
        readyBefore <- listReadyExecutions pool
        assertEq "both executions are ready" 2 (length readyBefore)
        completeExecution pool eid1
        readyAfter <- listReadyExecutions pool
        assertEq "only one execution remains ready" 1 (length readyAfter)
        assertEq "remaining is eid2" [eid2] readyAfter

  , Test "journal[manifest]: suspendTimer parks execution as waiting (not ready)" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid <- createExecution pool ident0
        suspendTimer pool eid (CassetteKey "sleepkey") "2026-06-15T00:00:10Z"
        st <- executionStatus pool eid
        -- executionStatus reads workflow_execution.ex_status which is still 'running'
        -- The run_queue state is 'waiting'; check via listReadyExecutions
        assertEq "executionStatus is still running" (Just "running") st
        ready <- listReadyExecutions pool
        assertEq "execution is NOT in ready list after suspend" [] ready

  , Test "journal[manifest]: fireDueTimers before wake returns empty, after wake fires" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid <- createExecution pool ident0
        let sleepKey = CassetteKey "sleepkey"
        suspendTimer pool eid sleepKey "2026-06-15T00:00:10Z"

        -- fire before wake-at: should return []
        fired0 <- fireDueTimers pool "2026-06-15T00:00:05Z"
        assertEq "fireDueTimers before wake returns []" [] fired0
        ready0 <- listReadyExecutions pool
        assertEq "exec still waiting after early fire" [] ready0

        -- fire after wake-at: should return [eid]
        fired1 <- fireDueTimers pool "2026-06-15T01:00:00Z"
        assertEq "fireDueTimers after wake returns [eid]" [eid] fired1
        ready1 <- listReadyExecutions pool
        assertEq "exec is ready again after firing" [eid] ready1

        -- the journal should now have a sleep entry under the sleep key
        st <- journalStoreManifest pool eid
        j  <- jsLoad st
        let entry = lookupEntry sleepKey j
        case entry of
          Nothing -> ioError (userError "expected sleep entry in journal after fireDueTimers, got Nothing")
          Just _  -> pure ()

        -- re-entrancy: a second fire does not double-fire (the exec is now 'ready', not 'waiting')
        fired2 <- fireDueTimers pool "2026-06-15T01:00:00Z"
        assertEq "fireDueTimers is idempotent (second fire returns [])" [] fired2
        st2 <- journalStoreManifest pool eid
        j2  <- jsLoad st2
        assertEq "no duplicate sleep entry after second fire" 1 (length (jEntries j2))

  , Test "journal[manifest]: jsIntent appears in pendingIntents; jsAppend clears it; jsLoad excludes intents" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid <- createExecution pool ident0
        store <- journalStoreManifest pool eid
        let k1 = CassetteKey "k1"
        -- Record intent only
        jsIntent store k1 "op" Keyable
        -- pendingIntents should show the intent
        p1 <- pendingIntents pool eid
        assertEq "pendingIntents after jsIntent" [(k1, Keyable)] p1
        -- jsLoad must NOT include the intent row (no result yet)
        j1 <- jsLoad store
        assertEq "jsLoad excludes intent rows" Nothing (lookupEntry k1 j1)
        -- Now append the result
        jsAppend store k1 "op" "v"
        -- pendingIntents should now be empty
        p2 <- pendingIntents pool eid
        assertEq "pendingIntents after jsAppend is empty" [] p2
        -- jsLoad must now include the result
        j2 <- jsLoad store
        case lookupEntry k1 j2 of
          Nothing -> ioError (userError "expected result entry in journal after jsAppend, got Nothing")
          Just e  -> assertEq "result entry bytes" ("v" :: ByteString) (e.eResult)

  , Test "journal[manifest]: suspendSignal parks execution as waiting (not ready)" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid <- createExecution pool ident0
        suspendSignal pool eid (CassetteKey "sk") "go"
        ready <- listReadyExecutions pool
        assertEq "execution is NOT in ready list after suspendSignal" [] ready

  , Test "journal[manifest]: deliverSignal wrong name returns False; correct name delivers and readies" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid <- createExecution pool ident0
        suspendSignal pool eid (CassetteKey "sk") "go"

        -- wrong name: should return False and leave exec waiting
        delivered0 <- deliverSignal pool eid "nope" "x"
        assertEq "deliverSignal wrong name returns False" False delivered0
        ready0 <- listReadyExecutions pool
        assertEq "exec still waiting after wrong-name deliver" [] ready0

        -- correct name: should return True, exec becomes ready
        delivered1 <- deliverSignal pool eid "go" "payload"
        assertEq "deliverSignal correct name returns True" True delivered1
        ready1 <- listReadyExecutions pool
        assertEq "exec is ready again after deliverSignal" [eid] ready1

        -- the journal should have an entry under CassetteKey "sk" with result="payload"
        st <- journalStoreManifest pool eid
        j  <- jsLoad st
        let entry = lookupEntry (CassetteKey "sk") j
        case entry of
          Nothing -> ioError (userError "expected signal entry in journal after deliverSignal, got Nothing")
          Just e  -> assertEq "signal entry result bytes" ("payload" :: ByteString) (e.eResult)
  ]

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

main :: IO ()
main = runTests $ concat
  [ memoryConformance   "file"     withMemFile
  , memoryConformance   "pure"     (\k -> newMemoryStorePure >>= k)
  , memoryConformance   "manifest" (\k -> withEphemeralDb (\p -> migrateMemory p >> k (memoryStoreManifest p)))
  , ledgerConformance   "file"     withLedgerFile
  , ledgerConformance   "pure"     (\k -> newLedgerStorePure >>= k)
  , ledgerConformance   "manifest" (\k -> withEphemeralDb (\p -> migrateLedger p >> k (ledgerStoreManifest p)))
  , researchConformance "dir"      withResearchDir
  , researchConformance "state"    (\k -> do { pr <- newIORef []; lr <- newIORef []; k (researchStoreState pr lr) })
  , researchConformance "manifest" (\k -> withEphemeralDb (\p -> migrateResearch p >> k (researchStoreManifest C.str p)))
  , memorySpecific
  , ledgerSpecific
  , journalSpecific
  ]
