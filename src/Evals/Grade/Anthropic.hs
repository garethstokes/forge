{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The live grading edge: an 'AnthropicConfig' from the grader's config
-- jsonb (model defaults to crucible's; @votes@ drives n-vote judging) and
-- crucible's eval scorer run against the real API.
module Evals.Grade.Anthropic
  ( gradeCfg
  , liveGradeRunner
  , liveCriterionJudge
  ) where

import Control.Exception (try)
import Data.Aeson (Value)
import qualified Data.Aeson.Types as AT
import Data.Text (Text)
import qualified Data.Text as T
import Effectful (runEff)

import qualified Crucible.Eval as Eval
import qualified Crucible.Eval.Judge as Judge
import Crucible.LLM.Anthropic (AnthropicConfig, AnthropicError)
import qualified Crucible.LLM.Anthropic as Anthropic
import Manifest (Aeson (..))

import Evals.Execute (ExecError (..))
import Evals.Execute.Anthropic (cfgFromParams)
import Evals.Grade (CriterionJudge, CriterionVerdict (..), GradeRunner, renderCriterion, votesFrom)
import Evals.Schema

-- | The grader's LLM config: optional @model@ key, plus the shared knob
-- mapping (max_tokens\/timeout\/retries).
gradeCfg :: Text -> Value -> AnthropicConfig
gradeCfg key cfgV = cfgFromParams key (modelFrom cfgV) cfgV
  where
    modelFrom = AT.parseMaybe (AT.withObject "config" (AT..: "model"))

-- | One crucible 'Eval.scoreN' per call (n = the config's @votes@); a thrown
-- 'AnthropicError' (after crucible's retries) becomes 'LlmError'.
liveGradeRunner :: Text -> GradeRunner
liveGradeRunner key gv expectation rendered =
  try (runEff (Anthropic.run (gradeCfg key cfgV)
                 (Eval.scoreN (votesFrom cfgV) id expectation rendered))) >>= \case
    Right s                    -> pure (Right s)
    Left (e :: AnthropicError) -> pure (Left (LlmError (T.pack (show e))))
  where Aeson cfgV = gv.config

-- | One crucible 'Judge.vote' per criterion (n = the config's @votes@); the
-- transcript is the graded text. NOTE: uses crucible's hardened prompt + a
-- Claude model, not HealthBench's published GPT-4.1 grader — scores are
-- directionally comparable, not benchmark-comparable.
liveCriterionJudge :: Text -> CriterionJudge
liveCriterionJudge key gv transcriptTxt c =
  try (runEff (Anthropic.run (gradeCfg key cfgV)
                 (Judge.vote True (votesFrom cfgV) (renderCriterion c) transcriptTxt))) >>= \case
    Right (Judge.Decided p w _ _ _) ->
      pure (Right CriterionVerdict { met = p, explanation = w })
    Right (Judge.AllErrored m) ->
      pure (Left (LlmError ("judge error: " <> m)))
    Left (e :: AnthropicError) ->
      pure (Left (LlmError (T.pack (show e))))
  where Aeson cfgV = gv.config
