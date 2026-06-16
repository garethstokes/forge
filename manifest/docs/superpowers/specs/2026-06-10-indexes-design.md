# Manifest — Declarative Indexes (GIN for jsonb) — Design

**Status:** Approved (autonomous-loop design; mirrors the RLS feature). Issue `manifest-uys`. · **Date:** 2026-06-10

**Goal:** Let an entity declare indexes (notably a GIN index on a `jsonb` column so `@>`
containment queries use it), and have the migration engine create them. Mirrors the
existing declarative RLS mechanism (`rlsPolicies`/`planRls`/`pg_policies` reconciliation).

---

## Design

An entity declares indexes the same way it declares cascade rules and RLS policies: a
defaulted `Entity` method plus a small builder DSL, reconciled by the migration engine.

### Modules (mirror `Core.Rls` / `Manifest.Rls`)

- **`Manifest.Core.Index`** (new, low): the entity-erased data.
  ```haskell
  data IndexMethod = Gin | Btree deriving (Eq, Show)
  methodSql :: IndexMethod -> ByteString   -- Gin->"gin", Btree->"btree"
  data IndexDef = IndexDef { idxName :: ByteString, idxMethod :: IndexMethod, idxColumns :: [ByteString] }
    deriving (Eq, Show)
  newtype Index a = Index { indexSpec :: (IndexMethod, [ByteString]) }   -- phantom in a; name derived later
  ```
- **`Manifest.Index`** (new, high): the builders.
  ```haskell
  gin   :: Column a t -> Index a       -- gin #col     (jsonb containment etc.)
  btree :: Column a t -> Index a       -- btree #col   (ordinary index)
  ```
  Both read `colName` from the entity-agnostic `#col` label (`Manifest.Core.Query.Column`).

### `Entity` gains a defaulted method (like `rlsPolicies`)

```haskell
indexes :: [Index a]
indexes = []
```

### `ManagedTable` + reconciliation (`Manifest.Migrate`)

- `ManagedTable` gains `mtIndexes :: [IndexDef]`. `managed` fills it, deriving each index
  name from the table so it is schema-unique:
  `idxName = <table>_<col1>[_<col2>...]_<method>_idx`.
- `MigrationPlan` gains `planIndexes :: [ByteString]`.
- DDL: `renderCreateIndex table (IndexDef n m cols) = "CREATE INDEX " <> n <> " ON " <>
  table <> " USING " <> methodSql m <> " (" <> intercalate ", " cols <> ")"`.
- `liveIndexes :: ByteString -> Db [ByteString]` queries
  `SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename=$1`.
- `indexesForTable`: if the table exists, emit `CREATE INDEX` for each declared index whose
  name is NOT already live. Like `rlsForTable`, returns `[]` when the table does not exist
  yet (reconciled after creation).
- `migrate` computes `planIndexes`; `migrateUp` applies it **after** the additive DDL and
  recomputes (so create-table-then-index in one run works), exactly as `planRls` is handled.

### Safety decision: create-only (no DROP)

RLS reconciliation drops policies the entity no longer declares, because every policy is
app-managed. Indexes are NOT all app-managed: Postgres auto-creates the primary-key index
(`<table>_pkey`) and unique-constraint indexes, and a user may add their own. Dropping
"unmanaged" indexes would risk dropping the PK index. So index reconciliation is
**create-if-absent only**; it never drops. Removing an index is a manual operation. This
is the one deliberate divergence from the RLS pattern.

---

## Testing

Against ephemeral Postgres (mirror `RlsSpec`):

- an entity with `indexes = [ gin #settingPrefs ]` (or a btree on a scalar): after
  `migrateUp`, the index exists in `pg_indexes` with the expected name and `USING gin`;
- idempotent: a second `migrateUp` creates nothing new (the index is already live);
- the index is created when the table is created in the SAME `migrateUp` run (recompute
  after additive);
- a unit test of `renderCreateIndex` output;
- the existing suite stays green (the new defaulted `indexes` method does not disturb
  entities that do not override it; `managed`/`MigrationPlan`/migrate-engine changes are
  additive).

## Out of scope

Dropping removed indexes (manual, for safety); partial / expression / unique indexes;
multi-column composite GIN specifics; opclass selection (`jsonb_path_ops`). These can be
follow-ups if needed.
