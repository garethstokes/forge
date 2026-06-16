# Manifest — Change Feed (z8h slice 1) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-11 · **Issue:** manifest-z8h

**Goal:** A `LISTEN/NOTIFY` change-feed primitive over the EXISTING
state-based world: opted-in entities emit a notification on every session
write; subscribers get `(table, pk)` wake-ups and re-read current state.
Unblocks eval sub-project D (live dashboard progress) with no event-sourcing
buy-in.

---

## 0. Context — what changed since the June 9 proposal

`2026-06-09-event-sourcing-frp-design.md` (a PROPOSAL, never approved)
sequenced z8h as: JSON support → ES core → projections → change feed, with
the feed tailing the *events log*. Two facts have moved:

1. **JSON support shipped independently** (the 2026-06-10 jsonb columns work:
   `Aeson` fields, gin indexes, `.->`/`.->>`). The proposal's slice 1 is done.
2. **The driving consumer's writes don't go through an event log.** Eval
   sub-project D needs "Output/Score rows changed for run N → poke the
   dashboard", but `executeRun`/`scoreRun` write ordinary entities through
   the state-based UoW and will not be rewritten as event-sourced
   aggregates. A feed that tails the events log would never see them.

**Decisions** (user-approved): build the change feed FIRST, rebased onto
state tables; **wake-up-only semantics** (a notification is a hint to
re-read, never data; no durable outbox — the ES core provides durable
history properly later); the ES core/projections/time-travel remain future
slices, unchanged in shape — when the events log lands, `append` emits
through this same machinery, so nothing here is throwaway.

## 1. Emission — opt-in per entity

`Entity` gains a defaulted class member, in the family of
`cascadeRules`/`rlsPolicies`/`indexes`:

```haskell
class Entity a where
  ...
  notifyChanges :: Bool
  notifyChanges = False
```

For an opted-in entity, every write through the session API emits
`SELECT pg_notify('manifest_<table>', <payload>)` on the same connection,
statement-logged like any other SQL:

| Write path | Payload |
|---|---|
| `add` / `save` / `delete` (snapshot path) | the row's pk rendered as text |
| `update` (command path; pk known) | the pk as text |
| `deleteWhere` (command path; no pks known) | empty string (pk-less wake-up) |

Channel name: `manifest_<table>` (the entity's table name). Postgres
provides the transactional correctness for free: `NOTIFY` inside a
transaction is delivered only at COMMIT and not at all on ROLLBACK;
autocommit writes deliver immediately. Postgres also dedups identical
(channel, payload) pairs within one transaction.

**Documented v1 limitations:**

- Cascade-DELETED children do not notify (the cascade walk operates on
  table names, not `Entity` instances; D has no need — revisit when a
  consumer does, e.g. by capturing a notify flag on `CascadeRule` like
  `crChildPk` was).
- No cross-write dedup beyond what Postgres does; N distinct writes in one
  transaction produce N notifications at commit. The sanctioned future
  optimization is session-level per-flush per-table coalescing — legitimate
  exactly because notifications are hints, not data — not an outbox.
- Migrations and raw `execDb` do not notify.

## 2. Subscription — `Manifest.Notify`

```haskell
-- | A wake-up: current state for this table moved. NEVER data — re-read.
data Change = Change
  { table :: ByteString          -- the table whose rows changed
  , key   :: Maybe ByteString    -- the pk as text; Nothing for bulk ops
  }

-- | Open a DEDICATED connection (LISTEN occupies it for life — pool
-- checkouts would starve writers), LISTEN on each table's channel, then
-- block forever dispatching notifications to the callback. Throws on
-- connection loss; the caller owns retry/supervision policy.
listenChanges :: ByteString -> [ByteString] -> (Change -> IO ()) -> IO ()
--               ^ conninfo     ^ table names   ^ per-notification
```

Mechanics: `connectdb`, `LISTEN manifest_<t>` per table, then a loop of
`threadWaitRead` on the libpq socket fd → `consumeInput` → drain
`notifies` → callback per notification. The callback runs on the listener's
thread; slow callbacks delay subsequent deliveries (documented — consumers
should hand off to their own machinery if they do real work).

**Semantics, stated in the haddocks:** a missed notification (listener not
yet attached, connection drop, NOTIFY queue overflow) means staleness until
the next write. Pollable consumers should poll as a backstop. This is the
honest contract of `LISTEN/NOTIFY`; durable delivery is the ES core's job
later.

## 3. How it sits in the codebase

- `Manifest.Entity` — the `notifyChanges` member.
- `Manifest.Session` — emission in `flushSave`/`flushDelete` (snapshot
  path) and `Manifest.Session.Command` (`update`/`deleteWhere`). Emission
  is one `execDb "SELECT pg_notify($1, $2)"` guarded by the entity's flag —
  visible in `statementLog` like everything else.
- New `Manifest.Notify` — `Change`, `listenChanges`. Uses
  `Manifest.Postgres`'s libpq wrapping (plus whatever small additions the
  async-notification loop needs: socket fd access, `consumeInput`,
  `notifies`).
- Re-exports from the umbrella `Manifest` module: `Change(..)`,
  `listenChanges` (and `notifyChanges` rides along in `Entity(..)`).
- No migration-engine changes; no schema objects (channels are dynamic).

## 4. Testing

Ephemeral Postgres; the listener runs on a forked thread (its own conninfo
from the ephemeral cluster) collecting `Change`s into an `IORef`; assertions
wait bounded (a sentinel write pattern, not bare sleeps, wherever possible):

1. `add`/`save` (via field mutation)/`delete` on an opted-in entity each
   deliver `(manifest_<table>, Just pk)`.
2. Two writes inside one `withTransaction` deliver only after commit; a
   rolled-back transaction delivers nothing.
3. `update`/`deleteWhere` deliver (pk and pk-less respectively).
4. A non-opted entity delivers nothing (negative case bounded by a sentinel
   write on an opted-in entity afterwards).
5. Two tables listened simultaneously dispatch to the right `table` field.

## 5. What D does with it (NEXT spec, not this one)

manifest-evals opts in `Run`/`Output`/`Score`/`RunMetric`; the dashboard
server runs `listenChanges` and fans out over SSE; the Miso UI refetches the
affected view. None of that is in this slice.

## 6. Out of scope

- The ES core (aggregates, events log, `append`/`loadAggregate`,
  time travel) and projections — future z8h slices per the June 9 doc.
- Durable delivery / outbox / checkpoints.
- Reconnect/supervision inside `listenChanges` (caller policy).
- Notification payloads carrying row data.
- Cascade-child notification (documented limitation).
