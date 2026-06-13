{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The live grading edge: builds a crucible LLM config from the grader's
-- config jsonb and runs crucible's eval scorer / judge against the real API.
-- The @provider@ config key selects Anthropic (default) or OpenAI per grader.
module Evals.Grade.Live
  ( LiveKeys (..)
  , gradeCfg
  , openaiCfg
  , liveGradeRunner
  , liveCriterionJudge
  ) where

import Control.Exception (try)
import Data.Aeson (Value)
import qualified Data.Aeson.Types as AT
import Data.Text (Text)
import qualified Data.Text as T
import Effectful (runEff)

import qualified Crucible.Embed as Embed
import qualified Crucible.Eval as Eval
import qualified Crucible.Eval.Judge as Judge
import Crucible.LLM.Anthropic (AnthropicConfig, AnthropicError)
import qualified Crucible.LLM.Anthropic as Anthropic
import Crucible.LLM.OpenAI (OpenAIConfig, OpenAIError)
import qualified Crucible.LLM.OpenAI as OpenAI
import Manifest (Aeson (..))

import Evals.Execute (ExecError (..))
import Evals.Execute.Anthropic (cfgFromParams)
import Evals.Execute.OpenAI (openaiCfgFromParams)
import Evals.Grade (CriterionJudge, CriterionVerdict (..), GradeRunner, providerFrom, renderCriterion, votesFrom)
import Evals.Schema

-- | API keys for the live edge: Anthropic always; OpenAI only when a grader
-- selects it via @provider: openai@.
data LiveKeys = LiveKeys { anthropic :: Text, openai :: Maybe Text }

modelFrom :: Value -> Maybe Text
modelFrom = AT.parseMaybe (AT.withObject "config" (AT..: "model"))

-- | The grader's Anthropic config (optional @model@ + shared knobs).
gradeCfg :: Text -> Value -> AnthropicConfig
gradeCfg key cfgV = cfgFromParams key (modelFrom cfgV) cfgV

-- | The grader's OpenAI config (optional @model@ + shared knobs).
openaiCfg :: Text -> Value -> OpenAIConfig
openaiCfg key cfgV = openaiCfgFromParams key (modelFrom cfgV) cfgV

-- | One crucible 'Eval.scoreN' per call, dispatched to the grader's provider.
liveGradeRunner :: LiveKeys -> GradeRunner
liveGradeRunner keys gv expectation rendered =
  case providerFrom cfgV of
    "openai" -> case keys.openai of
      Nothing -> pure (Left (LlmError "grader provider is openai but OPENAI_API_KEY is not set"))
      Just k  -> try (runEff (OpenAI.run (openaiCfg k cfgV) act)) >>= \case
        Right s                  -> pure (Right s)
        Left (e :: OpenAIError)  -> pure (Left (LlmError (T.pack (show e))))
    _ -> try (runEff (Anthropic.run (gradeCfg keys.anthropic cfgV) act)) >>= \case
        Right s                     -> pure (Right s)
        Left (e :: AnthropicError)  -> pure (Left (LlmError (T.pack (show e))))
  where
    Aeson cfgV = gv.config
    -- Embed.none is safe: rubric/checklist expectations never embed; only a
    -- SimilarTo expectation would, and no grader kind here produces one.
    act = Embed.none (Eval.scoreN (votesFrom cfgV) id expectation rendered)

-- | One crucible 'Judge.vote' per criterion, dispatched to the grader's provider.
liveCriterionJudge :: LiveKeys -> CriterionJudge
liveCriterionJudge keys gv transcriptTxt c =
  case providerFrom cfgV of
    "openai" -> case keys.openai of
      Nothing -> pure (Left (LlmError "grader provider is openai but OPENAI_API_KEY is not set"))
      Just k  -> try (runEff (OpenAI.run (openaiCfg k cfgV) act)) >>= \case
        Right o                 -> decode o
        Left (e :: OpenAIError) -> pure (Left (LlmError (T.pack (show e))))
    _ -> try (runEff (Anthropic.run (gradeCfg keys.anthropic cfgV) act)) >>= \case
        Right o                    -> decode o
        Left (e :: AnthropicError) -> pure (Left (LlmError (T.pack (show e))))
  where
    Aeson cfgV = gv.config
    act = Judge.vote True (Judge.defaultJudgeOpts { Judge.votes = votesFrom cfgV }) (renderCriterion c) transcriptTxt
    decode = \case
      Judge.Decided p w _ _ _ -> pure (Right CriterionVerdict { met = p, explanation = w })
      Judge.AllErrored m      -> pure (Left (LlmError ("judge error: " <> m)))
      Judge.AllAbstained m    -> pure (Left (LlmError ("judge abstained: " <> m)))
