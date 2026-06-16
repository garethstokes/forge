# Live Progress (sub-project D) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The dashboard updates itself while runs execute: entity writes emit manifest change-feed wake-ups → the dashboard server fans them out over SSE → the Miso UI refetches the current view (debounced).

**Architecture:** Four entity opt-ins + a manifest re-pin are the whole data change. A new `Evals.Dashboard.Events` module owns the listener supervisor (reconnect loop over `listenChanges`) and a broadcast-`TChan` hub; `GET /api/events` streams `data: <ChangeDto json>` lines with 25s keepalives. The UI adds an EventSource shim, a pure route-relevance function, and a 300ms setTimeout debounce that re-dispatches the current route's existing fetch.

**Tech Stack:** manifest @ `0e414c29f77fe8668daefdcbbb5af56576ff1267` (the change feed), wai `responseStream`, stm (GHC boot package — add to depends, no lock entry needed), http-client streaming (`withResponse`/`brRead`) for tests, miso 1.11 JS DSL for the EventSource/setTimeout shims.

**Spec:** `docs/superpowers/specs/2026-06-12-live-progress-design.md` · **Issue:** manifest-cz2

**Repo facts:** `Manifest.Testing.withEphemeralDb'` exposes the cluster conninfo (the SSE test needs it for the listener). `Manifest.Notify.Change {table, key :: ByteString/Maybe ByteString}` — clashes with `ChangeDto` field names; import qualified where both appear. `dashboardApp :: Pool -> FilePath -> Application` is called from `app-dashboard/Main.hs` and ~6 `testWithApplication` sites in `test/ApiSpec.hs` — gaining a hub argument touches all of them (mechanical). The UI's existing fetch actions + stale-response route guards live in `evals-ui/src/Main.hs`; the JS-DSL shim precedent (getHash/setHash via `jsg`) is in there too. REMEMBER the zinc quirk: after editing the manifest rev, run `nix develop -c zinc update manifest`.

## File structure

- Modify `zinc.toml` (manifest rev; lib depends += `stm`), `zinc.lock` (via zinc update).
- Modify `src/Evals/Schema.hs` (four `notifyChanges = True`).
- Modify `evals-api/src/Evals/Api.hs` (+ `ChangeDto`).
- Create `src/Evals/Dashboard/Events.hs` (hub + supervisor + SSE response).
- Modify `src/Evals/Dashboard.hs` (route + hub arg), `app-dashboard/Main.hs` (hub + forkIO supervisor).
- Modify `test/ApiSpec.hs` (hub plumbing + ChangeDto tests + SSE test).
- Modify `evals-ui/src/{Main.hs,Evals/Ui/{Model,Fetch,View}.hs}`, `static/style.css`.
- Modify `README.md`.

---

### Task 1: data layer — re-pin + opt-ins + ChangeDto

**Files:** `zinc.toml`, `zinc.lock`, `src/Evals/Schema.hs`, `evals-api/src/Evals/Api.hs`, `test/ApiSpec.hs`.

- [ ] **Step 1:** `zinc.toml` `[dependencies.manifest]`: `rev = "0e414c29f77fe8668daefdcbbb5af56576ff1267"`, comment gains "+ the change feed (z8h slice 1)". Run `nix develop -c zinc update manifest` — expect `~ manifest <old> -> 0e414c2`.
- [ ] **Step 2: failing DTO test.** In `test/ApiSpec.hs` round-trip section add (with its siblings):

```haskell
  rt "ChangeDto" (ChangeDto { table = "outputs", key = Just "42" })
  rt "ChangeDto pk-less" (ChangeDto { table = "scores", key = Nothing })
  expect "ChangeDto wire keys"
    ((decode (encode (ChangeDto "runs" (Just "7"))) :: Maybe Value)
       == Just (object ["table" .= ("runs" :: Text), "key" .= ("7" :: Text)]))
```

Run — compile failure (`ChangeDto` missing).
- [ ] **Step 3:** `evals-api/src/Evals/Api.hs` — export `ChangeDto (..)` and add:

```haskell
-- | One change-feed wake-up forwarded over SSE: current state for 'table'
-- moved (key = the row pk as text, when known). A hint to refetch — never data.
data ChangeDto = ChangeDto
  { table :: Text, key :: Maybe Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

- [ ] **Step 4:** `src/Evals/Schema.hs` — add `notifyChanges = True` to the `Entity` instances for `Run`, `Output`, `Score`, `RunMetric` (one line each, after `indexes`/`cascadeRules`; NOTE `RunMetric` is currently `deriving via (Table "run_metrics" RunMetricT)` — convert it to a standalone instance: `instance Entity RunMetric where { tableMeta = genericTableMeta @RunMetricT "run_metrics"; notifyChanges = True }`).
- [ ] **Step 5:** `nix develop -c zinc test 2>&1 | tail -6` — ALL FOUR existing spec lines green (engine writes now emit `pg_notify` statements; no existing assertion counts statements — if something breaks, investigate, don't paper over).
- [ ] **Step 6: commit** `feat(live): re-pin manifest with the change feed; opt in Run/Output/Score/RunMetric; ChangeDto`.

---

### Task 2: server fan-out — Events module + /api/events (TDD)

**Files:** Create `src/Evals/Dashboard/Events.hs`; Modify `src/Evals/Dashboard.hs`, `app-dashboard/Main.hs`, `test/ApiSpec.hs`, `zinc.toml` (lib depends += `stm`).

- [ ] **Step 1: failing SSE test.** In `test/ApiSpec.hs`: first, mechanically thread a hub through the existing `testWithApplication` sites: each block gains `hub <- newEventHub` and passes `dashboardApp pool <dir> hub`. Then add an `sseSpec` (called from ApiSpec's main; uses `withEphemeralDb'` — extend the Manifest.Testing import):

```haskell
sseSpec :: IO ()
sseSpec = withEphemeralDb' $ \conninfo pool -> do
  _ <- withSession pool migrateAll
  now <- getCurrentTime
  hub <- newEventHub
  _ <- forkIO (runListener conninfo hub)
  mgr <- newManager defaultManagerSettings
  testWithApplication (pure (dashboardApp pool "static" hub)) $ \port -> do
    req0 <- parseRequest ("http://localhost:" <> show port <> "/api/events")
    let req = req0 { responseTimeout = responseTimeoutNone }
    withResponse req mgr $ \resp -> do
      expect "sse content type"
        (lookup "Content-Type" (responseHeaders resp) == Just "text/event-stream")
      -- the LISTEN attach races our first write: keep seeding minimal runs
      -- until a data: line arrives (each seed write is one wake-up).
      body <- seedUntilData pool now (responseBody resp)
      expect "a data: line decodes to a runs ChangeDto"
        (case extractData body of
           Just json -> case decode json :: Maybe ChangeDto of
             Just c -> c.table == "runs" && c.key /= Nothing
             Nothing -> False
           Nothing -> False)
```

with two helpers written concretely in the file:
- `seedUntilData :: Pool -> UTCTime -> BodyReader -> IO ByteString` — loop (≤50 × 200ms): seed one minimal Run row (a tiny `seedBareRun pool now` helper: dataset+version+target+tv once, then one Run per call — or simplest: one full seed then UPDATE its status each iteration via `update @Run`, each emitting a fresh wake-up), then `brRead` with a short timeout (`System.Timeout.timeout 200000 (brRead body)`) accumulating chunks; return as soon as the accumulated bytes contain `"data: "`. Fail with `userError` after the budget.
- `extractData :: ByteString -> Maybe LBS.ByteString` — the first line starting `data: `, stripped of the prefix (lazy for `decode`).
(Adapt names/details as the code demands; the CONTRACT: headers asserted, a real entity write through the pool produces a decodable `ChangeDto` on the open stream, bounded wait, no bare sleeps without budget.)

Run — compile failure (`Evals.Dashboard.Events` missing).

- [ ] **Step 2: implement `src/Evals/Dashboard/Events.hs`:**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The live half of the dashboard: a broadcast hub fed by manifest's change
-- feed, fanned out to browsers as Server-Sent Events. Wake-up-only semantics
-- end to end: an event is a hint to refetch, never data.
module Evals.Dashboard.Events
  ( EventHub
  , newEventHub
  , publish
  , runListener
  , sseResponse
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TChan, atomically, dupTChan, newBroadcastTChanIO, readTChan, writeTChan)
import Control.Exception (SomeException, try)
import Control.Monad (forever)
import Data.Aeson (encode)
import Data.ByteString (ByteString)
import Data.ByteString.Builder (lazyByteString)
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types (status200)
import Network.Wai (Response, responseStream)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)

import qualified Manifest.Notify as Notify
import Evals.Api (ChangeDto (..))

-- | One broadcast channel; every SSE client holds a 'dupTChan' view.
newtype EventHub = EventHub (TChan ChangeDto)

newEventHub :: IO EventHub
newEventHub = EventHub <$> newBroadcastTChanIO

publish :: EventHub -> ChangeDto -> IO ()
publish (EventHub ch) = atomically . writeTChan ch

-- | The change-feed tables the dashboard watches.
watchedTables :: [ByteString]
watchedTables = ["runs", "outputs", "scores", "run_metrics"]

-- | The listener supervisor: 'Manifest.Notify.listenChanges' throws on
-- connection loss by contract (the caller owns retry) — this is that caller.
-- Log and reconnect with a 1s backoff, forever. Run on its own thread.
runListener :: ByteString -> EventHub -> IO ()
runListener conninfo hub = forever $ do
  r <- try (Notify.listenChanges conninfo watchedTables (publish hub . toDto))
  case r of
    Left (e :: SomeException) ->
      hPutStrLn stderr ("evals-dashboard: change-feed listener died: " <> show e <> "; reconnecting in 1s")
    Right () -> pure ()
  threadDelay 1000000
  where
    toDto c = ChangeDto
      { table = TE.decodeUtf8Lenient (Notify.table c)
      , key   = TE.decodeUtf8Lenient <$> Notify.key c
      }

-- | The SSE stream for one client: subscribe a fresh view of the hub, then
-- alternate between forwarding events and 25s keepalive comments (which also
-- surface dead clients as write failures, ending this handler's thread).
sseResponse :: EventHub -> Response
sseResponse (EventHub ch) =
  responseStream status200
    [ ("Content-Type", "text/event-stream")
    , ("Cache-Control", "no-cache") ]
    $ \write flush -> do
        myChan <- atomically (dupTChan ch)
        write ": connected\n\n" >> flush
        forever $ do
          mc <- timeout 25000000 (atomically (readTChan myChan))
          case mc of
            Just c  -> write (lazyByteString ("data: " <> encode c <> "\n\n")) >> flush
            Nothing -> write ": keepalive\n\n" >> flush
```

(Builder literals: `": connected\n\n"` needs the Builder OverloadedStrings instance — if it gripes, use `byteString ": connected\n\n"`. The `Notify.table`/`Notify.key` accessors: `Change`'s fields — adjust to qualified record access or pattern matching as the import style requires.)

- [ ] **Step 3: wire it.** `src/Evals/Dashboard.hs`: `dashboardApp :: Pool -> FilePath -> EventHub -> Application`; route `["api", "events"]` → `respond (sseResponse hub)` BEFORE the `("api":_)` fallthrough (and OUTSIDE the JSON-500 `handle` wrapper if that wrapper would interfere with streaming — judge; the stream itself shouldn't be wrapped). `app-dashboard/Main.hs`: `hub <- newEventHub`, `_ <- forkIO (runListener (BC.pack url) hub)` (the url binding already exists for `newPool`), pass `hub` to `dashboardApp`. `zinc.toml` lib depends += `"stm"`.

- [ ] **Step 4:** `nix develop -c zinc test 2>&1 | tail -6` — all green incl. `sseSpec`. Run TWICE (the SSE test has timing; fix sync, never weaken). `nix develop -c zinc build` links.
- [ ] **Step 5: commit** `feat(live): SSE fan-out — Events hub, listener supervisor, GET /api/events`.

---

### Task 3: UI — EventSource, relevance, debounce, live dot

**Files:** `evals-ui/src/Main.hs`, `evals-ui/src/Evals/Ui/{Model,Fetch,View}.hs`, `static/style.css`. Adapt-latitude on miso 1.11 DSL specifics; the BEHAVIOUR contract is fixed. Read the existing shims (getHash/setHash, the fetch layer) first — they are the precedent.

- [ ] **Step 1: model + actions.** `Model.hs`: `data LiveStatus = LiveConnected | LiveReconnecting` (start Reconnecting); model gains `_liveM :: LiveStatus`, `_refetchQueuedM :: Bool` (+ lenses, matching the file's style). A PURE `relevantTo :: Route -> MisoString -> Bool` (route × table): `RunsR` → table elem ["runs","run_metrics"]; `RunR _`/`CompareR _ _` → table elem ["runs","outputs","scores","run_metrics"]. Actions in Main.hs: `SseOpen`, `SseError`, `GotChange ChangeDto`, `DoRefetch`.
- [ ] **Step 2: the EventSource shim** (`Fetch.hs` or a small `Events` section there): `connectEvents :: (ChangeDto -> JSM ()) -> JSM () -> JSM () -> JSM ()` — `new EventSource('/api/events')` via the JS DSL; `onmessage` decodes `event.data` (aeson `eitherDecodeStrictText` like the fetch layer) and invokes the first callback (undecodable lines: ignore); `onopen`/`onerror` invoke the others. Hook it at startup the way the app's other one-time wiring works (the `mount`/initial action path): dispatch `SseOpen`/`SseError`/`GotChange` through the sink.
- [ ] **Step 3: update logic** (Main.hs):
  - `SseOpen` → `liveM .= LiveConnected`; `SseError` → `LiveReconnecting` (EventSource auto-reconnects itself; we only reflect status).
  - `GotChange c` → if `relevantTo route c.table && not refetchQueued`: set queued, schedule `DoRefetch` after 300ms via a setTimeout shim (`jsg "setTimeout"` with a callback through the sink — NOT threadDelay, which would block the JS event loop). If queued already or irrelevant: no-op.
  - `DoRefetch` → clear queued; re-dispatch the CURRENT route's existing fetch action (whatever entering that route dispatches today — reuse, don't duplicate; the existing stale-response guards make any race safe).
- [ ] **Step 4: view + css.** Header gains a live dot: `span` with class `live on`/`live off` and a title ("live" / "reconnecting…"). `style.css`: `.live` dot styles (8px circle, green/gray).
- [ ] **Step 5: builds.** Native `nix develop -c zinc build` green; `bash scripts/build-ui.sh` green (artifacts restaged — they're gitignored). Suite sanity (`zinc test` — server untouched by this task, quick confirmation).
- [ ] **Step 6: commit** `feat(ui): live updates — EventSource shim, route relevance, debounced refetch, live dot`.

---

### Task 4: human checkpoint + close-out

**Files:** `README.md`; beads (manifest repo); memory of the demo flow.

- [ ] **Step 1: live demo setup.** `nix develop -c bash scripts/seed-demo.sh`; start the server (`MANIFEST_DATABASE_URL=postgresql:///evals_demo EVALS_HTTP_PORT=8788 EVALS_STATIC_DIR=static nix develop -c ./.zinc/build/evals-dashboard`, background). Verify `/api/events` streams (curl with a short timeout shows `: connected`).
- [ ] **Step 2: HUMAN CHECKPOINT (no API key needed).** Ask the human to open `http://localhost:8788/#/runs`, then prove liveness by writing rows while they watch — e.g. via psql against evals_demo: `UPDATE runs SET status='running' WHERE id=1;` (status chip flips without refresh), then `INSERT INTO outputs (run, example, text, latency_ms) VALUES (1, 1, 'live row!', 5);` while they're on `#/runs/1` (a row appears), then revert (`DELETE` the row, restore status). Provide the exact statements in the checkpoint message. STOP for confirmation.
- [ ] **Step 3: README.** Dashboard section gains a "Live updates" paragraph: SSE at `/api/events`, the four watched tables, wake-up-only semantics, the live dot, debounce.
- [ ] **Step 4: full suite + both builds once more; commit + push manifest-evals.**
- [ ] **Step 5: close the issue** (manifest repo): `bd close manifest-cz2 --reason "Shipped: manifest change feed -> Evals.Dashboard.Events (broadcast hub + listener supervisor) -> GET /api/events (SSE, keepalives) -> Miso EventSource shim with route-relevant debounced refetch + live indicator. Spec: manifest-evals docs/superpowers/specs/2026-06-12-live-progress-design.md."` + commit/push beads. The eval orchestrator (A/B/C/scoring/D) is complete.

---

## Self-Review

**1. Spec coverage:** §1 (re-pin, four opt-ins, zero engine changes) → Task 1; §2 (Events module: supervisor w/ 1s backoff + stderr log, broadcast hub, /api/events with headers/keepalives/ChangeDto wire) → Task 2; §3 (EventSource shim w/ live dot + auto-reconnect-reflect, pure relevance per route, 300ms debounce reusing existing fetches + stale guards) → Task 3; §4 (streaming SSE test w/ bounded waits, ChangeDto round-trip+golden, existing suites green, human checkpoint) → Tasks 1, 2, 4; §5 out-of-scope absent (no WebSocket, no per-run streams, no server coalescing, no replay).

**2. Placeholder scan:** Task 2's test sketch names two helpers with their contracts and bounded-wait requirements spelled out (concrete code required in the file — the sketch says "written concretely"); Task 3 carries declared miso-DSL adapt-latitude with a fixed behaviour contract, the same pattern as the B plan's UI task. No TBDs.

**3. Type consistency:** `EventHub`/`newEventHub`/`publish`/`runListener`/`sseResponse` consistent across Tasks 2–4; `dashboardApp :: Pool -> FilePath -> EventHub -> Application` matches Main + every test site; `ChangeDto {table, key}` matches Task 1's definition, Task 2's encode, Task 3's decode; `relevantTo :: Route -> MisoString -> Bool` consumed only in Task 3.
