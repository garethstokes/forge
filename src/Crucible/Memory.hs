{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
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
  , MemoryItemT (..)
  , MemoryItem
  , MemoryEntry (..)
  , Query (..)
  , Memory (..)
  , remember, recall, forget
  , recallAs
  , queryLive
  , runMemoryScripted
  , runMemoryPure
  , runMemoryFile
  , MemoryStore (..)
  , runMemoryWith
  , memoryStoreFile
  , memoryStorePure
  , newMemoryStorePure
  , memoryItemCodec
  , memoryKindCodec
  ) where

import Control.Exception (IOException, try)
import Data.Functor.Identity (Identity)
import Data.IORef (IORef, newIORef, readIORef, atomicModifyIORef')
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import GHC.Generics (Generic)
import Manifest.Core.Table (Field, Pk)

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (evalState, get, modify, put, runState)

import Crucible.Codec (JSONCodec, object, field, optField, enum, str, int, list', bimapCodec, dimapCodec, encodeText)
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

data MemoryItemT f = MemoryItem
  { memId     :: Field f (Pk MemoryId)
  , kind      :: Field f MemoryKind
  , content   :: Field f Text
  , tags      :: Field f [Text]
  , source    :: Field f Provenance
  , createdAt :: Field f Int
  }
  deriving Generic

type MemoryItem = MemoryItemT Identity

deriving instance Eq   (MemoryItemT Identity)
deriving instance Show (MemoryItemT Identity)

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

memoryKindCodec :: JSONCodec MemoryKind
memoryKindCodec = enum [("episodic", Episodic), ("semantic", Semantic), ("procedural", Procedural)]

memoryIdCodec :: JSONCodec MemoryId
memoryIdCodec = dimapCodec MemoryId idInt int

data RawProv = RawProv { by :: Text, name :: Maybe Text }

provenanceCodec :: JSONCodec Provenance
provenanceCodec = bimapCodec toP fromP
  (object (RawProv <$> field "by" (.by) str <*> optField "name" (.name) str))
  where
    toP r = case r.by of
      "skill"         -> maybe (Left "skill provenance needs a name") (Right . BySkill) r.name
      "session"       -> maybe (Left "session provenance needs a name") (Right . BySession) r.name
      "consolidation" -> Right ByConsolidation
      "curated"       -> Right Curated
      other           -> Left ("unknown provenance: " <> T.unpack other)
    fromP (BySkill n)     = RawProv "skill" (Just n)
    fromP (BySession n)   = RawProv "session" (Just n)
    fromP ByConsolidation = RawProv "consolidation" Nothing
    fromP Curated         = RawProv "curated" Nothing

memoryItemCodec :: JSONCodec MemoryItem
memoryItemCodec = object (MemoryItem
  <$> field "id"        (.memId)     memoryIdCodec
  <*> field "kind"      (.kind)      memoryKindCodec
  <*> field "content"   (.content)   str
  <*> field "tags"      (.tags)      (list' str)
  <*> field "source"    (.source)    provenanceCodec
  <*> field "createdAt" (.createdAt) int)

data RawEntry = RawEntry { entry :: Text, item :: Maybe MemoryItem, fid :: Maybe MemoryId }

entryCodec :: JSONCodec MemoryEntry
entryCodec = bimapCodec toE fromE
  (object (RawEntry <$> field "entry" (.entry) str
                    <*> optField "item" (.item) memoryItemCodec
                    <*> optField "id"   (.fid)  memoryIdCodec))
  where
    toE r = case r.entry of
      "remembered" -> maybe (Left "remembered entry needs an item") (Right . Remembered) r.item
      "forgot"     -> maybe (Left "forgot entry needs an id") (Right . Forgot) r.fid
      other        -> Left ("unknown entry: " <> T.unpack other)
    fromE (Remembered it) = RawEntry "remembered" (Just it) Nothing
    fromE (Forgot i)      = RawEntry "forgot" Nothing (Just i)

-- | Read the entry log, tolerant of blank/garbled lines (skipped).
readLog :: FilePath -> IO [MemoryEntry]
readLog path = do
  r <- try (TIO.readFile path) :: IO (Either IOException Text)
  let contents = either (const "") Prelude.id r
  pure [e | ln <- T.lines contents, not (T.null (T.strip ln))
          , Right e <- [decodeLLM entryCodec ln]]

appendEntry :: FilePath -> MemoryEntry -> IO ()
appendEntry path e = TIO.appendFile path (encodeText entryCodec e <> "\n")

-- | A thick backend handle: one 'IO' action per 'Memory' operation. The seam
-- that lets a backend (file, in-memory, or a future Postgres satellite) be a
-- parameter of the interpreter rather than a fresh interpreter per backend.
data MemoryStore = MemoryStore
  { doRemember :: MemoryDraft -> IO MemoryId
  , doRecall   :: Query       -> IO [MemoryItem]
  , doForget   :: MemoryId    -> IO ()
  }

-- | Run 'Memory' against a thick handle (near-passthrough).
runMemoryWith :: (IOE :> es) => MemoryStore -> Eff (Memory : es) a -> Eff es a
runMemoryWith s = interpret $ \_ -> \case
  Remember d -> liftIO (s.doRemember d)
  Recall q   -> liftIO (s.doRecall q)
  Forget i   -> liftIO (s.doForget i)

-- | JSONL-file backend as a handle. id = createdAt = count of prior Remembered
-- entries. Single-writer; the read-count-append in doRemember is not atomic
-- (same caveat as the original interpreter).
memoryStoreFile :: FilePath -> MemoryStore
memoryStoreFile path = MemoryStore
  { doRemember = \d -> do
      es <- readLog path
      let n = length [() | Remembered _ <- es]
      appendEntry path (Remembered (itemOf d n))
      pure (MemoryId n)
  , doRecall = \q -> queryLive q <$> readLog path
  , doForget = \i -> appendEntry path (Forgot i)
  }

-- | In-memory backend as a handle over an 'IORef' of the entry log. The IO
-- analogue of 'runMemoryPure'. 'atomicModifyIORef'' makes remember/forget atomic
-- within a single process.
memoryStorePure :: IORef [MemoryEntry] -> MemoryStore
memoryStorePure ref = MemoryStore
  { doRemember = \d -> atomicModifyIORef' ref $ \es ->
      let n = length [() | Remembered _ <- es]
      in (es ++ [Remembered (itemOf d n)], MemoryId n)
  , doRecall = \q -> queryLive q <$> readIORef ref
  , doForget = \i -> atomicModifyIORef' ref (\es -> (es ++ [Forgot i], ()))
  }

-- | Allocate a fresh in-memory memory handle (its own empty 'IORef' entry log).
newMemoryStorePure :: IO MemoryStore
newMemoryStorePure = memoryStorePure <$> newIORef []

-- | A JSONL log at the path. Remember/Forget append one line; Recall reads,
-- folds, filters, budgets. id = count of prior Remembered entries;
-- createdAt = the same ordinal (a uniform counter, not wall-clock).
-- git-diffable, lexical + tag matching. Single-writer: each Remember does a
-- read-count-append, which is not atomic, so concurrent Remember calls from
-- separate threads or processes can assign duplicate ids or interleave lines.
runMemoryFile :: (IOE :> es) => FilePath -> Eff (Memory : es) a -> Eff es a
runMemoryFile path = runMemoryWith (memoryStoreFile path)
