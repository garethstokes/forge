# manifest-core Split — Design (Phase 0)

**Date:** 2026-06-15
**Status:** Committed spec
**Repo:** `manifest` (this repo)
**Context:** Phase 0 of crucible's persistence epic (crucible-5dl / crucible-gjm).
crucible-core wants to define its domain types as Higher-Kinded Data
(`MemoryItemT f` with manifest's `Field`/`Pk`/`Serial`) so a Postgres backend can
be `deriving via (Table …) Entity`-derived — but crucible-core must NOT gain a
`libpq` dependency. This requires manifest's pure HKD/codec/entity layer to be
importable without the connection/IO layer.

## The problem this solves

Today `manifest` is a single package: the pure layer (type markers, codecs,
generic entity derivation, SQL string rendering) and the impure layer (libpq
connection pool, the `Db` unit-of-work monad, query execution, migrations,
ephemeral-cluster test helpers) ship together. Any consumer that only needs the
*types* (to declare entities or share a schema) is forced to depend on
`postgresql-libpq`, `process`, `directory`, and `stm`. Splitting out a
dependency-light `manifest-core` lets type-only consumers (starting with
crucible-core) depend on the pure layer alone, while `manifest` keeps the full
API behind an unchanged umbrella.

## Goal

Split `manifest` into two packages in one zinc workspace, with **no change to the
public `Manifest` umbrella API** (so `manifest-evals` and any `import Manifest`
consumer need only a pin bump, no code changes):

- **`manifest-core`** (new, pure, libpq-free) — types, codecs, generic entity
  derivation, SQL rendering.
- **`manifest`** (depends on `manifest-core` + libpq) — connection pool, `Db`
  unit-of-work, query executor, relations, notify, migrate, testing, RLS DSL, and
  the `Manifest` umbrella that re-exports both.

## The cut line

Module names are **unchanged**; only their owning package and file location move.
The 15 pure modules move from `src/Manifest/…` to `manifest-core/src/Manifest/…`
(same `Manifest/` subpath, so import paths are identical).

**→ `manifest-core` (PURE — verified acyclic: none import an impure module):**

| Module | Role |
|--------|------|
| `Manifest.Core.SqlType` | SQL type enum + DDL rendering |
| `Manifest.Core.Table` | `Serial`, `PrimaryKey`, `Pk`, `Nullable`, `Field`, `Base`, `FieldMeta` |
| `Manifest.Core.Codec` | `Codec`, `DbType`, `RowDecoder` (pure profunctor codecs) |
| `Manifest.Core.Meta` | `ColumnMeta`/`TableMeta`, generic `genericTableMeta` |
| `Manifest.Core.Query` | query **AST**: `Column`, `Cond`, `Assign`, `Op` + operator builders |
| `Manifest.Core.Sql` | SQL string rendering (SELECT/INSERT/UPDATE/DELETE) |
| `Manifest.Core.Cascade` | `OnDelete`, `CascadeRule` |
| `Manifest.Core.Rls` | RLS **types**: `PolicyCmd`, `PolicyDef`, `Policy` |
| `Manifest.Core.Index` | `IndexMethod`, `IndexDef`, `Index`, `SomeColumn` |
| `Manifest.Core.Relation` | relationship DSL types: `Card`, `HasRelation`, `RelSpec` |
| `Manifest.Entity` | `Entity` class, `Key`, generic row decode/encode/primKey |
| `Manifest.Derive` | `Table` deriving-via instance for `Entity` |
| `Manifest.Error` | `DecodeError`, `DbError`, `DbException` |
| `Manifest.Json` | `Json`/`Aeson` jsonb `DbType` wrappers |
| `Manifest.Index` | pure DSL builders: `gin`, `btree`, `unique` |

**→ stays in `manifest` (IMPURE — libpq / process / IO):**
`Manifest.Postgres`, `Manifest.Session`, `Manifest.Session.Command`,
`Manifest.Query` (executor — `runQuery`/`from`/`where_`/`withCte`/`Expr`/jsonb ops),
`Manifest.Relation`, `Manifest.Relation.Loaded`, `Manifest.Notify`,
`Manifest.Migrate`, `Manifest.Testing`, `Manifest.Rls` (DSL — uses
`Query.Expr`/`renderPredicate`), and `Manifest` (umbrella).

**Boundary note:** `Manifest.Rls` is mostly pure but `using`/`withCheck` call
`renderPredicate` from the impure `Manifest.Query`, so it stays in `manifest`.
The pure RLS *types* are already separated as `Manifest.Core.Rls` (→ core).

## Packaging

```
manifest/                     (repo root)
  zinc.toml                   [workspace] members = [".", "manifest-core"]
  src/Manifest.hs             umbrella (re-exports both packages, UNCHANGED)
  src/Manifest/…              the 11 impure modules
  manifest-core/
    zinc.toml                 package manifest-core
    src/Manifest/Core/…       the 10 Core.* modules
    src/Manifest/{Entity,Derive,Error,Json,Index}.hs
```

- `manifest-core/zinc.toml` deps: `base, bytestring, containers, text, time,
  transformers, profunctors, autodocodec, aeson` — **drops** `postgresql-libpq`,
  `process`, `directory`, `stm`. Git-pin source overrides for `profunctors` and
  `autodocodec` (currently in the root `[dependencies]`) must be reachable by the
  `manifest-core` member (workspace-level overrides — match whatever pattern
  `manifest-evals`' multi-member workspace uses; resolve during planning).
- `manifest/zinc.toml` lib deps: add `manifest-core`; keep the rest (libpq,
  process, directory, stm still needed by the impure modules). The `Manifest`
  umbrella and the impure modules import the Core modules transitively via
  `manifest-core` — no source edits to imports are required because module names
  are unchanged.

## Invariants (acceptance)

1. `manifest-core` builds with **no** `postgresql-libpq`/`process`/`directory`/`stm`
   dependency (proves the cut is clean; a stray impure import fails the build).
2. The `Manifest` umbrella exports the **same** symbols as before (no consumer API
   change). Spot-check by building the existing test suite unchanged.
3. `manifest`'s full ephemeral-pg test suite passes unchanged.
4. `manifest-evals` (separate repo) compiles against the new manifest rev with
   only a pin bump — verified opportunistically, not blocking this phase.

## Testing

- Pure split correctness is proven by the build: `manifest-core` compiling without
  libpq + `manifest` compiling on top of it.
- Run the existing manifest test suite (ephemeral Postgres) to confirm no behaviour
  changed. No new tests are required for a pure move; optionally add a trivial
  `manifest-core` smoke test (a codec round-trip) so the new package has a test
  target, only if zinc requires a test stanza.

## Out of scope

- Any API/behaviour change to manifest (this is a pure relocation).
- crucible-side work (HKD migration, `crucible-manifest`, ephemeral tests) — that
  is Phase 1 in the crucible repo.
- The `withRecursive` graph combinator (shaping doc Part 2) — unrelated.

## Risks

- **zinc workspace dependency overrides** — confirm how git-pin source overrides
  (`profunctors`, `autodocodec`) are declared so both members resolve them; mirror
  `manifest-evals`' multi-member layout. (Plan step 1 validates with a build.)
- **A pure module secretly importing an impure one** — caught immediately by the
  `manifest-core` build (the impure module won't be in scope). Fix by moving the
  offending helper or keeping that module in `manifest`.
