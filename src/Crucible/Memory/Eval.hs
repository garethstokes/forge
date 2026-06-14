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
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Crucible.Memory (MemoryItem (..))
import Crucible.Skill (Skill (..), Instruction (..), withPreamble)

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
