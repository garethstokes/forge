---
title: Getting started
nav_order: 2
---

# Getting started

This page covers the three steps to use Manifest: define a table, open a session,
and do a first round-trip (`add` / `get` / `save`). Every snippet matches the real
API, the same surface the [tutorials](tutorials/index.md) compile and run as tests.

A Manifest table is one higher-kinded record. That declaration provides the
runtime value, the typed column references the query layer uses, and (via
`deriving Generic` and an `Entity` instance) the table metadata, the row codec,
and the generic CRUD the session drives. For a plain entity the `Entity` instance
is one `deriving via` line, shown below ([Entities](entities.md)).

## 1. Define a table

A table is a record parameterized by a functor `f`, with each field wrapped in
`Col f`. In `Identity` context `Col` erases its markers, so `type User = UserT
Identity` is the plain value `userId :: Int, userName :: Text, userEmail :: Maybe
Text`. The `PrimaryKey (Serial Int)` marker is visible to the metadata deriver but
invisible in the value.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

import Data.Functor.Identity (Identity)
import Data.Text (Text)
import GHC.Generics (Generic)
import Manifest

data UserT f = User
  { userId    :: Col f (PrimaryKey (Serial Int))   -- primary key: the first field
  , userName  :: Col f Text
  , userEmail :: Col f (Maybe Text)
  } deriving Generic

-- The clean runtime value: userId :: Int, userName :: Text, userEmail :: Maybe Text
type User = UserT Identity

deriving via (Table "users" UserT) instance Entity User
```

That one `deriving via` line provides everything: it derives the table name (from
the `"users"` string), the columns, types, PK and serial flags, the row codec, and
`primKey`. There is no `type PrimKey` line to write; the primary-key type is read
from the first field, which is the primary key by convention. The field labels
become typed column references (`#userName`). The session's `get` / `add` / `save`
/ `delete` are generic over the `Entity` class, so deriving the instance is all it
takes.

> An entity that needs `onDelete` cascade rules or row-level-security policies
> writes a short explicit instance instead of the `deriving via` line; the row
> codec and `primKey` still default. See [Entities](entities.md).

## 2. Open a session

A session runs over a connection pool. Build a pool with `newPool` (a libpq
conninfo string and a pool size), then run a `Db` action with `withSession`:

```haskell
import qualified Data.ByteString.Char8 as BC

main :: IO ()
main = do
  pool <- newPool (BC.pack "host=localhost dbname=app user=app") 4
  withSession pool $ do
    -- a Db action: reads and writes share one session and identity map
    pure ()
  closePool pool
```

`withSession :: Pool -> Db a -> IO a` acquires a connection, sets up a fresh
identity map and pending-set, runs your action, and releases the connection. Wrap
writes you want atomic in `withTransaction` (`BEGIN` / `COMMIT`, with rollback on
exception); the flush runs on commit.

## 3. A first round-trip

```haskell
withSession pool $ do
  -- add: a Transient value becomes Persistent; issues INSERT ... RETURNING pk
  -- eagerly and hands the value back with its assigned primary key.
  u <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" } :: User)

  -- get: load by primary key; the row becomes Persistent and a snapshot is taken.
  mu <- get (Key (userId u))           -- :: Db (Maybe User)

  -- save: hand the edited value back. The flush diffs it against the snapshot and
  -- emits a minimal UPDATE; here, only user_name changed.
  withTransaction $ save (u { userName = "Bob" } :: User)
```

`add` returns the value with its serial PK filled in (you start it at `0`; the
database assigns the real id). `get (Key k)` returns `Db (Maybe User)`. `save`
takes the whole edited value; the session works out which columns changed and
writes only those.

## Build setup

Manifest is a Haskell library. Import the umbrella module `Manifest`, which
re-exports the curated public surface (`withSession`, `add`, `get`, `save`,
`delete`, `Entity`, `Key`, the query DSL, relationships, cascades, migrations).
Add it as a dependency the way your build tool pins git dependencies, then
`import Manifest`.

> **The test suite (and the tutorials) need a Postgres.** Manifest talks to a real
> database; there is no in-memory backend. The suite spins up an ephemeral,
> isolated Postgres per run (`initdb` plus `pg_ctl` on a private socket; see
> `test/Fixtures.hs`), so you need `initdb`, `pg_ctl`, and `psql` on `PATH`. The
> dev shell provides them. Running your own app just needs a Postgres reachable via
> the conninfo you pass to `newPool`.

## Examples

The [tutorials](tutorials/index.md) are the worked examples. Each is a literate
Haskell page that the suite compiles and runs against Postgres:

- [Unit of Work](tutorials/Tutorial/UnitOfWork.lhs): edit a value, get a minimal
  `UPDATE`.
- [Relationships](tutorials/Tutorial/Relationships.lhs): load related rows two
  ways.
- [Cascades](tutorials/Tutorial/Cascades.lhs): delete a parent, its children go
  too.

From there, the reference pages cover each layer in depth: start with
[Entities](entities.md) and [Unit of Work](unit-of-work.md).
