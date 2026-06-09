---
title: Migrations
nav_order: 7
---

# Migrations

Your record declarations are the schema. The same `UserT f` record that gives you
the runtime value and the query column references also carries the table metadata:
table name, columns, SQL types, nullability, and the primary key. The migration
engine reflects that metadata, compares it against the live database, and produces
the additive DDL to bring the database into line. You don't keep a separate schema
file in sync by hand; the records are the single source of truth. Migrations also
reconcile row-level-security policies; see [Row-level security](rls.md).

This page covers reflecting an entity's schema with `managed`, computing and
applying plans with `migrate` / `migrateUp`, the `manifest-migrate` CLI, the
`schema_migrations` tracking table, and the additive-only policy that surfaces
destructive changes rather than applying them. The core is **built** (Sub-project 3);
the *Status* section is precise about the follow-ups that are deferred.

## Concepts

Manifest already derives table metadata from each entity for the codec and CRUD.
Migrations reuse that same metadata, so there is one description of the schema, the
record, and the migrator can't drift from what the session reads and writes. The
policy is conservative: it will freely add tables and columns, but it will never drop
or retype anything automatically. A change that would lose data is surfaced for
review, not applied, so running a migration can't silently destroy a column.

## Reflecting an entity: `managed`

`managed` reflects an entity's schema into a `ManagedTable` (its name and columns):

```hs
managed :: Entity a => Proxy a -> ManagedTable
```

```haskell
schema :: [ManagedTable]
schema = [ managed (Proxy @User), managed (Proxy @Post) ]
```

A `[ManagedTable]` is the full set of tables the migrator manages; you list one
`managed (Proxy @Entity)` per entity.

## Computing a plan: `migrate`

`migrate` diffs the managed tables against the live database and returns a
`MigrationPlan`: the additive DDL to apply, plus any destructive issues that need
human review.

```hs
migrate :: [ManagedTable] -> Db MigrationPlan

data MigrationPlan = MigrationPlan
  { planAdditive    :: [ByteString]   -- CREATE TABLE / ADD COLUMN, in order
  , planDestructive :: [String]       -- "column … type mismatch …"; review only
  }
```

The per-table diff (`diffTable`) yields one of three outcomes. `CreateTable`: the
table is absent, so a `CREATE TABLE`. `AlterTable`: the table exists but is missing
columns, so `ALTER TABLE … ADD COLUMN`, plus any destructive issues. `UpToDate`: no
change.

## Applying a plan: `migrateUp`

`migrateUp` computes the plan and applies the additive part in a transaction,
recording a row in the tracking table:

```hs
migrateUp :: [ManagedTable] -> Db MigrationPlan
```

It first ensures the `schema_migrations` tracking table exists, then:

* if the plan has any destructive issues, it aborts (throws); destructive changes are
  never silently applied;
* otherwise it runs the additive statements inside `withTransaction` and inserts a
  `schema_migrations` row recording how many statements were applied.

`migrateUp` is idempotent: a second run against an already-migrated database computes
an empty additive plan and is a no-op.

## The CLI: `manifest-migrate`

The `manifest-migrate` executable (`app/Main.hs`) wires a `[ManagedTable]` schema to
the two subcommands. It reads the connection string from the `MANIFEST_DATABASE_URL`
environment variable:

```sh
export MANIFEST_DATABASE_URL=postgres://localhost/mydb

manifest-migrate diff   # print the pending additive DDL; destructive issues to stderr (NOT applied)
manifest-migrate up     # apply the additive plan in a transaction; record it in schema_migrations
```

`diff` prints the additive statements to stdout, and any destructive issues to stderr
under a `-- destructive (review, not applied):` banner. `up` applies the plan and
reports how many statements ran.

## Tracking: `schema_migrations`

`migrateUp` bootstraps a `schema_migrations` table (`id`, `applied_at`, `statements`)
if it doesn't exist, and inserts one row per applied migration. This records that a
migration ran and how many statements it applied. (It is not yet a per-version ledger
keyed to named migration files; see *Status*.)

## Additive-only, with destructive surfaced

The engine compares the record's columns to the live columns:

* a column in the record but not live becomes an additive `ADD COLUMN` (or, if the
  whole table is absent, a `CREATE TABLE`);
* a column in both, but with a different SQL type, becomes a destructive issue: it is
  reported but never applied. `migrateUp` aborts the whole run if any exist.

So the happy path (adding a new entity, or adding a field to an existing one) is fully
automatic, while anything that could lose data stops at the human. This is the
conservative core; the richer destructive operations are deferred (below).

## Examples

`test/MigrateSpec.hs` exercises the engine against real Postgres: `diffTable` on an
empty database returns `CreateTable`; a table missing a column returns `AlterTable`
with the additive `ADD COLUMN`; a type mismatch is flagged destructive and not
applied; `migrateUp` creates the managed tables, is a no-op on re-run, applies a
missing column, and aborts on a destructive diff with no DDL applied. The shapes there
are the shapes the CLI drives.

## Status

The migration **core is built and tested** (Sub-project 3): schema reflection via
`managed`, plan computation via `migrate` / `diffTable`, transactional application via
`migrateUp` with `schema_migrations` tracking, the `manifest-migrate diff` / `up` CLI,
and the additive-only policy that surfaces destructive changes instead of applying
them.

These follow-ups are **Planned**, not built, and this page does not show them as
working:

* **Versioned migration files.** There is no generation of
  numbered/named `.sql` migration files, and `schema_migrations` is a run-count ledger
  rather than a per-version history keyed to such files. Migrations are computed live
  from the records, not replayed from a file series.
* **Auto-applied destructive changes.** Column renames, drops, and type changes are
  detected (type changes are surfaced as destructive issues) but never applied
  automatically; they are reported for manual handling.
* **Nullability diffs.** Changing a column's `NULL` / `NOT NULL` is not yet diffed or
  migrated; only column presence and SQL type are compared.
