{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | A small memory effect in the house style: a linear append-only log of
-- 'Remember'/'Forget' entries with provenance, recalled under a budget.
-- 'Forget' supersedes (an appended tombstone), it never erases, so history
-- survives for audit. Interpreters: 'runMemoryScripted' (tests),
-- 'runMemoryPure' (property tests), 'runMemoryFile' (a git-diffable JSONL
-- store, added in Task 2). 'recallAs' decodes recalled content through a
-- codec, so a memory that no longer fits today's schema comes back as a
-- 'DecodeError' (stale).
module Crucible.Memory
  ( MemoryKind (..)
  , MemoryId (..)
  , Provenance (..)
  , MemoryDraft (..)
  , MemoryItem (..)
  , Query (..)
  , Memory (..)
  , remember, recall, forget
  , recallAs
  , runMemoryScripted
  , runMemoryPure
  ) where

import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret, send)
import Effectful.State.Static.Local (evalState, get, modify, put, runState)

import Crucible.Codec (JSONCodec)
import Crucible.Decode (DecodeError, decodeLLM)

data MemoryKind = Episodic | Semantic | Procedural
  deriving (Eq, Show)

newtype MemoryId = MemoryId Int deriving (Eq, Show)

idInt :: MemoryId -> Int
idInt (MemoryId i) = i

-- | Who/what wrote a memory. Mandatory; enables trust-aware retrieval,
-- bulk revocation, and a raw-vs-derived distinction.
data Provenance
  = BySkill Text
  | BySession Text
  | ByConsolidation
  | Curated
  deriving (Eq, Show)

data MemoryDraft = MemoryDraft
  { kind    :: MemoryKind
  , content :: Text
  , tags    :: [Text]
  , source  :: Provenance
  }
  deriving (Eq, Show)

data MemoryItem = MemoryItem
  { memId     :: MemoryId
  , kind      :: MemoryKind
  , content   :: Text
  , tags      :: [Text]
  , source    :: Provenance
  , createdAt :: Int
  }
  deriving (Eq, Show)

data Query = Query
  { needle   :: Text
  , anyTags  :: [Text]
  , maxItems :: Int
  }
  deriving (Eq, Show)

data MemoryEntry = Remembered MemoryItem | Forgot MemoryId
  deriving (Eq, Show)

data Memory :: Effect where
  Remember :: MemoryDraft -> Memory m MemoryId
  Recall   :: Query -> Memory m [MemoryItem]
  Forget   :: MemoryId -> Memory m ()
type instance DispatchOf Memory = Dynamic

remember :: (Memory :> es) => MemoryDraft -> Eff es MemoryId
remember = send . Remember

recall :: (Memory :> es) => Query -> Eff es [MemoryItem]
recall = send . Recall

forget :: (Memory :> es) => MemoryId -> Eff es ()
forget = send . Forget

-- | The live (non-forgotten) items of a log, in append order.
liveItems :: [MemoryEntry] -> [MemoryItem]
liveItems es = [it | Remembered it <- es, idInt it.memId `notElem` forgotten]
  where forgotten = [idInt i | Forgot i <- es]

-- | Does an item satisfy a query (tag overlap and case-folded needle infix)?
matchQuery :: Query -> MemoryItem -> Bool
matchQuery q it =
  (null q.anyTags || any (`elem` it.tags) q.anyTags)
    && (T.null q.needle || T.toCaseFold q.needle `T.isInfixOf` T.toCaseFold it.content)

-- | The shared recall kernel: live items matching the query, most-recent
-- first (descending createdAt, ties by descending id), capped at maxItems.
queryLive :: Query -> [MemoryEntry] -> [MemoryItem]
queryLive q =
  take (max 0 q.maxItems)
    . sortOn (\it -> Down (it.createdAt, idInt it.memId))
    . filter (matchQuery q)
    . liveItems

-- | Build a stored item from a draft, an id, and a createdAt ordinal.
itemOf :: MemoryDraft -> Int -> MemoryItem
itemOf d n = MemoryItem (MemoryId n) d.kind d.content d.tags d.source n

-- | Canned recalls popped per 'Recall' (mirrors 'runLLMScripted'). Remember
-- returns sequential ids; Forget is a no-op. State: (next id, remaining batches).
runMemoryScripted :: [[MemoryItem]] -> Eff (Memory : es) a -> Eff es a
runMemoryScripted batches = reinterpret (evalState (0 :: Int, batches)) $ \_ -> \case
  Remember _ -> do
    (n, bs) <- get @(Int, [[MemoryItem]])
    put (n + 1, bs)
    pure (MemoryId n)
  Recall _ -> do
    (n, bs) <- get @(Int, [[MemoryItem]])
    case bs of
      (x : xs) -> put (n, xs) >> pure x
      []       -> pure []
  Forget _ -> pure ()

-- | An in-memory append log in local State. Returns the result plus the
-- final live items (query-all order, no budget), for property tests.
runMemoryPure :: Eff (Memory : es) a -> Eff es (a, [MemoryItem])
runMemoryPure action = do
  (a, es) <- reinterpret (runState ([] :: [MemoryEntry])) (\_ -> \case
    Remember d -> do
      es <- get @[MemoryEntry]
      let n = length [() | Remembered _ <- es]
      put (es ++ [Remembered (itemOf d n)])
      pure (MemoryId n)
    Recall q -> queryLive q <$> get @[MemoryEntry]
    Forget i -> modify @[MemoryEntry] (++ [Forgot i])) action
  pure (a, queryLive (Query "" [] (maxBound :: Int)) es)

-- | Recall, then decode each item's content through the codec. The item is
-- always present; only the content decode can fail, so a 'Left' is a stale
-- memory (it no longer fits today's schema) with its 'MemoryItem' intact.
recallAs :: (Memory :> es) => JSONCodec a -> Query -> Eff es [(MemoryItem, Either DecodeError a)]
recallAs c q = map (\m -> (m, decodeLLM c m.content)) <$> recall q
