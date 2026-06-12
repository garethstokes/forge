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
  , Instruction (..)
  , skill
  , skillWith
  , withPreamble
  , withConstraints
  , withRetries
  , withTests
  , withExamples
  , examplesFromTests
  , withReasoning
  , prompt
  , call
  , testSkill
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text.Encoding as TE
import qualified Data.Aeson as A
import NeatInterpolation (text)

import Effectful
import Autodocodec (dimapCodec, toJSONVia)

import Crucible.Codec (JSONCodec, field, object, schemaText, str)
import Crucible.Embed (Embed)
import Crucible.Eval (Case (..), Expectation (..), Report, runEval)
import Crucible.LLM (LLM, Message (..), Role (..), complete)
import Crucible.Decode (decodeLLM, DecodeError (..))

-- | A skill's instruction, structured so tooling can revise the prompt
-- around a fixed task. 'preamble' renders before the task; 'constraints'
-- renders after the input (instructions near the end are followed most
-- reliably). Both default to empty and are the slots 'Crucible.Skill.Improve.improveSkill'
-- mutates; 'task' is the core instruction and is never machine-edited.
data Instruction i = Instruction
  { preamble    :: Text
  , task        :: i -> Text
  , constraints :: Text
  }

-- | A declared LLM skill: a task instruction plus input/output codecs.
data Skill i o = Skill
  { name        :: Text          -- ^ for introspection / evals
  , instruction :: Instruction i -- ^ preamble + task + constraints
  , input       :: JSONCodec i   -- ^ used to render the input value into the prompt
  , output      :: JSONCodec o   -- ^ schema injection + tolerant decode
  , retries     :: Int           -- ^ decode-failure retries
  , tests       :: [Case i o]    -- ^ attached test cases; run with 'testSkill'
  , examples    :: [(i, o)]      -- ^ few-shot exchanges rendered into the prompt
  }

-- | Construct a 'Skill' from a bare task function (empty preamble and
-- constraints); @retries@ defaults to 2, @tests@ and @examples@ to none.
skill :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> Skill i o
skill n inC outC instr = skillWith n inC outC (Instruction "" instr "")

-- | 'skill' with all three instruction parts declared.
skillWith :: Text -> JSONCodec i -> JSONCodec o -> Instruction i -> Skill i o
skillWith n inC outC ins =
  Skill { name = n, instruction = ins, input = inC, output = outC
        , retries = 2, tests = [], examples = [] }

-- | Replace the instruction's preamble (rendered before the task).
withPreamble :: Text -> Skill i o -> Skill i o
withPreamble p fn = let ins = fn.instruction in fn { instruction = ins { preamble = p } }

-- | Replace the instruction's constraints (rendered after the input).
withConstraints :: Text -> Skill i o -> Skill i o
withConstraints c fn = let ins = fn.instruction in fn { instruction = ins { constraints = c } }

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

-- | Make the skill reason before it answers: the output contract becomes
-- @{"reasoning": <string>, "result": <o>}@ with the reasoning field first,
-- so the result tokens are conditioned on the reasoning (the same
-- CoT-before-verdict effect the eval judge uses). 'call' still returns @o@;
-- the reasoning is requested, decoded, and discarded. Best for extraction
-- and judgement-heavy skills; skip it for trivial classification, where the
-- extra tokens buy nothing. Note: attached examples encode through the same
-- contract with an empty reasoning string; write the codec by hand if your
-- examples should demonstrate reasoning too.
withReasoning :: Skill i o -> Skill i o
withReasoning fn = fn { output = reasoned fn.output }
  where
    reasoned oc =
      dimapCodec snd (\o -> ("", o))
        (object
          ( (,) <$> field "reasoning" fst str
                <*> field "result"    snd oc ))

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
      ${schema}
      Your reply is parsed by a machine; any text outside the JSON is an error.|]
    -- assembled by concatenation, not [text| |]: the slot blocks are
    -- conditional, and interpolated trailing newlines are not preserved
    -- reliably by the quasiquoter. Empty slots contribute nothing.
    userMsg i' =
      Message User $ T.concat
        [ block sk.instruction.preamble
        , (sk.instruction.task) i'
        , "\n\n<input>\n"
        , jsonText (toJSONVia sk.input i')
        , "\n</input>\n\n"
        , block sk.instruction.constraints
        , "Respond with JSON only; your reply is parsed by a machine."
        ]
    block t = if T.null t then "" else t <> "\n\n"
    pair (ei, eo) = [userMsg ei, Message Assistant (jsonText (toJSONVia sk.output eo))]

-- | Run a typed skill: build the prompt, call the model, and decode the reply
-- against the output codec. On a decode failure, re-ask with the parse error
-- and the schema contract restated (error feedback converges faster when it
-- repeats what right looks like), up to 'retries' times; on exhaustion
-- return 'Left'.
call :: (LLM :> es) => Skill i o -> i -> Eff es (Either DecodeError o)
call fn@Skill{output = outC, retries = rets} inp = loop rets (prompt fn inp)
  where
    schema = schemaText outC
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
                       , Message User [text|
                           Your reply did not parse: ${e}.
                           Respond ONLY with valid JSON matching this schema:
                           ${schema}|]
                       ]
                )

-- | Run a skill's attached 'tests' through the eval pipeline and aggregate
-- a 'Report'. Each case 'call's the skill with its input and scores the result
-- against its 'Expectation'; a decode failure scores 0. The render function is
-- used when a 'Rubric' case hands the output to the LLM judge. Needs
-- @LLM :> es@ and @Embed :> es@ (discharge the latter with
-- 'Crucible.Embed.none' when no case uses 'Crucible.Eval.SimilarTo'), so
-- the same cases run scripted, replayed, or live.
testSkill :: (Eq o, LLM :> es, Embed :> es) => (o -> Text) -> Skill i o -> Eff es (Report i (Either DecodeError o))
testSkill render sk =
  runEval render' (call sk) (map liftCase sk.tests)
  where
    render' = either (\e -> "decode error: " <> e.message) render
    liftCase (Case i n ex) = Case i n (liftExp ex)
    liftExp :: Eq o => Expectation o -> Expectation (Either DecodeError o)
    liftExp (Exactly e)   = Predicate (either (const False) (== e))
    liftExp (Predicate p) = Predicate (either (const False) p)
    liftExp (Rubric r)    = Rubric r
