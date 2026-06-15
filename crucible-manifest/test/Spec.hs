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
  ]
