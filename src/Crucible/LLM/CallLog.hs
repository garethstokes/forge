{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Per-call introspection for 'Provider' chains, used qualified:
-- @CallLog.new@, @CallLog.logging@, @CallLog.drain@. The 'logging'
-- decorator times and records every member attempt, failed ones
-- included, so a fallback walk reads back as zero or more Left entries
-- followed by the Right entry that answered (or all Left when the chain
-- exhausted). Decoration is explicit and 'Crucible.LLM.Fallback' is
-- untouched: undecorated chains pay nothing.
module Crucible.LLM.CallLog
  ( CallEntry (..)
  , CallLog
  , new
  , logging
  , drain
  ) where

import Control.Exception (SomeException, throwIO, try)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTimeNSec)

import Crucible.LLM.Provider (Provider (..))
import Crucible.Usage (Usage)

-- | One member attempt: who was asked, how long it took, and how it
-- ended (rendered error, or the call's usage).
data CallEntry = CallEntry
  { provider   :: Text
  , model      :: Text
  , durationMs :: Int
  , outcome    :: Either Text Usage
  }
  deriving (Eq, Show)

-- | An opaque accumulating handle.
newtype CallLog = CallLog (IORef [CallEntry])

new :: IO CallLog
new = CallLog <$> newIORef []

-- | Wrap a provider so every complete\/converse call is timed and
-- recorded. Success records the usage and returns the result; failure
-- records the rendered error and RETHROWS, so fallback semantics
-- (advance on synchronous failure, rethrow async) are untouched. Even
-- async exceptions are recorded before rethrowing.
logging :: CallLog -> Provider -> Provider
logging lg p = Provider
  { name = p.name
  , model = p.model
  , complete = \msgs -> timed lg p (p.complete msgs)
  , converse = \specs msgs -> timed lg p (p.converse specs msgs)
  }

-- | Time one call returning @(r, Usage)@, record the entry, propagate
-- the result or rethrow the failure.
timed :: CallLog -> Provider -> IO (r, Usage) -> IO (r, Usage)
timed (CallLog ref) p act = do
  t0 <- getMonotonicTimeNSec
  r <- try @SomeException act
  t1 <- getMonotonicTimeNSec
  let ms = fromIntegral ((t1 - t0) `div` 1000000)
      record o = atomicModifyIORef' ref (\es -> (CallEntry p.name p.model ms o : es, ()))
  case r of
    Right v@(_, u) -> record (Right u) >> pure v
    Left e         -> record (Left (T.pack (show e))) >> throwIO e

-- | Read the entries in chronological order and clear the handle, so
-- phases of a longer program can collect their own windows.
drain :: CallLog -> IO [CallEntry]
drain (CallLog ref) = reverse <$> atomicModifyIORef' ref (\es -> ([], es))
