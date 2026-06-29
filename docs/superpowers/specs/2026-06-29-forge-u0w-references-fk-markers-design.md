# forge-u0w — `References` FK relationship markers

**Status:** Approved design (brainstorm complete) · **Date:** 2026-06-29
**Bead:** forge-u0w · **Depends on:** forge-2am (field-policy markers, merged)

---

## Problem

Today one logical foreign-key relationship is declared in **three** separate
places, none of which records the FK at the column site:

1. **The FK column** — a plain scalar on the child: `postAuthor :: Field f Int`.
   Nothing marks it as a foreign key.
2. **Navigation** (`HasRelation`) — hand-written type-class instances in *both*
   directions (`Post "author"` via `belongsTo`, `User "posts"` via `hasMany`).
3. **Cascade policy** — on the *parent's* `cascadeRules`, enforced in
   **application code** (recursive-delete SQL). The generated DDL emits **no FK
   constraints at all** — referential integrity is pure convention.

forge-2am's two-axis marker grammar (`PrimaryKey`/`Serial`/`Generated`/`Touched`/
`Default`/`Secret`/`ReadOnly`) was designed to accommodate a `References T` marker
so FK relationships join the same vocabulary. This bead designs that marker.

## Scope decision

Settled during brainstorming:

- **In scope:** a single `References T` marker at the column site that (1) makes the
  column a readwrite scalar of the target's PK type, and (2) drives DDL emission of a
  real `REFERENCES target(pk)` constraint (with no `ON DELETE` clause — SQL's
  `NO ACTION`). This adds **DB-enforced referential integrity**, which is entirely
  absent today.
- **Out of scope:**
  - **A column-level `ON DELETE` policy** (`ReferencesOnDelete p T` →
    `... ON DELETE CASCADE`). Cascades are already fully modelled by the existing
    app-level machinery (see "Cascade interaction" below), so a DB-enforced policy is
    an *optimisation*, not a requirement — deferred to a follow-up bead. Keeping it
    out avoids promoting `OnDelete` to a kind, a `KnownOnDelete` reflection class, and
    a second (DB-level) cascade mechanism running alongside the app-level one.
  - **Navigation derivation** (auto-generating `HasRelation` instances) — needs
    Template Haskell, which forge-2am deliberately avoided; and the relation name
    (`"author"`) is not recoverable from the column name (`postAuthor`). Separate
    bead.
  - **App-level cascade machinery** (`Manifest.Core.Cascade`, `cascadeRules`,
    recursive delete) — **unchanged**.
  - **Composite / multi-column FKs** — single-column FK to the target's single PK
    only (matches the system's single-PK assumption).
  - **Retrofitting FK constraints onto pre-existing columns/tables** — the migration
    engine is additive (it does not alter existing columns or add DEFAULTs after the
    fact); FKs are emitted only at table-create / column-add.

## Usage (consumer's view)

### Declaring an entity

Today an FK column is an untyped scalar:

```haskell
data PostT f = Post
  { postId     :: Field f (PrimaryKey (Serial Int))
  , postAuthor :: Field f Int          -- FK by convention only
  , postTitle  :: Field f Text
  } deriving Generic
```

With the marker, the column names its target:

```haskell
data PostT f = Post
  { postId     :: Field f (PrimaryKey (Serial Int))
  , postAuthor :: Field f (References User)            -- required FK
  , postTitle  :: Field f Text
  } deriving Generic

data ProfileT f = Profile
  { profileId   :: Field f (PrimaryKey (Serial Int))
  , profileUser :: Field f (Nullable (References User)) -- optional FK
  , profileBio  :: Field f Text
  } deriving Generic
```

The `Entity`, `HasRelation`, and `cascadeRules` declarations are written exactly as
today — the marker changes only the column field type and the generated DDL.

### What the projections give the caller

The FK is a plain readwrite scalar of the target's PK type — nothing about
constructing or reading rows changes:

```haskell
-- Identity (read) row:   postAuthor :: Int          ;  profileUser :: Maybe Int
-- Create payload:        postAuthor :: Int          ;  profileUser :: Maybe Int
-- Update payload:        postAuthor :: Patch Int     ;  profileUser :: Patch (Maybe Int)

p <- add (Post { postId = 0, postAuthor = uid, postTitle = "Hello" } :: Post)
patch (Key (postId p)) [ #postAuthor =. otherUid ]      -- reassign the FK like any column
```

### What the migration emits

```sql
CREATE TABLE posts
  ( post_id     BIGSERIAL PRIMARY KEY
  , post_author BIGINT NOT NULL
  , post_title  TEXT NOT NULL
  , FOREIGN KEY (post_author) REFERENCES users(user_id) );

CREATE TABLE profiles
  ( profile_id   BIGSERIAL PRIMARY KEY
  , profile_user BIGINT                       -- nullable: the optional FK
  , profile_bio  TEXT NOT NULL
  , FOREIGN KEY (profile_user) REFERENCES users(user_id) );
```

Adding a marked FK column to an existing table emits the constraint inline:

```sql
ALTER TABLE posts ADD COLUMN post_author BIGINT NOT NULL REFERENCES users(user_id);
```

### What changes at runtime

Referential integrity is now enforced by the **database**: inserting a `Post` whose
`postAuthor` is not an existing `user_id` fails with an FK violation — which does not
happen today (the DDL carries no constraints). Reads, writes, cascades, and the
`HasRelation` navigation API are unchanged.

## Cascade interaction (why `References` alone suffices)

Cascades remain modelled entirely by the existing app-level machinery
(`flushDelete` in `Manifest.Session`, driven by the parent's `cascadeRules`). A plain
`References` constraint (`NO ACTION`) is **compatible** with it, because that machinery
deletes **children-first, parent-last, in one transaction**:

`flushDelete` runs `restrictPass` → `mutatePass` → then deletes the parent; and
`mutatePass` is deepest-first (it descends into a `Cascade` rule's children before
deleting the child rows). So by the time the parent `DELETE` executes, no child row
references it and the `NO ACTION` constraint is satisfied. `SetNull` nulls the child
FKs first; `Restrict` aborts the whole delete before any mutation. All three agree
with a `NO ACTION` DB constraint — the constraint simply guarantees the integrity the
cascades already assume.

A column-level `ON DELETE CASCADE` (the deferred `ReferencesOnDelete` follow-up) would
let the DB perform the cascade so the parent-side `cascadeRules` could be dropped — an
optimisation, not a capability gap.

**Behavioural caveat:** today, deleting a parent that has children *and no cascade
rule* silently orphans them (their FK values dangle). With the FK constraint, that
same delete becomes a hard DB error — the caller must declare a `cascadeRules` entry
(or remove the children first). This is the intended, safer behaviour, but it is a
change for any entity that has children and no cascade rule.

## Why the column-marker can only express the owning side

A column marker can only describe the **forward / owning** side of a relationship
(this row points at exactly one parent → `One`, or `Opt` when the FK is nullable).
The **reverse** side (`hasMany` / `hasOpt`) has no column to mark, so it stays a
separate `HasRelation` declaration. Cardinality at the column level is therefore
expressed entirely by **nullability**:

- Required FK (`One`):  `Field f (References User)`
- Optional FK (`Opt`):  `Field f (Nullable (References User))`

## Module-layering resolution

`manifest-core` module graph: `Table.hs` (markers, `Base`, `Field`, `FieldMeta`)
→ `Meta.hs` (`ColumnMeta`, `GColumns`, `genericTableMeta`) → `Entity.hs` (`Entity`,
`PrimKey`) → (in the `manifest` pkg) `Migrate.hs`.

The marker's two jobs pull on layers in opposite directions; both are resolved:

1. **Column type — `Base (References t) = PrimKey t`.** `Base` lives in `Table.hs`
   but `PrimKey`/`GPrimKeyType` currently live above it in `Entity.hs` → cycle.
   **Resolution: relocate `PrimKey`/`GPrimKeyType` down into `Table.hs`** (or a low
   `Core` module). They depend only on `Base`, `Exposed`, and `GHC.Generics` — all
   already low — so the move is mechanical; `Entity.hs` re-exports them so existing
   imports are unaffected.

2. **DDL `REFERENCES users(user_id)` — needs the target's table + PK names**, which
   exist only as runtime values inside `Entity target`'s `tableMeta`, above
   `Meta.hs` → cycle. **Resolution: resolve FK target names in the migration/DDL
   layer, not in core metadata.** A type-level walk over `Rep (t Exposed)` (sibling
   to `GColumns`) lives in the `manifest` package where `Entity` is visible; for each
   FK field it requires `Entity target` and reads `tmTable`/`pkColumn` from
   `tableMeta @target`. `ColumnMeta` and `Entity` stay unchanged — FK info is only
   ever needed for DDL (at read/write time an FK is a plain scalar).

## Design

### Marker (`Manifest/Core/Table.hs`)

```haskell
data References (t :: Type)   -- FK to t's primary key
```

Exported from `Table.hs` alongside the existing vocabulary. Nullability composes with
the existing `Nullable` synonym on the **outside**: `Nullable (References User)`.

### `Base` family (`Table.hs`)

```haskell
Base (References t) = PrimKey t
Base (Maybe a)      = Maybe (Base a)   -- NEW, backward-compatible
```

The `Base (Maybe a)` clause makes `Nullable (References User)` (= `Maybe (References
User)`) strip to `Maybe (PrimKey User)` = `Maybe Int`. It is backward-compatible:
`Base (Maybe Text) = Maybe (Base Text) = Maybe Text` (unchanged). Placed before the
catch-all `Base a = a`.

### `Field` projections — no new clauses

The existing catch-all clauses handle the marker because `Base` strips it:

| Context  | `Field f (References User)` | `Field f (Nullable (References User))` |
|----------|-----------------------------|----------------------------------------|
| Identity | `Int`                       | `Maybe Int`                            |
| Create   | `Int`                       | `Maybe Int`                            |
| Update   | `Patch Int`                 | `Patch (Maybe Int)`                    |
| Exposed  | `Exposed (References User)`  | `Exposed (Maybe (References User))`    |

No `References`-specific `Field` clauses are added — an FK is a readwrite scalar.

### `FieldMeta` (`Table.hs`)

```haskell
instance DbType (PrimKey t) => FieldMeta (References t) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldNullable = False
  fieldSqlType = cSqlType (dbType @(PrimKey t))

-- Nullable FK form — needed because GColumns resolves FieldMeta on the field's
-- Exposed inner type, and there is no DbType for `Maybe (References t)` (unlike a
-- plain `Maybe Int`, which resolves via the OVERLAPPABLE DbType instance):
instance DbType (PrimKey t) => FieldMeta (Maybe (References t)) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldNullable = True
  fieldSqlType = cSqlType (dbType @(PrimKey t))
```

The column's SQL type is the target PK's SQL type (`BIGINT` for a `Serial Int` PK);
the nullable form sets `fieldNullable = True` so the column DDL omits `NOT NULL`.
`fieldTouchedOnUpdate` inherits the class default `False`. This is the only reason
`PrimKey` must be reachable from `Table.hs`. No FK *flag* is added to `FieldMeta` —
the migration-layer walk identifies FK fields structurally by marker head.

### FK reflection + DDL (`manifest` package, `Migrate.hs` layer)

- **`ForeignKey`** value: `{ fkColumn, fkRefTable, fkRefPkColumn }`.
- **`GForeignKeys (rep)`** — a type-level walk over `Rep (t Exposed)` (sibling of
  `GColumns`) with instances matching the FK marker head in `Exposed`: `References t`
  and its `Maybe` (nullable) form. Each FK instance carries `Entity target` and emits
  one `ForeignKey`, reading `tmTable`/`pkColumn` from `tableMeta @target` and the
  column name from the `Selector`.
- **`ManagedTable`** gains `mtForeignKeys :: [ForeignKey]`, populated where the
  managed schema is assembled (the layer that already sees `Entity`).
- **`renderCreateTable`** appends table-level constraint clauses after the column
  defs: `, FOREIGN KEY (post_author) REFERENCES users(user_id)`.
- **`renderAddColumn`** appends the FK inline on a newly-added column:
  `ALTER TABLE posts ADD COLUMN post_author BIGINT NOT NULL REFERENCES users(user_id)`.

## Testing / verification

1. **Type-level projection proofs** (a `ProjectionSpec`-style module): `Field Create
   (References User) ~ Int`, `Field Update (References User) ~ Patch Int`, `Field
   Identity (References User) ~ Int`, and the nullable form `Field Create (Nullable
   (References User)) ~ Maybe Int`.
2. **DDL render tests**: a fixture entity with a required FK and a nullable FK →
   assert `renderCreateTable` includes the correct `FOREIGN KEY (...) REFERENCES
   tbl(pk)` clauses (and the nullable column omits `NOT NULL`); assert
   `renderAddColumn` emits the inline `REFERENCES …` form.
3. **Integration (ephemeral Postgres)**:
   - Migrate the fixture schema; an FK-violating insert (author id not present) fails
     with an FK error.
   - **Cascade-compatibility**: a parent entity with a `Cascade` `cascadeRules` entry
     and a `References` child — deleting the parent succeeds (children removed
     first), proving the `NO ACTION` constraint does not break the app cascade.
4. **Regression**: existing plain-`Int` FK fixtures (`postAuthor`, `tagUser`,
   `profileUser`, `employeeManager`) emit byte-identical DDL (they have no marker);
   the `PrimKey` relocation keeps the whole `manifest` suite and the whole-workspace
   `zinc build` green.

## Files (anticipated)

- `manifest/manifest-core/src/Manifest/Core/Table.hs` — `References` marker; `Base`
  clauses; `FieldMeta` instances (required + nullable); **relocate**
  `PrimKey`/`GPrimKeyType` here.
- `manifest/manifest-core/src/Manifest/Entity.hs` — re-export `PrimKey`/
  `GPrimKeyType` from `Table` (compatibility); no behavioural change.
- `manifest/src/Manifest/Migrate.hs` (+ possibly a new
  `Manifest/Migrate/ForeignKey.hs`) — `ForeignKey`, `GForeignKeys`, `mtForeignKeys`,
  FK clauses in `renderCreateTable`/`renderAddColumn`.
- Tests: a new `ReferencesSpec` (type proofs + DDL render + integration), plus a
  fixture entity carrying the required and nullable FK shapes.

## Known limitation — FK table-creation ordering

Because the FK constraint is emitted **inline** in `CREATE TABLE`, the migrate
`[ManagedTable]` list order becomes load-bearing: a table whose `References` FK
targets another must appear **after** its target in the list, or `migrate up` fails
at run time with `relation "…" does not exist`. (Self-referential FKs are fine.)
Documented in `migrateUp`'s haddock. The clean fix — emitting FKs as an
`ALTER TABLE … ADD CONSTRAINT` post-pass after all `CREATE TABLE`s (which also handles
circular references) — is tracked as a follow-up bead.

## Out of scope / follow-up

- **`ReferencesOnDelete p T`** — a column-level DB-enforced `ON DELETE` policy
  (promote `OnDelete` to a kind, `KnownOnDelete` reflection, emit `ON DELETE …` in the
  FK clause). An optimisation over the app-level cascades. **Filed as a follow-up
  bead.**
- **FK emission via `ALTER TABLE … ADD CONSTRAINT` post-pass** — removes the
  table-ordering requirement above and supports circular FKs. **Filed as a follow-up
  bead.**
- Navigation derivation (`HasRelation` from the marker) — needs TH; separate bead.
- Retrofitting FK constraints onto existing columns/tables — needs constraint
  diffing the additive engine does not do.
- Composite/multi-column foreign keys.
- A manual `Entity` instance (not via the `deriving via Table` carrier) with a
  `References` column must set `foreignKeys = genericForeignKeys @t` to emit the
  constraint — the carrier does this automatically; manual instances opt in.
