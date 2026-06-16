# Manifest — Design v0.1

**Status:** Approved design (brainstorm complete) · **Date:** 2026-06-07
**A Haskell database / ORM library.** Sibling to [Lune](../../lune).

---

## 0. Thesis

The Haskell ecosystem has **excellent "Core" layers** — beam, rel8, esqueleto, opaleye give
you type-safe, composable SQL — but **no real "ORM" layer**. Nobody has ported SQLAlchemy's
*Unit-of-Work*: a `Session` with an identity map, change tracking that emits minimal `UPDATE`s,
relationship-loading strategies, and cascades. That gap exists because the obvious implementation
relies on *mutating objects in place*, which is unidiomatic — even impossible — in Haskell.

**Manifest is the Unit-of-Work layer Haskell never had**, built on a thin, owned, Higher-Kinded-Data
Core, with a derive layer that turns record declarations into schema, CRUD, relationships, and
migrations.

The name puns on its job: a ship's *manifest* is literally an identity map of cargo, and to
*manifest* a record is to make it real (persist it).

---

## 1. Design decisions (the settled forks, with rationale)

These were resolved during brainstorming and are the load-bearing commitments. Recorded here so
the *why* survives.

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| Scope | Which layer to attack | **All three: Core / ORM / Derive, as a layered stack** | The SQLAlchemy magic lives across layers; the gap is the ORM, but it needs a Core under it and a Derive over it. |
| Schema repr | How schema appears in types | **Higher-Kinded Data (HKD)** | Max type-safety; one declaration serves table/row/query (beam/rel8 family). Accepts the type-complexity tax. |
| Core | Build vs borrow the query layer | **Thin custom HKD Core, fully owned** | Borrow *ideas*, not deps. Only the subset the ORM needs; keeps the stack seam-free. |
| Session | The effect/monad model | **Bespoke `Db` monad** — sealed `newtype Db a = Db (ReaderT Session IO a)` | Concrete, explicit, no framework tax. `withTransaction`/`withConnection` on `bracket`. `effectful` adapter left as a future door, `MonadDb` class graftable later. |
| Change tracking | Detecting dirties in immutable Haskell | **Snapshot-diff (default) + explicit-command (escape hatch)** | Snapshot-diff preserves SQLAlchemy's "edit a plain value, session computes the minimal write." Command path covers blind/bulk writes. |
| Relationships | Representation + loading | **Explicit-load `Relation` substrate (A) + opt-in phantom load-tracking (D) over the same data** | Haskell can't lazy-load (field access is pure). A is the honest floor; D adds compile-time load guarantees as an opt-in ceiling. |
| Transport | Wire protocol | **Borrow** (`hasql` connection layer / `postgresql-libpq`) | Unlike Lune's pure-protocol approach: rewriting the wire protocol is months of reliability risk for zero differentiation. Own everything *above* the socket. |
| Errors | Result vs exceptions | **Typed `DbException` thrown internally (bracket-friendly rollback) + `try`-combinators at the boundary** | Exceptions compose with `bracket` for automatic rollback; `Db a -> Db (Either DbError a)` gives Lune-style explicit handling where wanted. `Maybe` for not-found. |
| Derive | Codegen mechanism | **Generics-first; optional TH front-end later** | Transparent foundation (hand-write HKD record + `deriving Generic`); TH sugar recovers Lune's terse `@derive(Table)` once the core is proven. |
| Backend | Scope | **Postgres-only MVP**, `Backend`-parameterized SQL gen, STM pool | Mirrors Lune; SQLite follows without re-architecting. |

---

## 2. Architecture

### 2.1 Layer cake (dependencies strictly downward)

```
┌─────────────────────────────────────────────────────────┐
│  Layer 3 — Derive       (records → schema, CRUD,         │
│                          relationships, migrations)       │
├─────────────────────────────────────────────────────────┤
│  Layer 2 — ORM/Session  (Db monad, identity map,         │
│                          snapshot-diff, relationships,    │
│                          loading strategies, cascades)    │
├─────────────────────────────────────────────────────────┤
│  Layer 1 — Core         (HKD tables, query AST,          │
│                          conditions, SQL gen, codecs)     │
├─────────────────────────────────────────────────────────┤
│  Transport (borrowed)   (connection, wire I/O, STM pool)  │
└─────────────────────────────────────────────────────────┘
```

Layer 1 knows nothing of the Session — it is usable standalone (the "drop to Core" escape hatch
SQLAlchemy gives you). Layer 2 builds the Unit-of-Work on Core. Layer 3 generates Layer 1/2
artifacts from record declarations. Each layer is independently usable and testable.

### 2.2 Module map (rough)

```
Manifest.Core.Table        -- HKD table classes, Col/Columnar, field metadata
Manifest.Core.Query        -- query AST: select/where/join/order/limit
Manifest.Core.Sql          -- AST → SQL string + params (Backend-parameterized)
Manifest.Core.Codec        -- applicative encoders/decoders (Lune-style)
Manifest.Session           -- Db monad, Session, identity map, run/withTransaction
Manifest.Session.Track     -- snapshot-diff, dirty-set, flush
Manifest.Session.Command   -- explicit-command escape hatch (update key [...])
Manifest.Relation          -- Relation type, with, selectin/joined strategies
Manifest.Derive            -- Generics metadata derivation (Entity instances)
Manifest.Migrate           -- record-derived schema diff → reviewable DDL
Manifest.Postgres          -- backend instance + transport binding
```

---

## 3. Layer 1 — Core (thin, owned HKD)

A deliberately small Higher-Kinded-Data expression layer — only the subset the ORM needs. We own
SQL generation; we borrow ideas (not code) from beam/rel8.

- **HKD tables.** `data UserT f` parameterized by a functor; `Col f` (the `Columnar` family)
  collapses to plain types in `Identity` context and to typed column expressions in query context.
- **Query AST.** `select` / `where_` / `order` / `limit` / `offset`; joins/aggregates are a
  follow-up (Sub-project 4), not MVP.
- **Conditions.** `==.`, `/=.`, `>.`, `<.`, `like`, `isNull`, `in_`, composable with `&&.`/`||.`.
- **Codec.** Applicative encoders/decoders in the Lune/Elm lineage:
  `User <$> col int <*> col text <*> col (nullable text)`. No `mapN` ceiling (applicative, not
  fixed-arity combinators — fixing Lune §8.10's 5-field limit).
- **SQL generation** is `Backend`-parameterized (placeholder style, identifier quoting, etc.) so
  SQLite can follow.

---

## 4. Layer 2 — Session & snapshot-diff (the Unit-of-Work)

The layer that does not exist anywhere in Haskell today.

### 4.1 The `Db` monad and `Session`

```haskell
newtype Db a = Db (ReaderT Session IO a)
  deriving (Functor, Applicative, Monad, MonadIO)

data Session = Session
  { sessConn     :: Connection          -- borrowed from the STM pool
  , sessIdentity :: IORef IdentityMap   -- (TypeRep, PKBytes) → baseline snapshot
  , sessPending  :: IORef PendingSet     -- adds / saves / deletes awaiting flush
  , sessConfig   :: SessionConfig
  }

withSession     :: Pool -> Db a -> IO a   -- acquire conn, fresh maps, run, release
withTransaction :: Db a -> Db a           -- bracket: BEGIN / COMMIT / ROLLBACK-on-exception
```

The identity map is heterogeneous, keyed by `(TypeRep, PKBytes)`, snapshots type-erased and
recovered via `Typeable` — internal, never user-visible.

### 4.2 Entity lifecycle (SQLAlchemy's four states, ported)

```
 Transient ──add──▶ Pending ──flush──▶ Persistent ──delete+flush──▶ Deleted
 (plain value,                         (in identity map,
  no session)                           has baseline snapshot)
```

`get`/`select` produce **Persistent** entities (snapshot recorded). `add` takes a **Transient**
value to **Pending**; flush makes it Persistent with its serial PK filled via `RETURNING`.

### 4.3 The key insight: **identity is the primary key**

SQLAlchemy hides per-object state on the Python object. A plain Haskell value has no hidden state —
so `save u'` finds the row's identity and baseline **by its primary key** (a field on the record).
Identity is *value-based via the PK*, which is exactly correct: the PK **is** the row's identity.
No object wrappers, fully compatible with plain immutable records.

**Honest cost of immutability:** the session cannot observe a mutation to a value it handed out
(`let u' = u { userName = "Bob" }` is invisible to it). You **hand the new value back** via `save`.
`save` is cheap (stash desired state, mark key dirty); the diff is deferred to flush.

### 4.4 Flush algorithm

Runs on `withTransaction` commit, explicit `flush`, or (if autoflush on) before a query:

1. **Adds** → `INSERT ... RETURNING pk`; capture PK; store row as baseline; mark Persistent.
2. **Saves** → diff handed-back value vs baseline **column-by-column** (generic HKD fold collecting
   only changed `Col` fields) → `UPDATE t SET <changed> WHERE pk = $n`; refresh snapshot. No-op
   saves emit nothing.
3. **Deletes** → `DELETE ... WHERE pk = $n`.
4. **Ordering** → MVP: inserts → updates → deletes. FK-aware topological ordering is a follow-up.

The PK is never a diff target (changing it = identity change → command path).

### 4.5 Command escape hatch (path C) — same Session, no snapshot

```haskell
update      :: Key a -> [Assign a] -> Db ()   -- blind UPDATE t SET .. WHERE pk=..
deleteWhere :: [Cond a]            -> Db ()    -- bulk DELETE, no per-row identity
```

Bypasses the identity map for blind/bulk writes; invalidates any stale snapshots it touches.

### 4.6 API surface (worked example, both paths, one transaction)

```haskell
withSession pool $ withTransaction $ do
  Just u <- get @User (Key 42)            -- baseline snapshot stored
  save u { userName = "Bob" }             -- stash desired state; diff deferred
  newP   <- add Post{ postTitle = "Hi", postAuthor = 42, .. }  -- INSERT on flush, PK back
  update (Key 42) [ #userLastSeen =. now ]          -- command path
  deleteWhere @LoginToken [ #tokenExpiry <. now ]   -- bulk command path
  -- commit → flush emits:
  --   UPDATE users SET name=$1 WHERE id=42;
  --   INSERT INTO posts (...) RETURNING id;
  --   UPDATE users SET last_seen=$1 WHERE id=42;
  --   DELETE FROM login_tokens WHERE expiry < $1;
```

### 4.7 Policy knobs (approved defaults)

- **Autoflush before queries — ON** (toggleable). Reads see un-flushed writes (SQLAlchemy default).
- **Read-refreshes-snapshot — "pending wins."** A re-load refreshes the baseline of a *non-pending*
  entity; for a *pending* entity it keeps your desired state and leaves the baseline as-loaded so the
  diff still reflects intent.
- **Identity-map lifetime — per-session, spanning transactions, expire-on-commit OFF.** Loaded
  entities stay usable after commit (simpler than SQLAlchemy's expire-ON for an immutable-value world).

---

## 5. Layer 3a — Relationships & loading strategies

Relations are **not stored columns** on the HKD record (they don't live in the table), so they're
handled separately, and the phantom load-set rides on an opt-in wrapper — never on the bare value.

### 5.1 Two representations, one substrate

**Bare entity (A path) — no phantom, no wrapper:**
```haskell
load :: HasRelation a name => Label name -> a -> Db (Target a name)
posts <- load #posts user        -- :: Db [Post]  — plain, zero type machinery
```
A user who never wants type-level tracking lives entirely here. This is the floor.

**Loaded entity (D path) — phantom load-set on an opt-in wrapper:**
```haskell
data Ent (loaded :: [Symbol]) a = Ent { entVal :: a, entRels :: RelMap }

get  :: Key a -> Db (Maybe (Ent '[] a))                        -- nothing loaded
with :: HasRelation a name
     => Strategy name -> Ent l a -> Db (Ent (Insert name l) a) -- accumulates the set
posts :: Member "posts" loaded => Ent loaded User -> [Post]    -- total accessor
```

The phantom rides on `Ent loaded a` **only**; queries, `Db` actions, and the bare `a` never carry it.

### 5.2 Defanging D's type errors (the mitigations)

D ships safely because its scary machinery is never on the critical path and its one user-visible
failure is a written sentence:

1. **`Unsatisfiable` (GHC 9.8+) custom message** on the accessor — reading an unloaded relation prints
   *"Relation 'posts' is not loaded on this User. Add `with (selectin #posts)`, or call `load #posts u`."*
   not a type-list dump.
2. **Membership-only, never set-equality** — the type system is only ever asked "is `"posts"` ∈ load-set?".
3. **Track `Symbol` names, not types** — load-set is `'["posts"]`, keeping `Post`/`Comment` out of errors.
   The `#posts` label *is* that Symbol.
4. **Users never write the list** — accumulated by `with`, in zero annotations.
5. **Closed, total type families** — final equation is the `Unsatisfiable` case; never stuck.
6. **`HasField`-style accessor** hides the constraint behind an ordinary field read.
7. **Minimal blast radius** — phantom on the entity value only.
8. **Golden-test the error output** so refactors can't regress the message.

**Drop-to-A is always available:** `load #posts (entVal u)` — same data, no rewrite, no lock-in.

### 5.3 Declaring relationships (metadata)

```haskell
class HasRelation a (name :: Symbol) where
  type Target      a name :: Type     -- [Post] / Maybe Profile / Author
  type Cardinality a name :: Card     -- Many | One | Opt
  relSpec :: RelSpec a name           -- target table + FK columns

instance HasRelation User "posts" where
  type Target User "posts" = [Post]
  type Cardinality User "posts" = Many
  relSpec = hasMany PostTable #authorId
```

`with`'s return type and the accessor's result type are computed from `Target`/`Cardinality`
(`Many → [Post]`, `Opt → Maybe Profile`, `One → Author`), totally. Hand-declared now; TH-derivable later.

### 5.4 Loading strategies (SQLAlchemy's, ported)

- **`selectin` (default).** Load parents, then one `SELECT child WHERE fk IN (parent_pks)`, stitch in
  memory. 2 queries, no row multiplication.
- **`joined`.** Single `LEFT JOIN`, decode nested. Fewer round-trips; multiplies rows for collections.

```haskell
with (selectin #posts <> joined #profile) ent     -- multiple, chainable
with (selectin (#posts ./ #comments)) ent          -- one level deep
```
`with #posts` defaults to `selectin`. Arbitrary-depth nesting → follow-up.

### 5.5 Integration with the Unit-of-Work

- **Loaded children enter the identity map** with their own baseline snapshots — a fetched `Post` is
  immediately a managed Persistent entity; modify + `save` flows through the same snapshot-diff path.
- **Cascades** — MVP: per-relation `onDelete` policy (`Cascade | SetNull | Restrict`) honored at flush.
  `save`-cascade and `delete-orphan` are follow-ups (scope control).

---

## 6. Layer 3b — Derive & migrations

### 6.1 HKD ↔ plain-record reconciliation (beam's trick)

```haskell
data UserT f = User
  { userId    :: Col f (PrimaryKey (Serial Int))   -- markers in the type
  , userName  :: Col f Text
  , userEmail :: Col f (Maybe Text) }
  deriving (Generic)

type User = UserT Identity     -- userId :: Int, userName :: Text — the clean value
```

`Col f` erases markers in `Identity` context (`Col Identity (PrimaryKey (Serial Int)) = Int`) and
yields typed column expressions in query context. PK/serial markers are visible to the metadata
deriver but invisible in the value — that is how `@primaryKey`/`@serial` translate without an
annotation syntax.

### 6.2 What Generics derives (no TH)

`deriving (Generic)` + `deriving anyclass (Entity)` gives:

| Derived | Powers |
|---|---|
| Table metadata | name, columns, types, PK, serial flags |
| Codec | row ↔ `User` |
| `Entity UserT` instance | the class `get`/`add`/`save`/`delete` are generic over |
| Column labels | `#userName` → typed column ref via HKD field metadata |

No per-table codegen for the query/command surface — labels do the work, consistent with `#posts`:
```haskell
select $ from @User & where_ (#userName ==. "Bob")
update key [ #userName =. "Bob" ]
```

### 6.3 Optional TH front-end (recovers Lune's terseness — later)

Generics is the honest foundation. A later TH macro takes a terse declaration and generates the
`UserT f` record + `Generic` + relationship stubs — restoring the one-block `@derive(Table)` feel.
**Sugar, not foundation** — deferred so Layer 1–2 stay transparent and TH-free.

### 6.4 Migrations — Alembic's model, ported

**Records are the schema source of truth.** A migration is the diff between record-derived schema and
the live DB:

```
manifest migrate diff     -- introspect DB, compute delta vs records, write reviewable up/down
manifest migrate up       -- apply pending, tracked in schema_migrations table
```

Autogenerate-then-review, like Alembic. Destructive ops (drops, type changes) are surfaced for human
sign-off, never silently executed.

**MVP scope:** `CREATE TABLE` from records + additive diffs (new table/column). Renames, type changes,
drops → reviewable follow-up. No silent destructive DDL, ever.

---

## 7. Build order / decomposition

Dependencies are strictly downward, so each sub-project is its own spec → plan → implementation cycle.

- **Sub-project 1 — "Prove the UoW" (first buildable slice).**
  Borrowed Postgres transport + minimal Core (single-table select/insert/update + conditions, *no joins*)
  + Session with identity map + snapshot-diff + `get`/`add`/`save`/`delete` + `withTransaction` +
  Generics-derived `Entity`. One table, end to end, demonstrating: *edit a plain value → session emits a
  minimal `UPDATE`.*
- **Sub-project 2 — Relationships** + loading strategies (selectin/joined), `Ent` wrapper, A/D paths.
- **Sub-project 3 — Migrations** (diff/up, reviewable DDL).
- **Sub-project 4 — Core joins/aggregates** + the TH front-end sugar.

---

## 8. Deferred (explicit non-goals for the MVP)

- Joins, aggregations, subqueries, CTEs in Core (Sub-project 4)
- FK-aware topological flush ordering
- `save`-cascade and `delete-orphan`
- Arbitrary-depth relationship nesting
- Destructive migration diffs (rename/type-change/drop) auto-application
- TH front-end sugar
- Additional backends (SQLite, MySQL)
- `effectful`/`MonadDb` adapters
- Streaming results, prepared-statement caching, LISTEN/NOTIFY

---

## 9. Open questions to revisit during Sub-project 1

- Exact `Col`/`Columnar` family encoding for marker erasure (PK/Serial) under `Identity`.
- Snapshot storage form: decoded record vs encoded column vector (diff granularity vs cost).
- `Key a` representation (newtype over the PK column type; composite PKs deferred).
- Which borrowed transport (`hasql` connection layer vs `postgresql-libpq`) — measured in SP1.
```
