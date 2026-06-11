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
  , JudgeExample (..)
  , JudgeOpts (..)
  , defaultJudgeOpts
  , balanceExamples
  , balanceBy
  , judgePrompt
  , judgeOnce
  , VoteOutcome (..)
  , vote
  ) where

import Control.Applicative ((<|>))
import Data.Bits (shiftL, shiftR, xor)
import Data.List (partition, sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
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

-- | A labelled output shown to the judge as a worked example for the
-- rubric under test. Verdicts always render; the critique renders only
-- when present.
data JudgeExample = JudgeExample
  { rendered :: Text
  , pass     :: Bool
  , why      :: Maybe Text
  }
  deriving (Eq, Show)

-- | Knobs for a judged evaluation. Future judge options (abstain policy,
-- panels) extend this record rather than adding function variants.
data JudgeOpts = JudgeOpts
  { votes    :: Int             -- ^ samples per judgement (odd; 1 = single call)
  , examples :: [JudgeExample]  -- ^ few-shot examples for Rubric judging
  }
  deriving (Eq, Show)

defaultJudgeOpts :: JudgeOpts
defaultJudgeOpts = JudgeOpts { votes = 1, examples = [] }

-- | Deterministic seeded shuffle (xorshift keys; no extra dependencies).
shuffleSeeded :: Int -> [a] -> [a]
shuffleSeeded seed xs = map snd (sortOn fst (zip keys xs))
  where
    keys = take (length xs) (drop 1 (iterate step (step (seed * 2654435761 + 1))))
    step x = let a = x `xor` (x `shiftL` 13)
                 b = a `xor` (a `shiftR` 7)
             in b `xor` (b `shiftL` 17)

-- | Pick n items, roughly balanced between the two classes of the
-- predicate, deterministically for a given seed: shuffle each class, then
-- alternate picks (predicate-true first); when one class runs out, fill
-- from the other. n over supply returns everything (balanced-first order);
-- n <= 0 returns [].
balanceBy :: (x -> Bool) -> Int -> Int -> [x] -> [x]
balanceBy p seed n xs = take (max 0 n) (interleave yes' no')
  where
    (yes, no) = partition p xs
    yes' = shuffleSeeded seed yes
    no'  = shuffleSeeded (seed + 1) no
    interleave (a : as) (b : bs) = a : b : interleave as bs
    interleave as []             = as
    interleave [] bs             = bs

-- | 'balanceBy' on the example's verdict: roughly equal pass and fail
-- examples, so the judge cannot infer a base-rate prior.
balanceExamples :: Int -> Int -> [JudgeExample] -> [JudgeExample]
balanceExamples = balanceBy (.pass)

-- | The judge's messages, pure and testable (mirrors 'Crucible.Skill.prompt').
-- With no examples the user message is byte-identical to the plain
-- two-line form. Assembled by concatenation: conditional blocks do not
-- belong in quasiquotes.
judgePrompt :: [JudgeExample] -> Text -> Text -> [Message]
judgePrompt exs rubric graded =
  [ judgeSystem
  , Message User $ T.concat $
      ["Rubric: " <> rubric <> "\n"]
        ++ exampleBlock
        ++ ["Output to grade: " <> graded]
  ]
  where
    exampleBlock
      | null exs = []
      | otherwise =
          "\nExamples of past verdicts for this rubric:\n\n"
            : map one exs
    one e =
      "Example output:\n" <> e.rendered
        <> "\nVerdict: " <> (if e.pass then "pass" else "fail")
        <> maybe "" ("\nWhy: " <>) e.why
        <> "\n\n"

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
judgeOnce :: (LLM :> es) => [JudgeExample] -> Text -> Text -> Eff es (Either JudgeError Verdict)
judgeOnce exs rubric graded = do
  let msgs = judgePrompt exs rubric graded
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

-- | The result of an n-sample majority vote. 'why' is a SAMPLE from the
-- winning side, not the reason the vote went that way (a rationale attached
-- to a vote outcome is not causal); 'dissent' keeps the first rationale from
-- the losing side, when one was cast.
data VoteOutcome
  = Decided { pass :: Bool, why :: Text, dissent :: Maybe Text, yes :: Int, no :: Int }
  | AllErrored Text
  deriving (Eq, Show)

-- | Sample the judge up to @n@ times (sequentially) and majority-vote.
-- With early stopping on, the loop ends as soon as one side holds a strict
-- majority of n (at n=3, two agreeing votes settle it). An errored sample
-- consumes an attempt without casting a vote; if every attempt errors, the
-- outcome is 'AllErrored'. A tie on an exhausted budget (possible only via
-- errors) resolves to fail. The rationale kept is the first vote on the
-- winning side; the first losing-side rationale is kept as 'dissent'.
-- Callers should use odd n; n <= 1 is a single sample.
vote :: (LLM :> es) => Bool -> JudgeOpts -> Text -> Text -> Eff es VoteOutcome
vote earlyStop opts rubric graded = go n' (0, 0) (Nothing, Nothing) ""
  where
    n'   = max 1 opts.votes
    need = n' `div` 2 + 1

    decideYes (firstYes, firstNo) y f = Decided True  (fromMaybe "" firstYes) firstNo  y f
    decideNo  (firstYes, firstNo) y f = Decided False (fromMaybe "" firstNo)  firstYes y f

    go :: (LLM :> es) => Int -> (Int, Int) -> (Maybe Text, Maybe Text) -> Text -> Eff es VoteOutcome
    go 0 (y, f) firsts lastErr
      | y == 0 && f == 0 = pure (AllErrored lastErr)
      | y > f            = pure (decideYes firsts y f)
      | otherwise        = pure (decideNo firsts y f)
    go k tally@(y, f) firsts@(firstYes, firstNo) lastErr
      | earlyStop && y >= need = pure (decideYes firsts y f)
      | earlyStop && f >= need = pure (decideNo firsts y f)
      | otherwise = do
          r <- judgeOnce opts.examples rubric graded
          case r of
            Left (JudgeError m) -> go (k - 1) tally firsts m
            Right v
              | v.pass    -> go (k - 1) (y + 1, f) (firstYes <|> Just v.why, firstNo) lastErr
              | otherwise -> go (k - 1) (y, f + 1) (firstYes, firstNo <|> Just v.why) lastErr
