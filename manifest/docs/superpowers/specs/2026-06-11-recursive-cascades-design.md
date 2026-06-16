# Recursive (multi-level) cascade deletes — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-11 · **Issue:** manifest-va2

**Goal:** `delete` walks the whole cascade tree, so deleting a `Run` removes its
`Output`s AND the `Score`s under them. Today `flushDelete` emits one flat
DELETE per rule — grandchildren are silently orphaned.

---

## 0. Context

Cascades are session-level only: the migration engine emits no FK constraints
(PK + NOT NULL only), and `flushDelete` runs the parent's `cascadeRules` in two
passes (all `Restrict` checks, then the mutating `Cascade`/`SetNull`
statements) before deleting the parent row. A `CascadeRule` is resolved at
declaration time to `(crChildTable, crFkColumn, crPolicy)` bytestrings, so the
child's own rules are invisible at delete time. Surfaced by the eval schema
(`Run → Output → Score`, manifest-evals).

**Decisions made:** recursion lives at the session level (no DB `ON DELETE`
FKs — keeps manifest's session-owned, statement-logged identity and avoids
migration-engine changes), and recursive semantics are the DEFAULT — flat
cascade-with-orphans was a bug, not a feature. No new API surface.

## 1. Rule capture

`CascadeRule` (`Manifest.Core.Cascade`) grows two fields, both captured by
`cascade` (`Manifest.Core.Relation`) where `Entity c` is already in scope:

```haskell
data CascadeRule = CascadeRule
  { crChildTable :: ByteString
  , crFkColumn   :: ByteString
  , crPolicy     :: OnDelete
  , crChildPk    :: ByteString      -- the child's own PK column (for subquery chaining)
  , crChildRules :: [CascadeRule]   -- the child's OWN cascadeRules, captured lazily
  }
```

`crChildPk = cmName (pkColumn (tableMeta @c))`; `crChildRules = cascadeRules @c`.

The capture MUST stay lazy (no strictness annotations, no `deriving (Eq, Show)`
forcing in hot paths): a self-referential entity makes the structure infinite;
the walk guards termination, construction stays cheap. `Eq`/`Show` instances
on `CascadeRule` cannot remain derived over an infinite structure — they
compare/show only the finite fields (hand-written instances; as built, the
four fields excluding `crChildRules`).

## 2. The delete walk

`flushDelete` keeps its two-pass, all-or-nothing shape. Each pass walks the
rule tree carrying a *scope*: the SQL fragment selecting exactly the rows being
deleted at that level, built as nested `IN` subqueries chained through
`crChildPk`.

- Depth 1 scope: `WHERE <fk> = $1` (the parent PK param, as today).
- Depth 2 scope: `WHERE <fk2> IN (SELECT <pk1> FROM <child1> WHERE <fk1> = $1)`.
- Depth N: one more nesting level per depth.

**Pass 1 — Restrict, whole tree, before any mutation.** Every `Restrict` rule
reachable through `Cascade` edges is checked:
`SELECT 1 FROM <childN> <scope> LIMIT 1` — any hit throws (as today), aborting
the entire delete with nothing mutated. So `Run→Output Cascade,
Output→Score Restrict` makes deleting a Run FAIL while Scores exist, instead
of orphaning them.

**Pass 2 — mutation, deepest-first.** For each `Cascade` rule, first recurse
into `crChildRules` (with the extended scope), then
`DELETE FROM <child> <scope>`. `SetNull` emits
`UPDATE <child> SET <fk> = NULL <scope>` and does NOT descend further (those
rows survive; their subtree is unaffected). Finally the parent row is deleted
and dropped from the identity map (unchanged).

**Traversal rules:**

- Recursion descends only through `Cascade` edges. `Restrict` and `SetNull`
  rules are leaves (checked / applied at their depth, never expanded).
- **Cycle guard:** the walk tracks the chain of child tables on the current
  path; a rule whose `crChildTable` is already on the path is not descended
  into (its own DELETE/check still runs at that depth). A self-referencing
  entity (`Comment → Comment Cascade`) therefore cascades one level per
  declared edge, not arbitrary row depth — a documented limitation
  (row-level recursion would need `WITH RECURSIVE`; YAGNI until someone has a
  real tree schema).
- `SetNull` onto a NOT NULL column fails at runtime exactly as it does today —
  the schema author's responsibility.

## 3. Blast radius

- `Manifest.Core.Cascade` — the two new fields; hand-written or dropped
  `Eq`/`Show`.
- `Manifest.Core.Relation.cascade` — capture `crChildPk`/`crChildRules`.
- `Manifest.Session` — `flushDelete`/`restrictCheck`/`applyMutating` become the
  scoped tree walk (helpers may be reshaped freely; they are not exported).
- No migration-engine, query-DSL, or other API changes. `CascadeRule(..)` is
  re-exported from `Manifest`; downstream pattern matches on the old three
  fields would break — accepted (young library, all callers in-house).
- Statement log: every emitted statement remains visible, as today.
- Known pre-existing wart, explicitly unchanged: cascade-deleted children
  already loaded into the session identity map stay there, stale.
- Concurrency: session-level cascades remain non-atomic against concurrent
  writers unless wrapped in `withTransaction` — unchanged; callers who need
  atomicity already use `withTransaction . delete`.

## 4. Testing

In the manifest suite (ephemeral Postgres), a dedicated three-level fixture
schema (Grandparent → Parent Cascade → Child …):

1. **Three-level cascade:** deleting the grandparent removes parents AND
   children (the orphan bug, fixed).
2. **Restrict at depth:** with `… → Child Restrict` and a child row present,
   the grandparent delete throws and NOTHING is deleted (two-pass atomicity,
   checked under `withTransaction`).
3. **SetNull at depth:** the child FK is NULLed for exactly the in-scope rows;
   the child rows survive; out-of-scope rows untouched.
4. **Cycle guard:** a self-referential entity (`Node → Node Cascade`): deleting
   a node removes its direct children, terminates, and leaves depth-2
   descendants (the documented one-level-per-edge limitation, locked in by a
   test).
5. The existing suite (140 tests) stays green — any test that asserted flat
   semantics is updated to the new semantics deliberately.

**Follow-up (manifest-evals, separate change after re-pinning manifest):**
SchemaSpec scenario A's "cascades are single-level" comment and both-edges
workaround update to assert the recursive behaviour directly (delete the Run,
assert Outputs AND Scores gone).

## 5. Out of scope

- DB-level `ON DELETE` FK constraints (a possible future hardening; would be
  its own design).
- Row-level recursion for self-referential entities (`WITH RECURSIVE`).
- Identity-map invalidation of cascade-deleted children (pre-existing wart).
- Batch/multi-root deletes; `deleteWhere` interaction is unchanged (it has no
  cascade semantics today and gains none here).
