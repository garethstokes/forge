---
title: Unit of Work
nav_order: 4
---

# Unit of Work

The Unit of Work is the layer this library exists for: a session with an identity
map and change tracking that lets you **edit plain values and have the session
compute the minimal SQL**. You load (or create) a record, edit a field with
ordinary record-update syntax, hand it back with `save`, and at flush time
Manifest diffs it against the snapshot it took when the value entered the session
and emits an `UPDATE` touching only the columns that actually changed. You never
hand-write the SQL and never declare which columns are dirty.

This page covers the `Db` monad and `Session`, the identity map, the four entity
states, snapshot-diff change tracking, the flush algorithm, autoflush, and the
command escape hatch. The runnable companion is the
[Unit of Work tutorial](tutorials/Tutorial/UnitOfWork.lhs) — a literate page the
suite compiles and runs against Postgres.

## Why

In SQLAlchemy you edit an object and the session works out the SQL, because the
session can observe the object mutate in place. A plain Haskell value has no
hidden state, so that trick doesn't exist:
`let u' = u { userName = "Bob" }` is invisible to the session. Manifest takes the
honest path. Identity is the **primary key** — a field already on the record — and
you hand the edited value back via `save`. The session looks up the row's baseline
*by its primary key*, diffs your value against it, and writes only the difference.
That is value-based identity, and it is exactly correct: the PK **is** the row's
identity.

## What

### The `Db` monad and `Session`

`Db` is a sealed `newtype` over `ReaderT Session IO`:

```hs
newtype Db a = Db (ReaderT Session IO a)
  deriving (Functor, Applicative, Monad, MonadIO)
```

A `Session` bundles the borrowed connection, the identity map, the pending-write
queue, the statement log, and the config:

```hs
data Session = Session
  { sessConn     :: Connection
  , sessIdentity :: IORef IdentityMap
  , sessPending  :: IORef [PendingOp]
  , sessLog      :: IORef [(ByteString, [SqlParam])]
  , sessConfig   :: SessionConfig
  }
```

You never touch `Session` directly. You run a `Db` action with `withSession`,
which acquires a connection from the pool, sets up fresh per-session maps, runs
your action, and releases the connection:

```haskell
withSession pool $ do
  -- a Db action: reads and writes share one session + identity map
  pure ()
```

Writes you want atomic go inside `withTransaction`, which brackets the block with
`BEGIN` / `COMMIT` (rolling back and re-throwing on exception) and **flushes
pending writes on commit**.

### The identity map

The identity map is `(type, encoded-PK) → baseline column vector`:

```hs
type IdentityMap = Map (SomeTypeRep, SqlParam) [SqlParam]
```

It is heterogeneous — it holds every entity type at once — keyed by the row's type
and its encoded primary key, mapping to the *baseline*: the encoded column values
as they were when the value became managed. That baseline is what `save` diffs
against. The map is internal and never user-visible.

A value enters the map (gets a baseline snapshot) when it becomes Persistent:
- `get` / `selectWhere` load it from the database;
- `add` inserts it and reads back the `RETURNING` row;
- a relationship load (`load`, `with`) registers each loaded child.

### The four entity states

Manifest ports SQLAlchemy's four states:

```
 Transient ──add──▶ Pending ──flush──▶ Persistent ──delete+flush──▶ Deleted
 (plain value,                         (in identity map,
  no session)                           has baseline snapshot)
```

* **Transient** — a plain value you constructed, not yet in any session
  (`User { … }`).
* **Pending** — handed to the session, awaiting flush. (`save` and `delete`
  queue Pending ops; `add` is eager — see the note under *Flush*.)
* **Persistent** — in the identity map with a baseline snapshot. `get` /
  `selectWhere` produce Persistent entities directly; `add` makes its value
  Persistent once the `INSERT … RETURNING` completes.
* **Deleted** — flushed `delete`; the row is gone and its identity-map entry is
  dropped.

### Snapshot-diff change tracking

This is the heart of it. When a value becomes Persistent the session stores its
encoded columns as a baseline. `save u'` queues the value; at flush the session
compares the handed-back value against the baseline **column by column** and
builds an `UPDATE` naming only the columns that differ. The primary key is never a
diff target (changing it would be an identity change, which is the command path's
job). A `save` that changed nothing emits no SQL at all.

So editing one field of a three-column row produces a one-column `UPDATE`:

```haskell
u <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" } :: User)
withTransaction $ save (u { userName = "Bob" } :: User)
--   flush diffs against the baseline → only user_name changed →
--   UPDATE users SET user_name = $1 WHERE user_id = $2
```

That is the assertion the [Unit of Work tutorial](tutorials/Tutorial/UnitOfWork.lhs)
makes, exactly, against a live Postgres.

## How

### The flush algorithm

A flush runs on `withTransaction` commit, on an explicit `flush`, or — when
autoflush is on — before each query. It drains the pending queue and applies the
deferred operations:

1. **Saves** → for each, look up the baseline; diff the handed-back value against
   it column-by-column; emit `UPDATE t SET <changed columns> WHERE pk = $n` over
   the changed non-PK columns only; refresh the baseline. A no-op save (nothing
   changed) emits nothing. A `save` of a value with no baseline is an error
   (`UnmanagedSave`) — you can only `save` something the session is managing.
2. **Deletes** → for each, apply onDelete cascades (see [Cascades](cascades.md)),
   then `DELETE … WHERE pk = $n`, and drop the row from the identity map.

> **Adds are eager.** The design sketches the flush as inserts → updates →
> deletes, and that *ordering* holds, but in this build `add` issues its
> `INSERT … RETURNING` immediately rather than queuing it: it has to, because it
> needs the database-assigned serial PK back in hand to return the persistent
> value. So by flush time the inserts have already happened; the flush itself
> applies the queued saves then the queued deletes. The observable order across a
> transaction is still insert, then update, then delete.
>
> **Planned:** FK-aware topological ordering of the flush is a deferred follow-up;
> today the order is the fixed insert → update → delete above.

### Autoflush

Autoflush is **on** by default (`cfgAutoflush = True`). Before each read
(`get` / `selectWhere`) the session flushes pending writes first, so a read sees
your un-flushed edits — the SQLAlchemy default. You can think of it as: your
writes are visible to your own subsequent reads within the session, without you
calling `flush` by hand.

### The command escape hatch

Snapshot-diff is the default, but for blind or bulk writes there is a command path
that bypasses the identity map entirely:

```hs
update      :: (Entity a, ToField (PrimKey a)) => Key a -> [Assign a] -> Db ()
deleteWhere :: Entity a                        => [Cond a]            -> Db ()
```

`update` issues a single blind `UPDATE t SET … WHERE pk = $n` from the given
`#col =. value` assignments — no snapshot, no diff. `deleteWhere` issues a bulk
`DELETE` over `[Cond a]` conditions with no per-row identity. Both run
immediately (logged, autocommit) and touch neither the pending queue nor the
baselines. Use them when you genuinely want a blind write — a counter bump, a bulk
expiry — and don't need the row's prior state:

```haskell
update (Key 42) [ #userName =. "Bob" ]          -- blind single-row UPDATE
deleteWhere @Post [ #postAuthor ==. 7 ]         -- bulk DELETE by condition
```

## Examples

The clearest worked example is the
[Unit of Work tutorial](tutorials/Tutorial/UnitOfWork.lhs): it `add`s a `User`,
`save`s it with one field changed inside a transaction, captures the session's
`statementLog`, and asserts the only `UPDATE` issued is the minimal one. Because
the page is a test, that assertion is checked on every run — the documentation
can't drift from the behaviour.

For the read/edit side without the session plumbing:

```hs
withSession pool $ do
  Just user <- get (Key 1)          -- becomes Persistent; baseline taken here
  withTransaction $
    save (user { userEmail = Just "new@x.io" })
    -- diff vs baseline → UPDATE users SET user_email = $1 WHERE user_id = $2
```

Change the email instead of the name and the minimal `UPDATE` shifts columns; the
mechanism is identical. The reference pages either side of this one are
[Entities](entities.md) (the records the session manages) and
[Relationships](relationships.md) (loading related rows, all of which become
managed and flow through this same snapshot-diff path).
