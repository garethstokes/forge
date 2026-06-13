{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The live model edge: build an 'AnthropicConfig' from a 'TargetVersion'
-- and run crucible's Anthropic interpreter. Retries\/backoff\/timeouts are
-- crucible's; this module only maps configuration and catches the typed error.
module Evals.Execute.Anthropic
  ( cfgFrom
  , cfgFromParams
  , liveAnthropicRunner
  ) where

import Control.Exception (try)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Types as AT
import Data.Text (Text)
import qualified Data.Text as T
import Effectful (runEff)

import Crucible.LLM (complete)
import Crucible.LLM.Anthropic (AnthropicConfig (..), AnthropicError, defaultAnthropicConfig)
import qualified Crucible.LLM.Anthropic as Anthropic
import Manifest (Aeson (..))

import Evals.Execute (ExecError (..), LlmRunner)
import Evals.Schema

-- | Map the known LLM knobs of a params jsonb onto a config: optional model
-- override plus max_tokens/timeout/retries. Shared by the target path
-- ('cfgFrom') and the grader path ("Evals.Grade.Live").
cfgFromParams :: Text -> Maybe Text -> Value -> AnthropicConfig
cfgFromParams key mModel paramsVal = base
  { maxTokens   = intParam "max_tokens" base.maxTokens
  , timeoutSecs = intParam "timeout"    base.timeoutSecs
  , maxRetries  = intParam "retries"    base.maxRetries
  }
  where
    base :: AnthropicConfig
    base = case mModel of
      Just m  -> (defaultAnthropicConfig key) { model = m }
      Nothing -> defaultAnthropicConfig key
    intParam :: AT.Key -> Int -> Int
    intParam k dflt = case paramsVal of
      Object o -> maybe dflt id (AT.parseMaybe (AT..: k) o)
      _        -> dflt

-- | 'cfgFromParams' with the target's mandatory model.
cfgFrom :: Text -> TargetVersion -> AnthropicConfig
cfgFrom key tv = cfgFromParams key (Just tv.model) paramsVal
  where Aeson paramsVal = tv.params

-- | The live backend: one @Anthropic.usage@-interpreted 'complete' per call;
-- a thrown 'AnthropicError' (after crucible's own retries) becomes 'LlmError'.
liveAnthropicRunner :: Text -> LlmRunner
liveAnthropicRunner key tv msgs =
  try (runEff (Anthropic.usage (cfgFrom key tv) (complete msgs))) >>= \case
    Right (t, u)                 -> pure (Right (t, u))
    Left (e :: AnthropicError)   -> pure (Left (LlmError (T.pack (show e))))
