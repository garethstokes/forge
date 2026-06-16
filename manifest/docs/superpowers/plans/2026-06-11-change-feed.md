# Change Feed (z8h slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opted-in entities emit `pg_notify('manifest_<table>', <pk>)` on every session write; `Manifest.Notify.listenChanges` delivers `(table, pk)` wake-ups to subscribers on a dedicated connection.

**Architecture:** Two halves built listener-first (so emission is testable): `Manifest.Notify` (a blocking libpq LISTEN loop over a dedicated connection) and a `notifyChanges :: Bool` Entity member guarding one `emitChange` call in each session write path. Postgres provides commit-gating of NOTIFY for free. Wake-up-only semantics; no outbox.

**Tech Stack:** GHC 9.10.1, zinc, postgresql-libpq's async-notification API (`socket`/`consumeInput`/`notifies`), the in-repo Harness + `withEphemeralDb`.

**Spec:** `docs/superpowers/specs/2026-06-11-change-feed-design.md` · **Issue:** manifest-z8h (stays OPEN — this is slice 1)

**Verified repo facts:** `Manifest.Postgres` wraps `Database.PostgreSQL.LibPQ` directly (`Connection = PQ.Connection`); libpq's `PQ.socket :: Connection -> IO (Maybe Fd)`, `PQ.consumeInput`, `PQ.notifies :: Connection -> IO (Maybe Notify)` (with `notifyRelname`/`notifyExtra`) are available. `withEphemeralDb` builds its conninfo internally and does not expose it — the listener needs it, hence `withEphemeralDb'`. Write paths: `add` (Session.hs:166, INSERT + decode returning the row WITH its pk), `flushSave` (Session.hs:191, skips the UPDATE entirely when no column changed), `flushDelete` (Session.hs:214, after the cascade walk), `update`/`deleteWhere` (Session/Command.hs:22,32). `save` only queues — flushed by `flush`/autoflush. `SqlParam = Maybe ByteString`.

## File structure

- Create `src/Manifest/Notify.hs` — `Change`, `listenChanges`.
- Modify `src/Manifest/Testing.hs` — add `withEphemeralDb'` (conninfo-exposing), reimplement `withEphemeralDb` on it.
- Modify `src/Manifest/Entity.hs` — `notifyChanges` class member.
- Modify `src/Manifest/Session.hs` — `emitChange` + calls in `add`/`flushSave`/`flushDelete`; export `emitChange`.
- Modify `src/Manifest/Session/Command.hs` — calls in `update`/`deleteWhere`.
- Modify `src/Manifest.hs` — re-export `Change(..)`, `listenChanges` (both export sections; `notifyChanges` rides along in `Entity(..)`).
- Create `test/NotifySpec.hs`; Modify `test/Spec.hs`.
- Create `docs/change-feed.md`; Modify `docs/index.md` (nav), `zinc.toml` only if a dep is missing (expected: none — libpq + bytestring already there).

---

### Task 1: the listener (`Manifest.Notify` + `withEphemeralDb'`)

**Files:** Create `src/Manifest/Notify.hs`, `test/NotifySpec.hs`; Modify `src/Manifest/Testing.hs`, `test/Spec.hs`.

- [ ] **Step 1: failing test.** Create `test/NotifySpec.hs` (listener-only scenarios; the emission scenarios are Task 2 — structure the module so Task 2 extends it):

```haskell
{-# LANGUAGE OverloadedStrings #-}
module NotifySpec (tests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Manifest.Notify (Change (..), listenChanges)
import Manifest.Postgres (withConnection, execText)
import Manifest.Testing (withEphemeralDb')
import Harness

-- Collect changes into an IORef from a forked listener; a listener crash is
-- recorded as a poisoned sentinel so tests fail loudly instead of hanging.
startListener :: ByteString -> [ByteString] -> IO (IORef [Change])
startListener conninfo tabs = do
  ref <- newIORef []
  _ <- forkIO $ do
    r <- try (listenChanges conninfo tabs (\c -> atomicModifyIORef' ref (\cs -> (cs ++ [c], ()))))
    case r of
      Left (e :: SomeException) ->
        atomicModifyIORef' ref (\cs -> (cs ++ [Change "LISTENER-DIED" (Just (BC8 (show e)))], ()))
      Right () -> pure ()
  pure ref
  where -- helper to pack a String; write it as BC.pack with the right import
-- NOTE to implementer: replace the BC8 pseudo-call with Data.ByteString.Char8.pack
-- and import qualified Data.ByteString.Char8 as BC.

-- Poll (10ms steps, 5s budget) until at least n changes arrived.
awaitChanges :: IORef [Change] -> Int -> IO [Change]
awaitChanges ref n = go (500 :: Int)
  where
    go 0 = readIORef ref
    go k = do
      cs <- readIORef ref
      if length cs >= n then pure cs else threadDelay 10000 >> go (k - 1)

tests :: [Test]
tests = group "Notify"
  [ test "listener receives raw pg_notify on a watched channel, strips the prefix" $
      withEphemeralDb' $ \conninfo pool -> do
        ref <- startListener conninfo ["pings"]
        -- listener warm-up: LISTEN registration races the first write; retry
        -- a sentinel notify until it lands, then measure from there.
        awaitWarmup conninfo pool ref
        _ <- withConnection pool (\c -> execText c "SELECT pg_notify('manifest_pings', '42')" [])
        cs <- awaitChanges ref 2
        assertEqual "change" (Change "pings" (Just "42")) (last cs)
  , test "empty payload becomes Nothing; unwatched channels are not delivered" $
      withEphemeralDb' $ \conninfo pool -> do
        ref <- startListener conninfo ["pings"]
        awaitWarmup conninfo pool ref
        _ <- withConnection pool (\c -> execText c "SELECT pg_notify('manifest_quiets', 'x')" [])
        _ <- withConnection pool (\c -> execText c "SELECT pg_notify('manifest_pings', '')" [])
        cs <- awaitChanges ref 2
        assertEqual "only the watched channel, pk-less"
          (Change "pings" Nothing) (last cs)
  , test "two watched tables dispatch with the right table field" $
      withEphemeralDb' $ \conninfo pool -> do
        ref <- startListener conninfo ["pings", "pongs"]
        awaitWarmup conninfo pool ref
        _ <- withConnection pool (\c -> execText c "SELECT pg_notify('manifest_pongs', '7')" [])
        cs <- awaitChanges ref 2
        assertEqual "pongs change" (Change "pongs" (Just "7")) (last cs)
  ]

-- Repeatedly nudge until the listener proves it is attached (first delivery).
awaitWarmup :: ByteString -> Pool -> IORef [Change] -> IO ()
awaitWarmup _conninfo pool ref = go (100 :: Int)
  where
    go 0 = ioError (userError "listener never attached")
    go k = do
      _ <- withConnection pool (\c -> execText c "SELECT pg_notify('manifest_pings', 'warmup')" [])
      cs <- readIORef ref
      if null cs then threadDelay 50000 >> go (k - 1) else pure ()
```

(Adapt imports/pool type as needed — `Pool` from Manifest.Postgres; assertions use the existing Harness. The warmup leaves a variable number of warmup changes in the ref, hence `last cs` assertions and `awaitChanges ref (priorCount+1)` — implementer: snapshot `length` after warmup and await `len+1`, asserting on the new tail, rather than the loose `2` written above. Keep the assertions exact about the NEW change.)

Wire `NotifySpec.tests` into `test/Spec.hs` (import + append `++ NotifySpec.tests`).

- [ ] **Step 2:** `nix develop -c zinc test 2>&1 | tail -4` — compile FAILURE (`Manifest.Notify`, `withEphemeralDb'` missing).

- [ ] **Step 3: `withEphemeralDb'`.** In `src/Manifest/Testing.hs`: export both names; the primed variant hands `(conninfo, pool)`:

```haskell
-- | 'withEphemeralDb' that also hands over the cluster's conninfo, for callers
-- that need their own extra connection (e.g. a "Manifest.Notify" listener,
-- which must not occupy a pool slot).
withEphemeralDb' :: (ByteString -> Pool -> IO a) -> IO a
```

Mechanically: rename the existing body to `withEphemeralDb'`, change `body pool` to `body conninfo pool` (the `conninfo` binding already exists in the body), add `import Data.ByteString (ByteString)`, and define `withEphemeralDb body = withEphemeralDb' (\_ pool -> body pool)`.

- [ ] **Step 4: `Manifest.Notify`.** Create `src/Manifest/Notify.hs`:

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The change feed's subscriber half. A 'Change' is a WAKE-UP — a hint that
-- current state for a table moved — never data: consumers re-read. A missed
-- notification (listener not yet attached, connection drop, queue overflow)
-- means staleness until the next write; pollable consumers should poll as a
-- backstop. Durable delivery is the (future) event-store's job, not this
-- feed's. Emission lives in "Manifest.Session" behind the per-entity
-- 'Manifest.Entity.notifyChanges' flag.
module Manifest.Notify
  ( Change (..)
  , listenChanges
  ) where

import Control.Concurrent (threadWaitRead)
import Control.Exception (throwIO)
import Control.Monad (forever, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Database.PostgreSQL.LibPQ as PQ
import Manifest.Error (DbError (..), DbException (..))

-- | Current state for 'table' moved. 'key' is the pk rendered as text, or
-- 'Nothing' for bulk operations ('deleteWhere'). Re-read; never trust as data.
data Change = Change
  { table :: ByteString
  , key   :: Maybe ByteString
  }
  deriving (Eq, Show)

-- | Open a DEDICATED connection (LISTEN occupies it for life — a pool
-- checkout would starve writers), LISTEN on each table's
-- @manifest_\<table\>@ channel, then block forever dispatching notifications
-- to the callback. The callback runs on this thread: slow callbacks delay
-- subsequent deliveries — hand off if you do real work. Throws 'DbException'
-- on connection loss; retry/supervision is the caller's policy.
listenChanges :: ByteString -> [ByteString] -> (Change -> IO ()) -> IO ()
listenChanges conninfo tables onChange = do
  conn <- PQ.connectdb conninfo
  st <- PQ.status conn
  unless (st == PQ.ConnectionOk) (failWith conn)
  mapM_ (\t -> run conn ("LISTEN \"manifest_" <> t <> "\"")) tables
  drain conn
  forever $ do
    fd <- PQ.socket conn >>= maybe (failWith conn) pure
    threadWaitRead fd
    ok <- PQ.consumeInput conn
    unless ok (failWith conn)
    drain conn
  where
    run conn sql = do
      mres <- PQ.exec conn sql
      case mres of
        Nothing -> failWith conn
        Just res -> do
          rst <- PQ.resultStatus res
          unless (rst `elem` [PQ.CommandOk, PQ.TuplesOk]) (failWith conn)
    drain conn =
      PQ.notifies conn >>= \case
        Nothing -> pure ()
        Just n -> do
          let chan    = PQ.notifyRelname n
              t       = maybe chan id (BS.stripPrefix "manifest_" chan)
              payload = PQ.notifyExtra n
          onChange (Change t (if BS.null payload then Nothing else Just payload))
          drain conn

failWith :: PQ.Connection -> IO a
failWith conn = do
  msg <- maybe "connection lost" id <$> PQ.errorMessage conn
  throwIO (DbException (QueryError msg))
```

(Check `PQ.exec`'s exact name/signature in the pinned postgresql-libpq — `exec :: Connection -> ByteString -> IO (Maybe Result)`; adjust if the version differs. `Fd` from `PQ.socket` works with `threadWaitRead` directly.)

- [ ] **Step 5:** suite green (the three listener tests + all existing). **Step 6: commit** `feat(notify): Manifest.Notify listener + withEphemeralDb' (change feed, z8h slice 1)`.

---

### Task 2: emission (`notifyChanges` + the write paths)

**Files:** Modify `src/Manifest/Entity.hs`, `src/Manifest/Session.hs`, `src/Manifest/Session/Command.hs`, `test/NotifySpec.hs`.

- [ ] **Step 1: failing tests.** Extend `test/NotifySpec.hs` with fixture entities + emission scenarios. Fixtures (NotifySpec-local, Fixtures.hs style — read test/Fixtures.hs for the HKD idiom):

```haskell
-- opted-in
data PingT f = Ping { pingId :: Field f (Pk Int), pingMsg :: Field f Text } deriving Generic
type Ping = PingT Identity
instance Entity Ping where
  tableMeta     = genericTableMeta @PingT "pings"
  notifyChanges = True

-- opted-in, second table for dispatch tests
data PongT f = Pong { pongId :: Field f (Pk Int), pongMsg :: Field f Text } deriving Generic
type Pong = PongT Identity
instance Entity Pong where
  tableMeta     = genericTableMeta @PongT "pongs"
  notifyChanges = True

-- NOT opted in
data QuietT f = Quiet { quietId :: Field f (Pk Int), quietMsg :: Field f Text } deriving Generic
type Quiet = QuietT Identity
deriving via (Table "quiets" QuietT) instance Entity Quiet
```

DDL helper creating the three tables via `withConnection`/`execText` (`pings(ping_id BIGSERIAL PRIMARY KEY, ping_msg TEXT NOT NULL)` etc.). Scenarios (each its own `test`, using `startListener`/`awaitWarmup`/`awaitChanges` from Task 1; snapshot the ref length after warmup and assert on the tail):

1. **add/save/delete each notify with the pk**: `p <- add (Ping 0 "a")` → `Change "pings" (Just <pk>)`; mutate via `save p { pingMsg = "b" } >> flush` → another; `delete p >> flush`... delete is queued too — use `withTransaction (delete p)` like CascadeSpec, or `delete p` + `flush` → a third. Assert the three arrive in order with the same pk (render expectation from `p`'s id: `BC.pack (show (pingId p))`).
2. **flushSave skips unchanged**: `save p` with NO field changed + `flush` → NO new change (bounded by a sentinel `add` on Ping afterwards — assert exactly the sentinel arrived).
3. **transaction gating**: `withTransaction (add (Ping 0 "t1") >> add (Ping 0 "t2") >> pure ())` → exactly 2 new changes after; then a `withTransaction` whose body `add`s and then `ioError`s (caught with `try`) → NO new changes (sentinel-bounded).
4. **command path**: `update @Ping (Key pid) [#pingMsg =. "u"]` → `Change "pings" (Just pk)`; `deleteWhere ([#pingMsg ==. "u"] :: [Cond Ping])` → `Change "pings" Nothing`.
5. **non-opted entity is silent**: `add (Quiet 0 "q")` → nothing (sentinel-bounded via a Ping add).
6. **dispatch**: listener on ["pings","pongs"]; `add (Pong 0 "p")` → `Change "pongs" (Just pk)`.

- [ ] **Step 2:** run — compile failure (`notifyChanges` not a class member).

- [ ] **Step 3: implement.**

`src/Manifest/Entity.hs` (next to `cascadeRules`, same defaulting style):

```haskell
  -- | Opt this entity into the change feed: every session write emits
  -- @pg_notify('manifest_<table>', <pk-as-text>)@ — a wake-up for
  -- "Manifest.Notify" subscribers, never data. Default off.
  notifyChanges :: Bool
  notifyChanges = False
```

`src/Manifest/Session.hs` — the shared emitter (exported; Command.hs uses it too):

```haskell
-- | Emit the change-feed wake-up for an opted-in entity. Goes through
-- 'execDb' so it appears in the statement log; Postgres delivers NOTIFY at
-- COMMIT inside a transaction (and drops it on ROLLBACK), immediately
-- otherwise. The payload is the pk as text, or empty for bulk operations.
emitChange :: forall a. Entity a => SqlParam -> Db ()
emitChange pk =
  when (notifyChanges @a) $
    void $ execDb "SELECT pg_notify($1, $2)"
      [ Just ("manifest_" <> tmTable (tableMeta @a))
      , Just (maybe "" id pk) ]
```

Call sites (each one line, after the existing write):
- `add` (Session.hs:166): in the `(row : _)` branch after `setBaseline a'`: `emitChange @a (pkParam a')` (the decoded row carries the assigned pk).
- `flushSave` (Session.hs:191): inside the `else do` branch (i.e. only when an UPDATE was actually issued), after the `execDb`: `emitChange @a (pkParam a)`.
- `flushDelete` (Session.hs:214): after the parent-row `execDb (renderDelete …)`: `emitChange @a parent`. (Cascade-deleted children deliberately do NOT notify — documented limitation; add a one-line comment at the cascade walk noting it.)
- `Session/Command.hs update`: after the `execDb`: `emitChange @a (encode (unKey key))`.
- `Session/Command.hs deleteWhere`: after the `execDb`: `emitChange @a Nothing`.

Imports: `when` (Control.Monad) where missing; Command.hs imports `emitChange` from `Manifest.Session` (extend its import + Session's export list).

- [ ] **Step 4:** suite green — every scenario incl. the existing 147ish (cascade/flush specs must be unaffected: their fixtures don't opt in, so zero new statements in their logs — if a FlushSpec statement-count assertion breaks, that means a non-opted entity emitted: a real bug, fix the guard).

- [ ] **Step 5: commit** `feat(notify): per-entity notifyChanges emission across all session write paths`.

---

### Task 3: umbrella exports + docs

**Files:** Modify `src/Manifest.hs`, `docs/index.md`; Create `docs/change-feed.md`.

- [ ] **Step 1:** `src/Manifest.hs`: add `Change(..)` and `listenChanges` to BOTH export sections (the file has two export lists, line ~96 and ~215 — match how `CascadeRule(..)` appears in both) under a `-- * Change feed` heading, with `import Manifest.Notify (Change (..), listenChanges)`. (`notifyChanges` is already exported via `Entity(..)`.)
- [ ] **Step 2:** `docs/change-feed.md` (mirror docs/cascades.md's length/voice, ~60 lines): why (live consumers without polling), the opt-in (`notifyChanges = True`), what's emitted per write path (the table from the spec §1), `listenChanges` usage with the dedicated-connection + wake-up-only caveats, the three v1 limitations, and a short worked example (a Ping entity + a listener loop). Add to docs/index.md's nav list after the cascades entry.
- [ ] **Step 3:** suite once more (docs only — sanity). **Step 4: commit** `docs(notify): change-feed manual page + umbrella exports`.

---

### Task 4: close-out

- [ ] **Step 1:** Full suite + `git push`.
- [ ] **Step 2:** beads — z8h stays OPEN (slice 1 of a larger arc); record progress:

```bash
bd update manifest-z8h --notes "Slice 1 (change feed) shipped: notifyChanges opt-in + pg_notify emission on all session write paths + Manifest.Notify.listenChanges (wake-up-only; spec docs/superpowers/specs/2026-06-11-change-feed-design.md). Remaining slices per the partially-superseded 2026-06-09 proposal: ES core (aggregates/log/time-travel), projections. Next consumer: eval sub-project D (manifest-cz2) is now unblocked."
git add .beads/issues.jsonl && git commit -m "chore(bd): z8h slice 1 shipped (change feed)" && git push
```

(If `bd update --notes` isn't the right flag, use `bd comment` or the closest notes mechanism — check `bd update --help`.)
- [ ] **Step 3:** Also update manifest-cz2 (sub-project D) to drop its blocker note if beads tracks that linkage.

---

## Self-Review

**1. Spec coverage:** §1 emission (opt-in member, the per-path payload table, commit gating, the three limitations incl. the cascade-children comment) → Task 2; §2 subscription (`Change`, `listenChanges`, dedicated connection, drain loop, throw-on-loss, callback-on-listener-thread haddock) → Task 1; §3 placement (Entity/Session/Command/Notify/umbrella, no migration changes) → Tasks 1–3; §4's five test scenarios → Task 1 (raw delivery, prefix strip, pk-less, dispatch) + Task 2 (write paths, txn gating incl. rollback, command path, non-opted negative, dispatch via entities); §5 (D consumption) correctly absent; §6 out-of-scope absent (no outbox, no reconnect logic, no payload data).

**2. Placeholder scan:** the Task 1 test sketch carries two flagged implementer notes (the `BC8` pseudo-call → `BC.pack`, and the snapshot-length-then-await-tail discipline replacing the loose `2`s) — both are explicit instructions with the exact replacement named, not TBDs. Task 3's docs step specifies the content list and the model page rather than full prose — appropriate for a manual page.

**3. Type consistency:** `Change {table, key}` matches across Notify (Task 1), the tests (Tasks 1–2), and the exports (Task 3); `listenChanges :: ByteString -> [ByteString] -> (Change -> IO ()) -> IO ()` consistent; `emitChange :: forall a. Entity a => SqlParam -> Db ()` call sites all pass `SqlParam` (= `Maybe ByteString`): `pkParam a'`/`pkParam a`/`parent`/`encode (unKey key)`/`Nothing`; `withEphemeralDb' :: (ByteString -> Pool -> IO a) -> IO a` matches its uses.
