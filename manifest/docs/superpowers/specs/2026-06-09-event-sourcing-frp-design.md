# Manifest — Event Sourcing / FRP — Design Proposal

**Status:** **PROPOSAL — PARTIALLY SUPERSEDED.** Slice 1 (JSON support) shipped independently (2026-06-10 jsonb columns); the change feed was re-scoped onto state tables and approved as `2026-06-11-change-feed-design.md` (built first, ahead of the ES core). The ES core/projections sections remain an unapproved proposal. Captures the direction explored while
brainstorming issue `manifest-z8h`. It is a starting point for discussion, not an
accepted design, and nothing here is committed to be built. · **Date:** 2026-06-09

**Scope of this document:** weigh the options for adding event sourcing and reactive
("FRP") capabilities to Manifest, propose a set of design choices, and recommend a
decomposition with a first MVP slice. Approval and implementation are separate, later
decisions. The "(Brainstorm leaning: …)" notes below record which option was favoured
during the exploration; they are proposals, not ratified decisions.

---

## 0. Stance

Manifest today is a state-based ORM: a Unit of Work with an identity map and
snapshot-diff `save`, current-state tables, a typed query builder, migrations, and
RLS. The design adds **opt-in event-sourced aggregates that coexist with that
world** — not a rewrite into full event sourcing.

A type *opts in* to event sourcing (the way entities opt into `rlsPolicies` /
`cascadeRules`). For an opted-in aggregate, an append-only event log is the source
of truth and current state is a fold of its events; every other type keeps the
normal state-based UoW. (Brainstorm leaning: **B**, opt-in hybrid, over a thin
event-log/outbox adjunct (A) or full event sourcing everywhere (C).)

This fits Manifest's "thin, owned Core you opt into" philosophy and keeps each piece
tractable and independently shippable.

---

## 1. Events

### 1.1 Aggregates (the opt-in surface)

An aggregate declares its event type, a seed state, and a fold:

```haskell
class Aggregate a where
  type Event a
  initial :: a                  -- empty/seed state (before any event)
  apply   :: a -> Event a -> a  -- fold one event into the state
```

The aggregate's `Event a` is an ordinary Haskell sum type (`OrderPlaced … | ItemAdded
… | OrderShipped`). The *decide* logic (`state -> command -> [Event a]`) is plain
application code, deliberately **not** part of Manifest (see §1.4).

### 1.2 Payload representation — JSON (aeson)

Events are heterogeneous-per-stream and evolve over time, so payloads are stored as
`jsonb` and (de)serialised with **aeson** (`ToJSON`/`FromJSON`, derivable via
`Generic`). An aggregate's `Event a` sum round-trips as tagged JSON
(`{"tag":"OrderPlaced","contents":{…}}`), so a stream's payloads decode straight back
to `Event a`.

(Brainstorm leaning: **A**, jsonb via aeson, over reusing Manifest's text codec into
one opaque column (B) or one table per event type (C). Accepted consequence: aeson
becomes Manifest's first dependency beyond boot libs + `postgresql-libpq`; this also
needs a `SqlJsonb` column type + a JSON codec, which is independently useful and is
folded into the first slice — see §4.)

### 1.3 The event log

A single global, append-only log:

```
events
  ( stream_id   text         not null
  , version     bigint       not null        -- per-stream sequence, 1-based
  , event_type  text         not null        -- aggregate type tag (for filtering/dispatch)
  , payload     jsonb        not null
  , occurred_at timestamptz  not null default now()
  , global_seq  bigserial                    -- total order across all streams
  , primary key (stream_id, version) )        -- uniqueness = optimistic concurrency
```

- `stream_id` identifies an aggregate instance (e.g. `"Order-123"`).
- `(stream_id, version)` primary key gives **optimistic concurrency**: appending at an
  already-used version fails.
- `global_seq` gives a **total order** that projections (§2) and the change feed (§3)
  consume in sequence.

### 1.4 Write/read API — a minimal typed event store

Manifest provides the concurrency-safe store + fold; it does **not** provide a
command/decider layer (that is an application-architecture concern and composes
cleanly on top later).

```haskell
type StreamId = ByteString
type Version  = Int

-- read: fold the stream into current state, with its current version
loadAggregate   :: forall a. Aggregate a => StreamId -> Db (a, Version)

-- read at a point in history (time travel; see §3)
loadAggregateAt :: forall a. Aggregate a => StreamId -> At -> Db (a, Version)
data At = AtVersion Version | AtTime UTCTime

-- write: append new events at an expected version; fails on conflict
append :: forall a. Aggregate a => StreamId -> Version -> [Event a] -> Db ()
```

`append` writes inside the caller's `withTransaction`, reusing the existing session.
A conflict (someone else advanced the stream) surfaces as a typed error the caller
can retry.

(Brainstorm leaning: **A**, minimal store, over a baked-in decider (B).)

**Deferred:** command/decider helpers; snapshots (periodic state snapshots to bound
replay cost); multi-aggregate transactions beyond the single-stream `append`.

---

## 2. Projections

A **read model is a normal Manifest Entity** (a current-state table) that the full
query builder reads. A projection turns events into read-model writes, using the
ordinary session write API (`add`/`save`/`update`/`deleteWhere`).

### 2.1 Definition — per-aggregate, typed

A projection consumes one aggregate's slice of the log, typed as its `Event a`:

```haskell
data Projection a = Projection
  { projName   :: ByteString            -- checkpoint identity
  , projApply  :: Event a -> Db ()      -- mutate read-model Entities
  , projReset  :: Db ()                 -- truncate the read model (for rebuild)
  }
```

(Brainstorm leaning: **A now**, per-aggregate typed projections; **B later**, global
projections with typed per-event-type handlers for read models that span multiple
aggregates.)

### 2.2 Consumption — asynchronous catch-up, checkpointed

A projection tracks how far it has consumed in a checkpoint table:

```
projection_checkpoints ( name text primary key, position bigint not null )
```

```haskell
-- process events with global_seq > checkpoint, advance the checkpoint
catchUp :: Aggregate a => Projection a -> Db ()

-- rebuild: reset checkpoint to 0, projReset (truncate), replay the whole log
rebuild :: Aggregate a => Projection a -> Db ()

-- replay up to a point (materialise the read model "as of" a position/time)
replayTo :: Aggregate a => Projection a -> At -> Db ()
```

The application drives `catchUp` (a loop, a timer, or — once §3 lands — a
notification). Eventual consistency for read models; the *defining ES capability,
rebuild-from-log,* falls straight out of `projReset` + replay.

(Brainstorm leaning: **B (async catch-up) now, growing into C (also inline
strong-consistency)** later. Inline mode — apply a projection in the same transaction
as `append` for read-after-write consistency — is a deferred follow-up that reuses the
same `projApply` handler.)

**Deferred:** inline/synchronous projections; global multi-aggregate projections (§2.1
B); automatic incremental view maintenance over arbitrary queries (see §3.4).

---

## 3. Reactive / time travel

### 3.1 Time travel — in scope

Nearly free given the log; included in the ES-core slice:

- `loadAggregateAt streamId (AtVersion v | AtTime t)` — fold a stream up to a point.
- `replayTo projection (AtVersion … | AtTime …)` — materialise a read model as it was.

Bounded folds/replays over data already present; no new infrastructure.

### 3.2 Reactive — a change-feed primitive (not a full FRP layer)

A live tail of the log, driven by Postgres `LISTEN/NOTIFY`: `append` issues a
`NOTIFY` (and projection advance can too), so subscribers learn of new events as they
land, and projections can catch up live instead of polling.

```haskell
-- block, invoking the callback for each event past `from`, live via LISTEN/NOTIFY
subscribe :: StreamFilter -> Position -> (RawEvent -> IO ()) -> Db ()

-- keep a projection current by listening instead of looping
runLive   :: Aggregate a => Projection a -> Db ()
```

This reuses `global_seq`/checkpoints; it is the Area-2 runner driven by notifications.
It is the *building block* for reactive reads (re-read a query/projection when its
inputs change) without committing to any FRP semantics; the application composes the
reactivity.

(Brainstorm leaning: **A**, change-feed primitive, over a full FRP layer (B) or
deferring reactive entirely (C).)

### 3.3 Why not a full FRP layer now

A `Behavior`/`Signal` runtime adds composable derived values, glitch-free
consistency, and automatic subscription lifecycle. Those are properties of a reactive
*runtime*, essentially persistence-independent, and Haskell already has libraries
(reflex, sodium) built to provide them. The right architecture is: **Manifest emits
the typed feed; an FRP library consumes it.** Baking a reactive runtime into an ORM
is scope creep, not a Manifest strength.

Crucially, the headline FRP promise — fine-grained incremental updates ("count
updates by ±1 without re-running the query") — is **incremental view maintenance
(IVM)**, a deep, separate undertaking that a "full FRP layer now" would *not* deliver
anyway: a naively-built FRP-over-a-database layer re-runs the query on each relevant
notification under the hood (coarse re-query dressed up as `Behavior Int`). So
choosing the feed now gives up reactive *ergonomics*, not reactive *capability*, and
not the deep win (which is out of scope for either path near-term).

And the Manifest-specific point: **projections already are hand-written incremental
view maintenance** (you write how each event mutates the read model). The change feed
makes them *live*. A live dashboard ("open orders per org, in real time") is a live,
incrementally-maintained read today: maintain a counts projection (§2), and the feed
pushes you to re-read the already-aggregated projection row. No FRP layer required.

### 3.4 Deferred (separate future slices)

- **FRP-the-runtime** — `Behavior`/`Event`/`Signal` ergonomics over the feed; a
  separate layer or a delegation to an existing FRP library.
- **Incremental view maintenance** — query-result deltas from event deltas
  (differential-dataflow flavour); its own research-flavoured project, independent of
  the FRP surface.

---

## 4. Scope & decomposition

The whole is sizable with a forced dependency chain, so it decomposes into sequenced,
independently-shippable sub-projects:

| # | Sub-project | Contents |
|---|---|---|
| 1 | **JSON support** | `aeson` dependency, a `SqlJsonb` column type, a Generics-derived JSON codec. Prerequisite; independently useful (any entity can carry `jsonb`). |
| 2 | **Event store + aggregates + time travel (the ES core)** | `Aggregate` class, the `events` log + migration, `append` (optimistic concurrency) / `loadAggregate` (fold) / `loadAggregateAt` (history), typed conflict errors. |
| 3 | **Projections** | `Projection a`, the checkpoint table, `catchUp` / `replayTo` / `rebuild`, read models as queryable Entities. |
| 4 | **Reactive change feed** | `LISTEN/NOTIFY`-driven `subscribe` / `runLive`; live projection catch-up. |

**First MVP slice = the ES core (sub-projects 1 + 2 folded together).** It is
self-contained and end-to-end useful: define an aggregate, append events with
optimistic concurrency, rebuild its current state by folding, and view its history.
The `jsonb` codec rides along (the event store needs it) and is reusable on its own.
Projections (3) and the reactive feed (4) layer on cleanly as follow-on specs.

(Brainstorm leaning: **A**, decompose with the first cut at the ES core, over folding
projections into the first slice (B) or one mega-spec (C). Each sub-project gets its
own spec → plan → implementation cycle when/if pursued.)

### 4.1 How it sits in the codebase

A new opt-in layer on top of the existing Core/Session, reusing what is already
there:

- **Session** (`Db`, `withTransaction`, `execDb`) for the transactional write/read path.
- **The codec** (extended in sub-project 1 with `jsonb`/aeson).
- **Migrations** for the `events` log, `projection_checkpoints`, and read-model tables
  (read models are ordinary `managed` Entities).
- **The query builder** for reading projections (no new read API needed).

Likely modules: `Manifest.Event` (aggregates + store), `Manifest.Projection`, and a
`Manifest.Event.Live` (or similar) for the feed — each opt-in, none touching the
state-based UoW.

---

## 5. Open questions (settle in the relevant sub-project's plan)

- **Conflict-retry ergonomics** — does `append` expose a retry combinator, or leave
  retry to the caller? (ES core.)
- **Snapshots** — when streams get long, fold cost grows; a snapshot table is the
  standard mitigation. Deferred, but the `loadAggregate` fold should be written so a
  snapshot can short-circuit it later.
- **`event_type` granularity** — aggregate-type tag (chosen, for per-aggregate
  projection filtering) vs constructor-name. Aggregate-type is enough for slice 2/3;
  revisit if global projections (§2.1 B) need finer dispatch.
- **JSON schema evolution / upcasting** — old events with a stale shape. aeson
  tolerant decoders cover simple cases; an explicit upcast hook is a later concern.
- **`NOTIFY` payload size limits** — `NOTIFY` payloads are capped (~8000 bytes), so
  the feed should notify with just `global_seq` and have subscribers read the event,
  not ship the payload through `NOTIFY`. (Reactive sub-project.)

---

## 6. Out of scope (for the whole effort, not just slice 1)

- A command/decider/CQRS framework (the decide logic stays application code).
- A full FRP runtime (`Behavior`/`Signal`) — a separate library on top of the feed.
- Automatic incremental view maintenance over arbitrary queries.
- Cross-aggregate transactional consistency beyond single-stream `append`.
