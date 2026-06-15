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

-- | A small work ledger in the house style: an append-only log of work items
-- with a compare-and-set claim, so independent workers (or sessions) can pull
-- one item each without colliding. Structurally a sibling of 'Crucible.Memory':
-- events appended on write, folded on read. 'runLedgerState' is the in-memory
-- test interpreter; 'runLedgerFile' is a git-diffable JSONL store that outlives
-- a session. 'claim' succeeds only when the item is still 'Ready'.
module Crucible.Ledger
  ( WorkId (..)
  , WorkState (..)
  , WorkItem (..)
  , Ledger (..)
  , record, claim, complete, listReady
  , runLedgerState
  , runLedgerFile
  , LedgerStore (..)
  , runLedgerWith
  , ledgerStoreFile
  , ledgerStorePure
  , newLedgerStorePure
  , workStateCodec
  , workItemCodec
  ) where

import Control.Exception (IOException, try)
import Data.IORef (IORef, newIORef, readIORef, atomicModifyIORef')
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (runState, get, put, modify)

import Crucible.Codec (JSONCodec, object, field, optField, enum, str, int, bimapCodec, dimapCodec, encodeText)
import Crucible.Decode (decodeLLM)

newtype WorkId = WorkId Int deriving (Eq, Show)

widInt :: WorkId -> Int
widInt (WorkId i) = i

data WorkState = Ready | Claimed | Done
  deriving (Eq, Show)

data WorkItem = WorkItem
  { wid      :: WorkId
  , payload  :: Text
  , state    :: WorkState
  , claimant :: Maybe Text
  }
  deriving (Eq, Show)

data Ledger :: Effect where
  Record    :: Text -> Ledger m WorkId
  Claim     :: WorkId -> Text -> Ledger m Bool
  Complete  :: WorkId -> Ledger m ()
  ListReady :: Ledger m [WorkItem]
type instance DispatchOf Ledger = Dynamic

record :: (Ledger :> es) => Text -> Eff es WorkId
record = send . Record

claim :: (Ledger :> es) => WorkId -> Text -> Eff es Bool
claim w who = send (Claim w who)

complete :: (Ledger :> es) => WorkId -> Eff es ()
complete = send . Complete

listReady :: (Ledger :> es) => Eff es [WorkItem]
listReady = send ListReady

data LedgerEvent
  = EvRecorded  WorkId Text
  | EvClaimed   WorkId Text
  | EvCompleted WorkId
  deriving (Eq, Show)

-- | Fold the event log into the current work items, in record order. Rescans
-- the log per recorded item (O(items * events)); fine at ledger sizes, like the
-- sibling fold in 'Crucible.Memory'.
foldItems :: [LedgerEvent] -> [WorkItem]
foldItems evs = map build recorded
  where
    recorded = [(i, p) | EvRecorded i p <- evs]
    build (i, p) = foldl step (WorkItem i p Ready Nothing) evs
      where
        step it = \case
          EvClaimed j who | j == i -> it { state = Claimed, claimant = Just who }
          EvCompleted j   | j == i -> it { state = Done }
          _ -> it

-- | The Ready items, in record order.
readyOf :: [LedgerEvent] -> [WorkItem]
readyOf = filter (\it -> it.state == Ready) . foldItems

-- | The current state of one id, if it exists.
stateOf :: WorkId -> [LedgerEvent] -> Maybe WorkState
stateOf w evs = case [it | it <- foldItems evs, it.wid == w] of
  (it : _) -> Just it.state
  []       -> Nothing

-- | In-memory interpreter (tests). Returns the result and the final ledger
-- (every item, record order, any state) for assertions.
runLedgerState :: Eff (Ledger : es) a -> Eff es (a, [WorkItem])
runLedgerState action = do
  (a, evs) <- reinterpret (runState ([] :: [LedgerEvent])) (\_ -> \case
    Record p -> do
      evs <- get @[LedgerEvent]
      let n = length [() | EvRecorded _ _ <- evs]
      put (evs ++ [EvRecorded (WorkId n) p])
      pure (WorkId n)
    Claim w who -> do
      evs <- get @[LedgerEvent]
      case stateOf w evs of
        Just Ready -> put (evs ++ [EvClaimed w who]) >> pure True
        _          -> pure False
    Complete w -> modify @[LedgerEvent] (++ [EvCompleted w])
    ListReady -> readyOf <$> get @[LedgerEvent]) action
  pure (a, foldItems evs)

workIdCodec :: JSONCodec WorkId
workIdCodec = dimapCodec WorkId widInt int

workStateCodec :: JSONCodec WorkState
workStateCodec = enum [("ready", Ready), ("claimed", Claimed), ("done", Done)]

workItemCodec :: JSONCodec WorkItem
workItemCodec = object (WorkItem
  <$> field "id"       ((.wid)      :: WorkItem -> WorkId)   workIdCodec
  <*> field "payload"  ((.payload)  :: WorkItem -> Text)     str
  <*> field "state"    ((.state)    :: WorkItem -> WorkState) workStateCodec
  <*> optField "claimant" ((.claimant) :: WorkItem -> Maybe Text) str)

data RawEvent = RawEvent { event :: Text, rid :: Maybe WorkId, payload :: Maybe Text, by :: Maybe Text }

eventCodec :: JSONCodec LedgerEvent
eventCodec = bimapCodec toE fromE
  (object (RawEvent <$> field "event" ((.event)   :: RawEvent -> Text)       str
                    <*> optField "id"      ((.rid)     :: RawEvent -> Maybe WorkId)  workIdCodec
                    <*> optField "payload" ((.payload) :: RawEvent -> Maybe Text)    str
                    <*> optField "by"      ((.by)      :: RawEvent -> Maybe Text)    str))
  where
    toE r = case r.event of
      "recorded"  -> maybe (Left "recorded event needs id and payload") Right
                       (EvRecorded <$> r.rid <*> r.payload)
      "claimed"   -> maybe (Left "claimed event needs id and by") Right
                       (EvClaimed <$> r.rid <*> r.by)
      "completed" -> maybe (Left "completed event needs an id") (Right . EvCompleted) r.rid
      other       -> Left ("unknown event: " <> T.unpack other)
    fromE (EvRecorded i p)  = RawEvent "recorded" (Just i) (Just p) Nothing
    fromE (EvClaimed i who) = RawEvent "claimed" (Just i) Nothing (Just who)
    fromE (EvCompleted i)   = RawEvent "completed" (Just i) Nothing Nothing

-- | Read the event log, tolerant of blank/garbled lines (skipped).
readLog :: FilePath -> IO [LedgerEvent]
readLog path = do
  r <- try (TIO.readFile path) :: IO (Either IOException Text)
  let contents = either (const "") Prelude.id r
  pure [e | ln <- T.lines contents, not (T.null (T.strip ln))
          , Right e <- [decodeLLM eventCodec ln]]

appendEvent :: FilePath -> LedgerEvent -> IO ()
appendEvent path e = TIO.appendFile path (encodeText eventCodec e <> "\n")

-- | A thick backend handle: one 'IO' action per 'Ledger' operation. The seam
-- that lets a backend be a parameter of the interpreter rather than a fresh
-- interpreter per backend.
data LedgerStore = LedgerStore
  { doRecord    :: Text -> IO WorkId
  , doClaim     :: WorkId -> Text -> IO Bool
  , doComplete  :: WorkId -> IO ()
  , doListReady :: IO [WorkItem]
  }

-- | Run 'Ledger' against a thick handle (near-passthrough).
runLedgerWith :: (IOE :> es) => LedgerStore -> Eff (Ledger : es) a -> Eff es a
runLedgerWith s = interpret $ \_ -> \case
  Record p    -> liftIO (s.doRecord p)
  Claim w who -> liftIO (s.doClaim w who)
  Complete w  -> liftIO (s.doComplete w)
  ListReady   -> liftIO s.doListReady

-- | JSONL-file backend as a handle. Single-writer; the read-then-append in
-- doRecord/doClaim is not atomic (concurrent writers can collide), same caveat
-- as the original interpreter.
ledgerStoreFile :: FilePath -> LedgerStore
ledgerStoreFile path = LedgerStore
  { doRecord = \p -> do
      evs <- readLog path
      let n = length [() | EvRecorded _ _ <- evs]
      appendEvent path (EvRecorded (WorkId n) p)
      pure (WorkId n)
  , doClaim = \w who -> do
      evs <- readLog path
      case stateOf w evs of
        Just Ready -> appendEvent path (EvClaimed w who) >> pure True
        _          -> pure False
  , doComplete  = \w -> appendEvent path (EvCompleted w)
  , doListReady = readyOf <$> readLog path
  }

-- | In-memory backend as a handle over an 'IORef' of the event log. The IO
-- analogue of 'runLedgerState'. 'atomicModifyIORef'' makes record/claim atomic
-- within a single process.
ledgerStorePure :: IORef [LedgerEvent] -> LedgerStore
ledgerStorePure ref = LedgerStore
  { doRecord = \p -> atomicModifyIORef' ref $ \evs ->
      let n = length [() | EvRecorded _ _ <- evs]
      in (evs ++ [EvRecorded (WorkId n) p], WorkId n)
  , doClaim = \w who -> atomicModifyIORef' ref $ \evs ->
      case stateOf w evs of
        Just Ready -> (evs ++ [EvClaimed w who], True)
        _          -> (evs, False)
  , doComplete  = \w -> atomicModifyIORef' ref (\evs -> (evs ++ [EvCompleted w], ()))
  , doListReady = readyOf <$> readIORef ref
  }

-- | Allocate a fresh in-memory ledger handle (its own empty 'IORef' event log).
-- Convenience so callers/tests need no access to the internal 'LedgerEvent'.
newLedgerStorePure :: IO LedgerStore
newLedgerStorePure = ledgerStorePure <$> newIORef []

-- | A JSONL log at the path: Record/Claim/Complete append one line; ListReady
-- reads and folds. id = count of prior Recorded events. git-diffable, outlives
-- sessions. Single-writer: each Record/Claim does a read-then-append, which is
-- not atomic, so concurrent calls from separate threads or processes can assign
-- duplicate ids or let two claims of one item both observe Ready.
runLedgerFile :: (IOE :> es) => FilePath -> Eff (Ledger : es) a -> Eff es a
runLedgerFile path = runLedgerWith (ledgerStoreFile path)
