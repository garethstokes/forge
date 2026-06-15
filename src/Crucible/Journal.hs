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
    -- * Wire codec
  , journalCodec
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.List as L
import Data.Text (Text)
import qualified Data.Text.Encoding as TE

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
-- capture. (A captured-at timestamp is added in Phase 1, where a clock exists.)
data JournalIdentity = JournalIdentity
  { jiWorkflowType :: Text
  , jiInput        :: ByteString
  , jiAppVersion   :: Text
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

lookupEntry :: CassetteKey -> Journal -> Maybe Entry
lookupEntry k = L.lookup k . jEntries

-- | Append an entry under a key, assigning the next sequence number. Last write
-- wins on a duplicate key; a caller that genuinely repeats one op with
-- identical normalized args disambiguates by adding a call index to the parts.
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
-- path of live execution.
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
  <*> field "appVersion"   jiAppVersion   str)

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
