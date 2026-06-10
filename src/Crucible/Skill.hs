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
  }

-- | Construct a 'Skill'; @retries@ defaults to 2, @tests@ to none.
skill :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> Skill i o
skill n inC outC instr =
  Skill { name = n, instruction = instr, input = inC, output = outC
        , retries = 2, tests = [] }

-- | Override the decode-failure retry budget.
withRetries :: Int -> Skill i o -> Skill i o
withRetries n fn = fn { retries = n }

-- | Attach test cases to a skill, declared next to the prompt they exercise.
-- Run them with 'testSkill'.
withTests :: [Case i o] -> Skill i o -> Skill i o
withTests cs fn = fn { tests = cs }

-- | Encode a value to JSON text via its codec.
jsonText :: A.Value -> Text
jsonText = TE.decodeUtf8 . LB.toStrict . A.encode

-- | The seed messages 'call' sends for a given input: a System message carrying
-- the output-schema contract, and a User message with the instruction plus the
-- rendered input. Exposed for introspection/debugging and tested directly.
prompt :: Skill i o -> i -> [Message]
prompt Skill{output = outC, instruction = instr, input = inC} inp =
  [ Message System [text|
      Respond ONLY with JSON matching this schema:
      ${schema}|]
  , Message User [text|
      ${task}

      Input:
      ${rendered}|]
  ]
  where
    schema   = schemaText outC
    task     = instr inp
    rendered = jsonText (toJSONVia inC inp)

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
