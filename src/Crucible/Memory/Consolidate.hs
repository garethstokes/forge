{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | Offline memory consolidation: a 'Skill' proposes a 'ConsolidationPlan'
-- (keep/drop/supersede/merge per item) over the current memories, and
-- 'applyPlan' executes it as 'Memory' operations, stamping derived memories
-- 'Crucible.Memory.ByConsolidation'. crucible ships the skill and the apply;
-- when consolidation runs is the host's business. The skill is iterable with
-- 'Crucible.Skill.testSkill' like any other.
module Crucible.Memory.Consolidate
  ( ConsolidationOp (..)
  , ConsolidationPlan (..)
  , consolidationSkill
  , applyPlan
  , unaddressed
  , consolidate
  ) where

import Control.Monad (void)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import NeatInterpolation (text)

import Crucible.Codec (JSONCodec, object, field, optField, str, int, list', bimapCodec, dimapCodec)
import Crucible.Decode (DecodeError)
import Crucible.LLM (LLM)
import Crucible.Memory
  ( Memory, MemoryItem (..), MemoryId (..), MemoryKind (..), MemoryDraft (..)
  , Provenance (..), Query, recall, remember, forget
  , memoryItemCodec, memoryKindCodec )
import Crucible.Skill (Skill, skill, call)

-- | One consolidation operation. 'Keep' records a deliberate retention (a
-- no-op for the store; an item the plan never mentions is also kept).
data ConsolidationOp
  = Keep      MemoryId
  | Drop      MemoryId
  | Supersede MemoryId   MemoryKind Text
  | Merge     [MemoryId] MemoryKind Text
  deriving (Eq, Show)

newtype ConsolidationPlan = ConsolidationPlan { ops :: [ConsolidationOp] }
  deriving (Eq, Show)

-- The wire shape for one op (a tagged object).
data RawOp = RawOp
  { op      :: Text
  , id      :: Maybe Int
  , ids     :: Maybe [Int]
  , kind    :: Maybe MemoryKind
  , content :: Maybe Text
  }

opCodec :: JSONCodec ConsolidationOp
opCodec = bimapCodec toOp fromOp
  (object (RawOp <$> field    "op"      ((.op)      :: RawOp -> Text)                str
                 <*> optField "id"      ((.id)      :: RawOp -> Maybe Int)            int
                 <*> optField "ids"     ((.ids)     :: RawOp -> Maybe [Int])          (list' int)
                 <*> optField "kind"    ((.kind)    :: RawOp -> Maybe MemoryKind)     memoryKindCodec
                 <*> optField "content" ((.content) :: RawOp -> Maybe Text)           str))
  where
    toOp r = case r.op of
      "keep"      -> Keep . MemoryId <$> need "id" r.id
      "drop"      -> Drop . MemoryId <$> need "id" r.id
      "supersede" -> Supersede <$> (MemoryId <$> need "id" r.id)
                               <*> need "kind" r.kind <*> need "content" r.content
      "merge"     -> Merge <$> (map MemoryId <$> need "ids" r.ids)
                           <*> need "kind" r.kind <*> need "content" r.content
      other       -> Left ("unknown op: " <> T.unpack other)
    need _    (Just v) = Right v
    need name Nothing  = Left ("op missing field: " <> name)
    fromOp (Keep (MemoryId i))          = RawOp "keep" (Just i) Nothing Nothing Nothing
    fromOp (Drop (MemoryId i))          = RawOp "drop" (Just i) Nothing Nothing Nothing
    fromOp (Supersede (MemoryId i) k t) = RawOp "supersede" (Just i) Nothing (Just k) (Just t)
    fromOp (Merge is k t)               = RawOp "merge" Nothing (Just [i | MemoryId i <- is]) (Just k) (Just t)

planCodec :: JSONCodec ConsolidationPlan
planCodec = dimapCodec ConsolidationPlan (.ops) (list' opCodec)

-- | The consolidation skill: live items as JSON in <input>, a plan array out.
consolidationSkill :: Skill [MemoryItem] ConsolidationPlan
consolidationSkill = skill "consolidate" (list' memoryItemCodec) planCodec
  (\_ -> [text|
    You are consolidating an agent's memory. The current memories are in the
    <input> block as a JSON array; each has an id, kind, tags, and content.
    Propose a consolidation plan as a JSON array of operations:
    - {"op":"drop","id":N} to forget a memory that is noise, redundant, or wrong.
    - {"op":"supersede","id":N,"kind":K,"content":"..."} to replace one memory
      with a corrected or refined version. You may change its kind, for example
      promoting an episodic observation into a semantic fact.
    - {"op":"merge","ids":[N,...],"kind":K,"content":"..."} to combine several
      related memories into one; choose the kind of the result.
    - {"op":"keep","id":N} to record that a memory is deliberately retained.
    Any memory you do not mention is kept. Only drop, supersede, or merge when it
    clearly improves the store. K is one of episodic, semantic, procedural.|])

opIds :: ConsolidationOp -> [MemoryId]
opIds (Keep i)          = [i]
opIds (Drop i)          = [i]
opIds (Supersede i _ _) = [i]
opIds (Merge is _ _)    = is

-- | Execute a plan as Memory operations. Keep is a no-op; Drop forgets;
-- Supersede forgets the old and remembers a new (kind, content) with that
-- item's tags; Merge forgets all referenced and remembers one new (kind,
-- content) with the union of their tags. Derived memories are stamped
-- 'ByConsolidation'. Items the plan never mentions are untouched.
applyPlan :: (Memory :> es) => [MemoryItem] -> ConsolidationPlan -> Eff es ()
applyPlan items (ConsolidationPlan os) = mapM_ step os
  where
    tagsOf is = nub [t | it <- items, it.memId `elem` is, t <- it.tags]
    step (Keep _)          = pure ()
    step (Drop i)          = forget i
    step (Supersede i k t) = forget i >> void (remember (MemoryDraft k t (tagsOf [i]) ByConsolidation))
    step (Merge is k t)    = mapM_ forget is >> void (remember (MemoryDraft k t (tagsOf is) ByConsolidation))

-- | The items a plan never references (implicitly kept), for auditing.
unaddressed :: [MemoryItem] -> ConsolidationPlan -> [MemoryItem]
unaddressed items (ConsolidationPlan os) =
  [it | it <- items, it.memId `notElem` mentioned]
  where mentioned = concatMap opIds os

-- | Recall under a query, ask the skill for a plan, apply it, return the plan.
-- A plan that fails to decode is returned as 'Left' and applies nothing.
consolidate :: (Memory :> es, LLM :> es)
            => Skill [MemoryItem] ConsolidationPlan -> Query
            -> Eff es (Either DecodeError ConsolidationPlan)
consolidate sk q = do
  items <- recall q
  r <- call sk items
  case r of
    Right plan -> applyPlan items plan >> pure (Right plan)
    Left e     -> pure (Left e)
