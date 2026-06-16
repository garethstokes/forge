{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | Derived claim checking (the SFS recipe): decompose a rendered output
-- into atomic factual claims, then verify each claim against the provided
-- evidence with a binary judge vote. Authored checklist criteria catch
-- missing expected content; derived claims catch invented content.
--
-- No-closed-loop compliance: every verification call receives the original
-- evidence verbatim; the claim is the SUBJECT of the judgement, not a
-- derived substitute for the evidence. Decomposition quality is the
-- metric's own degree of freedom, and condition rankings are empirically
-- invariant to the decomposer choice.
--
-- This module deliberately does not depend on 'Crucible.Eval' (it returns
-- a 'GroundingOutcome', which Eval converts to a Score) or on
-- 'Crucible.Skill' (the decomposer is local plumbing with the same repair
-- semantics 'Crucible.Skill.call' would provide; reusing call would create
-- an import cycle).
module Crucible.Eval.Grounding
  ( GroundingOutcome (..)
  , groundingOutcome
  ) where

import Data.Text (Text)
import Effectful
import NeatInterpolation (text)

import Crucible.Codec (JSONCodec, list', schemaText, str)
import Crucible.Decode (DecodeError (..), decodeLLM)
import Crucible.Eval.Judge (JudgeOpts (..), VoteOutcome (..), defaultJudgeOpts, vote)
import Crucible.LLM (LLM, Message (..), Role (..), complete)

-- | The outcome of a grounding check, before Score conversion (which lives
-- in "Crucible.Eval", keeping this module free of the Score type).
data GroundingOutcome
  = GroundingOutcome
      { supported :: Int
      , total     :: Int
      , lines'    :: [Text]  -- ^ one [supported]\/[unsupported] line per claim, in order
      }
  | NoClaims                 -- ^ the decomposer found no factual claims
  | DecomposeFailed Text     -- ^ decompose reply unusable after one repair
  deriving (Eq, Show)

-- | Decompose the rendered output into atomic claims, verify each against
-- the evidence with @vote True n@ (early stopping, like checklist
-- criteria), and tally. A claim whose vote all-errors counts unsupported
-- with a tagged line.
groundingOutcome :: (LLM :> es)
                 => Int      -- ^ votes per claim (odd; <=1 means one judge call)
                 -> Text     -- ^ evidence the output must be grounded in
                 -> Text     -- ^ rendered output
                 -> Eff es GroundingOutcome
groundingOutcome n evidence rendered = do
  claims <- decompose rendered
  case claims of
    Left m   -> pure (DecomposeFailed m)
    Right [] -> pure NoClaims
    Right cs -> do
      rs <- mapM verify cs
      pure (GroundingOutcome
              (length [() | (_, p, _) <- rs, p])
              (length rs)
              (map line rs))
  where
    verify claim = do
      out <- vote True defaultJudgeOpts { votes = n } "the claim is supported by the evidence" [text|
        Evidence:
        ${evidence}

        Claim:
        ${claim}|]
      pure $ case out of
        Decided p w _ _ _ -> (claim, p, w)
        AllErrored m      -> (claim, False, "judge error: " <> m)
        AllAbstained m    -> (claim, False, "judge abstained: " <> m)
    line (c, p, w) =
      (if p then "[supported] " else "[unsupported] ") <> c <> ": " <> w

-- | One decompose call with the Skill-style schema contract and one
-- schema-restating repair on a malformed reply.
decompose :: (LLM :> es) => Text -> Eff es (Either Text [Text])
decompose rendered = do
  raw <- complete msgs
  case decodeLLM claimsCodec raw of
    Right cs -> pure (Right cs)
    Left e1 -> do
      let m = e1.message
      raw2 <- complete
        ( msgs
            ++ [ Message Assistant raw
               , Message User [text|
                   Your reply did not parse: ${m}.
                   Respond ONLY with valid JSON matching this schema:
                   ${schema}|]
               ]
        )
      case decodeLLM claimsCodec raw2 of
        Right cs -> pure (Right cs)
        Left e2  -> pure (Left e2.message)
  where
    claimsCodec :: JSONCodec [Text]
    claimsCodec = list' str
    schema = schemaText claimsCodec
    msgs =
      [ Message System [text|
          Respond ONLY with JSON matching this schema:
          ${schema}|]
      , Message User [text|
          List the atomic factual claims made by the text below as a JSON array of
          strings. Atomic means one verifiable fact per claim. Each claim must be
          self-contained (no pronouns that depend on other claims). Merge trivial
          variations; list at most 20 claims. Output only the JSON array.

          Text:
          ${rendered}|]
      ]
