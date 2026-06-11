{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | The LLM judge layer: the verdict shape (reason-then-verdict), the
-- hardened grader prompt, validate-and-repair on the judge's own JSON, and
-- the sequential majority-vote loop. 'Crucible.Eval' builds 'Score's on top.
module Crucible.Eval.Judge
  ( Verdict (..)
  , verdictCodec
  , JudgeError (..)
  , judgeOnce
  , VoteOutcome (..)
  , vote
  ) where

import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Effectful
import NeatInterpolation (text)

import Crucible.Codec (JSONCodec, object, field, str, bool)
import Crucible.Decode (DecodeError (..), decodeLLM)
import Crucible.LLM (LLM, Message (..), Role (..), complete)

-- | The judge's structured verdict. Field order is deliberate: the codec
-- encodes and the prompt requests "why" first, so the verdict token is
-- conditioned on the reasoning (the CoT-before-verdict effect). Decoding is
-- order-insensitive; legacy {"pass", "why"} JSON still parses.
data Verdict = Verdict { why :: Text, pass :: Bool } deriving (Eq, Show)

verdictCodec :: JSONCodec Verdict
verdictCodec = object (Verdict <$> field "why"  (.why)  str
                               <*> field "pass" (.pass) bool)

-- | The judge's own reply failed to parse, even after one repair attempt.
newtype JudgeError = JudgeError Text deriving (Eq, Show)

-- | The hardened grader system message, shared by every judge call.
judgeSystem :: Message
judgeSystem = Message System [text|
  You are a strict grader.
  Reason through each rubric requirement in "why" first, quoting the part of
  the output that satisfies or violates it, then give the verdict.
  Length and style are not criteria unless the rubric says so.
  If a requirement is not demonstrably met, fail it.
  Respond ONLY with JSON {"why": <string>, "pass": <bool>}.|]

-- | One judge call with validate-and-repair: on a verdict decode failure,
-- re-prompt once with the raw reply and the parse error (the same idiom as
-- 'Crucible.Skill.call'), then give up with 'JudgeError'.
judgeOnce :: (LLM :> es) => Text -> Text -> Eff es (Either JudgeError Verdict)
judgeOnce rubric graded = do
  let msgs =
        [ judgeSystem
        , Message User [text|Rubric: ${rubric}
Output to grade: ${graded}|]
        ]
  raw <- complete msgs
  case decodeLLM verdictCodec raw of
    Right v -> pure (Right v)
    Left e1 -> do
      let m = e1.message
      raw2 <- complete
        ( msgs
            ++ [ Message Assistant raw
               , Message User [text|Your reply did not parse: ${m}. Respond with valid JSON only.|]
               ]
        )
      case decodeLLM verdictCodec raw2 of
        Right v -> pure (Right v)
        Left e2 -> pure (Left (JudgeError e2.message))

-- | The result of an n-sample majority vote.
data VoteOutcome
  = Decided { pass :: Bool, why :: Text, yes :: Int, no :: Int }
  | AllErrored Text
  deriving (Eq, Show)

-- | Sample the judge up to @n@ times (sequentially) and majority-vote.
-- With early stopping on, the loop ends as soon as one side holds a strict
-- majority of n (at n=3, two agreeing votes settle it). An errored sample
-- consumes an attempt without casting a vote; if every attempt errors, the
-- outcome is 'AllErrored'. A tie on an exhausted budget (possible only via
-- errors) resolves to fail. The rationale kept is the first vote on the
-- winning side. Callers should use odd n; n <= 1 is a single sample.
vote :: (LLM :> es) => Bool -> Int -> Text -> Text -> Eff es VoteOutcome
vote earlyStop n rubric graded = go n' (0, 0) (Nothing, Nothing) ""
  where
    n'   = max 1 n
    need = n' `div` 2 + 1

    go :: (LLM :> es) => Int -> (Int, Int) -> (Maybe Text, Maybe Text) -> Text -> Eff es VoteOutcome
    go 0 (y, f) (firstYes, firstNo) lastErr
      | y == 0 && f == 0 = pure (AllErrored lastErr)
      | y > f            = pure (Decided True  (fromMaybe "" firstYes) y f)
      | otherwise        = pure (Decided False (fromMaybe "" firstNo)  y f)
    go k tally@(y, f) firsts@(firstYes, firstNo) lastErr
      | earlyStop && y >= need = pure (Decided True  (fromMaybe "" firstYes) y f)
      | earlyStop && f >= need = pure (Decided False (fromMaybe "" firstNo)  y f)
      | otherwise = do
          r <- judgeOnce rubric graded
          case r of
            Left (JudgeError m) -> go (k - 1) tally firsts m
            Right v
              | v.pass    -> go (k - 1) (y + 1, f) (firstYes <|> Just v.why, firstNo) lastErr
              | otherwise -> go (k - 1) (y, f + 1) (firstYes, firstNo <|> Just v.why) lastErr
