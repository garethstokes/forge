{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | Measuring whether a memory pays rent. 'memoryLift' runs a skill's
-- attached test cases with and without candidate memories rendered into the
-- preamble and returns both reports; 'liftDelta' reduces the pair to the
-- pass-rate and mean-score deltas. Decoupled from the 'Crucible.Memory'
-- effect: the candidates are a plain '[MemoryItem]', so this needs only LLM
-- and Embed (via 'Crucible.Skill.testSkill'). 'withMemories' also stands
-- alone for running a skill with recalled context in production.
module Crucible.Memory.Eval
  ( renderMemories
  , withMemories
  , memoryLift
  , liftDelta
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Effectful (Eff, (:>))
import Crucible.Decode (DecodeError)
import Crucible.Embed (Embed)
import Crucible.Eval (Report (..))
import Crucible.LLM (LLM)
import Crucible.Memory (MemoryItem (..))
import Crucible.Skill (Skill (..), Instruction (..), withPreamble, testSkill)

-- | Render memory contents as a labelled preamble block. Content only;
-- kind/tags/source are internal taxonomy and are not rendered. Empty list
-- renders the empty string.
renderMemories :: [MemoryItem] -> Text
renderMemories [] = ""
renderMemories ms =
  "Relevant memories from past sessions:\n"
    <> T.concat ["- " <> m.content <> "\n" | m <- ms]

-- | Append rendered memories to a skill's instruction preamble (after any
-- existing preamble, separated by a blank line). An empty list returns the
-- skill unchanged.
withMemories :: [MemoryItem] -> Skill i o -> Skill i o
withMemories [] sk = sk
withMemories ms sk = withPreamble newPreamble sk
  where
    existing    = sk.instruction.preamble
    rendered    = renderMemories ms
    newPreamble = if T.null existing then rendered
                                     else existing <> "\n\n" <> rendered

-- | Ablation: run the skill's attached test cases without memories
-- (baseline) and with them (lifted), returning both reports as
-- (baseline, lifted). Needs only LLM + Embed (via 'testSkill'); decoupled
-- from the Memory effect, so the candidates can come from 'recall' or be a
-- literal proposed memory under review.
memoryLift :: (Eq o, LLM :> es, Embed :> es)
           => (o -> Text) -> Skill i o -> [MemoryItem]
           -> Eff es (Report i (Either DecodeError o), Report i (Either DecodeError o))
memoryLift render sk ms = do
  base   <- testSkill render sk
  lifted <- testSkill render (withMemories ms sk)
  pure (base, lifted)

-- | The headline deltas of an ablation, lifted minus baseline:
-- (passRate delta, meanScore delta). Positive means the memories paid rent.
liftDelta :: (Report i a, Report i a) -> (Double, Double)
liftDelta (base, lifted) =
  ( lifted.passRate  - base.passRate
  , lifted.meanScore - base.meanScore )
