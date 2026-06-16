# Durable Execution — Phase 0: In-Memory Journal Replay Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the in-memory replay core of crucible's durable execution substrate — a keyed, portable `Journal` plus `record`/`replay` primitives whose `MissPolicy` makes a code change surface as a first-class `Divergence`.

**Architecture:** A new domain-agnostic module `Crucible.Journal` in the house style of `Crucible.Ledger`: pure data types, an effectful pair of primitives over `State Journal` (so they are `runPureEff`-testable, exactly like `runLedgerState`), and an autodocodec wire codec that fixes the portable journal format early. No storage, no worker, no domain effects, no IO — those are Phase 1+. The journal is a keyed association list (`[(CassetteKey, Entry)]`), mirroring `Crucible.Ledger`'s plain-list event log (O(n) scans, "fine at these sizes"), which avoids adding a `containers` dependency.

**Tech Stack:** GHC 9.12.2 via zinc; `effectful` (`State.Static.Local`, `Error.Static`); `autodocodec` via `Crucible.Codec`; `base64-bytestring` (already a lib dep) for the codec. Tests are appended to the single `runChecks [...]` list in `test/Spec.hs`.

**Spec:** `docs/superpowers/specs/2026-06-15-durable-execution-design.md` (this is "Phase 0 — replay core").
**Tracker:** `crucible-9t3` (Phase 0), under epic `crucible-w0k`. Claim with `bd update crucible-9t3 --claim` before starting.

---

## Conventions for the executor (read once)

- **Build:** `nix develop -c zinc build` — compiles lib + test. A new file under `src/` is auto-discovered (zinc `[build.lib]` uses `source-dirs = ["src"]`, no module list); **no `zinc.toml` change is needed** (verify: `Crucible.Ledger` is registered nowhere yet compiles).
- **Test:** `nix develop -c zinc test` — runs `test/Spec.hs`, printing `ok <name>` / `FAIL <name>` lines and a final `ALL PASS` or `FAILURES`.
- **In Haskell, "the test fails first" means the build fails** (e.g. `Could not find module 'Crucible.Journal'` or `Variable not in scope`). That is the red state. Implement, then build+test goes green.
- **Module style:** copy the pragma block and shape of `src/Crucible/Ledger.hs`. Use plain record selectors (this module does **not** enable `NoFieldSelectors`).
- **Where tests go:** `test/Spec.hs` has one top-level `main = runChecks [ <check>, <check>, ... ]`. Append new `, check ...` entries at the **end of that list**. Locate the closing bracket with:
  ```bash
  grep -n '^  ]$' test/Spec.hs | tail -1
  ```
  Insert the new entries immediately before that `  ]` line. Top-level helper defs (`encInt`, `decInt`) go anywhere at top level — put them just above `main`.

---

## File Structure

- **Create `src/Crucible/Journal.hs`** — the entire Phase 0 surface: types (`CassetteKey`, `Entry`, `JournalIdentity`, `Journal`, `MissPolicy`, `Divergence`, `ReplayOutcome`, `JournalError`), pure ops (`mkKey`, `emptyJournal`, `lookupEntry`, `insertEntry`), the primitives (`record`, `replay`), and the wire codec (`journalCodec`).
- **Modify `test/Spec.hs`** — add imports near the existing import block; add `encInt`/`decInt` helpers above `main`; append `check` entries to the `runChecks` list.
- **Create `docs/journal.md`** — a short usage note, matching the per-effect docs shipped with `Crucible.Ledger`/`Crucible.Agents`.

---

## Task 1: `Crucible.Journal` — types and pure operations

**Files:**
- Create: `src/Crucible/Journal.hs`
- Modify: `test/Spec.hs` (imports + helpers + checks)

- [ ] **Step 1: Add imports and helpers to `test/Spec.hs`**

Add to the import block (just after the other `import qualified Crucible.* as *` lines, e.g. below the `Crucible.Ledger` imports near line 83). Use **qualified** effectful imports to avoid clashing with existing imports:

```haskell
import qualified Crucible.Journal as J
import Crucible.Journal (Journal (..), JournalIdentity (..), Entry (..), CassetteKey (..), MissPolicy (..), Divergence (..), ReplayOutcome (..), JournalError (..))
import qualified Effectful.State.Static.Local as ES
import qualified Effectful.Error.Static as EE
```

Add these top-level helpers just above `main`:

```haskell
-- Phase 0 journal tests: encode/decode an Int as the recorded result bytes.
encInt :: Int -> BC.ByteString
encInt = BC.pack . show

decInt :: BC.ByteString -> Either Data.Text.Text Int
decInt b = case reads (BC.unpack b) of
  [(n, "")] -> Right n
  _         -> Left "bad int"
```

- [ ] **Step 2: Add the failing checks** to the end of the `runChecks` list (before the final `  ]`)

```haskell
  , check "journal: empty journal has no entries"
      (0 :: Int)
      (length (J.jEntries (J.emptyJournal (J.JournalIdentity "wf" "" "v1"))))
  , check "journal: insert then lookup returns the bytes with seq 0"
      (Just (0 :: Int, "6"))
      (let k = J.mkKey "double" ["3"]
           j = J.insertEntry k (encInt 6) (J.emptyJournal (J.JournalIdentity "double" "" "v1"))
       in (\e -> (J.eSeq e, BC.unpack (J.eResult e))) <$> J.lookupEntry k j)
  , check "journal: lookup of an absent key is Nothing"
      (Nothing :: Maybe Int)
      (let j = J.emptyJournal (J.JournalIdentity "double" "" "v1")
       in J.eSeq <$> J.lookupEntry (J.mkKey "double" ["3"]) j)
  , check "journal: two inserts get sequential seqs"
      [0 :: Int, 1]
      (let j0 = J.emptyJournal (J.JournalIdentity "double" "" "v1")
           j1 = J.insertEntry (J.mkKey "double" ["3"]) (encInt 6) j0
           j2 = J.insertEntry (J.mkKey "double" ["4"]) (encInt 8) j1
       in map (J.eSeq . snd) (J.jEntries j2))
  , check "journal: distinct args produce distinct keys"
      False
      (J.mkKey "double" ["3"] == J.mkKey "double" ["4"])
  , check "journal: same op+args produce equal keys"
      True
      (J.mkKey "double" ["3"] == J.mkKey "double" ["3"])
```

- [ ] **Step 3: Run the build to verify it fails**

Run: `nix develop -c zinc build`
Expected: FAIL — `Could not find module 'Crucible.Journal'`.

- [ ] **Step 4: Create `src/Crucible/Journal.hs`**

```haskell
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
```

- [ ] **Step 5: Build and run the Task 1 checks**

Run: `nix develop -c zinc build && nix develop -c zinc test`
Expected: build succeeds; the six `journal:` checks from this task print `ok ...`. (Other modules' checks unchanged.)

- [ ] **Step 6: Commit**

```bash
git add src/Crucible/Journal.hs test/Spec.hs
git commit -m "feat(journal): keyed portable journal types + pure ops"
```

---

## Task 2: the `record` primitive (effectful, over `State Journal`)

`record` is already written in the Task 1 module body. This task proves it through the effect, the way `runLedgerState` is exercised.

**Files:**
- Modify: `test/Spec.hs` (checks only)

- [ ] **Step 1: Add the failing checks** (before the final `  ]`)

```haskell
  , check "journal: record returns the live value and appends one entry"
      (6 :: Int, 1 :: Int)
      (let ident = J.JournalIdentity "double" "" "v1"
           (a, j) = runPureEff (ES.runState (J.emptyJournal ident)
                      (J.record (J.mkKey "double" ["3"]) encInt (pure (6 :: Int))))
       in (a, length (J.jEntries j)))
  , check "journal: recorded bytes are recoverable by key"
      (Just "6")
      (let ident = J.JournalIdentity "double" "" "v1"
           (_, j) = runPureEff (ES.runState (J.emptyJournal ident)
                      (J.record (J.mkKey "double" ["3"]) encInt (pure (6 :: Int))))
       in BC.unpack . J.eResult <$> J.lookupEntry (J.mkKey "double" ["3"]) j)
  , check "journal: two records append in order with sequential seqs"
      [0 :: Int, 1]
      (let ident = J.JournalIdentity "calc" "" "v1"
           (_, j) = runPureEff (ES.runState (J.emptyJournal ident) (do
                      _ <- J.record (J.mkKey "double" ["3"]) encInt (pure (6 :: Int))
                      J.record (J.mkKey "triple" ["3"]) encInt (pure (9 :: Int))))
       in map (J.eSeq . snd) (J.jEntries j))
```

- [ ] **Step 2: Build to verify these compile and run**

Run: `nix develop -c zinc build && nix develop -c zinc test`
Expected: the three new checks print `ok ...`. (No implementation change — `record` exists; if a check fails, fix the test, not the module.)

- [ ] **Step 3: Commit**

```bash
git add test/Spec.hs
git commit -m "test(journal): record primitive over State Journal"
```

---

## Task 3: the `replay` primitive — hit, all three miss policies, decode error

`replay` is already written in Task 1. This task pins every branch.

**Files:**
- Modify: `test/Spec.hs` (checks only)

- [ ] **Step 1: Add the failing checks** (before the final `  ]`)

```haskell
  , check "journal: replay hit returns Replayed with the decoded value"
      (Right (J.Replayed (6 :: Int)))
      (fmap fst (runPureEff (EE.runErrorNoCallStack
        (ES.runState
          (J.insertEntry (J.mkKey "double" ["3"]) (encInt 6) (J.emptyJournal (J.JournalIdentity "double" "" "v1")))
          (J.replay J.Signal (J.mkKey "double" ["3"]) decInt (pure 0))))))
  , check "journal: replay miss under Signal flags divergence and runs live"
      (Right (J.Diverged (J.Divergence (J.mkKey "double" ["99"])) (198 :: Int)))
      (fmap fst (runPureEff (EE.runErrorNoCallStack
        (ES.runState (J.emptyJournal (J.JournalIdentity "double" "" "v1"))
          (J.replay J.Signal (J.mkKey "double" ["99"]) decInt (pure 198))))))
  , check "journal: replay miss under Fallthrough runs live silently (no divergence)"
      (Right (J.Replayed (198 :: Int)))
      (fmap fst (runPureEff (EE.runErrorNoCallStack
        (ES.runState (J.emptyJournal (J.JournalIdentity "double" "" "v1"))
          (J.replay J.Fallthrough (J.mkKey "double" ["99"]) decInt (pure 198))))))
  , check "journal: replay miss under Fail aborts with MissError"
      (Left (J.MissError (J.mkKey "double" ["99"])) :: Either J.JournalError (J.ReplayOutcome Int))
      (fmap fst (runPureEff (EE.runErrorNoCallStack
        (ES.runState (J.emptyJournal (J.JournalIdentity "double" "" "v1"))
          (J.replay J.Fail (J.mkKey "double" ["99"]) decInt (pure 0))))))
  , check "journal: replay hit with undecodable bytes is a DecodeError"
      (Left (J.DecodeError (J.mkKey "double" ["3"]) "bad int") :: Either J.JournalError (J.ReplayOutcome Int))
      (fmap fst (runPureEff (EE.runErrorNoCallStack
        (ES.runState
          (J.insertEntry (J.mkKey "double" ["3"]) (BC.pack "not-a-number") (J.emptyJournal (J.JournalIdentity "double" "" "v1")))
          (J.replay J.Signal (J.mkKey "double" ["3"]) decInt (pure 0))))))
```

- [ ] **Step 2: Build and run**

Run: `nix develop -c zinc build && nix develop -c zinc test`
Expected: all five checks print `ok ...`.

- [ ] **Step 3: Commit**

```bash
git add test/Spec.hs
git commit -m "test(journal): replay hit + Fail/Signal/Fallthrough miss + decode error"
```

---

## Task 4: the portable wire codec round-trips

`journalCodec` is written in Task 1. This task proves the format round-trips, fixing it for later phases.

**Files:**
- Modify: `test/Spec.hs` (checks only)

- [ ] **Step 1: Add the failing checks** (before the final `  ]`)

```haskell
  , check "journal: codec round-trips a journal with identity + entries"
      (Right True)
      (let j0 = J.emptyJournal (J.JournalIdentity "calc" "the-input" "sha-abc")
           j  = J.insertEntry (J.mkKey "triple" ["3"]) (encInt 9)
                  (J.insertEntry (J.mkKey "double" ["3"]) (encInt 6) j0)
           v  = toJSONVia J.journalCodec j
       in fmap (== j) (AT.parseEither (parseJSONVia J.journalCodec) v))
  , check "journal: codec round-trips an empty journal"
      (Right True)
      (let j = J.emptyJournal (J.JournalIdentity "wf" "" "v1")
           v = toJSONVia J.journalCodec j
       in fmap (== j) (AT.parseEither (parseJSONVia J.journalCodec) v))
```

- [ ] **Step 2: Build and run**

Run: `nix develop -c zinc build && nix develop -c zinc test`
Expected: both checks print `ok ...`. (`toJSONVia`, `parseJSONVia`, `AT` are already imported in `Spec.hs`.)

- [ ] **Step 3: Commit**

```bash
git add test/Spec.hs
git commit -m "test(journal): portable wire codec round-trips"
```

---

## Task 5: end-to-end story — record original code, replay changed code, surface the diverged op

The Phase 0 thesis in one check: a journal recorded by the *original* program is replayed by *changed* code; the unchanged op replays (`Replayed`), the new op surfaces a `Divergence`.

**Files:**
- Modify: `test/Spec.hs` (checks only)

- [ ] **Step 1: Add the failing check** (before the final `  ]`)

```haskell
  , check "journal: record-then-replay-changed surfaces exactly the new op as Diverged"
      (Right [J.Replayed (6 :: Int), J.Diverged (J.Divergence (J.mkKey "triple" ["3"])) 9])
      (let ident = J.JournalIdentity "calc" "" "v1"
           -- original code recorded only `double 3`
           (_, j) = runPureEff (ES.runState (J.emptyJournal ident)
                      (J.record (J.mkKey "double" ["3"]) encInt (pure (6 :: Int))))
           -- changed code keeps `double 3` (hits) and adds `triple 3` (diverges)
       in fmap fst (runPureEff (EE.runErrorNoCallStack (ES.runState j (do
            a <- J.replay J.Signal (J.mkKey "double" ["3"]) decInt (pure 6)
            b <- J.replay J.Signal (J.mkKey "triple" ["3"]) decInt (pure 9)
            pure [a, b])))))
```

- [ ] **Step 2: Build and run**

Run: `nix develop -c zinc build && nix develop -c zinc test`
Expected: the check prints `ok ...`; the run ends `ALL PASS`.

- [ ] **Step 3: Commit**

```bash
git add test/Spec.hs
git commit -m "test(journal): end-to-end record/replay-changed divergence story"
```

---

## Task 6: usage doc

**Files:**
- Create: `docs/journal.md`

- [ ] **Step 1: Write `docs/journal.md`**

```markdown
# Crucible.Journal — the durable execution replay core (Phase 0)

A `Journal` is a keyed, portable recording of an effectful program's operations.
It is the in-memory core of crucible's durable execution substrate (see
`docs/superpowers/specs/2026-06-15-durable-execution-design.md`); later phases
back it with Postgres + a worker and build orchestration on top.

## Model

- `mkKey op parts` — a `CassetteKey` from an operation name and already-
  normalized argument parts. The app strips volatile fields before keying.
- `record key encode action` — run `action` live and append its encoded result.
  This is the production / capture path.
- `replay policy key decode live` — serve a recorded result. On a miss the
  `MissPolicy` decides: `Fail` aborts (crash-recovery strictness), `Signal`
  runs `live` and flags a `Divergence` (eval: a miss is the measurement),
  `Fallthrough` runs `live` silently.

Keys are content-addressed, so changed code replaying an old journal hits the
ops it shares and diverges on the rest — divergence is a first-class
`ReplayOutcome`, not a desync.

## Example

```haskell
-- record (live): run the real op, journal its result
(_, j) <- pure $ runPureEff $ runState (emptyJournal ident) $
  record (mkKey "lookupTwin" [machineIdBytes]) encodeTwin (lookupTwinLive mid)

-- replay (eval): re-run changed code against the recording
runPureEff $ runErrorNoCallStack $ runState j $
  replay Signal (mkKey "lookupTwin" [machineIdBytes]) decodeTwin (lookupTwinLive mid)
```

`record`/`replay` run over `State Journal`, so they are `runPureEff`-testable.
Persisting the journal uses `journalCodec` (a stable, base64-framed JSON form).
```

- [ ] **Step 2: Commit**

```bash
git add docs/journal.md
git commit -m "docs(journal): Phase 0 usage note"
```

---

## Self-Review

**Spec coverage (Phase 0 = "replay core"):**
- `Journal` keyed + portable identity → Task 1 (`Journal`, `JournalIdentity`, keyed assoc list). ✓
- `MissPolicy` (`Fail`/`Signal`/`Fallthrough`) → Task 1 type, Task 3 behaviour. ✓
- `record`/`replay` primitives → Task 1 code, Tasks 2–3 behaviour. ✓
- Divergence surfaced → `ReplayOutcome`/`Divergence`, Tasks 3 & 5. ✓
- In-memory store, pure-testable → `State Journal` + `runPureEff`, all tasks. ✓
- Portable format fixed early (open Q2: codec/format) → `journalCodec`, Task 4. ✓
- Out of Phase 0 (correctly deferred): IO sink, Postgres backing, worker, `Workflow` orchestration effect, `Fake` policy, captured-at clock, hashing of keys. Noted in module haddock + spec phasing.

**Placeholder scan:** none — every step has full code and exact commands.

**Type consistency:** `CassetteKey`/`Entry`/`Journal`/`MissPolicy`/`Divergence`/`ReplayOutcome`/`JournalError` and `mkKey`/`emptyJournal`/`lookupEntry`/`insertEntry`/`record`/`replay`/`journalCodec` are used identically across tasks; `record` takes `(a -> ByteString)`, `replay` takes `(ByteString -> Either Text a)` + a live `Eff es a` and returns `ReplayOutcome a`, consistent in every test. Qualified `ES.`/`EE.` avoid import clashes with `Spec.hs`.

**Dependency check:** uses only declared lib deps (`base`, `bytestring`, `text`, `effectful`, `autodocodec` via `Crucible.Codec`, `base64-bytestring`). No `containers` (assoc list instead). No `zinc.toml` change.
