{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
import Control.Exception (SomeException, bracket, catch)
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
  ]
