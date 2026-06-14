{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeOperators #-}

-- | Grounding-gated writes for 'Crucible.Research'. 'writeGrounded' grounds a
-- page's body against a source trace with 'Crucible.Eval.Grounding' and commits
-- with 'writePage' only if the supported fraction meets the gate's threshold,
-- so a page lands only when its claims are backed by its sources. The gate is
-- opt-in; plain 'writePage' stays unverified. Lives apart from
-- 'Crucible.Research' so that module keeps no dependency on the eval machinery
-- (mirrors 'Crucible.Agents.Gate').
module Crucible.Research.Grounded
  ( NoClaimsPolicy (..)
  , GroundGate (..)
  , defaultGroundGate
  , writeGrounded
  , GroundingOutcome (..)
  ) where

import Data.Text (Text)

import Effectful

import Crucible.Eval.Grounding (GroundingOutcome (..), groundingOutcome)
import Crucible.LLM (LLM)
import Crucible.Research (Page (..), Research, writePage)

data NoClaimsPolicy = CommitNoClaims | RejectNoClaims
  deriving (Eq, Show)

data GroundGate = GroundGate
  { threshold  :: Double          -- ^ min fraction of claims supported to commit (1.0 = all)
  , votes      :: Int             -- ^ judge votes per claim (odd; <=1 means one judge call)
  , onNoClaims :: NoClaimsPolicy  -- ^ commit or reject when the body makes no claims
  }

-- | All claims supported, one vote per claim, commit when there are no claims.
defaultGroundGate :: GroundGate
defaultGroundGate = GroundGate 1.0 1 CommitNoClaims

-- | Ground a page's body against the evidence and commit via 'writePage' only if
-- it passes the gate. @Right ()@ means committed; @Left outcome@ means not
-- written (the 'GroundingOutcome' explains why: unsupported claims, a no-claims
-- rejection, or a verifier breakdown).
writeGrounded :: (Research meta :> es, LLM :> es)
              => GroundGate -> Text -> Page meta -> Eff es (Either GroundingOutcome ())
writeGrounded gate evidence page = do
  outcome <- groundingOutcome gate.votes evidence page.body
  case outcome of
    NoClaims -> case gate.onNoClaims of
      CommitNoClaims -> commit
      RejectNoClaims -> pure (Left NoClaims)
    DecomposeFailed _ -> pure (Left outcome)
    GroundingOutcome s t _
      | t == 0                                            -> commit
      | fromIntegral s / fromIntegral t >= gate.threshold -> commit
      | otherwise                                         -> pure (Left outcome)
  where
    commit = writePage page >> pure (Right ())
