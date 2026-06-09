# Manifest — Typed Fields (newtype columns + typed PK/FK) — Design

**Status:** Approved design (brainstorm complete). Issue `manifest-29q`. · **Date:** 2026-06-09

**Goal:** Let important fields be distinct newtypes — typed primary keys and foreign
keys (a `UserId` cannot be confused with a `PostId` or filled from the wrong id), and
any domain value (`Email`, `Money`, `Slug`) as a first-class column — built on
hand-written newtypes that Manifest makes frictionless. Purely additive: existing
entities with bare `Int`/`Text` fields keep working unchanged.

---

## 0. Stance

Manifest entities are HKD records whose runtime fields are bare base types today
(`userId :: Int`, `postAuthor :: Int`). That permits two classes of mistake the type
checker should catch:

- **id confusion** — using a `PostId` where a `UserId` is expected;
- **wrong foreign key** — filling `postAuthor` (a user id) from a `postId`.

The fix is to type those fields as distinct newtypes. The chosen approach is **A:
hand-written newtypes, made frictionless** (over auto-generating ids in the deriver,
which is a deferred follow-up). The same enabler that makes a typed id work makes any
domain newtype a column.

The striking property of this design is how little new machinery it needs: the
existing `Col`/`Base`/`Serial`/`PrimaryKey` families and the codec are already
type-generic, so most of the work is **validating, documenting, and dogfooding** a
capability the type machinery already supports, plus a minimal helper for any gap
found.

---

## 1. Enabler — newtype columns

A value type is usable as a column when it has three capabilities:

- `ToField` / `FromField` (`Manifest.Core.Codec`) — encode/decode the libpq text value.
- `ScalarMeta` (`Manifest.Core.Table`) — its `SqlType` and nullability.

A user makes any newtype a first-class column with one deriving clause:

```haskell
newtype UserId = UserId Int deriving newtype (ToField, FromField, ScalarMeta)
-- equivalently: deriving (ToField, FromField, ScalarMeta) via Int
```

Consequences that already hold:

- `Maybe UserId` (a nullable typed FK) works through the existing
  `ToField`/`FromField`/`ScalarMeta` instances for `Maybe a`.
- The same clause turns `Email`/`Money`/`Slug` (newtypes over `Text`/`Int`) into
  columns; ids are just the headline use.

**Validation the slice must do:** confirm all three classes derive cleanly for a
newtype. `ToField`/`FromField` mention the type variable in their methods, so GND
coerces them straightforwardly. `ScalarMeta`'s methods (`scalarType :: SqlType`,
`scalarNullable :: Bool`) are `@a`-dispatched and do not mention the variable; GND or
`DerivingVia Int` should still produce the instance, but if a wrinkle appears the
fallback is a documented one-line instance (`instance ScalarMeta UserId where { scalarType = SqlBigInt; scalarNullable = False }`)
or a small `DerivingVia` helper Manifest exports. Either way the user writes one short
clause.

---

## 2. Typed primary keys

Declare the id newtype, use it inside the PK marker, and point the entity's `PrimKey`
at it:

```haskell
data UserT f = User
  { userId    :: Col f (PrimaryKey (Serial UserId))   -- runtime UserId; column BIGSERIAL
  , userName  :: Col f Text
  } deriving Generic
type User = UserT Identity

instance Entity User where
  type PrimKey User = UserId
  tableMeta  = genericTableMeta @UserT "users"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = userId
```

Everything downstream already flows the newtype, with no new machinery:

- `Base (PrimaryKey (Serial UserId)) = Base (Serial UserId) = UserId`, so
  `Col Identity (PrimaryKey (Serial UserId)) = UserId` — the runtime field is `UserId`.
- The `Serial` marker still drives `BIGSERIAL` (its `FieldMeta` instance is independent
  of the inner type), so the migration/DDL is unchanged.
- `add` reads the `RETURNING` id back into `UserId` via its `FromField`.
- `Key User = Key { unKey :: UserId }`, so `get (Key (UserId 42))`.
- The identity map keys on the encoded PK (`pkParam` via `ToField UserId`) — unchanged
  bytes, so identity/`save`/`flush` are unaffected.

---

## 3. Typed foreign keys (typed-by-convention)

A foreign-key field is typed as the *target's* id:

```haskell
data PostT f = Post
  { postId     :: Col f (PrimaryKey (Serial PostId))
  , postAuthor :: Col f UserId          -- FK to users.user_id, typed
  , postTitle  :: Col f Text
  } deriving Generic
```

This gives the practical safety with zero new machinery:

- You cannot fill `postAuthor` from a `PostId` — it is a `UserId` in the record and
  everywhere it is read or written.
- It flows through the query builder unchanged (the column/operators are
  `t`-polymorphic): `#postAuthor ==. val someUserId`, `deleteWhere @Post [#postAuthor ==. uid]`.
- `Key`-based operations need only `ToField UserId` (from the enabler).
- Relationship loading is unaffected: `belongsTo (Proxy @"postAuthor")` /
  `hasMany (Proxy @"postAuthor")` are name-based, and `UserId` encodes to the same
  bytes as `Int`, so the join values match. The relationship declaration is **not yet
  type-checked** against the target's `PrimKey` (that is follow-up B).

---

## 4. Deferred (follow-ups)

- **B — relationship-enforced FK ↔ PK matching.** `belongsTo`/`hasMany` additionally
  require, at the type level, that the FK column's value type unifies with the target
  entity's `PrimKey`, so a mis-wired relation (FK pointing at the wrong entity's id)
  fails to compile. Touches the `HasRelation`/relationship-builder constraints; layers
  cleanly on this slice.
- **Auto-generated ids.** Extend the `mkEntity` TH front-end to mint a `<Entity>Id`
  newtype and wire it as the PK, so opting in is zero-boilerplate for TH-declared
  entities.

---

## 5. Scope & validation

One small, self-contained slice, framed as **validate + document + dogfood**:

1. **Validate** that a newtype derives `ToField`/`FromField`/`ScalarMeta` and works as
   a PK and FK end to end. If a deriving gap appears (most likely `ScalarMeta`), add the
   minimal helper or document the one-line instance.
2. **Dogfood** with a typed-id demo entity (a new fixture, not a migration of the whole
   suite) that proves an end-to-end round-trip: `add` (insert + `RETURNING`-decode into
   the id newtype), `get` by `Key`, a typed FK filled from the parent's id, a
   relationship load across the typed FK, and a query by the typed column
   (`#fk ==. val theId`).
3. **Document** a manual section ("Typed fields") showing the deriving pattern, a typed
   PK, a typed FK, and a domain newtype (`Email`).

### 5.1 What changes in the library

Likely **little or no** library code — the capability already exists. Concretely:

- Confirm/enable the three-class deriving for newtypes; export a `DerivingVia` helper
  only if needed.
- Re-export whatever a user needs from one import (`ToField`, `FromField`,
  `ScalarMeta`, `SqlType` constructors) so a typed-column newtype can be declared
  against `import Manifest` alone.

Existing entities and tests are untouched; the demo entity is additive.

---

## 6. Testing

Against the ephemeral Postgres (`Fixtures.withTestDb`/`withEmptyDb`):

- **Round-trip:** define a `Account`/`Note` pair with `AccountId`/`NoteId` newtype PKs
  and a typed FK `noteAccount :: Col f AccountId`; `add` an account, `add` a note with
  its id, `get (Key accId)` decodes the id newtype, `selectWhere [#noteAccount ==. val accId]`
  filters by the typed FK.
- **Compile-time safety (golden):** a small standalone module that tries to fill the
  typed FK with the wrong id newtype must fail to compile (reuse the
  `RelationErrorSpec` shell-out-to-ghc pattern), proving the type actually distinguishes
  ids.
- **Domain newtype:** an `Email` newtype over `Text` round-trips as a normal column.

---

## 7. Out of scope

- Relationship-level FK ↔ PK enforcement (follow-up B).
- Auto-generating id newtypes in the deriver / `mkEntity`.
- Smart-constructor / validation layers on domain newtypes (e.g. a checked `Email`);
  the newtype is a transparent column, validation is the application's concern.
