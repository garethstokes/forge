{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | Typed LLM functions: declare an 'LlmFn' once (input type, output type, and a
-- task instruction) and 'call' it for a typed, structured result. The output
-- schema is injected into the prompt and the reply is tolerantly decoded against
-- the output 'Codec'. 'call' needs only @LLM :> es@, so it runs under the
-- scripted, cassette, and live Anthropic interpreters unchanged.
module Crucible.Function
  ( LlmFn (..)
  , llmFn
  , withRetries
  , fnPrompt
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

-- | A declared LLM function: a task instruction plus input/output codecs.
data LlmFn i o = LlmFn
  { fnName        :: Text        -- ^ for introspection / evals
  , fnInstruction :: i -> Text   -- ^ the task (may reference input fields)
  , fnInput       :: JSONCodec i -- ^ used to render the input value into the prompt
  , fnOutput      :: JSONCodec o -- ^ schema injection + tolerant decode
  , fnRetries     :: Int         -- ^ decode-failure retries
  }

-- | Construct an 'LlmFn'; @fnRetries@ defaults to 2.
llmFn :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> LlmFn i o
llmFn name inC outC instr =
  LlmFn { fnName = name, fnInstruction = instr, fnInput = inC, fnOutput = outC, fnRetries = 2 }

-- | Override the decode-failure retry budget.
withRetries :: Int -> LlmFn i o -> LlmFn i o
withRetries n fn = fn { fnRetries = n }

-- | Encode a value to JSON text via its codec.
jsonText :: A.Value -> Text
jsonText = TE.decodeUtf8 . LB.toStrict . A.encode

-- | The seed messages 'call' sends for a given input: a System message carrying
-- the output-schema contract, and a User message with the instruction plus the
-- rendered input. Exposed for introspection/debugging and tested directly.
fnPrompt :: LlmFn i o -> i -> [Message]
fnPrompt fn input =
  [ Message System [text|
      Respond ONLY with JSON matching this schema:
      ${schema}|]
  , Message User [text|
      ${instruction}

      Input:
      ${rendered}|]
  ]
  where
    schema      = schemaText (fnOutput fn)
    instruction = fnInstruction fn input
    rendered    = jsonText (toJSONVia (fnInput fn) input)

-- | Run a typed function: build the prompt, call the model, and decode the reply
-- against the output codec. On a decode failure, re-ask with the parse error fed
-- back (up to 'fnRetries' times); on exhaustion return 'Left'.
call :: (LLM :> es) => LlmFn i o -> i -> Eff es (Either String o)
call fn input = loop (fnRetries fn) (fnPrompt fn input)
  where
    loop n msgs = do
      raw <- complete msgs
      case decodeLLM (fnOutput fn) raw of
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
