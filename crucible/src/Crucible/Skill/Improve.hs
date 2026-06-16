{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | A testSkill-driven instruction optimizer (a GEPA-lite hill-climb): each
-- round, a reflector skill reads the failing cases (full original prompts,
-- outputs, and score rationales, re-injected every round) and proposes
-- revised preamble and constraints; the candidate is kept only on a strict
-- meanScore improvement over the attached test cases.
--
-- Honesty rails, not optional: optimizing against an LLM judge is Goodhart
-- territory. Calibrate the judge ('Crucible.Eval.Calibrate.calibrate',
-- kappa above 0.6) BEFORE trusting the optimizer's gains; keep held-out
-- cases OUT of the skill's tests and verify the winner against them by
-- hand ('improveSkill' does no splitting); and review the accepted slots
-- before shipping them, because they are text the reflector wrote.
--
-- Cost per round: one full 'testSkill' run (cases x judge calls, doubled
-- by verdict repairs) plus one reflection call.
module Crucible.Skill.Improve
  ( ImproveStep (..)
  , improveSkill
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import GHC.Generics (Generic)
import NeatInterpolation (text)

import Crucible.Codec (str)
import Crucible.Codec.Generic (HasCodec (codec), genericCodec)
import Crucible.Decode (DecodeError (..))
import Crucible.Embed (Embed)
import Crucible.Eval (Case (..), Report (..), Result (..), Score (..))
import Crucible.LLM (LLM, Message (..), Role (..))
import Crucible.Skill
  ( Instruction (..), Skill (..), call, prompt, skill, testSkill
  , withConstraints, withPreamble )

-- | The reflector's proposal: new values for the two mutable slots.
data Revision = Revision { preamble :: Text, constraints :: Text }
  deriving (Show, Generic)

instance HasCodec Revision where codec = genericCodec

-- | One optimizer round's record: what was proposed, what it scored, and
-- whether it was kept. A reflector decode failure records a rejected step
-- carrying the CURRENT slots and scores (there is no proposal to show).
data ImproveStep = ImproveStep
  { round'      :: Int
  , accepted    :: Bool
  , passRate    :: Double
  , meanScore   :: Double
  , preamble    :: Text
  , constraints :: Text
  }
  deriving (Eq, Show)

-- | The internal revision-proposing skill.
reflector :: Skill Text Revision
reflector = skill "reflect-instruction" str codec $ \digest -> [text|
  You are revising the prompt of an LLM skill whose test cases are failing.
  You may ONLY rewrite the skill's preamble (text rendered before the task)
  and constraints (text rendered after the input). The task itself is fixed
  and shown inside each failing prompt below.
  Study the failures, then propose a revised preamble and constraints that
  make the failing cases pass without contradicting the task.

  ${digest}|]

-- | Hill-climb the skill's preamble and constraints against its attached
-- test cases for up to @rounds@ reflection attempts. Returns the best
-- skill found and the chronological step history. Stops early when every
-- case passes. An empty test list returns immediately.
improveSkill :: (Eq o, LLM :> es, Embed :> es)
             => Int -> (o -> Text) -> Skill i o -> Eff es (Skill i o, [ImproveStep])
improveSkill rounds render sk0
  | null sk0.tests = pure (sk0, [])
  | otherwise = do
      rep0 <- testSkill render sk0
      go 1 sk0 rep0.meanScore rep0.passRate (failuresOf rep0) []
  where
    go k best bestMean bestPass fails steps
      | k > rounds || null fails = pure (best, reverse steps)
      | otherwise = do
          r <- call reflector (digest best fails)
          case r of
            Left _ ->
              go (k + 1) best bestMean bestPass fails
                (ImproveStep k False bestPass bestMean
                   best.instruction.preamble best.instruction.constraints
                 : steps)
            Right rev -> do
              let cand = withPreamble rev.preamble (withConstraints rev.constraints best)
              repC <- testSkill render cand
              let step acc = ImproveStep k acc repC.passRate repC.meanScore
                               rev.preamble rev.constraints
              if repC.meanScore > bestMean
                then go (k + 1) cand repC.meanScore repC.passRate
                       (failuresOf repC) (step True : steps)
                else go (k + 1) best bestMean bestPass fails (step False : steps)

    failuresOf rep =
      [ (c, out, sc)
      | Result{case' = c, output = out, score = sc} <- rep.results
      , sc.value < 1.0
      ]

    digest best fails = T.intercalate "\n\n" $
      [ "Current preamble (may be empty):\n" <> best.instruction.preamble
      , "Current constraints (may be empty):\n" <> best.instruction.constraints
      ]
        ++ concat
          [ [ "Failing case: " <> c.name
            , "Prompt sent:\n" <> renderMsgs (prompt best c.input)
            , "Output:\n" <> either (\e -> "decode error: " <> e.message) render out
            , "Score rationale:\n" <> sc.rationale
            ]
          | (c, out, sc) <- fails
          ]

    renderMsgs ms =
      T.intercalate "\n" [roleLabel r <> ": " <> c | Message r c <- ms]
    roleLabel System    = "System"
    roleLabel User      = "User"
    roleLabel Assistant = "Assistant"
    roleLabel Tool      = "Tool"
