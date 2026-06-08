{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
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

import Effectful

import Crucible.Codec (Codec (..))
import qualified Crucible.Json.Decode as D
import Crucible.Json.Encode (encode)
import Crucible.LLM (LLM, Message (..), Role (..), complete)
import Crucible.SAP (decodeLLM)
import Crucible.Schema (renderSchema)

-- | A declared LLM function: a task instruction plus input/output codecs.
data LlmFn i o = LlmFn
  { fnName        :: Text        -- ^ for introspection / evals
  , fnInstruction :: i -> Text   -- ^ the task (may reference input fields)
  , fnInput       :: Codec i     -- ^ used to render the input value into the prompt
  , fnOutput      :: Codec o     -- ^ schema injection + tolerant decode
  , fnRetries     :: Int         -- ^ decode-failure retries
  }

-- | Construct an 'LlmFn'; @fnRetries@ defaults to 2.
llmFn :: Text -> Codec i -> Codec o -> (i -> Text) -> LlmFn i o
llmFn name inC outC instr =
  LlmFn { fnName = name, fnInstruction = instr, fnInput = inC, fnOutput = outC, fnRetries = 2 }

-- | Override the decode-failure retry budget.
withRetries :: Int -> LlmFn i o -> LlmFn i o
withRetries n fn = fn { fnRetries = n }

-- | The seed messages 'call' sends for a given input: a System message carrying
-- the output-schema contract, and a User message with the instruction plus the
-- rendered input. Exposed for introspection/debugging and tested directly.
fnPrompt :: LlmFn i o -> i -> [Message]
fnPrompt fn input =
  [ Message System ("Respond ONLY with JSON matching this schema:\n" <> renderSchema (codecSchema (fnOutput fn)))
  , Message User (fnInstruction fn input <> "\n\nInput:\n" <> encode (codecEncode (fnInput fn) input))
  ]

-- | Run a typed function: build the prompt, call the model once, and decode the
-- reply against the output codec. (Retry-on-failure is added in a later task.)
call :: (LLM :> es) => LlmFn i o -> i -> Eff es (Either D.Error o)
call fn input = do
  raw <- complete (fnPrompt fn input)
  pure (decodeLLM (fnOutput fn) raw)
