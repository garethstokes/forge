---
title: Getting started
nav_order: 2
---

# Getting started

This walks through the three things you need to use Manifest: **define a table**,
**open a session**, and do a **first round-trip** (`add` / `get` / `save`). Every
snippet below matches the real API — the same surface the
[tutorials](tutorials/index.md) compile and run as tests.

## Why

A Manifest table is one higher-kinded record. That single declaration gives you
the clean runtime value, the typed column references the query layer uses, and —
via `deriving Generic` and an `Entity` instance — the table metadata, the row
codec, and the generic CRUD the session drives. No Template Haskell, no per-table
boilerplate beyond the record and the instance.

## What

### 1. Define a table

A table is a record parameterized by a functor `f`, with each field wrapped in
`Col f`. In `Identity` context `Col` erases its markers, so `type User = UserT
Identity` is the plain value `userId :: Int, userName :: Text, userEmail :: Maybe
Text`. The `PrimaryKey (Serial Int)` marker is visible to the metadata deriver
but invisible in the value.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

import Data.Functor.Identity (Identity)
import Data.Text (Text)
import GHC.Generics (Generic)
import Manifest

data UserT f = User
  { userId    :: Col f (PrimaryKey (Serial Int))
  , userName  :: Col f Text
  , userEmail :: Col f (Maybe Text)
  } deriving Generic

-- The clean runtime value: userId :: Int, userName :: Text, userEmail :: Maybe Text
type User = UserT Identity

instance Entity User where
  type PrimKey User = Int
  tableMeta  = genericTableMeta @UserT "users"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = userId
```

`deriving Generic` plus this `Entity` instance is everything: `genericTableMeta`
derives the table name, columns, types, PK and serial flags; `genericRowDecoder`
/ `genericRowEncode` derive the row codec; and the field labels become typed
column references (`#userName`). The session's `get` / `add` / `save` / `delete`
are generic over the `Entity` class — defining the instance is all it takes.

### 2. Open a session

A session runs over a connection pool. Build a pool with `newPool` (a libpq
conninfo string and a pool size), then run a `Db` action with `withSession`:

```haskell
import qualified Data.ByteString.Char8 as BC

main :: IO ()
main = do
  pool <- newPool (BC.pack "host=localhost dbname=app user=app") 4
  withSession pool $ do
    -- a Db action: reads and writes share one session + identity map
    pure ()
  closePool pool
```

`withSession :: Pool -> Db a -> IO a` acquires a connection, sets up a fresh
identity map and pending-set, runs your action, and releases the connection.
Wrap writes you want atomic in `withTransaction` (`BEGIN` / `COMMIT`, with
rollback on exception); the flush runs on commit.

### 3. A first round-trip

```haskell
withSession pool $ do
  -- add: a Transient value -> Pending; flush emits INSERT ... RETURNING pk and
  -- hands the value back with its assigned primary key.
  u <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" } :: User)

  -- get: load by primary key; the row becomes Persistent and a snapshot is taken.
  mu <- get (Key (userId u))           -- :: Db (Maybe User)

  -- save: hand the edited value back. The flush diffs it against the snapshot and
  -- emits a minimal UPDATE -- here, only user_name changed.
  withTransaction $ save (u { userName = "Bob" } :: User)
```

`add` returns the value with its serial PK filled in (you start it at `0`; the
database assigns the real id). `get (Key k)` returns `Db (Maybe User)`. `save`
takes the whole edited value — the session works out which columns changed and
writes only those.

## How (build setup)

Manifest is a Haskell library; import the umbrella module `Manifest`, which
re-exports the curated public surface (`withSession`, `add`, `get`, `save`,
`delete`, `Entity`, `Key`, the query DSL, relationships, cascades, migrations).
Add it as a dependency the way your build tool pins git dependencies, then
`import Manifest`.

> **The test suite (and the tutorials) need a Postgres.** Manifest talks to a
> real database — there is no in-memory backend. The suite spins up an ephemeral,
> isolated Postgres per run (`initdb` + `pg_ctl` on a private socket; see
> `test/Fixtures.hs`), so you need `initdb`, `pg_ctl`, and `psql` on `PATH`. The
> dev shell provides them. Running your own app just needs a Postgres reachable
> via the conninfo you pass to `newPool`.

## Examples

The [tutorials](tutorials/index.md) are the worked examples — each is a literate
Haskell page that the suite compiles and runs against Postgres:

- [Unit of Work](tutorials/Tutorial/UnitOfWork.lhs) — edit a value, get a minimal
  `UPDATE`.
- [Relationships](tutorials/Tutorial/Relationships.lhs) — load related rows two
  ways.
- [Cascades](tutorials/Tutorial/Cascades.lhs) — delete a parent, its children go
  too.

From there, the reference pages cover each layer in depth: start with
[Entities](entities.md) and [Unit of Work](unit-of-work.md).
