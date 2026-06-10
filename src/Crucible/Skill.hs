{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoFieldSelectors #-}
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
  , prompt
  , call
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text.Encoding as TE
import qualified Data.Aeson as A
import NeatInterpolation (text)

import Effectful
import Autodocodec (toJSONVia)

import Crucible.Codec (JSONCodec, schemaText)
import Crucible.LLM (LLM, Message (..), Role (..), complete)
import Crucible.SAP (decodeLLM)

-- | A declared LLM skill: a task instruction plus input/output codecs.
data Skill i o = Skill
  { name        :: Text        -- ^ for introspection / evals
  , instruction :: i -> Text   -- ^ the task (may reference input fields)
  , input       :: JSONCodec i -- ^ used to render the input value into the prompt
  , output      :: JSONCodec o -- ^ schema injection + tolerant decode
  , retries     :: Int         -- ^ decode-failure retries
  }

-- | Construct a 'Skill'; @retries@ defaults to 2.
skill :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> Skill i o
skill n inC outC instr =
  Skill { name = n, instruction = instr, input = inC, output = outC, retries = 2 }

-- | Override the decode-failure retry budget.
withRetries :: Int -> Skill i o -> Skill i o
withRetries n fn = fn { retries = n }

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
call :: (LLM :> es) => Skill i o -> i -> Eff es (Either String o)
call fn@Skill{output = outC, retries = rets} inp = loop rets (prompt fn inp)
  where
    loop n msgs = do
      raw <- complete msgs
      case decodeLLM outC raw of
        Right o -> pure (Right o)
        Left err
          | n <= 0    -> pure (Left err)
          | otherwise ->
              let e = T.pack err
              in loop (n - 1)
                ( msgs
                    ++ [ Message Assistant raw
                       , Message User [text|Your reply did not parse: ${e}. Respond with valid JSON only.|]
                       ]
                )
