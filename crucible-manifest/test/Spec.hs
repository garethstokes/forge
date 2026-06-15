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
  , lookupEntry
  )
import Crucible.Manifest.Journal
  ( migrateJournal
  , createExecution
  , journalStoreManifest
  , claimExecution
  , completeExecution
  , listReadyExecutions
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
