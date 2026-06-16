---
title: Change Feed
nav_order: 10
---

# Change Feed

Manifest writes go to Postgres, but downstream code — a live dashboard, a
cache invalidator, a progress-streaming endpoint — often needs to know when a
row changed without busy-polling. The change feed wires `LISTEN/NOTIFY` into
the session so that opted-in entities emit a `pg_notify` on every write, and a
dedicated subscriber thread receives wake-ups through `listenChanges`. The
driving case is the eval dashboard: when `Output` and `Score` rows are
committed, the server pushes an SSE event and the UI refetches.

This page covers the opt-in declaration, the wake-up semantics, a worked
example, and the documented limitations. The semantics and API shown here
match the tested fixtures in `test/NotifySpec.hs`.

## Why

The alternative to `LISTEN/NOTIFY` is polling: a background loop wakes on a
timer and re-reads. Polling is simple but wastes work when nothing changed and
adds latency when something has. `LISTEN/NOTIFY` flips the model: the database
notifies the subscriber immediately after a commit, the subscriber re-reads
only what it needs, and the connection sleeps in between.

Manifest's change feed keeps the semantics state-based: a notification is a
**hint to re-read**, not a payload. The subscriber receives `(table, pk)` and
then does a `get` or `selectWhere` to learn the current value. This means
notifications are cheap (one small `pg_notify` per write), missed notifications
produce staleness rather than data loss, and the subscriber is always consistent
with committed state.

## What

An entity opts in by overriding the `notifyChanges` class member (it defaults
to `False`):

```haskell
instance Entity Ping where
  tableMeta    = ...
  rowDecoder   = ...
  rowEncode    = ...
  primKey      = ...
  notifyChanges = True
```

With `notifyChanges = True`, every write through the session API emits
`SELECT pg_notify('manifest_<table>', <payload>)` on the same connection,
inside the same transaction:

| Write path | Payload |
|---|---|
| `add` / `save` / `delete` (snapshot path) | pk rendered as text |
| `update` (command path; pk known) | pk as text |
| `deleteWhere` (command path; no pks known) | empty string (pk-less wake-up) |

The channel name is `manifest_<table>` where `<table>` is the entity's table
name. Postgres delivers `NOTIFY` at commit and suppresses it entirely on
rollback, so subscribers only see writes that actually landed.

On the subscriber side, `Change` carries the table and optional pk:

```haskell
data Change = Change
  { table :: ByteString        -- the table whose rows changed
  , key   :: Maybe ByteString  -- pk as text; Nothing for bulk ops
  }
```

A `Change` is a hint. Re-read after receiving one; never treat it as data.

## How

A worked example: a `Ping` entity opts in, a listener loop prints each change,
and a session writes a few rows.

```haskell
import Manifest
import Manifest.Core.Meta (genericTableMeta)
import Manifest.Core.Table (Field, Pk)
import Manifest.Notify (Change (..), listenChanges)
import Control.Concurrent (forkIO)
import Data.Functor.Identity (Identity)
import Data.ByteString.Char8 (putStrLn)
import GHC.Generics (Generic)
import Prelude hiding (putStrLn)

-- A minimal entity with notifyChanges enabled.
data PingT f = Ping
  { pingId  :: Field f (Pk Int)
  , pingMsg :: Field f String
  } deriving Generic

type Ping = PingT Identity

instance Entity Ping where
  tableMeta     = genericTableMeta @PingT "pings"
  notifyChanges = True

main :: IO ()
main = do
  let conninfo = "postgresql:///mydb"
  pool <- newPool conninfo 4

  -- listenChanges needs a DEDICATED connection — LISTEN occupies it
  -- for its lifetime and must not share the pool.
  _ <- forkIO $
    listenChanges conninfo ["pings"] $ \ch ->
      putStrLn ("change: table=" <> table ch
             <> " key=" <> maybe "(bulk)" id (key ch))

  withSession pool $ withTransaction $ do
    p <- add (Ping { pingId = 0, pingMsg = "hello" } :: Ping)
    save (p { pingMsg = "world" } :: Ping)
  -- notifications are delivered after the withTransaction commits.
```

`listenChanges` opens its own libpq connection, sends `LISTEN manifest_pings`,
then blocks in a `threadWaitRead` loop on the socket's file descriptor. Each
time Postgres wakes it, it drains all pending `notifies` and calls the callback
for each one. The callback runs on the listener's thread: slow callbacks delay
subsequent deliveries, so hand off to a queue or `Chan` if your consumer does
real work.

A missed notification — because the listener was not yet attached, the
connection dropped, or the Postgres `NOTIFY` queue overflowed — means the
subscriber sees staleness until the next write triggers a new notification.
Subscribers that must not miss changes should poll on a background timer as a
backstop. `listenChanges` throws `DbException` on connection loss; reconnect
and supervision are the caller's responsibility.

## Limitations

- **Cascade children are silent.** A `Cascade`-deleted child entity does not
  emit a notification, even if it has `notifyChanges = True`. The cascade walk
  operates on table names rather than `Entity` instances. If you need
  notifications from cascade children, add an explicit `delete` before the
  parent delete or trigger the cascade yourself.
- **No cross-write dedup.** N distinct writes in one transaction produce N
  notifications at commit (Postgres deduplicates identical `(channel, payload)`
  pairs, but distinct pks are not identical). The sanctioned future optimization
  is session-level per-flush per-table coalescing; this is safe because
  notifications are hints, not data.
- **Migrations and raw `execDb` are silent.** `migrateUp` and hand-written SQL
  run outside the `notifyChanges` path; they do not emit notifications.
- **Concurrent work benefits from `-threaded`.** The blocking libpq calls
  (`connectdb`, the LISTEN round-trips) are safe FFI calls that stall the entire
  non-threaded runtime while they run; compile listeners that share a process
  with real concurrent work using `-threaded`.
