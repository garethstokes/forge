{-# LANGUAGE DataKinds #-}
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
  , executionStatus
  , fireDueTimers
  )
import Crucible.Worker
  ( WorkflowDef (..)
  , RunResult (..)
  , runOnce
  )
import Crucible.Workflow
  ( Workflow
  , WorkflowEnv (..)
  , WaitSpec (..)
  , Suspended (..)
  , now
  , durableSleep
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

identSleep :: JournalIdentity
identSleep = JournalIdentity "test-durable-sleep" "" "v1" "2026-06-15T00:00:00Z"

-- ---------------------------------------------------------------------------
-- Fixed WorkflowEnv for tests
-- ---------------------------------------------------------------------------

fixedEnv :: WorkflowEnv
fixedEnv = WorkflowEnv
  { weNow   = pure "2026-06-15T00:00:00Z"
  , weNewId = pure "id-1"
  }

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

-- | Build the full 3-step WorkflowDef used by the resume run.
-- The program is typed over the full Workflow effect stack but only uses
-- recordTo/replayFrom (Workflow ops are present in the row but unused here).
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
        res <- runOnce pool "worker-1" lease fixedEnv def (const (pure ()))
        case res of
          Just (Completed _) -> pure ()
          other              -> assertEq "runOnce claimed and ran the execution to success"
                                  "Just (Completed _)" (show other)

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

  , Test "worker: an errored run is NOT silently completed (stays 'running')" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid <- createExecution pool ident0

        -- A workflow whose program returns Left: replayFrom with Fail against an
        -- empty journal misses → throwError (MissError …) → runEff yields Left.
        -- The program is typed over the full Workflow effect stack; only
        -- replayFrom is used (Workflow ops are present in the row but unused).
        let failingDef = WorkflowDef
              { wdType    = "test-3-activity"
              , wdProgram = \() j _store -> do
                  _ <- replayFrom j Fail (mkKey "absent" []) decInt (pure (0 :: Int))
                  pure (0 :: Int)
              }
        let lease = "2099-01-01T00:00:00Z"
        res <- runOnce pool "worker-err" lease fixedEnv failingDef (const (pure ()))

        -- (a) runOnce ran but reported the error
        case res of
          Just (Errored _) -> pure ()
          other            -> assertEq "runOnce returned Just (Errored _)"
                               "Just (Errored _)" (show other)

        -- (b) the execution is NOT completed — it must remain 'running'
        st <- executionStatus pool eid
        assertEq "errored execution stays 'running' (not 'completed')"
          (Just ("running" :: Text)) st

  , Test "worker: DurableSleep suspend/resume — post-sleep activity runs exactly once after timer fires" $
      withEphemeralDb $ \pool -> do
        migrateJournal pool
        eid <- createExecution pool identSleep

        -- Activity counter: proves the post-sleep step ran live (exactly once,
        -- only after the timer fired).
        counter <- newIORef (0 :: Int)

        -- The workflow: journal the current time, durable-sleep 10s, run a
        -- counted activity, return the journaled clock value.
        let sleepDef = WorkflowDef
              { wdType    = "test-durable-sleep"
              , wdProgram = \() j store -> do
                  t <- now
                  durableSleep 10
                  _ <- recordTo store (mkKey "act" []) "act" encInt
                         (liftIO (modifyIORef' counter (+1)) >> pure (1 :: Int))
                  pure t
              }
        let lease = "2099-01-01T00:00:00Z"

        -- ----------------------------------------------------------------
        -- First runOnce: records 'now', hits durableSleep (no entry) → suspends.
        -- ----------------------------------------------------------------
        res1 <- runOnce pool "worker-sleep" lease fixedEnv sleepDef (const (pure ()))

        -- Assert: suspended with the expected wake-at (now + 10s)
        case res1 of
          Just (SuspendedRun (WaitTimer _ wakeAt)) ->
            assertEq "wake-at is now + 10 seconds" "2026-06-15T00:00:10Z" wakeAt
          other ->
            ioError (userError ("expected SuspendedRun but got: " <> show other))

        -- The execution is still running (not completed)
        st1 <- executionStatus pool eid
        assertEq "execution stays 'running' while waiting" (Just ("running" :: Text)) st1

        -- The execution is NOT in the ready list (it is waiting)
        ready1 <- listReadyExecutions pool
        assertEq "execution not ready while waiting" [] ready1

        -- The post-sleep activity did NOT run
        c1 <- readIORef counter
        assertEq "activity counter still 0 after suspend" 0 c1

        -- ----------------------------------------------------------------
        -- Fire the timer (well past the wake-at).
        -- ----------------------------------------------------------------
        fired <- fireDueTimers pool "2026-06-15T01:00:00Z"
        assertEq "fireDueTimers returned the suspended exec id" [eid] fired

        -- Now the execution is ready again
        ready2 <- listReadyExecutions pool
        assertEq "execution ready again after timer fires" [eid] ready2

        -- ----------------------------------------------------------------
        -- Second runOnce: replays 'now' (hit — same value), durableSleep
        -- (hit — timer entry present → continue), runs activity live, completes.
        -- ----------------------------------------------------------------
        res2 <- runOnce pool "worker-sleep" lease fixedEnv sleepDef (const (pure ()))

        -- Assert: completed with the journaled clock value from run 1
        case res2 of
          Just (Completed t) ->
            assertEq "journaled 'now' survived the suspend" "2026-06-15T00:00:00Z" t
          other ->
            ioError (userError ("expected Completed but got: " <> show other))

        -- Activity ran exactly once (live, during the second run)
        c2 <- readIORef counter
        assertEq "activity counter is 1 after resume (ran exactly once)" 1 c2

        -- Execution is completed
        st2 <- executionStatus pool eid
        assertEq "execution completed after resume" (Just ("completed" :: Text)) st2
  ]

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

main :: IO ()
main = runTests workerTests
