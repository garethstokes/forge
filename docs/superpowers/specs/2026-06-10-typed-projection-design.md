# Manifest — Typed Projection (`?.`) — Design

**Status:** Approved (autonomous-loop design). Issue `manifest-bxw`. · **Date:** 2026-06-10

**Goal:** Remove the `:: Expr (Json T)` annotation needed when using jsonb operators on a
projected column, by adding a typed projection operator `?.` that recovers a column's real
type from the entity's record. As a bonus it makes projection typo-safe (a wrong field name
is a compile error).

---

## Problem

The query builder's `#label` projection is type-polymorphic: `#col :: Column a t` fixes
neither the entity nor the column type (only the handle's `^.` pins the entity). So
`s ^. #col :: Expr t` with `t` free. The jsonb operators need the document type — e.g.
`.->>` returns `Expr Text` and never mentions the document type `a`, so `t` stays
ambiguous and GHC cannot pick the `JsonbExpr` instance. Today the user writes
`(s ^. #userPrefs :: Expr (Json Prefs)) .->> "theme"`. The annotation is the wart.

## Design — a typed projection `?.`

Add an operator that recovers the column's real type from the entity's `Generic` record,
WITHOUT changing the existing `^.`/`#label`/`Column` machinery (additive, opt-in, zero
blast radius on existing queries).

### A Symbol-carrying label (so the operator sees the field name at the type level)

```haskell
data Label (name :: Symbol) = Label
instance (n ~ name) => IsLabel n (Label name) where fromLabel = Label
```

`#col` resolves to `Column a t` where `^.` is expected and to `Label "col"` where `?.` is
expected; no overlap (different target types), so both operators coexist.

### A generic "field type by name" lookup (scratch-verified)

```haskell
type family FieldType (name :: Symbol) (e :: Type) :: Type where
  FieldType name e = FromJust name (FindField name (Rep e))

type family FindField (name :: Symbol) (rep :: Type -> Type) :: Maybe Type where
  FindField name (D1 m f)  = FindField name f
  FindField name (C1 m f)  = FindField name f
  FindField name (a :*: b) = OrElseM (FindField name a) (FindField name b)
  FindField name (S1 ('MetaSel ('Just name)  su ss ds) (Rec0 t)) = 'Just t
  FindField name (S1 ('MetaSel ('Just other) su ss ds) (Rec0 t)) = 'Nothing

type family OrElseM (m :: Maybe Type) (n :: Maybe Type) :: Maybe Type where
  OrElseM ('Just t) _ = 'Just t
  OrElseM 'Nothing  n = n

type family FromJust (name :: Symbol) (m :: Maybe Type) :: Type where
  FromJust name ('Just t) = t
  FromJust name 'Nothing  = TypeError ('Text "entity has no field named " ':<>: 'ShowType name)
```

At `Identity` the HKD field reduces (`Field Identity (Json Prefs) = Base (Json Prefs) =
Json Prefs`), so `Rep (SettingT Identity)` carries `Rec0 (Json Prefs)` and
`FieldType "settingPrefs" Setting = Json Prefs`. (Verified in a scratch build.)

### The operator

```haskell
(?.) :: forall name e. (KnownSymbol name, Generic e) => Handle e -> Label name -> Expr (FieldType name e)
Handle al ?. _ = Expr (al <> "." <> camelToSnake (symbolVal (Proxy @name))) []
infixl 8 ?.
```

`camelToSnake` (from `Manifest.Core.Meta`) maps the field-name label to the column name,
matching how `tableMeta` derives column names. The result `Expr (FieldType name e)` is
fully pinned, so:

```haskell
s ?. #userPrefs .->> "theme" .== val "dark"   -- no annotation; Expr (Json Prefs) inferred
s ?. #userPrefs .@> Json (Prefs "dark" [])
s ?. #userName  .== val "ada"                 -- works for ordinary columns too (Expr Text)
```

A wrong name (`s ?. #userPrfs`) is a compile error (the `TypeError` from `FromJust`).

`?.` is for `Handle`; `OptHandle` keeps using `^.` (a left-join's nullable projection is a
less common spot for jsonb navigation; can be added later if wanted).

---

## Scope & testing

**In scope:** `Label`, the `FieldType`/`FindField`/`OrElseM`/`FromJust` families, and `?.`
in `Manifest.Query`; re-export `?.`/`Label`/`FieldType` from the umbrella; update the
JSONB manual section to show `?.` as the clean form (annotation no longer needed).

**Testing** (ephemeral Postgres, reuse `test/JsonSpec.hs`'s `Setting`/`Prefs`):
- the jsonb `.->>` / `.@>` query written with `?.` and NO annotation compiles and returns
  the right rows (mirror the existing annotated tests, dropping the annotation);
- `?.` on an ordinary (non-jsonb) column yields the right typed `Expr` and filters
  correctly;
- a compile-failure golden (reuse the shell-out-to-ghc pattern) that `s ?. #wrongName`
  fails to compile with the "no field named" error (proves the typo-safety);
- existing suite stays green (additive; `^.` untouched).

**Out of scope:** changing `^.` / `#label` / `Column` to be type-aware (large blast
radius); `?.` for `OptHandle`; projecting through joins by entity.
