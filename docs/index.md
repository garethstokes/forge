---
title: Home
nav_order: 1
---

# manifest

Manifest is a Unit-of-Work ORM for Haskell, built on a small Higher-Kinded-Data
Core. It provides an identity map, change tracking that emits minimal `UPDATE`s,
relationship-loading strategies, onDelete cascades, and schema migrations derived
from your record declarations.

```haskell
withSession pool $ do
  u <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" } :: User)
  withTransaction $ save (u { userName = "Bob" } :: User)
  -- flush computes the minimal write:
  -- UPDATE users SET user_name = $1 WHERE user_id = $2
```

## Concepts

Identity is the primary key, a field on the record. You read a value, edit it as
an ordinary Haskell value, and hand it back with `save`. The session diffs it
against the snapshot it took when the value entered the session and emits an
`UPDATE` touching only the columns that changed. You do not write SQL, and you do
not mark columns dirty.

One record declaration serves three roles. A higher-kinded record `UserT f`
becomes, in `Identity` context, the runtime value `type User = UserT Identity`;
in query context the same fields become typed column references (`#userName`).
`deriving Generic` and an `Entity` instance provide the table metadata, the row
codec, and the generic CRUD the session drives. You can write the record and
instance by hand or generate them with the `mkEntity` Template Haskell macro.

On top of the Core sits the session: an identity map, the four entity states
(transient, pending, persistent, deleted), snapshot-diff change tracking, an
insert/update/delete flush, relationship loading (two strategies, `selectin` and
`joined`), and onDelete cascades applied at flush.

## Pages

- [Getting started](getting-started.md): define a table, open a session, do a
  first round-trip (`add` / `get` / `save`).
- [Entities](entities.md): HKD records, `Col`/`Identity` erasure, `deriving
  Generic` and the `Entity` instance, keys, `#label` column references, and the
  `mkEntity` macro.
- [Unit of Work](unit-of-work.md): the `Db` monad, the identity map, the four
  states, snapshot-diff, and the flush algorithm.
- [Relationships](relationships.md): the A-path (`load`) and D-path (`Ent` /
  `with` / `rel`), `selectin` vs `joined`, and one-level nesting.
- [Cascades](cascades.md) and [Migrations](migrations.md): onDelete policies, and
  records as the schema source of truth.
- [Queries](queries.md): the query builder, ordering, pagination, inner joins, and
  aggregates.
- [Row-level security](rls.md): declarative tenant policies, declarative migration,
  and `withRlsContext` for the per-request context.
- [Tutorials](tutorials/index.md): literate Haskell pages that are also runnable
  tests in the suite.

## Examples

The tutorials are the worked examples. Each is a literate `.lhs` file that the
test suite compiles and runs against a real Postgres, so the code on the page is
the code that runs. Start with
[Unit of Work](tutorials/Tutorial/UnitOfWork.lhs).

## Status

The Unit of Work, relationships, cascades, migrations, the Template Haskell entity
front-end, and the query builder (joins, ordering, pagination, and aggregates) are
built and tested. See the reference pages, and [Queries](queries.md) for the builder.

The `mkEntity` macro generates the record, `deriving Generic`, and the `Entity`
instance from one block (see [Entities](entities.md)). It builds the core entity;
relationships and cascades are declared separately. Hand-writing the record and
instance is fully supported and is what the snippets above show.

The site is published by GitHub Pages' built-in Jekyll build of `docs/`; there is
no Actions workflow. The tutorials run as tests and require a Postgres (the suite
spins up an ephemeral one); a local Jekyll build is out of scope.
