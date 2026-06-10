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

-- | 'defaultAnthropicConfig' + the target's @model@, with the known
-- @params@ jsonb knobs mapped on top: @max_tokens@ → 'maxTokens', @timeout@ →
-- 'timeoutSecs', @retries@ → 'maxRetries'. Unknown keys (e.g. @temperature@ —
-- crucible has no such knob) are ignored.
cfgFrom :: Text -> TargetVersion -> AnthropicConfig
cfgFrom key tv = base
  { maxTokens   = intParam "max_tokens" base.maxTokens
  , timeoutSecs = intParam "timeout"    base.timeoutSecs
  , maxRetries  = intParam "retries"    base.maxRetries
  }
  where
    base :: AnthropicConfig
    base = (defaultAnthropicConfig key) { model = tv.model }
    Aeson paramsVal = tv.params
    intParam :: AT.Key -> Int -> Int
    intParam k dflt = case paramsVal of
      Object o -> maybe dflt id (AT.parseMaybe (AT..: k) o)
      _        -> dflt

-- | The live backend: one @Anthropic.usage@-interpreted 'complete' per call;
-- a thrown 'AnthropicError' (after crucible's own retries) becomes 'LlmError'.
liveAnthropicRunner :: Text -> LlmRunner
liveAnthropicRunner key tv msgs =
  try (runEff (Anthropic.usage (cfgFrom key tv) (complete msgs))) >>= \case
    Right (t, u)                 -> pure (Right (t, u))
    Left (e :: AnthropicError)   -> pure (Left (LlmError (T.pack (show e))))
