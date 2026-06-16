{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | OpenAI config plumbing for the grading edge: map the shared LLM knobs of a
-- config jsonb onto an 'OpenAIConfig'. Mirrors "Evals.Execute.Anthropic".
module Evals.Execute.OpenAI (openaiCfgFromParams) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Types as AT
import Data.Text (Text)

import Crucible.LLM.OpenAI (OpenAIConfig (..), defaultOpenAIConfig)

-- | Optional model override plus max_tokens/timeout/retries from the jsonb.
openaiCfgFromParams :: Text -> Maybe Text -> Value -> OpenAIConfig
openaiCfgFromParams key mModel paramsVal = base
  { maxTokens   = intParam "max_tokens" base.maxTokens
  , timeoutSecs = intParam "timeout"    base.timeoutSecs
  , maxRetries  = intParam "retries"    base.maxRetries
  }
  where
    base :: OpenAIConfig
    base = case mModel of
      Just m  -> (defaultOpenAIConfig key) { model = m }
      Nothing -> defaultOpenAIConfig key
    intParam :: AT.Key -> Int -> Int
    intParam k dflt = case paramsVal of
      Object o -> maybe dflt id (AT.parseMaybe (AT..: k) o)
      _        -> dflt
