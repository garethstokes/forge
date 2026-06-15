{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

import Control.Exception (SomeException, try, evaluate)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.IORef (IORef, newIORef, readIORef, modifyIORef')
import Data.Text (Text)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

import Manifest (withEphemeralDb)

import Crucible.Journal
  ( JournalStore (..)
  , JournalIdentity (..)
  , Journal (..)
  , CassetteKey
  , JournalError
  , MissPolicy (..)
  , ReplayOutcome (..)
  , mkKey
  , recordTo
  , replayFrom
  )
import Crucible.Manifest.Journal
  ( migrateJournal
  , createExecution
  , journalStoreManifest
  , listReadyExecutions
  )
import Crucible.Worker
  ( WorkflowDef (..)
  , runOnce
  )

import Effectful (Eff, IOE, runEff, liftIO, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)

-- ---------------------------------------------------------------------------
-- Tiny harness (no hspec dep; mirrored from crucible-manifest/test/Conformance)
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
-- Codec helpers
-- ---------------------------------------------------------------------------

encInt :: Int -> ByteString
encInt = BC.pack . show

decInt :: ByteString -> Either Text Int
decInt b = case reads (BC.unpack b) of
  [(n, "")] -> Right n
  _         -> Left "bad int"

-- ---------------------------------------------------------------------------
-- Workflow building block
-- ---------------------------------------------------------------------------

-- | Run one activity step: replay from the pre-loaded journal on a hit
-- (Fallthrough — does NOT bump counter); on a miss, run live: bump counter,
-- recordTo the store, and return the value.
step
  :: (IOE :> es, Error JournalError :> es)
  => IORef Int      -- ^ side-effect counter (oracle for re-execution)
  -> JournalStore
  -> Journal
  -> Text           -- ^ step name / op key
  -> Int            -- ^ live value
  -> Eff es Int
step counter store j name val = do
  let k = mkKey name []
  out <- replayFrom j Fallthrough k decInt
           (recordTo store k name encInt
              (liftIO (modifyIORef' counter (+1)) >> pure val))
  pure $ case out of
    Replayed a   -> a
    Diverged _ a -> a

-- ---------------------------------------------------------------------------
-- Test workflow identity
-- ---------------------------------------------------------------------------

ident0 :: JournalIdentity
ident0 = JournalIdentity "test-3-activity" "" "v1" "2026-06-15T00:00:00Z"

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

-- | Build the full 3-step WorkflowDef used by the resume run.
fullWorkflowDef :: IORef Int -> WorkflowDef () Int
fullWorkflowDef counter = WorkflowDef
  { wdType    = "test-3-activity"
  , wdProgram = \() j store -> do
      v1 <- step counter store j "step1" 10
      v2 <- step counter store j "step2" 20
      v3 <- step counter store j "step3" 30
      pure (v1 + v2 + v3)
  }

workerTests :: [Test]
workerTests =
  [ Test "worker: crash/resume — only step3 re-runs live on resume" $
      withEphemeralDb $ \pool -> do

        -- 0. Migrate and create an execution
        migrateJournal pool
        eid <- createExecution pool ident0

        -- 1. PARTIAL RUN (simulate crash after step1 + step2)
        --    We run the store directly without calling completeExecution
        --    so the execution stays in 'ready' state for the worker to claim.
        counter <- newIORef (0 :: Int)
        do
          store <- journalStoreManifest pool eid
          j     <- jsLoad store
          _ <- runEff (runErrorNoCallStack @JournalError (do
                 _ <- step counter store j "step1" 10
                 _ <- step counter store j "step2" 20
                 -- crash here (no step3, no completeExecution)
                 pure ()))
          pure ()

        -- counter should be 2 (step1 + step2 ran live)
        cAfterPartial <- readIORef counter
        assertEq "counter after partial run" 2 cAfterPartial

        -- 2. Verify execution is still claimable (ready)
        readyBefore <- listReadyExecutions pool
        assertEq "execution is still ready after partial run" [eid] readyBefore

        -- 3. RESUME with a fresh worker
        let def = fullWorkflowDef counter
        let lease = "2099-01-01T00:00:00Z"
        meid <- runOnce pool "worker-1" lease def (const (pure ()))
        assertEq "runOnce claimed and ran the execution" (Just eid) meid

        -- 4. Assertions
        --    counter == 3 total: 2 from partial + 1 from resume (only step3 ran live)
        cFinal <- readIORef counter
        assertEq "counter after resume (only step3 ran live, not step1/2)" 3 cFinal

        -- execution should be completed (no longer in ready list)
        readyAfter <- listReadyExecutions pool
        assertEq "execution removed from ready after complete" [] readyAfter

        -- final journal has 3 entries (step1 + step2 from partial, step3 from resume)
        store <- journalStoreManifest pool eid
        j     <- jsLoad store
        let entries = length (jEntries j)
        assertEq "final journal has 3 entries" 3 entries
  ]

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

main :: IO ()
main = runTests workerTests
