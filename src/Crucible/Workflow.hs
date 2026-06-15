{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Phase 2a of crucible's durable execution substrate: the Workflow effect.
--
-- 'Workflow' is a GADT effect (effectful Dynamic dispatch) that provides
-- journaled non-determinism primitives:
--
--   * 'Now'          — current time as ISO-8601 text, journaled so replays
--                      see the original value even after a suspend/resume.
--   * 'NewId'        — a fresh unique id, journaled for the same reason.
--   * 'DurableSleep' — a durable timer: first encounter suspends the
--                      execution (throws 'Suspended'); on replay after the
--                      timer fires, it returns () and execution continues.
--
-- The interpreter 'runWorkflow' threads a per-run call-index ('State Int'),
-- reads/writes via a 'JournalStore' (Phase 1), and signals suspension via
-- 'Error Suspended'. A live 'IORef Journal' (seeded from the loaded snapshot
-- and updated on each append) ensures within-run lookups also see values
-- recorded earlier in the same pass.
--
-- NO OverloadedRecordDot — Crucible.Journal uses plain field accessors only.
module Crucible.Workflow
  ( -- * Effect
    Workflow (..)
  , now
  , newId
  , durableSleep
  , awaitSignal
    -- * Interpreter
  , WorkflowEnv (..)
  , WaitSpec (..)
  , Suspended (..)
  , runWorkflow
  , realWorkflowEnv
    -- * Combinator
  , retryN
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.IORef (IORef, newIORef, readIORef, modifyIORef', atomicModifyIORef')
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time
  ( UTCTime
  , getCurrentTime
  , addUTCTime
  , parseTimeM
  , formatTime
  , defaultTimeLocale
  )

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret, send)
import Effectful.State.Static.Local (State, evalState, get, put)
import Effectful.Error.Static (Error, throwError)

import Crucible.Journal
  ( JournalStore (..)
  , Journal
  , CassetteKey (..)
  , Entry (..)
  , lookupEntry
  , insertEntry
  , mkKey
  , JournalError
  )

-- ---------------------------------------------------------------------------
-- Effect

data Workflow :: Effect where
  Now          :: Workflow m Text
  NewId        :: Workflow m Text
  DurableSleep :: Int -> Workflow m ()
  AwaitSignal  :: Text -> Workflow m ByteString

type instance DispatchOf Workflow = Dynamic

-- | Record or replay the current time as ISO-8601 text.
now :: (Workflow :> es) => Eff es Text
now = send Now

-- | Record or replay a fresh unique id.
newId :: (Workflow :> es) => Eff es Text
newId = send NewId

-- | Durable timer: suspends on first encounter; continues on replay after
-- the timer entry has been appended by the timer driver.
durableSleep :: (Workflow :> es) => Int -> Eff es ()
durableSleep = send . DurableSleep

-- | Await an external signal by name.  Suspends on first encounter; returns
-- the delivered payload (raw 'ByteString') on replay after the signal is
-- delivered.
awaitSignal :: (Workflow :> es) => Text -> Eff es ByteString
awaitSignal = send . AwaitSignal

-- ---------------------------------------------------------------------------
-- Supporting types

-- | What an execution is waiting on.
-- Carries the cassette key and the wait-specific payload.
data WaitSpec
  = WaitTimer  CassetteKey Text   -- ^ call-index key, wake-at ISO-8601
  | WaitSignal CassetteKey Text   -- ^ call-index key, signal name
  deriving (Eq, Show)

-- | Thrown (via 'Error') when a workflow hits a 'DurableSleep' with no
-- journal entry — the run is suspended until the timer fires.
newtype Suspended = Suspended WaitSpec
  deriving (Eq, Show)

-- | Injectable non-determinism sources.  Real IO in production; fixed
-- values or IORef-counters in tests.
data WorkflowEnv = WorkflowEnv
  { weNow   :: IO Text   -- ^ current time as ISO-8601
  , weNewId :: IO Text   -- ^ a fresh unique id
  }

-- ---------------------------------------------------------------------------
-- Interpreter

-- | Run a 'Workflow' computation with journaled determinism.
--
-- 'State Int' (the call index) is encapsulated inside the handler via
-- 'evalState'; it does not appear in the action's effect row.
--
-- The caller must discharge 'Error Suspended', 'Error JournalError', and
-- 'IOE' at an outer layer (see 'runEff', 'runErrorNoCallStack').
runWorkflow
  :: (IOE :> es, Error Suspended :> es, Error JournalError :> es)
  => WorkflowEnv
  -> JournalStore
  -> Journal
  -> Eff (Workflow : es) a
  -> Eff es a
runWorkflow env store j0 act = do
  liveRef <- liftIO (newIORef j0)
  reinterpret (evalState (0 :: Int)) (\_ -> \case
    Now   -> journaled liveRef "now"   (weNow env)
    NewId -> journaled liveRef "newId" (weNewId env)
    DurableSleep secs -> do
      k    <- nextKey "sleep"
      live <- liftIO (readIORef liveRef)
      case lookupEntry k live of
        Just _  -> pure ()   -- timer fired and entry appended; continue
        Nothing -> do
          t  <- liftIO (weNow env)
          let wa = addSeconds secs t
          throwError (Suspended (WaitTimer k wa))
    AwaitSignal name -> do
      k    <- nextKey "signal"
      live <- liftIO (readIORef liveRef)
      case lookupEntry k live of
        Just e  -> pure (eResult e)   -- delivered payload (raw ByteString)
        Nothing -> throwError (Suspended (WaitSignal k name))
    ) act
  where
    -- Increment the call index and return the key for this op call.
    nextKey :: (State Int :> handlerEs) => Text -> Eff handlerEs CassetteKey
    nextKey op = do
      n <- get
      put (n + 1 :: Int)
      pure (mkKey op [BC.pack (show n)])

    -- Record-or-replay a Text-valued primitive.
    journaled
      :: (IOE :> handlerEs, Error JournalError :> handlerEs, State Int :> handlerEs)
      => IORef Journal -> Text -> IO Text -> Eff handlerEs Text
    journaled ref op src = do
      k    <- nextKey op
      live <- liftIO (readIORef ref)
      case lookupEntry k live of
        Just e  -> pure (TE.decodeUtf8 (eResult e))
        Nothing -> do
          v <- liftIO src
          let bs = TE.encodeUtf8 v
          liftIO (jsAppend store k op bs)
          liftIO (modifyIORef' ref (insertEntry k bs))
          pure v

-- ---------------------------------------------------------------------------
-- addSeconds

-- | Add @secs@ seconds to an ISO-8601 timestamp (format: @%Y-%m-%dT%H:%M:%SZ@).
-- Returns the original text unchanged on a parse failure (total; documents).
addSeconds :: Int -> Text -> Text
addSeconds secs t =
  case parseTimeM True defaultTimeLocale fmt (T.unpack t) :: Maybe UTCTime of
    Nothing -> t   -- parse failure: return unchanged
    Just ut ->
      let ut' = addUTCTime (fromIntegral secs) ut
      in T.pack (formatTime defaultTimeLocale fmt ut')
  where
    fmt = "%Y-%m-%dT%H:%M:%SZ"

-- ---------------------------------------------------------------------------
-- realWorkflowEnv

-- | A production 'WorkflowEnv' backed by real IO.
--
-- 'weNow'   — 'getCurrentTime' formatted as @%Y-%m-%dT%H:%M:%SZ@ (the same
--             format 'addSeconds' parses, so durable-sleep wake-at arithmetic
--             round-trips correctly).
-- 'weNewId' — a unique id: timestamp with picosecond precision plus an
--             atomically-incremented counter, ensuring uniqueness even within
--             the same picosecond.
realWorkflowEnv :: IO WorkflowEnv
realWorkflowEnv = do
  ctr <- newIORef (0 :: Int)
  pure WorkflowEnv
    { weNow   = fmt <$> getCurrentTime
    , weNewId = do
        n <- atomicModifyIORef' ctr (\x -> (x + 1, x))
        t <- getCurrentTime
        pure (fmtId t <> "-" <> T.pack (show n))
    }
  where
    fmt   = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
    fmtId = T.pack . formatTime defaultTimeLocale "%Y%m%d%H%M%S%q"

-- ---------------------------------------------------------------------------
-- retryN

-- | Run an action up to @n@ times (clamped to at least 1), returning the
-- first 'Right' result or the last 'Left' if all attempts fail.
--
-- Note: when used with journaled activities, a successful run is recorded in
-- the journal, so on replay the inner action hits its recorded result
-- immediately — retryN only re-runs live on the first pass.
retryN :: Monad m => Int -> m (Either e a) -> m (Either e a)
retryN n act = go (max 1 n)
  where
    go 1 = act
    go k = act >>= either (const (go (k - 1))) (pure . Right)
