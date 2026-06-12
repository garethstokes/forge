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
  , xorshiftInts
  , balanceExamples
  , balanceBy
  , judgePrompt
  , judgeOnce
  , VoteOutcome (..)
  , vote
  , Rating (..)
  , ratingCodec
  , ratePrompt
  , rateOnce
  , RateOutcome (..)
  , rate
  ) where

import Control.Applicative ((<|>))
import Data.Bits (shiftL, shiftR, xor)
import Data.List (partition, sort, sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import NeatInterpolation (text)

import Crucible.Codec (JSONCodec, object, field, str, bool, int)
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

-- | An infinite deterministic Int stream from the xorshift step. Exported
-- for the calibration bootstrap and for tests; not cryptographic.
xorshiftInts :: Int -> [Int]
xorshiftInts seed = drop 1 (iterate step (step (seed * 2654435761 + 1)))
  where
    step x = let a = x `xor` (x `shiftL` 13)
                 b = a `xor` (a `shiftR` 7)
             in b `xor` (b `shiftL` 17)

-- | Deterministic seeded shuffle (xorshift keys; no extra dependencies).
shuffleSeeded :: Int -> [a] -> [a]
shuffleSeeded seed xs = map snd (sortOn fst (zip (take (length xs) (xorshiftInts seed)) xs))

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

-- | The judge's structured ordinal rating. Same field order rationale as
-- 'Verdict': "why" first so the level is conditioned on the reasoning.
data Rating = Rating { why :: Text, level :: Int } deriving (Eq, Show)

ratingCodec :: JSONCodec Rating
ratingCodec = object (Rating <$> field "why"   (.why)   str
                             <*> field "level" (.level) int)

-- | The rating system message; k is the top level of the scale.
rateSystem :: Int -> Message
rateSystem k =
  let kTxt = T.pack (show k)
  in Message System [text|
  You are a strict grader.
  Reason through the rubric and the level anchors in "why" first, quoting the
  part of the output that determines the level, then give the level.
  Length and style are not criteria unless the rubric says so.
  Respond ONLY with JSON {"why": <string>, "level": <int between 1 and ${kTxt}>}.|]

-- | The rater's messages, pure and testable (mirrors 'judgePrompt').
-- Anchors render in ascending level order; sparse anchoring (ends only)
-- is expected. Assembled by concatenation: list blocks do not belong in
-- quasiquotes.
ratePrompt :: Int -> [(Int, Text)] -> Text -> Text -> [Message]
ratePrompt k anchors rubric graded =
  [ rateSystem k
  , Message User $ T.concat $
      ["Rubric: " <> rubric <> "\nLevels:\n"]
        ++ [ T.pack (show l) <> ": " <> d <> "\n" | (l, d) <- sortOn fst anchors ]
        ++ ["Output to grade: " <> graded]
  ]

-- | One rating call with validate-and-repair: a decode failure OR an
-- out-of-range level re-prompts once with the raw reply and the error,
-- then gives up with 'JudgeError'.
rateOnce :: (LLM :> es) => Int -> [(Int, Text)] -> Text -> Text -> Eff es (Either JudgeError Rating)
rateOnce k anchors rubric graded = do
  let msgs = ratePrompt k anchors rubric graded
  raw <- complete msgs
  case checked raw of
    Right v -> pure (Right v)
    Left m1 -> do
      raw2 <- complete
        ( msgs
            ++ [ Message Assistant raw
               , Message User [text|Your reply did not parse: ${m1}. Respond with valid JSON only.|]
               ]
        )
      case checked raw2 of
        Right v -> pure (Right v)
        Left m2 -> pure (Left (JudgeError m2))
  where
    checked raw = case decodeLLM ratingCodec raw of
      Left e -> Left e.message
      Right r
        | r.level < 1 || r.level > k ->
            Left ("level " <> T.pack (show r.level) <> " outside 1.." <> T.pack (show k))
        | otherwise -> Right r

-- | The result of an n-sample ordinal rating. 'why' is a SAMPLE from the
-- median level (the first one); 'dissent' keeps the first rationale from a
-- sample more than one level away from the median, when one was cast.
data RateOutcome
  = Rated { level :: Int, why :: Text, dissent :: Maybe Text, agree :: Int, others :: Int }
  | RateAllErrored Text
  deriving (Eq, Show)

-- | Sample the rater n times (sequentially, no early stop: the median
-- needs the full sample) and aggregate: median level with ties rounding
-- DOWN (the lower middle of an even split), 'agree' counts samples at the
-- median, 'others' the rest. Errored samples are excluded; all errored
-- yields 'RateAllErrored' with the last error.
rate :: (LLM :> es) => Int -> Int -> [(Int, Text)] -> Text -> Text -> Eff es RateOutcome
rate n k anchors rubric graded = do
  rs <- mapM (const (rateOnce k anchors rubric graded)) [1 .. max 1 n]
  let oks  = [r | Right r <- rs]
      errs = [m | Left (JudgeError m) <- rs]
  pure $ case oks of
    [] -> RateAllErrored (last ("" : errs))
    _  ->
      let levels = sort (map (.level) oks)
          med    = levels !! ((length levels - 1) `div` 2)
          agree  = length (filter (== med) levels)
          dis    = case [r.why | r <- oks, abs (r.level - med) > 1] of
                     (d : _) -> Just d
                     []      -> Nothing
          w      = head [r.why | r <- oks, r.level == med]
      in Rated med w dis agree (length levels - agree)
