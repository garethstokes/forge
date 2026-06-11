{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | Typed LLM skills: declare a 'Skill' once (input type, output type, and a
-- task instruction) and 'call' it for a typed, structured result. The output
-- schema is injected into the prompt and the reply is tolerantly decoded against
-- the output 'Codec'. 'call' needs only @LLM :> es@, so it runs under the
-- scripted, cassette, and live Anthropic interpreters unchanged.
module Crucible.Skill
  ( Skill (..)
  , skill
  , withRetries
  , withTests
  , withExamples
  , examplesFromTests
  , prompt
  , call
  , testSkill
  ) where

import Data.Text (Text)
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text.Encoding as TE
import qualified Data.Aeson as A
import NeatInterpolation (text)

import Effectful
import Autodocodec (toJSONVia)

import Crucible.Codec (JSONCodec, schemaText)
import Crucible.Eval (Case (..), Expectation (..), Report, runEval)
import Crucible.LLM (LLM, Message (..), Role (..), complete)
import Crucible.Decode (decodeLLM, DecodeError (..))

-- | A declared LLM skill: a task instruction plus input/output codecs.
data Skill i o = Skill
  { name        :: Text        -- ^ for introspection / evals
  , instruction :: i -> Text   -- ^ the task (may reference input fields)
  , input       :: JSONCodec i -- ^ used to render the input value into the prompt
  , output      :: JSONCodec o -- ^ schema injection + tolerant decode
  , retries     :: Int         -- ^ decode-failure retries
  , tests       :: [Case i o]  -- ^ attached test cases; run with 'testSkill'
  , examples    :: [(i, o)]    -- ^ few-shot exchanges rendered into the prompt
  }

-- | Construct a 'Skill'; @retries@ defaults to 2, @tests@ and @examples@ to none.
skill :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> Skill i o
skill n inC outC instr =
  Skill { name = n, instruction = instr, input = inC, output = outC
        , retries = 2, tests = [], examples = [] }

-- | Override the decode-failure retry budget.
withRetries :: Int -> Skill i o -> Skill i o
withRetries n fn = fn { retries = n }

-- | Attach test cases to a skill, declared next to the prompt they exercise.
-- Run them with 'testSkill'.
withTests :: [Case i o] -> Skill i o -> Skill i o
withTests cs fn = fn { tests = cs }

-- | Replace the skill's few-shot examples. Each pair renders as a real
-- User/Assistant exchange before the live one (see 'prompt'); the Assistant
-- turn is the output encoded via the output codec, so examples demonstrate
-- the exact reply contract and cannot drift from the schema. Three to five
-- examples capture most of the benefit; the instruction text repeats once
-- per pair, so each example costs prompt tokens.
withExamples :: [(i, o)] -> Skill i o -> Skill i o
withExamples exs fn = fn { examples = exs }

-- | Move the first @n@ 'Exactly' test cases into the examples (appending to
-- any existing examples, preserving order). Moving rather than copying means
-- a case is either taught or tested, never both, so 'testSkill' scores stay
-- meaningful with no special handling. Non-'Exactly' cases are skipped and
-- remain tests; fewer than @n@ available moves what exists; @n <= 0@ moves
-- nothing.
examplesFromTests :: Int -> Skill i o -> Skill i o
examplesFromTests n fn = fn { examples = fn.examples ++ moved, tests = kept }
  where
    (moved, kept) = go (max 0 n) fn.tests
    go 0 cs = ([], cs)
    go _ [] = ([], [])
    go k (Case i' _ (Exactly o') : cs) =
      let (ms, ks) = go (k - 1) cs in ((i', o') : ms, ks)
    go k (c : cs) =
      let (ms, ks) = go k cs in (ms, c : ks)

-- | Encode a value to JSON text via its codec.
jsonText :: A.Value -> Text
jsonText = TE.decodeUtf8 . LB.toStrict . A.encode

-- | The seed messages 'call' sends for a given input: a System message
-- carrying the output-schema contract, one User/Assistant pair per attached
-- example (the User turn is the instruction applied to the example input;
-- the Assistant turn is the codec-encoded example output, a perfect reply),
-- and finally the live User message. With no examples this is exactly the
-- two-message prompt it has always been. Exposed for introspection/debugging
-- and tested directly.
prompt :: Skill i o -> i -> [Message]
prompt sk inp =
  systemMsg : concatMap pair sk.examples ++ [userMsg inp]
  where
    schema = schemaText sk.output
    systemMsg = Message System [text|
      Respond ONLY with JSON matching this schema:
      ${schema}|]
    userMsg i' =
      let task     = sk.instruction i'
          rendered = jsonText (toJSONVia sk.input i')
      in Message User [text|
      ${task}

      Input:
      ${rendered}|]
    pair (ei, eo) = [userMsg ei, Message Assistant (jsonText (toJSONVia sk.output eo))]

-- | Run a typed skill: build the prompt, call the model, and decode the reply
-- against the output codec. On a decode failure, re-ask with the parse error fed
-- back (up to 'retries' times); on exhaustion return 'Left'.
call :: (LLM :> es) => Skill i o -> i -> Eff es (Either DecodeError o)
call fn@Skill{output = outC, retries = rets} inp = loop rets (prompt fn inp)
  where
    loop n msgs = do
      raw <- complete msgs
      case decodeLLM outC raw of
        Right o -> pure (Right o)
        Left err
          | n <= 0    -> pure (Left err)
          | otherwise ->
              let e = err.message
              in loop (n - 1)
                ( msgs
                    ++ [ Message Assistant raw
                       , Message User [text|Your reply did not parse: ${e}. Respond with valid JSON only.|]
                       ]
                )

-- | Run a skill's attached 'tests' through the eval pipeline and aggregate
-- a 'Report'. Each case 'call's the skill with its input and scores the result
-- against its 'Expectation'; a decode failure scores 0. The render function is
-- used when a 'Rubric' case hands the output to the LLM judge. Like 'call',
-- needs only @LLM :> es@, so the same cases run scripted, replayed, or live.
testSkill :: (Eq o, LLM :> es) => (o -> Text) -> Skill i o -> Eff es (Report i (Either DecodeError o))
testSkill render sk =
  runEval render' (call sk) (map liftCase sk.tests)
  where
    render' = either (\e -> "decode error: " <> e.message) render
    liftCase (Case i n ex) = Case i n (liftExp ex)
    liftExp :: Eq o => Expectation o -> Expectation (Either DecodeError o)
    liftExp (Exactly e)   = Predicate (either (const False) (== e))
    liftExp (Predicate p) = Predicate (either (const False) p)
    liftExp (Rubric r)    = Rubric r
