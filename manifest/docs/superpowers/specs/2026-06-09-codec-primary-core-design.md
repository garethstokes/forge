# Manifest — Codec-Primary Core (`Field` / `Codec` / `DbType`) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-09

**Goal:** Make the column codec a single profunctor value (`Codec a b`) carried by one
class (`DbType a`), replacing the three single-variance classes
(`ToField`/`FromField`/`ScalarMeta`); and rename the HKD field wrapper `Col` to `Field`
with marker aliases, so the core is both more uniform and more accessible. This is
**slice 1 of 2** in the "make the core friendlier" effort; slice 2 (JSONB columns via
autodocodec) layers on top and is out of scope here.

---

## 0. Stance

A column codec is inherently a profunctor: contravariant in the value it encodes,
covariant in the value it decodes. Today Manifest splits that into three one-sided
classes — `ToField` (encode), `FromField` (decode), `ScalarMeta` (SQL type +
nullability) — and the generic walks (`GColumns`/`GRowDecode`/`GRowEncode`) dispatch on
all three. autodocodec demonstrates the better shape: one bidirectional value is the
source of truth, and everything downstream (encode, decode, schema) is read from it.

We adopt that model for column codecs, with one adaptation: our "schema" is just a
`SqlType` plus a nullability flag, so a flat record profunctor suffices (no GADT). The
unification removes a whole class of "I added `ToField` but forgot `ScalarMeta`" gaps,
makes a custom/domain column a one-line `dimap`, and is the foundation slice 2 builds
on (a JSONB column is just another `DbType` instance).

Naming was the one collision to resolve: the user wants `Field` to replace `Col` (the
HKD wrapper), and the profunctor would also naturally be `Field`. Resolution: **`Field`**
= the HKD field wrapper (was `Col`); **`Codec`** = the profunctor column codec;
**`DbType`** = the class carrying it.

(Brainstorm leaning: full unification (A) over a contained feature; remove the three old
classes (a clean single-class core) over keeping them as derived facades, because GND
still gives newtypes a one-line `deriving newtype DbType`, so removal does not make the
typed-fields idiom worse — it makes it simpler.)

---

## 1. The `Codec` profunctor (`Manifest.Core.Codec`)

A flat record, contravariant in `a`, covariant in `b`:

```haskell
data Codec a b = Codec
  { cEncode   :: a -> SqlParam
  , cDecode   :: SqlParam -> Either DecodeError b
  , cSqlType  :: SqlType
  , cNullable :: Bool
  }
```

Combinators (the friendly surface); `cSqlType`/`cNullable` ride along unchanged through
`dimap`, which is exactly what makes a newtype reuse its base type's column type:

```haskell
dimap  :: (a' -> a) -> (b -> b') -> Codec a b -> Codec a' b'
lmap   :: (a' -> a) -> Codec a b -> Codec a' b
rmap   :: (b -> b') -> Codec a b -> Codec a b'
refine :: (b -> Either DecodeError c) -> Codec a b -> Codec a c   -- failing/validated decode
nullable :: Codec a a -> Codec (Maybe a) (Maybe a)                 -- NULL <-> Nothing, cNullable=True
```

Also expose a real `instance Profunctor Codec` (from the `profunctors` package, added as
a library dependency) so the standard `dimap`/`lmap`/`rmap` vocabulary works; the named
helpers above are thin re-exports/aliases for discoverability. `refine` and `nullable`
are Manifest-specific (no profunctor-class equivalent).

`RowDecoder a` (the existing row-level applicative) **stays** — it is the row builder the
generic walk assembles from per-column codecs. `Codec` is column-level; `RowDecoder` is
row-level.

---

## 2. The `DbType` class — the one leaf codec class

```haskell
class DbType a where
  dbType :: Codec a a

instance DbType Int    where dbType = Codec (Just . BC.pack . show) decInt  SqlBigInt False
instance DbType Text   where dbType = Codec (Just . encodeUtf8)     decText SqlText   False
instance DbType Bool   where dbType = Codec encBool                 decBool SqlBool   False
instance DbType String where dbType = dimap T.pack T.unpack (dbType @Text)   -- reuse Text
instance DbType a => DbType (Maybe a) where dbType = nullable dbType
```

`decInt`/`decText`/… are the existing decode bodies from the old `FromField` instances,
moved verbatim into `cDecode`. The `Maybe` instance moves the old nullable handling into
the `nullable` combinator.

Two helpers replace the old per-class entry points used across the codebase:

```haskell
encode    :: DbType a => a -> SqlParam       -- was toField        (= cEncode dbType)
decodeCol :: DbType a => RowDecoder a        -- was `field`        (one column via cDecode dbType)
```

---

## 3. Removing `ToField` / `FromField` / `ScalarMeta`

The three classes are deleted; `DbType` is the only leaf codec class. Migration of every
call/constraint site (wide but mechanical; the suite is the oracle):

- `Manifest.Core.Codec`: delete `ToField`/`FromField`; `field` → `decodeCol`. Keep
  `RowDecoder`, `decodeRow`, `SqlParam`.
- `Manifest.Core.Table`: delete `ScalarMeta`; `FieldMeta`'s base case reads
  `cSqlType (dbType @a)` / `cNullable (dbType @a)` instead of `scalarType`/`scalarNullable`.
  The `PrimaryKey`/`Serial` `FieldMeta` instances (which force `BIGSERIAL` etc.) are
  unchanged.
- `Manifest.Core.Meta` (`GColumns`): leaf instance reads the codec's `cSqlType`/`cNullable`
  (via `FieldMeta`, unchanged) — no direct change expected beyond the `FieldMeta` edit.
- `Manifest.Entity` (`GRowDecode`/`GRowEncode` leaves): `field` → `decodeCol`,
  `toField` → `encode`. `genericPrimKey`'s `FromField (PrimKey a)` constraint →
  `DbType (PrimKey a)`; its body uses `decodeCol`/`cDecode dbType`.
- `Manifest.Core.Query` (`==.`/`/=.`/`>.`/`<.`/`=.`, `val`): `ToField t` → `DbType t`,
  `toField` → `encode`.
- `Manifest.Query` (builder `val`, `currentSetting`/`lit` if they touch encode): same.
- `Manifest.Session` / `Session.Command` (`get`/`update`/`Key`): `ToField (PrimKey a)`
  → `DbType (PrimKey a)`, `toField` → `encode`.
- The umbrella `Manifest` re-exports `ToField(..)`/`FromField(..)`/`ScalarMeta(..)`
  (added in the typed-fields slice) → replace with `DbType(..)`, `Codec(..)`,
  `dimap`/`lmap`/`rmap`/`refine`/`nullable`, `encode`, `SqlType(..)`.

### 3.1 Typed-fields idiom gets simpler

GND still works because `Codec`'s params are representational (verify first — see §6), so
a newtype gets its codec in one clause, and a domain mapping is one line:

```haskell
newtype Email  = Email Text deriving newtype DbType            -- was: deriving newtype (ToField,FromField,ScalarMeta)
newtype UserId = UserId Int deriving newtype DbType
-- explicit / non-newtype mapping:
instance DbType Money where dbType = dimap unMoney Money (dbType @Int)
```

Typed PKs/FKs (`Field f (Pk UserId)`, `Field f UserId`) flow exactly as before: `Base`
reduces the markers, and `DbType UserId` provides the codec.

---

## 4. `Col` → `Field` rename + marker aliases (`Manifest.Core.Table`)

```haskell
type family Field (f :: Type -> Type) (a :: Type) :: Type where
  Field Identity a = Base a
  Field Exposed  a = Exposed a

type Pk a       = PrimaryKey (Serial a)
type Nullable a = Maybe a
```

`Col` is removed (renamed). Every entity declaration changes `Col f X` → `Field f X` and
`PrimaryKey (Serial T)` → `Pk T`; nullable columns may use `Nullable T`. This is a pure
spelling change: at `Exposed`, `Field Exposed a` still reduces to `Exposed a`, so the
generic walks and `GPrimKeyType` (which match `Rec0 (Exposed t)`) are untouched.
`Base`, `Exposed`, `PrimaryKey`, `Serial`, `FieldMeta` keep their names.

Entities to migrate (rename + alias, alongside the §3 codec migration where the entity
also declares newtype codecs): `test/Fixtures.hs`, `test/RlsSpec.hs`,
`test/TypedFieldsSpec.hs`, `app/Main.hs`, and any `Col`/`PrimaryKey (Serial …)` in
library example code.

Docs: `docs/entities.md`, `docs/getting-started.md`, `docs/index.md` move to
`Field`/`Pk`, and the typed-fields section shows `deriving newtype DbType` and a `dimap`
domain column. Manual voice (no em-dashes, no other-ORM names, no positioning claims).

---

## 5. End state (illustrative)

```haskell
newtype UserId = UserId Int deriving newtype DbType

data UserT f = User
  { userId   :: Field f (Pk UserId)
  , userName :: Field f Text
  , userBio  :: Field f (Nullable Text)
  } deriving Generic
type User = UserT Identity
deriving via (Table "users" UserT) instance Entity User
```

One codec class, the marker noise aliased away, and the HKD wrapper reads as `Field`.

---

## 6. Feasibility to verify first

Scratch-check (as the typed-fields and DerivingVia plumbing were) BEFORE the wide
migration:

1. **`deriving newtype DbType` works** — `Codec`'s `a`/`b` params get representational
   roles, so `Coercible (Codec Text Text) (Codec Email Email)` holds and GND derives the
   instance for `newtype Email = Email Text`.
2. **`dimap`/`refine`/`nullable` typecheck and round-trip** a sample domain newtype.

**Fallback if (1) resists:** drop `deriving newtype DbType`; users write the one-line
`instance DbType Email where dbType = dimap unEmail Email dbType`. The rest of the design
is unaffected.

---

## 7. Scope & testing

**In scope:** §1 `Codec` + combinators + `Profunctor` instance; §2 `DbType` + the scalar
instances + `encode`/`decodeCol`; §3 removal of the three classes with all constraint
sites migrated; §4 `Col`→`Field` rename + `Pk`/`Nullable` aliases + docs.

**Testing — the existing suite is the regression oracle:** every entity, CRUD verb
(`add`/`get`/`save`/`update`/`delete`/`selectWhere`), query op, and migration must behave
identically (same encoded bytes, same generated SQL types), because `Codec` reproduces
exactly what the three classes did. New focused tests:

- a `dimap`-defined domain column (e.g. `Money`) round-trips through the DB;
- a `deriving newtype DbType` column (e.g. `Email`) round-trips;
- a `refine`/validated decode rejects malformed input (a decode that returns `Left`).

**Out of scope (later):**

- **Slice 2 — JSONB columns via autodocodec** (`Json a` as a `DbType` instance,
  `SqlJsonb`, DDL/migration). This slice deliberately does not add the `autodocodec`
  dependency or any JSON type.
- `ProductProfunctor` / combinator-style row assembly — the HKD + Generics derivation
  remains the row builder; `Codec` is column-level only.
- User-facing profunctor *table* mappings (Opaleye-style entity definitions).
