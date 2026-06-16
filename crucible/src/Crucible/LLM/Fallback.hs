{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Multi-provider resilience at the runEff edge, used qualified:
-- @Fallback.run@, @Fallback.roundRobinChat@, and friends. Fallback happens
-- PER CALL: each 'Complete' or 'Converse' tries the members in order
-- (round-robin rotates the starting member per call), advancing on any
-- synchronous member failure after that member's own internal retries give up.
-- A misconfigured member falls through to a healthy one. When every member
-- fails, 'FallbackExhausted' carries each member's rendered error in the
-- order tried. Streaming stays single-provider; cassettes record at the
-- provider level, not the chain level.
module Crucible.LLM.Fallback
  ( FallbackError (..)
  , run
  , usage
  , runChat
  , usageChat
  , roundRobin
  , roundRobinUsage
  , roundRobinChat
  , roundRobinUsageChat
  ) where

import Control.Exception (Exception, SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret)
import Effectful.State.Static.Local (modify, runState)

import Crucible.Chat (Chat (..))
import Crucible.LLM (LLM (..))
import Crucible.LLM.Provider (Provider (..))
import Crucible.Usage (Usage)

-- | Every member failed: (provider name, rendered error), in tried order.
newtype FallbackError = FallbackExhausted [(Text, Text)]
  deriving (Eq, Show)

instance Exception FallbackError

-- | Try members starting at index s (wrapping), advancing on any synchronous failure.
attempt :: Int -> [Provider] -> (Provider -> IO r) -> IO r
attempt s ps act
  | null ps   = throwIO (FallbackExhausted [])
  | otherwise = go (rotate s ps) []
  where
    rotate i xs = let k = i `mod` length xs in drop k xs ++ take k xs
    go [] errs = throwIO (FallbackExhausted (reverse errs))
    go (p : rest) errs = do
      r <- try @SomeException (act p)
      case r of
        Right v -> pure v
        Left e
          | Just (SomeAsyncException _) <- fromException e -> throwIO e
          | otherwise -> go rest ((p.name, T.pack (show e)) : errs)

-- | A counter that yields 0, 1, 2, ... across calls.
nextIndex :: IORef Int -> IO Int
nextIndex ref = atomicModifyIORef' ref (\i -> (i + 1, i))

-- | Interpret 'LLM' over a fallback chain. Use as @Fallback.run@.
run :: (IOE :> es) => [Provider] -> Eff (LLM : es) a -> Eff es a
run ps = interpret $ \_ -> \case
  Complete msgs -> liftIO (fst <$> attempt 0 ps (\p -> p.complete msgs))

-- | Like 'run', also returning accumulated 'Usage' from the answering members.
usage :: (IOE :> es) => [Provider] -> Eff (LLM : es) a -> Eff es (a, Usage)
usage ps = reinterpret (runState mempty) $ \_ -> \case
  Complete msgs -> do
    (t, u) <- liftIO (attempt 0 ps (\p -> p.complete msgs))
    modify (<> u)
    pure t

-- | Interpret 'Chat' over a fallback chain. Use as @Fallback.runChat@.
runChat :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es a
runChat ps = interpret $ \_ -> \case
  Converse specs msgs -> liftIO (fst <$> attempt 0 ps (\p -> p.converse specs msgs))

-- | Like 'runChat', also returning accumulated 'Usage'.
usageChat :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es (a, Usage)
usageChat ps = reinterpret (runState mempty) $ \_ -> \case
  Converse specs msgs -> do
    (t, u) <- liftIO (attempt 0 ps (\p -> p.converse specs msgs))
    modify (<> u)
    pure t

-- | Like 'run', but each call starts one member further along the list. Use as @Fallback.roundRobin@.
roundRobin :: (IOE :> es) => [Provider] -> Eff (LLM : es) a -> Eff es a
roundRobin ps action = do
  ref <- liftIO (newIORef 0)
  interpret (\_ -> \case
    Complete msgs -> liftIO $ do
      s <- nextIndex ref
      fst <$> attempt s ps (\p -> p.complete msgs)) action

-- | Like 'roundRobin', also returning accumulated 'Usage'.
roundRobinUsage :: (IOE :> es) => [Provider] -> Eff (LLM : es) a -> Eff es (a, Usage)
roundRobinUsage ps action = do
  ref <- liftIO (newIORef 0)
  reinterpret (runState mempty) (\_ -> \case
    Complete msgs -> do
      s <- liftIO (nextIndex ref)
      (t, u) <- liftIO (attempt s ps (\p -> p.complete msgs))
      modify (<> u)
      pure t) action

-- | Like 'runChat', but each call starts one member further along the list.
roundRobinChat :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es a
roundRobinChat ps action = do
  ref <- liftIO (newIORef 0)
  interpret (\_ -> \case
    Converse specs msgs -> liftIO $ do
      s <- nextIndex ref
      fst <$> attempt s ps (\p -> p.converse specs msgs)) action

-- | Like 'roundRobinChat', also returning accumulated 'Usage'.
roundRobinUsageChat :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es (a, Usage)
roundRobinUsageChat ps action = do
  ref <- liftIO (newIORef 0)
  reinterpret (runState mempty) (\_ -> \case
    Converse specs msgs -> do
      s <- liftIO (nextIndex ref)
      (t, u) <- liftIO (attempt s ps (\p -> p.converse specs msgs))
      modify (<> u)
      pure t) action
