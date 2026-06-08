---
title: Home
nav_order: 1
---

# manifest

The Unit-of-Work layer Haskell never had.

The Haskell ecosystem has excellent *Core* layers — beam, rel8, esqueleto,
opaleye give you type-safe, composable SQL — but no real *ORM* layer. Nobody had
ported SQLAlchemy's **Unit of Work**: a session with an identity map, change
tracking that emits minimal `UPDATE`s, relationship-loading strategies, and
cascades. That gap exists because the obvious implementation relies on mutating
objects in place, which is unidiomatic — even impossible — in Haskell.

Manifest closes it. It is a SQLAlchemy-style Unit of Work sitting on a thin,
owned, Higher-Kinded-Data Core, with a derive layer that turns plain record
declarations into schema, CRUD, relationships, and migrations.

```haskell
withSession pool $ do
  u <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" } :: User)
  withTransaction $ save (u { userName = "Bob" } :: User)
  --                                        ^ edit a plain value;
  --   flush computes the minimal write: UPDATE users SET user_name = $1 WHERE user_id = $2
```

## Why

In SQLAlchemy you edit an object and the session works out the SQL. In Haskell a
value has no hidden state, so the trick everyone reached for — observe a mutation
in place — does not exist. Manifest takes the honest path: identity is the
**primary key** (a field on the record), and you hand the edited value back with
`save`. The session diffs it against the snapshot it took when the value entered
the session and emits an `UPDATE` touching only the columns that actually
changed. You never hand-write SQL; you never tell it which columns are dirty.

## What

One record declaration serves three jobs. A higher-kinded record `UserT f`
collapses, in `Identity` context, to the clean runtime value `type User =
UserT Identity`; in query context the same fields become typed column references
(`#userName`). `deriving Generic` plus an `Entity` instance derives the table
metadata, the row codec, and the generic CRUD the session drives — no Template
Haskell, no per-table codegen.

On top of that Core sits the session: an identity map, the four entity states
(transient → pending → persistent → deleted), snapshot-diff change tracking, an
insert→update→delete flush, relationship loading (two paths, `selectin` vs
`joined`), and onDelete cascades applied at flush.

## How

- **[Getting started](getting-started.md)** — define a table, open a session,
  do a first round-trip (`add` / `get` / `save`).
- **[Entities](entities.md)** — HKD records, `Col`/`Identity` erasure,
  `deriving Generic` + the `Entity` instance, keys, and `#label` column refs.
- **[Unit of Work](unit-of-work.md)** — the `Db` monad, the identity map, the
  four states, snapshot-diff, and the flush algorithm.
- **[Relationships](relationships.md)** — the A-path (`load`) and D-path
  (`Ent` / `with` / `rel`), `selectin` vs `joined`, and one-level nesting.
- **[Cascades](cascades.md)** and **[Migrations](migrations.md)** — onDelete
  policies, and records as the schema source of truth.
- **[Tutorials](tutorials/index.md)** — literate Haskell pages that are also
  runnable tests in the suite.

## Examples

The clearest examples are the [Tutorials](tutorials/index.md): each is a literate
`.lhs` file that the test suite compiles and runs against a real Postgres, so the
code on the page is the code that runs. Start with
[Unit of Work](tutorials/Tutorial/UnitOfWork.lhs).

## Status

Manifest is real and tested for the Unit of Work, relationships, cascades, and
migrations (the parts the reference pages document). Two surfaces named in the
design are **Planned**, not built — do not assume they work yet:

- **Joins and aggregates in the query Core** — the standalone query AST does not
  yet expose joins/aggregates (relationship loading *does* use a `LEFT JOIN`
  internally; that is a separate, working path).
- **The Template Haskell front-end** — the terse `@derive`-style macro is
  deferred. Today you hand-write the `UserT f` record + `deriving Generic` + the
  `Entity` instance, which is the honest, transparent foundation.

The site is published by **GitHub Pages' built-in Jekyll build** of `docs/` —
there is no Actions workflow. The tutorials run as tests and require a Postgres
(the suite spins up an ephemeral one); a local Jekyll build is out of scope.
