{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Conformance
  ( Test (..)
  , runTests
  , assertEq
  , WithStore
  , memoryConformance
  , ledgerConformance
  , researchConformance
  ) where

import Control.Exception (SomeException, try, evaluate)
import Data.Text (Text)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

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
import Crucible.Ledger
  ( LedgerStore (..)
  , WorkId (..)
  , WorkItem
  , WorkItemT (..)
  )
import Crucible.Research
  ( Link (..)
  , LinkType (..)
  , Page (..)
  , ResearchStore (..)
  , Slug (..)
  )

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

-- ---------------------------------------------------------------------------
-- WithStore
-- ---------------------------------------------------------------------------

type WithStore s = forall a. (s -> IO a) -> IO a

-- ---------------------------------------------------------------------------
-- Memory conformance
-- ---------------------------------------------------------------------------

memoryConformance :: String -> WithStore MemoryStore -> [Test]
memoryConformance be withS =
  [ Test (lbl "recall is most-recent-first") $ withS $ \s -> do
      mapM_ s.doRemember [d "a", d "b", d "c"]
      r <- s.doRecall (Query "" [] 10)
      assertEq "content order" (["c", "b", "a"] :: [Text]) (map ((.content) :: MemoryItem -> Text) r)

  , Test (lbl "forget removes from recall") $ withS $ \s -> do
      i <- s.doRemember (d "a")
      _ <- s.doRemember (d "b")
      s.doForget i
      r <- s.doRecall (Query "" [] 10)
      assertEq "content" (["b"] :: [Text]) (map ((.content) :: MemoryItem -> Text) r)

  , Test (lbl "budget caps recall") $ withS $ \s -> do
      mapM_ s.doRemember [d "a", d "b", d "c"]
      r <- s.doRecall (Query "" [] 1)
      assertEq "budget" (["c"] :: [Text]) (map ((.content) :: MemoryItem -> Text) r)

  , Test (lbl "tag filter") $ withS $ \s -> do
      _ <- s.doRemember (MemoryDraft Semantic "x" ["red"]  Curated)
      _ <- s.doRemember (MemoryDraft Semantic "y" ["blue"] Curated)
      r <- s.doRecall (Query "" ["red"] 10)
      assertEq "tagged" (["x"] :: [Text]) (map ((.content) :: MemoryItem -> Text) r)

  , Test (lbl "empty recall") $ withS $ \s -> do
      r <- s.doRecall (Query "" [] 10)
      assertEq "empty" ([] :: [Text]) (map ((.content) :: MemoryItem -> Text) r)
  ]
  where
    lbl m = "memory[" <> be <> "]: " <> m
    d c   = MemoryDraft Semantic c ["t"] Curated

-- ---------------------------------------------------------------------------
-- Ledger conformance
-- ---------------------------------------------------------------------------

ledgerConformance :: String -> WithStore LedgerStore -> [Test]
ledgerConformance be withS =
  [ -- NOTE: through the LedgerStore API, Ready rows are insert-only (claim/complete
    -- move a row OUT of Ready), so a black-box test cannot force Postgres to return
    -- Ready rows out of insertion order; the manifest backend's sortOn (.wid) in
    -- doListReady is therefore DEFENSIVE (Postgres does not promise scan order).
    -- This check still catches a wrong sort (descending / wrong column) and pins the
    -- record-order contract across all backends.
    Test (lbl "listReady is record order (mid-removal preserves order)") $ withS $ \s -> do
      _  <- s.doRecord "A"
      ib <- s.doRecord "B"
      _  <- s.doRecord "C"
      _  <- s.doRecord "D"
      s.doComplete ib
      rs <- s.doListReady
      assertEq "payloads" (["A", "C", "D"] :: [Text]) (map ((.payload) :: WorkItem -> Text) rs)

  , Test (lbl "claim drops from listReady; CAS rejects re-claim") $ withS $ \s -> do
      i  <- s.doRecord "A"
      _  <- s.doRecord "B"
      ok1 <- s.doClaim i "w"
      ok2 <- s.doClaim i "w2"
      rs  <- s.doListReady
      assertEq "first claim"           True  ok1
      assertEq "second claim (CAS)"    False ok2
      assertEq "remaining" (["B"] :: [Text]) (map ((.payload) :: WorkItem -> Text) rs)

  , Test (lbl "claim unknown id fails") $ withS $ \s -> do
      ok <- s.doClaim (WorkId 9999) "w"
      assertEq "unknown" False ok

  , Test (lbl "complete drops from listReady") $ withS $ \s -> do
      i <- s.doRecord "A"
      _ <- s.doRecord "B"
      s.doComplete i
      rs <- s.doListReady
      assertEq "remaining" (["B"] :: [Text]) (map ((.payload) :: WorkItem -> Text) rs)
  ]
  where
    lbl m = "ledger[" <> be <> "]: " <> m

-- ---------------------------------------------------------------------------
-- Research conformance
-- ---------------------------------------------------------------------------

researchConformance :: String -> WithStore (ResearchStore Text) -> [Test]
researchConformance be withS =
  [ Test (lbl "read round-trips a written page") $ withS $ \s -> do
      let p = Page (Slug "a") "Alpha" [Link (Slug "b") Extends] "alpha body" ("m" :: Text)
      s.doWrite p
      mp <- s.doRead (Slug "a")
      assertEq "page" (Just p) mp

  , Test (lbl "read absent is Nothing") $ withS $ \s -> do
      mp <- s.doRead (Slug "missing")
      assertEq "absent" (Nothing :: Maybe (Page Text)) mp

  , Test (lbl "overwrite replaces") $ withS $ \s -> do
      s.doWrite (Page (Slug "a") "Alpha" [Link (Slug "b") Extends] "old" ("m" :: Text))
      let p2 = Page (Slug "a") "Alpha2" [] "new" ("m2" :: Text)
      s.doWrite p2
      mp <- s.doRead (Slug "a")
      assertEq "overwritten" (Just p2) mp

  , Test (lbl "index lists sorted slugs") $ withS $ \s -> do
      s.doWrite (Page (Slug "b") "B" [] "x" ("" :: Text))
      s.doWrite (Page (Slug "a") "A" [] "y" ("" :: Text))
      ix <- s.doIndex
      assertEq "index" [Slug "a", Slug "b"] ix

  , Test (lbl "search greps title/body") $ withS $ \s -> do
      s.doWrite (Page (Slug "a") "Apple" [] "red fruit" ("" :: Text))
      s.doWrite (Page (Slug "b") "Boat"  [] "floats"    ("" :: Text))
      hits <- s.doSearch "fruit"
      assertEq "search" [Slug "a"] hits
  ]
  where
    lbl m = "research[" <> be <> "]: " <> m
