# Eval Orchestrator — Live Progress (sub-project D) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-12 · **Issue:** manifest-cz2

**Goal:** The dashboard updates itself while runs execute and scores land: open
a run's detail and watch output rows appear. manifest's change feed (z8h
slice 1, shipped 2026-06-11) → dashboard server fan-out over SSE → Miso UI
debounced refetch.

---

## 0. Context

manifest now has the change feed: `notifyChanges = True` on an entity makes
every session write emit `pg_notify('manifest_<table>', <pk>)` (commit-gated
by Postgres), and `Manifest.Notify.listenChanges` delivers `(table, key)`
wake-ups on a dedicated connection, throwing on disconnect (caller owns
retry). Semantics are wake-up-only: a `Change` is a hint to re-read, never
data. The dashboard (sub-project B) is a wasm Miso SPA over a warp JSON API.

**Decisions** (user-approved): SSE for the server→browser leg (one-way push
matches the refetch-only UI; browser-native `EventSource` with free
auto-reconnect; no new server dependency) — not WebSocket, not polling-only.

## 1. Data layer (manifest-evals)

- Re-pin manifest to the change-feed rev (remember: edit the rev, then
  `nix develop -c zinc update manifest`).
- `Evals.Schema`: `notifyChanges = True` on `Run`, `Output`, `Score`,
  `RunMetric`. Nothing else — `executeRun`/`scoreRun` write through the
  session API, so status flips, outputs, scores, and metric recomputes emit
  with zero engine changes. (`scoreRun`'s `deleteWhere` re-grades arrive as
  pk-less wake-ups; the UI refetches either way.)

## 2. Server fan-out — `Evals.Dashboard.Events` (new module)

- **Listener supervisor**: a thread started by `app-dashboard/Main`:
  `listenChanges conninfo ["runs","outputs","scores","run_metrics"]` inside
  a reconnect loop (log to stderr, 1s backoff). This is the change-feed
  contract's "caller owns retry" caller.
- **Broadcast hub**: one `newBroadcastTChanIO`; the listener callback writes
  every `Change` in; each SSE client `dupTChan`s its own view (no client
  bookkeeping — dropped dups are GC'd).
- **`GET /api/events`** (routed in `dashboardApp` before the `("api":_)`
  fallthrough): a wai `responseStream` with `Content-Type: text/event-stream`
  and `Cache-Control: no-cache`, looping read-dup-chan → write
  `data: <json>\n\n` → flush; a `: keepalive\n\n` comment every ~25s defeats
  idle timeouts and surfaces dead clients as write failures (ending the
  stream thread).
- **Wire shape**: `ChangeDto { table :: Text, key :: Maybe Text }` in
  `evals-api` (aeson Generic, like the rest) — the UI decodes with the same
  shared types as everything else.
- The server forwards every change, no coalescing — sanctioned by the
  change-feed spec (hints, not data); the debounce lives client-side.

## 3. UI (evals-ui)

- **EventSource shim** (sibling of the fetch shim, via miso's JS DSL):
  connect `new EventSource('/api/events')` once at startup; `onmessage` →
  decode `ChangeDto` → `GotChange` action; `onopen`/`onerror` → a
  `LiveStatus` (Connected / Reconnecting) shown as a small dot in the header
  (EventSource auto-reconnects on its own).
- **Relevance** (a pure function of route × change, unit-testable shape even
  if untested): `#/runs` refetches on `runs`/`run_metrics` changes;
  `#/runs/<id>` and `#/compare/<a>/<b>` refetch on ANY of the four tables
  (output/score pks cannot be mapped to run ids client-side; a spurious
  refetch is cheap for a single user).
- **Debounce ~300ms** via a setTimeout shim: a relevant change sets a
  `refetchQueued` flag and schedules one `DoRefetch`; changes arriving while
  queued are absorbed. `DoRefetch` re-dispatches the current route's fetch
  (the existing stale-response route guards already make late responses
  safe).
- No UI behaviour change when the stream is down beyond the indicator —
  manual navigation still fetches.

## 4. Testing

- **Server (ApiSpec)**: open `/api/events` with http-client's streaming
  `withResponse`/`brRead`; write an opted-in row through the pool; assert a
  `data:` line decoding to the right `ChangeDto` arrives (bounded wait).
  Headers asserted (`text/event-stream`). The supervisor's reconnect loop is
  kept too simple to need a test (log + delay + retry).
- **DTO**: `ChangeDto` round-trip + a golden key-set assertion, like its
  siblings.
- **Existing suites** must stay green — the entity opt-ins add `pg_notify`
  statements to engine writes, which no existing assertion counts (verify).
- **Human checkpoint**: seeded demo DB + a real `manifest-evals run` (and a
  `score`) executing while the dashboard is open — outputs appear live,
  status chip flips, metrics land.

## 5. Out of scope

- WebSocket; per-run scoped streams; server-side coalescing.
- Durable replay / missed-event recovery (wake-up-only by design; manual
  refresh covers any gap).
- Multi-user concerns (auth, per-client filtering).
- Browser-automation tests.
