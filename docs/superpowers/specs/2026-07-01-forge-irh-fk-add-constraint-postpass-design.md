# forge-irh — FK constraints via `ALTER TABLE … ADD CONSTRAINT` post-pass

**Status:** Approved design (brainstorm complete) · **Date:** 2026-07-01
**Bead:** forge-irh · **Follows:** forge-u0w (References FK markers, merged)

---

## Problem

forge-u0w made the migration engine emit `FOREIGN KEY (col) REFERENCES target(pk)`
constraints **inline** in `CREATE TABLE`. That makes the migrate `[ManagedTable]`
list order load-bearing: a table whose `References` FK targets another must appear
*after* its target in the list, or `migrate up` fails at run time with
`relation "…" does not exist`. Circular FKs (A→B and B→A) are impossible to express
at all. The forge-u0w final review flagged this as an Important sharp edge; the marker
+ spec document the ordering requirement as a stopgap. This bead removes it.

## Solution

Stop emitting FK constraints inline. Emit them in a separate **post-pass** of
`ALTER TABLE <child> ADD CONSTRAINT … FOREIGN KEY …` statements that runs *after* all
`CREATE TABLE`s (and `ADD COLUMN`s), when every target table is guaranteed to exist.
This is the standard approach and also makes circular FKs work.

The engine already has the exact pattern to mirror: **indexes** (`indexesForTable`/
`indexPlan`) and **RLS** (`rlsForTable`/`rlsPlan`) are reconciled the same way —
create-if-absent, never drop, computed against the live DB and recomputed inside the
migrate transaction after tables are created. FK reconciliation slots in identically.

## Design

### Stop inline FK emission

- **`renderCreateTable`** (`Manifest/Migrate.hs`) drops the `++ map fkDDL fks` part —
  emits columns only:
  ```haskell
  renderCreateTable (ManagedTable name cols _ _ _) =
    "CREATE TABLE " <> name <> " (" <> BC.intercalate ", " (map columnDDL cols) <> ")"
  ```
  (`fkDDL` is removed; `renderAddForeignKey` below replaces it.)
- **`renderAddColumn`** reverts to its pre-forge-u0w signature and body — no FK list,
  no inline `REFERENCES`:
  ```haskell
  renderAddColumn :: ByteString -> ColumnMeta -> ByteString
  renderAddColumn table c =
    "ALTER TABLE " <> table <> " ADD COLUMN " <> cmName c <> " " <> sqlTypeDDL (cmSqlType c)
      <> (if cmNullable c then "" else " NOT NULL")
  ```
  The `toAdditive` caller in `migrate` reverts to `renderAddColumn t c`; the
  `MigrateSqlSpec` callers revert to the 2-arg form (their expected strings are
  unchanged — they never asserted an FK). A newly-added FK column gets its constraint
  from the post-pass, so nothing is lost.

`ManagedTable.mtForeignKeys` stays (populated by `managed` from `foreignKeys @a`); the
post-pass reads it.

### FK post-pass (mirrors `indexPlan`/`rlsPlan`)

- **`renderAddForeignKey :: ByteString -> ForeignKey -> ByteString`** — the constraint
  is named `<table>_<column>_fkey` (Postgres's own default convention), so it is
  reconcilable by name:
  ```haskell
  renderAddForeignKey table fk =
    "ALTER TABLE " <> table <> " ADD CONSTRAINT "
      <> table <> "_" <> fkColumn fk <> "_fkey"
      <> " FOREIGN KEY (" <> fkColumn fk <> ") REFERENCES "
      <> fkRefTable fk <> "(" <> fkRefPkColumn fk <> ")"
  ```
- **`liveForeignKeys :: ByteString -> Db [ByteString]`** — the FK constraint names
  already on a table:
  ```sql
  SELECT constraint_name FROM information_schema.table_constraints
   WHERE table_schema='public' AND table_name=$1 AND constraint_type='FOREIGN KEY'
  ```
- **`foreignKeysForTable :: ManagedTable -> Db [ByteString]`** — `ADD CONSTRAINT`
  statements for `mtForeignKeys` whose generated name is not already live; `[]` when
  the table has no FKs or does not exist yet (exactly like `indexesForTable`).
  **Create-if-absent; never drops** (a constraint present in the DB but not declared is
  left alone — consistent with the index policy).
- **`foreignKeyPlan :: [ManagedTable] -> Db [ByteString]`** —
  `fmap concat . mapM foreignKeysForTable`.

### Orchestration

- **`MigrationPlan`** gains `planForeignKeys :: [ByteString]` (after `planIndexes`).
- **`migrate`** computes `fks <- foreignKeyPlan tables` and includes it in the plan.
- **`migrateUp`** — inside the existing single `withTransaction`, apply in this order:
  1. `additive` (all `CREATE TABLE` + `ADD COLUMN`) — unchanged.
  2. **recompute + apply `foreignKeyPlan tables`** — every target table now exists, so
     ordering is irrelevant and circular FKs resolve.
  3. RLS, then indexes — unchanged.
  The `schema_migrations` statement count includes the FK statements. The empty-work
  guard also considers `foreignKeyPlan` (so a run whose only pending work is a new FK
  constraint still opens the transaction).
- **`runMigrate "diff"`** prints a `-- foreign keys:` section (like `-- indexes:`).
- Remove the "table ordering is load-bearing" haddock note on `migrateUp` (the
  ordering requirement is gone).

### forge-u0w doc cleanup

- In `docs/superpowers/specs/2026-06-29-forge-u0w-references-fk-markers-design.md`,
  replace the "Known limitation — FK table-creation ordering" section with a pointer
  noting it was resolved by forge-irh (post-pass), and drop the ordering follow-up
  bullet from "Out of scope".
- In `Manifest/Core/Table.hs`, the `References` marker haddock's ordering caveat (if
  present) is removed; the manual-instance `foreignKeys = genericForeignKeys @t` note
  stays.

## Behavioural notes

- **Idempotent.** A second `migrate up` finds the named constraint already live and
  skips it. Re-running is a no-op.
- **`diff` preview on a brand-new DB.** `foreignKeysForTable` returns `[]` for
  not-yet-created tables, so `migrate diff` on a fresh schema shows `CREATE TABLE`s but
  not the FK statements — identical to the existing RLS/index preview behaviour;
  `migrate up` applies them correctly inside the transaction after creation.
- **Atomicity unchanged.** All DDL still runs in one transaction, so a failure rolls
  back the whole migration.
- **DDL surface change.** `CREATE TABLE` output no longer contains `FOREIGN KEY …`;
  FKs are separate `ALTER TABLE … ADD CONSTRAINT` statements. This is the only
  externally visible change and is covered by the render tests below.

## Testing / verification

1. **Render tests** (`ReferencesSpec`): `renderCreateTable (managed (Proxy @Doc))` now
   asserts a CREATE TABLE with **no** `FOREIGN KEY` clause; `renderAddColumn "docs"
   (ColumnMeta …)` (2-arg) asserts no inline `REFERENCES`; a new assertion on
   `renderAddForeignKey "docs" (ForeignKey "doc_author" "users" "user_id")` gives
   `ALTER TABLE docs ADD CONSTRAINT docs_doc_author_fkey FOREIGN KEY (doc_author) REFERENCES users(user_id)`.
2. **Integration — ordering no longer matters** (ephemeral Postgres via `migrateUp`):
   pass the managed tables in **child-before-parent** order (e.g. `[Item, Owner]` where
   `Item` references `Owner`) and assert `migrateUp` succeeds and the FK is enforced
   (an FK-violating insert fails). This is the regression that the old inline emission
   could not survive.
3. **Integration — idempotency**: run `migrateUp` twice on the same schema; the second
   run adds no FK constraint (assert `foreignKeyPlan` is empty / no duplicate-constraint
   error).
4. **Integration — circular FKs** (if expressible with the fixtures): two tables that
   reference each other migrate cleanly under the post-pass. If a clean circular
   fixture is impractical, the child-before-parent ordering test (2) already proves the
   ordering property; note the omission.
5. **Regression**: existing migration specs (`MigrateSqlSpec`, `MigrateSpec`,
   `MigrateMetaSpec`) stay green — unmarked entities have `mtForeignKeys = []`, so their
   DDL is unchanged, and `renderAddColumn`'s reverted signature restores the original
   `MigrateSqlSpec` calls. The forge-u0w FK-enforcement and cascade-compatibility
   integration tests still pass (they migrate/create their tables in dependency order,
   which the post-pass also satisfies).

## Files (anticipated)

- `manifest/src/Manifest/Migrate.hs` — remove `fkDDL` + inline FK from
  `renderCreateTable`; revert `renderAddColumn`; add `renderAddForeignKey`,
  `liveForeignKeys`, `foreignKeysForTable`, `foreignKeyPlan`; `MigrationPlan`
  `planForeignKeys`; wire `migrate`/`migrateUp`/`runMigrate`; drop the ordering
  haddock. Export `renderAddForeignKey` (for the render test).
- `manifest/test/MigrateSqlSpec.hs` — revert the two `renderAddColumn` calls to 2-arg.
- `manifest/test/ReferencesSpec.hs` — update DDL render tests; add the
  ordering-independence integration test (and idempotency / circular where practical).
- `docs/superpowers/specs/2026-06-29-forge-u0w-references-fk-markers-design.md` +
  `manifest/manifest-core/src/Manifest/Core/Table.hs` — remove the resolved
  ordering-limitation notes.

## Out of scope

- `ReferencesOnDelete` (DB-enforced `ON DELETE`) — its own bead; when built, the policy
  is appended to `renderAddForeignKey`'s output.
- Dropping constraints that exist in the DB but are no longer declared (the engine
  never drops FKs, RLS, or indexes — same policy).
- Constraint-diffing an FK whose *target* changed (a declared FK with the same name but
  a different target is left as-is — consistent with the never-alter policy). Real
  target changes are a destructive migration, out of scope here.
