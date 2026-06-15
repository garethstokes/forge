{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
import Control.Exception (SomeException, try, evaluate)
import Data.Text (Text)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

import Manifest (withEphemeralDb)

import Crucible.Memory
  ( MemoryDraft (..)
  , MemoryId (..)
  , MemoryItem
  , MemoryItemT (..)
  , MemoryKind (..)
  , MemoryStore (..)
  , Provenance (..)
  , Query (..)
  )
import Crucible.Manifest.Memory (memoryStoreManifest, migrateMemory)
import Crucible.Ledger
  ( WorkId (..)
  , WorkState (..)
  , WorkItemT (..)
  , WorkItem
  , LedgerStore (..)
  )
import Crucible.Manifest.Ledger (ledgerStoreManifest, migrateLedger)
import Crucible.Research
  ( Page (..)
  , Slug (..)
  , Link (..)
  , LinkType (..)
  , ResearchStore (..)
  )
import Crucible.Manifest.Research (researchStoreManifest, migrateResearch)
import qualified Crucible.Codec as C

-- ---------------------------------------------------------------------------
-- Tiny harness (no hspec dep)
-- ---------------------------------------------------------------------------

data Test = Test String (IO ())

runTests :: [Test] -> IO ()
runTests ts = do
  results <- mapM run ts
  let passed = length (filter id results)
      total  = length results
  putStrLn (show passed <> "/" <> show total <> " tests passed")
  if passed == total then exitSuccess else exitFailure
  where
    run (Test name act) = do
      r <- try (act >>= evaluate) :: IO (Either SomeException ())
      case r of
        Right () -> putStrLn ("  ok   " <> name) >> pure True
        Left e   -> hPutStrLn stderr ("  FAIL " <> name <> "\n         " <> show e) >> pure False

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq msg expected actual
  | expected == actual = pure ()
  | otherwise = ioError (userError
      (msg <> ": expected " <> show expected <> " but got " <> show actual))

assertBool :: String -> Bool -> IO ()
assertBool msg ok = if ok then pure () else ioError (userError msg)

-- | Extract content field from a MemoryItem (positional pattern match avoids
-- the NoFieldSelectors restriction on the .content selector).
itemContent :: MemoryItem -> Text
itemContent (MemoryItem _ _ c _ _ _) = c

-- | Extract the (memId, createdAt) pair from a MemoryItem positionally.
itemIdAndCreated :: MemoryItem -> (MemoryId, Int)
itemIdAndCreated (MemoryItem mid _ _ _ _ ca) = (mid, ca)

-- | Unwrap the three store operations from a MemoryStore.
storeOps :: MemoryStore
         -> ( MemoryDraft -> IO MemoryId
            , Query -> IO [MemoryItem]
            , MemoryId -> IO ()
            )
storeOps (MemoryStore r rc f) = (r, rc, f)

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

main :: IO ()
main = runTests
  [ Test "ids are distinct and increasing" $ withEphemeralDb $ \pool -> do
      migrateMemory pool
      let (remember, _recall, _forget) = storeOps (memoryStoreManifest pool)
      i1 <- remember (MemoryDraft Semantic  ("a" :: Text) ["t"] Curated)
      i2 <- remember (MemoryDraft Episodic  ("b" :: Text) ["t"] Curated)
      i3 <- remember (MemoryDraft Semantic  ("c" :: Text) ["t"] Curated)
      assertBool "i1 < i2" (i1 < i2)
      assertBool "i2 < i3" (i2 < i3)

  , Test "recall returns all matching items newest-first" $ withEphemeralDb $ \pool -> do
      migrateMemory pool
      let (remember, recall, _forget) = storeOps (memoryStoreManifest pool)
      _ <- remember (MemoryDraft Semantic  ("a" :: Text) ["t"] Curated)
      _ <- remember (MemoryDraft Episodic  ("b" :: Text) ["t"] Curated)
      _ <- remember (MemoryDraft Semantic  ("c" :: Text) ["t"] Curated)
      r1 <- recall (Query "" ["t"] 10)
      assertEq "recall all" (["c", "b", "a"] :: [Text]) (map itemContent r1)

  , Test "forget removes item from recall" $ withEphemeralDb $ \pool -> do
      migrateMemory pool
      let (remember, recall, forget) = storeOps (memoryStoreManifest pool)
      _ <- remember (MemoryDraft Semantic  ("a" :: Text) ["t"] Curated)
      i2 <- remember (MemoryDraft Episodic ("b" :: Text) ["t"] Curated)
      _ <- remember (MemoryDraft Semantic  ("c" :: Text) ["t"] Curated)
      forget i2
      r2 <- recall (Query "" ["t"] 10)
      assertEq "after forget" (["c", "a"] :: [Text]) (map itemContent r2)

  , Test "recall respects maxItems budget" $ withEphemeralDb $ \pool -> do
      migrateMemory pool
      let (remember, recall, _forget) = storeOps (memoryStoreManifest pool)
      _ <- remember (MemoryDraft Semantic  ("a" :: Text) ["t"] Curated)
      _ <- remember (MemoryDraft Episodic  ("b" :: Text) ["t"] Curated)
      _ <- remember (MemoryDraft Semantic  ("c" :: Text) ["t"] Curated)
      r3 <- recall (Query "" ["t"] 1)
      assertEq "budget 1" (["c"] :: [Text]) (map itemContent r3)

  , Test "recalled createdAt mirrors the assigned id" $ withEphemeralDb $ \pool -> do
      migrateMemory pool
      let (remember, recall, _forget) = storeOps (memoryStoreManifest pool)
      _ <- remember (MemoryDraft Semantic  ("a" :: Text) ["t"] Curated)
      _ <- remember (MemoryDraft Episodic  ("b" :: Text) ["t"] Curated)
      _ <- remember (MemoryDraft Semantic  ("c" :: Text) ["t"] Curated)
      -- The most recent item ("c") is returned first.
      rc <- recall (Query "" ["t"] 1)
      case rc of
        (it:_) -> do
          let (mid, ca) = itemIdAndCreated it
          assertEq "createdAt mirrors id" mid (MemoryId ca)
        [] -> ioError (userError "expected at least one recalled item")

  -- Ledger tests
  , Test "ledger: ids are distinct and increasing" $ withEphemeralDb $ \pool -> do
      migrateLedger pool
      let s = ledgerStoreManifest pool
      i1 <- s.doRecord "A"
      i2 <- s.doRecord "B"
      i3 <- s.doRecord "C"
      assertBool "i1 < i2" (i1 < i2)
      assertBool "i2 < i3" (i2 < i3)

  , Test "ledger: listReady returns all three items Ready" $ withEphemeralDb $ \pool -> do
      migrateLedger pool
      let s = ledgerStoreManifest pool
      _ <- s.doRecord "A"
      _ <- s.doRecord "B"
      _ <- s.doRecord "C"
      items <- s.doListReady
      assertEq "listReady count" 3 (length items)
      let states = map (\(WorkItem _ _ st _) -> st) items
      assertBool "all Ready" (all (== Ready) states)

  , Test "ledger: claim CAS — first claim wins, second fails" $ withEphemeralDb $ \pool -> do
      migrateLedger pool
      let s = ledgerStoreManifest pool
      i1 <- s.doRecord "A"
      _ <- s.doRecord "B"
      _ <- s.doRecord "C"
      r1 <- s.doClaim i1 "alice"
      assertBool "alice claimed" r1
      r2 <- s.doClaim i1 "bob"
      assertBool "bob rejected" (not r2)

  , Test "ledger: claimed item absent from listReady" $ withEphemeralDb $ \pool -> do
      migrateLedger pool
      let s = ledgerStoreManifest pool
      i1 <- s.doRecord "A"
      _ <- s.doRecord "B"
      _ <- s.doRecord "C"
      _ <- s.doClaim i1 "alice"
      items <- s.doListReady
      assertEq "2 ready after claim" 2 (length items)

  , Test "ledger: complete removes item from listReady" $ withEphemeralDb $ \pool -> do
      migrateLedger pool
      let s = ledgerStoreManifest pool
      i1 <- s.doRecord "A"
      i2 <- s.doRecord "B"
      _ <- s.doRecord "C"
      _ <- s.doClaim i1 "alice"
      s.doComplete i2
      items <- s.doListReady
      assertEq "1 ready after complete" 1 (length items)

  -- Research tests
  , Test "research: doRead returns written page" $ withEphemeralDb $ \pool -> do
      migrateResearch pool
      let rs = researchStoreManifest C.str pool
      rs.doWrite (Page (Slug "a") "Alpha" [Link (Slug "b") Extends] "alpha body" ("m" :: Text))
      rs.doWrite (Page (Slug "b") "Beta"  [] "beta body" ("n" :: Text))
      mpa <- rs.doRead (Slug "a")
      assertEq "read page a"
        (Just (Page (Slug "a") "Alpha" [Link (Slug "b") Extends] "alpha body" ("m" :: Text)))
        mpa

  , Test "research: overwrite replaces title/body/links/meta" $ withEphemeralDb $ \pool -> do
      migrateResearch pool
      let rs = researchStoreManifest C.str pool
      rs.doWrite (Page (Slug "a") "Alpha" [Link (Slug "b") Extends] "alpha body" ("m" :: Text))
      rs.doWrite (Page (Slug "a") "Alpha2" [] "new body" ("m2" :: Text))
      mpa <- rs.doRead (Slug "a")
      case mpa of
        Nothing -> ioError (userError "overwrite: page not found")
        Just pg -> do
          assertEq "overwrite title" "Alpha2" pg.title
          assertEq "overwrite body"  "new body" pg.body

  , Test "research: doIndex returns sorted slugs" $ withEphemeralDb $ \pool -> do
      migrateResearch pool
      let rs = researchStoreManifest C.str pool
      rs.doWrite (Page (Slug "a") "Alpha" [] "alpha body" ("m" :: Text))
      rs.doWrite (Page (Slug "b") "Beta"  [] "beta body"  ("n" :: Text))
      idx <- rs.doIndex
      assertEq "index" [Slug "a", Slug "b"] idx

  , Test "research: doSearch finds matching pages" $ withEphemeralDb $ \pool -> do
      migrateResearch pool
      let rs = researchStoreManifest C.str pool
      rs.doWrite (Page (Slug "a") "Alpha" [] "alpha body" ("m" :: Text))
      rs.doWrite (Page (Slug "b") "Beta"  [] "beta body"  ("n" :: Text))
      results <- rs.doSearch "beta"
      assertEq "search beta" [Slug "b"] results
  ]
