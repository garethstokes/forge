{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | Phase 0 of crucible's durable execution substrate: the in-memory journal
-- replay core. A 'Journal' is a keyed, portable recording of an effectful
-- program's operations. 'record' runs an op live and appends its result;
-- 'replay' serves a recorded result, and on a miss applies a 'MissPolicy' so a
-- code change surfaces as a first-class 'Divergence' rather than a desync.
--
-- Domain-agnostic: this module defines no domain effect and owns no storage.
-- The app supplies operation keys (already normalized) and result codecs; a
-- later phase backs the journal with Postgres and a worker. The primitives run
-- over 'State' 'Journal' so they are 'runPureEff'-testable, exactly like
-- 'Crucible.Ledger.runLedgerState'.
module Crucible.Journal
  ( -- * Keys
    CassetteKey (..)
  , mkKey
    -- * Journal
  , Entry (..)
  , JournalIdentity (..)
  , Journal (..)
  , emptyJournal
  , lookupEntry
  , insertEntry
    -- * Replay semantics
  , MissPolicy (..)
  , Divergence (..)
  , ReplayOutcome (..)
  , JournalError (..)
    -- * Primitives
  , record
  , replay
    -- * IO journal store (thick handle)
  , JournalStore (..)
  , recordTo
  , replayFrom
  , newInMemoryJournalStore
    -- * Wire codec
  , journalCodec
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.List as L
import Data.Text (Text)
import qualified Data.Text.Encoding as TE

import Data.IORef (newIORef, readIORef, modifyIORef')

import Effectful
import Effectful.State.Static.Local (State, get, modify)
import Effectful.Error.Static (Error, throwError)

import Crucible.Codec (JSONCodec, object, field, list', str, int, bimapCodec, dimapCodec)

-- | A content key for one recorded operation: an operation name plus
-- already-normalized argument parts, joined by a unit separator. crucible
-- imposes no normalization — the caller (the app) strips volatile fields
-- (timestamps, request-ids, auth) before building the key. The structured bytes
-- ARE the key (no hashing): dependency-free and debuggable; hashing is a later
-- optimization if keys grow large.
newtype CassetteKey = CassetteKey ByteString
  deriving (Eq, Ord, Show)

-- | Build a 'CassetteKey' from an op name and normalized argument parts, joined
-- by the 0x1f unit separator. Parts must not themselves contain 0x1f (the key is
-- not escaped or length-prefixed), or two distinct part lists could collide.
mkKey :: Text -> [ByteString] -> CassetteKey
mkKey op parts = CassetteKey (BS.intercalate sep (TE.encodeUtf8 op : parts))
  where sep = BS.pack [0x1f]  -- ASCII unit separator

-- | One recorded operation result: its append order and its encoded bytes.
data Entry = Entry
  { eSeq    :: Int
  , eResult :: ByteString
  } deriving (Eq, Show)

-- | Identity that makes a journal portable: enough to re-run the workflow from
-- scratch in a different process / at a later time / against changed code.
-- 'jiInput' is the raw workflow input; 'jiAppVersion' is the app's git sha at
-- capture; 'jiCapturedAt' is the ISO-8601 wall-clock time of capture.
data JournalIdentity = JournalIdentity
  { jiWorkflowType :: Text
  , jiInput        :: ByteString
  , jiAppVersion   :: Text
  , jiCapturedAt   :: Text
  } deriving (Eq, Show)

-- | A keyed recording. Entries are a plain association list in append order
-- (like 'Crucible.Ledger''s event log): keyed lookup tolerates out-of-order
-- replay and makes a miss a localized 'Divergence' rather than a cascading
-- desync — the property that lets changed code replay against an old journal.
data Journal = Journal
  { jIdentity :: JournalIdentity
  , jEntries  :: [(CassetteKey, Entry)]
  } deriving (Eq, Show)

emptyJournal :: JournalIdentity -> Journal
emptyJournal ident = Journal ident []

-- | The most recent entry recorded under a key (last write wins), or 'Nothing'.
-- The full append-only list is retained (ordering/audit); only the read picks the
-- latest, so a re-'record' of the same key is served correctly on replay.
lookupEntry :: CassetteKey -> Journal -> Maybe Entry
lookupEntry k = L.foldl' (\acc (k', e) -> if k' == k then Just e else acc) Nothing . jEntries

-- | Append an entry under a key, assigning the next sequence number. The list is
-- append-only (history retained); 'lookupEntry' returns the latest entry for a
-- key, so a duplicate key is last-write-wins on read. Callers should still key
-- each op call uniquely — disambiguate a genuine repeat of one op with identical
-- normalized args by adding a call-index part — so replay is unambiguous.
insertEntry :: CassetteKey -> ByteString -> Journal -> Journal
insertEntry k bs j = j { jEntries = jEntries j ++ [(k, Entry (length (jEntries j)) bs)] }

-- | What to do when 'replay' finds no entry for a key.
--
--   * 'Fail'        — abort with 'MissError' (crash-recovery strictness).
--   * 'Signal'      — run the live fallthrough and flag a 'Divergence' (eval:
--                     a miss is the measurement, not an error).
--   * 'Fallthrough' — run the live fallthrough silently, no divergence.
data MissPolicy = Fail | Signal | Fallthrough
  deriving (Eq, Show)

-- | A recorded code/behaviour divergence: the key the replay expected but the
-- journal did not contain.
newtype Divergence = Divergence { dKey :: CassetteKey }
  deriving (Eq, Show)

-- | The result of a 'replay': either served from the journal (or a silent
-- fallthrough), or a 'Signal'-policy miss carrying the live value so the
-- workflow can continue and still be graded.
data ReplayOutcome a
  = Replayed a
  | Diverged Divergence a
  deriving (Eq, Show, Functor)

data JournalError
  = MissError CassetteKey
  | DecodeError CassetteKey Text
  deriving (Eq, Show)

-- | Run a live action and append its encoded result under the key. The record
-- path of live execution. The key should be unique per op call (see 'mkKey'):
-- recording the same key twice retains both entries but replay serves the latest.
record :: (State Journal :> es)
       => CassetteKey -> (a -> ByteString) -> Eff es a -> Eff es a
record k enc act = do
  a <- act
  modify (insertEntry k (enc a))
  pure a

-- | Serve an op from the journal. On a hit, decode the recorded result (a
-- decode failure is a 'DecodeError'). On a miss, apply the 'MissPolicy'.
replay :: (State Journal :> es, Error JournalError :> es)
       => MissPolicy -> CassetteKey
       -> (ByteString -> Either Text a)  -- ^ decode recorded bytes
       -> Eff es a                       -- ^ live fallthrough
       -> Eff es (ReplayOutcome a)
replay pol k dec live = do
  j <- get
  case lookupEntry k j of
    Just e -> case dec (eResult e) of
      Right a  -> pure (Replayed a)
      Left err -> throwError (DecodeError k err)
    Nothing -> case pol of
      Fail        -> throwError (MissError k)
      Signal      -> Diverged (Divergence k) <$> live
      Fallthrough -> Replayed <$> live

-- IO journal store ----------------------------------------------------------

-- | A thick handle: one IO action per journal op (the durable seam, à la
-- 'MemoryStore'). 'jsAppend' persists one recorded result. The in-memory store
-- ignores op; the Postgres store in crucible-manifest stores it in a column.
data JournalStore = JournalStore
  { jsLoad   :: IO Journal
  , jsAppend :: CassetteKey -> Text -> ByteString -> IO ()   -- ^ key, op, encoded result
  }

-- | Run a live action and durably append its encoded result. The store-backed
-- record path.
recordTo :: (IOE :> es)
         => JournalStore -> CassetteKey -> Text -> (a -> ByteString) -> Eff es a -> Eff es a
recordTo s k op enc act = do
  a <- act
  liftIO (jsAppend s k op (enc a))
  pure a

-- | Serve an op from a pre-loaded 'Journal' (a worker loads once per claim).
-- On a miss, apply the 'MissPolicy': 'Fail' → 'throwError' 'MissError';
-- 'Signal' → run live + 'Diverged'; 'Fallthrough' → run live as a plain
-- 'Replayed'. Decode failure on a hit is handled like a miss per policy.
replayFrom :: (IOE :> es, Error JournalError :> es)
           => Journal -> MissPolicy -> CassetteKey
           -> (ByteString -> Either Text a)
           -> Eff es a
           -> Eff es (ReplayOutcome a)
replayFrom j pol k dec live = case lookupEntry k j of
  Just e  -> case dec (eResult e) of
               Right a -> pure (Replayed a)
               Left _  -> onMiss
  Nothing -> onMiss
  where
    onMiss = case pol of
      Fail        -> throwError (MissError k)
      Signal      -> Diverged (Divergence k) <$> live
      Fallthrough -> Replayed <$> live

-- | In-memory store over an 'IORef' 'Journal' (testable; the Phase-3 eval
-- consumer uses it). Ignores op (the 'Entry' type has no op field — that is
-- tracked by the Postgres store's column).
newInMemoryJournalStore :: Journal -> IO JournalStore
newInMemoryJournalStore j0 = do
  ref <- newIORef j0
  pure JournalStore
    { jsLoad   = readIORef ref
    , jsAppend = \k _op bs -> modifyIORef' ref (insertEntry k bs)
    }

-- Wire codec ----------------------------------------------------------------

-- | A 'ByteString' as base64 text in JSON.
b64Codec :: JSONCodec ByteString
b64Codec = bimapCodec (B64.decode . TE.encodeUtf8) (TE.decodeUtf8 . B64.encode) str

cassetteKeyCodec :: JSONCodec CassetteKey
cassetteKeyCodec = dimapCodec CassetteKey (\(CassetteKey b) -> b) b64Codec

identityCodec :: JSONCodec JournalIdentity
identityCodec = object (JournalIdentity
  <$> field "workflowType" jiWorkflowType str
  <*> field "input"        jiInput        b64Codec
  <*> field "appVersion"   jiAppVersion   str
  <*> field "capturedAt"   jiCapturedAt   str)

-- A flat wire shape for one keyed entry.
data WireEntry = WireEntry CassetteKey Int ByteString

wireEntryCodec :: JSONCodec WireEntry
wireEntryCodec = object (WireEntry
  <$> field "key"    (\(WireEntry k _ _) -> k) cassetteKeyCodec
  <*> field "seq"    (\(WireEntry _ s _) -> s) int
  <*> field "result" (\(WireEntry _ _ r) -> r) b64Codec)

-- | The portable journal format. Stable from Phase 0 so later phases (Postgres,
-- manifest-evals) read the same bytes.
journalCodec :: JSONCodec Journal
journalCodec = object (mk
  <$> field "identity" jIdentity                       identityCodec
  <*> field "entries"  (map pairToWire . jEntries)     (list' wireEntryCodec))
  where
    mk ident wires = Journal ident (map wireToPair wires)
    pairToWire (k, Entry s r) = WireEntry k s r
    wireToPair (WireEntry k s r) = (k, Entry s r)
