# Manifest — DerivingVia/Generics Entity (remove Template Haskell) — Design

**Status:** Approved design (brainstorm complete). Issue `manifest-czu`. · **Date:** 2026-06-09

**Goal:** Remove the Template Haskell entity front-end and replace its capability with
a fully-derivable `Entity` via `DerivingVia` + Generics + `DefaultSignatures`, so a
plain entity needs one `deriving via (Table "users" UserT) instance Entity User` line
and the `Entity` instance boilerplate (and the per-entity `type PrimKey` line)
disappears.

---

## 0. Stance

`mkEntity` (the TH macro from SP4a) did two jobs: generate the HKD record from a terse
field list, and generate the `Entity` instance. TH carries real costs (compile-time
weight, the `-fexternal-interpreter` golden hack and dynamic-GHC `dlopen` issues seen
in SP4a, tooling friction). The `Entity` instance is already ~90% generic
(`genericTableMeta`/`genericRowDecoder`/`genericRowEncode`); the remaining bits (table
name, `primKey`, `PrimKey`) can be pushed into a derivable form, eliminating the
hand-written instance without TH.

Trade accepted: Generics can derive *from* a type but cannot *generate* a declaration,
so the HKD record is now hand-written (`data UserT f = User { … :: Col f … } deriving
Generic`). We trade `mkEntity`'s terse record for "no TH + a one-line derivable
instance." (Brainstorm leaning: full DerivingVia replacement (A) over just deleting TH
(B); single `Entity` class with `DefaultSignatures` (A) over splitting schema/policy
into two classes (B), after a side-by-side example showed the single class is one line
for the common case.)

---

## 1. Removed

- `src/Manifest/Derive/TH.hs` (the `mkEntity`/`field` macro).
- `test/THSpec.hs` (its 4 tests: metadata, primKey, DB round-trip, no-PK golden) and
  its wiring in `test/Spec.hs`.
- `template-haskell` from `[build.lib].depends` in `zinc.toml`.
- `mkEntity`/`field` re-exports from `src/Manifest.hs`.
- The "Deriving entities with Template Haskell" section in `docs/entities.md`.

---

## 2. The derivable `Entity`

### 2.1 `PrimKey` becomes a standalone type family

Today `PrimKey` is an *associated* type, declared per instance (`type PrimKey User =
Int`). `DerivingVia` cannot derive associated types, so for a one-line `deriving via`
instance, `PrimKey` moves to a standalone closed family computed from the record's
metadata Rep:

```haskell
type family PrimKey a where
  PrimKey (Table name t) = GPrimKeyType (Rep (t Exposed))
  PrimKey (t Identity)   = GPrimKeyType (Rep (t Exposed))
```

`GPrimKeyType` walks the `Generic` rep of `t Exposed`, finds the field marked
`PrimaryKey …`, and returns `Base` of its inner marker (e.g. `PrimaryKey (Serial Int)`
→ `Int`; `PrimaryKey (Serial UserId)` → `UserId`). The two equations cover both a real
entity (`t Identity`) and the carrier (`Table name t`); both reduce to the same type,
which is what lets `deriving via` coerce `primKey`'s return type. This deletes the
`type PrimKey X = …` line from every entity.

### 2.2 `DefaultSignatures` for the name-free methods

`Entity` gains generic defaults for the methods that do not need the table name:

```haskell
class Typeable a => Entity a where
  tableMeta  :: TableMeta a                          -- NO default (needs the name)
  rowDecoder :: RowDecoder a
  default rowDecoder :: (Generic a, GRowDecode (Rep a)) => RowDecoder a
  rowDecoder = genericRowDecoder
  rowEncode  :: a -> [SqlParam]
  default rowEncode :: (Generic a, GRowEncode (Rep a)) => a -> [SqlParam]
  rowEncode = genericRowEncode
  primKey    :: a -> PrimKey a
  default primKey :: GPrimKey a => a -> PrimKey a
  primKey = genericPrimKey
  cascadeRules :: [CascadeRule]
  cascadeRules = []
  rlsPolicies  :: [Policy a]
  rlsPolicies  = []
```

`genericPrimKey :: GPrimKey a => a -> PrimKey a` is a generic projection: locate the
`PrimaryKey`-marked field (by the same Rep walk `GPrimKeyType` uses) and return its
value, typed as `PrimKey a`.

### 2.3 The `Table` carrier (the table name + the `deriving via` target)

```haskell
newtype Table (name :: Symbol) (t :: Type -> Type) = Table (t Identity)

instance ( KnownSymbol name, Generic (t Exposed), GColumns (Rep (t Exposed))
         , Generic (t Identity), GRowDecode (Rep (t Identity))
         , GRowEncode (Rep (t Identity)), GPrimKey (t Identity), Typeable (t Identity) )
      => Entity (Table name t) where
  tableMeta  = coerce (genericTableMeta @t (toName (symbolVal (Proxy @name))))
  rowDecoder = coerce (genericRowDecoder @(t Identity))
  rowEncode  (Table x) = genericRowEncode x
  primKey    (Table x) = genericPrimKey x
```

`deriving via (Table "users" UserT) instance Entity User` then coerces these onto
`User` (`= UserT Identity`), which has the same runtime representation as `Table "users"
UserT`. (`toName` is `BC.pack`; the table name is the `Symbol` verbatim, no
pluralisation.)

---

## 3. End state per entity

```haskell
-- plain entity: one line
deriving via (Table "posts" PostT) instance Entity Post

-- cascade / RLS entity: a short explicit instance (table name + the policy; rest defaults)
instance Entity User where
  tableMeta    = genericTableMeta @UserT "users"
  cascadeRules =
    [ cascade (Proxy @Post)    (Proxy @"postAuthor")  Cascade
    , cascade (Proxy @Profile) (Proxy @"profileUser") SetNull
    , cascade (Proxy @Tag)     (Proxy @"tagUser")     Restrict ]
```

Both forms drop the `type PrimKey` line, fully derive the schema, and are safe (no
overlapping instances). Modules using `deriving via` enable `DerivingVia`.

---

## 4. Migration (the bulk of the work)

Every entity declaration moves to the new form, and every `type PrimKey X = …` line is
removed (it is no longer an associated type, so those lines become compile errors):

- `test/Fixtures.hs`: `User` (cascades → explicit), `Post`/`Profile`/`Tag`/`Employee`/
  `Comment` (plain → `deriving via`).
- `test/RlsSpec.hs`: `Secret`/`Vault` (RLS policies → explicit), and the migration test
  entities.
- `test/TypedFieldsSpec.hs`: `Account`/`Note` (plain → `deriving via`).
- `app/Main.hs`: the `manifest-migrate` example entity.

The existing suite (minus THSpec's 4) must stay green: that is the proof the derived
instances behave identically to the hand-written ones (same `tableMeta`, codec,
`primKey`, identity-map keying, cascades, RLS).

---

## 5. Feasibility to verify first

Two type-level pieces carry the risk and get a scratch verification (the way the
newtype-column deriving was scratch-checked before the typed-fields slice) before the
migration:

1. **The standalone `PrimKey` family** reduces for both `t Identity` and the `Table
   name t` carrier, so `deriving via (Table "users" UserT) instance Entity User`
   typechecks (`PrimKey User ~ PrimKey (Table "users" UserT)`).
2. **`genericPrimKey`** compiles and returns the right field's value as `PrimKey a`.

**Fallback if either resists:** keep `PrimKey`/`primKey` minimally explicit — a tiny
per-entity line (`type instance PrimKey User = Int` via a standalone open family, or a
hand-written `primKey = userId`) — rather than fully generic. The table-name carrier and
the `DefaultSignatures` for `rowDecoder`/`rowEncode` still deliver most of the win, and
plain entities stay close to one line. The design degrades gracefully.

---

## 6. Scope & testing

One cohesive slice: the deriving overhaul forces the entity migration and enables the
TH removal, so they cannot sensibly be separated. Sizable but mechanical once the
carrier + the two generic pieces are in.

**Testing:** the existing suite is the regression oracle (entities must behave
identically after migration). Add one focused test that a freshly-declared plain entity
using only `deriving via (Table "x" XT) instance Entity X` round-trips end to end
(`add`/`get`/`selectWhere`), proving the derived path works for a brand-new entity, not
just the migrated fixtures.

---

## 7. Out of scope

- Auto-generating the HKD record from a terse field list (that was `mkEntity`'s other
  job; Generics cannot generate declarations, and reviving any record-generation is a
  non-goal).
- Pluralisation / name inference for the table name (it is the `Symbol` verbatim).
- The relationship-enforced FK↔PK check and `mkEntity` id auto-generation (the typed-
  fields follow-ups) remain separate and are unaffected by this change.
