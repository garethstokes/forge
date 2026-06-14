{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
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
  , parseVerdict
  ) where

import Control.Applicative ((<|>))
import Control.Exception (try)
import qualified Data.Aeson as A
import Data.Aeson (Value)
import qualified Data.Aeson.Types as AT
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Effectful (Eff, runEff)
import Effectful ((:>))
import Crucible.LLM (LLM, Message (..), Role (..), complete)

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
import Evals.Grade (Criterion' (..), CriterionJudge, CriterionVerdict (..), GradeRunner, providerFrom, renderCriterion, votesFrom)
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

-- | A config @prompt@ string of the grader version, when present, overrides
-- crucible's hardened judge prompt (used for HealthBench-faithful grading).
promptFrom :: Value -> Maybe Text
promptFrom = AT.parseMaybe (AT.withObject "config" (AT..: "prompt"))

-- | One crucible 'Judge.vote' per criterion, dispatched to the grader's provider.
liveCriterionJudge :: LiveKeys -> CriterionJudge
liveCriterionJudge keys gv transcriptTxt c =
  case promptFrom cfgV of
    Just tmpl -> runProvider (complete [ Message User (render tmpl) ])
                             (pure . parseVerdict)
    Nothing   -> runProvider (Judge.vote True opts (renderCriterion c) transcriptTxt)
                             decodeVote
  where
    Aeson cfgV = gv.config
    opts = Judge.defaultJudgeOpts { Judge.votes = votesFrom cfgV }
    -- HealthBench substitutes the conversation (ours: the transcript, which
    -- ends with "assistant: <completion>") and the bare rubric criterion.
    render tmpl = let Criterion' { criterion = crit } = c
                  in T.replace "<<rubric_item>>" crit
                               (T.replace "<<conversation>>" transcriptTxt tmpl)
    runProvider :: forall a. (forall es. (LLM :> es) => Eff es a)
                -> (a -> IO (Either ExecError CriterionVerdict))
                -> IO (Either ExecError CriterionVerdict)
    runProvider act handle =
      case providerFrom cfgV of
        "openai" -> case keys.openai of
          Nothing -> pure (Left (LlmError "grader provider is openai but OPENAI_API_KEY is not set"))
          Just k  -> try (runEff (OpenAI.run (openaiCfg k cfgV) act)) >>= \case
            Right o                 -> handle o
            Left (e :: OpenAIError) -> pure (Left (LlmError (T.pack (show e))))
        _ -> try (runEff (Anthropic.run (gradeCfg keys.anthropic cfgV) act)) >>= \case
            Right o                    -> handle o
            Left (e :: AnthropicError) -> pure (Left (LlmError (T.pack (show e))))
    decodeVote = \case
      Judge.Decided p w _ _ _ -> pure (Right CriterionVerdict { met = p, explanation = w })
      Judge.AllErrored m      -> pure (Left (LlmError ("judge error: " <> m)))
      Judge.AllAbstained m    -> pure (Left (LlmError ("judge abstained: " <> m)))

-- | Strip a leading ```json / ``` fence and a trailing ``` fence, mirroring
-- HealthBench's parse_json_to_dict regex (^```json\s*|\s*```$).
stripFences :: Text -> Text
stripFences raw =
  let t1 = T.strip raw
      t2 = maybe t1 T.stripStart (T.stripPrefix "```json" t1 <|> T.stripPrefix "```" t1)
      t3 = maybe t2 T.stripEnd (T.stripSuffix "```" (T.stripEnd t2))
  in T.strip t3

-- | Parse a grader response into a verdict: HealthBench returns a JSON object
-- with "criteria_met" (bool, required) and "explanation" (string, optional).
parseVerdict :: Text -> Either ExecError CriterionVerdict
parseVerdict raw =
  case A.eitherDecodeStrict (TE.encodeUtf8 (stripFences raw)) of
    Left e  -> Left (LlmError ("grader response not JSON: " <> T.pack e))
    Right v -> case AT.parseEither parseObj v of
      Left e   -> Left (LlmError ("grader JSON missing criteria_met: " <> T.pack e))
      Right cv -> Right cv
  where
    parseObj = AT.withObject "verdict" $ \o -> do
      m <- o AT..: "criteria_met"
      e <- o AT..:? "explanation" AT..!= ""
      pure CriterionVerdict { met = m, explanation = e }
