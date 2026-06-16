# Manifest — JSONB Columns (autodocodec) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-10

**Goal:** Let a column store a structured Haskell value as Postgres `jsonb`, serialized
through an autodocodec `HasCodec`, and let queries filter/extract on the document with
the common jsonb operators (`@>`, `->`, `->>`). This is **slice 2 of 2** of the "make
the core friendlier" effort; slice 1 (the `Codec`/`DbType` profunctor core) shipped and
is the foundation this builds on.

---

## 0. Stance

Slice 1 made the column codec a single profunctor value (`Codec a b`) carried by one
class (`DbType a`). A jsonb column is then just another `DbType` instance: a `Json a`
wrapper whose codec serializes `a` to/from JSON text (which libpq accepts as a `jsonb`
column value) and reports its SQL type as `jsonb`. autodocodec is the JSON engine
(chosen in the parent brainstorm): one `HasCodec a` value drives both encode and decode,
matching the "single source of truth" shape of `DbType` itself.

Storage alone is the floor; the value of jsonb in a database is querying into the
document, so this slice also adds the three everyday operators (`@>` containment,
`->` field-as-jsonb, `->>` field-as-text) to the query builder.

---

## 1. The `Json a` column (`Manifest.Json`, new module)

```haskell
newtype Json a = Json { unJson :: a } deriving (Eq, Show)

instance HasCodec a => DbType (Json a) where
  dbType = Codec
    { cEncode   = \(Json x) -> Just (jsonEncode x)            -- a -> jsonb text bytes
    , cDecode   = \p -> case p of
        Just bs -> bimap DecodeError Json (jsonDecode bs)     -- jsonb text bytes -> a
        Nothing -> Left (DecodeError "expected jsonb, got NULL")
    , cSqlType  = SqlJsonb
    , cNullable = False
    }
```

`jsonEncode`/`jsonDecode` wrap autodocodec-aeson: `jsonEncode = LB.toStrict .
encodeJSONViaCodec` (or the strict variant if exposed) and `jsonDecode =
eitherDecodeJSONViaCodec` (returns `Either String a`; `bimap DecodeError Json` adapts it).
`SqlParam = Maybe ByteString` is strict, so coerce the lazy bytes if needed.

This slots into the existing machinery with no other changes:

- At `Identity` the field is `Json a` (because `Base (Json a) = Json a`, the non-marker
  case), so `GRowEncode`/`GRowDecode` use `cEncode`/`cDecode` of `dbType @(Json a)`.
- `FieldMeta`'s base instance (`DbType a => FieldMeta a`) reports `fieldSqlType =
  cSqlType (dbType @(Json a)) = SqlJsonb`, so migration creates the column as `jsonb`.
- `Maybe (Json a)` (nullable jsonb) works through the existing `nullable` / `DbType
  (Maybe a)`.

An entity column is then just:

```haskell
data UserT f = User
  { userId    :: Field f (Pk Int)
  , userPrefs :: Field f (Json Prefs)        -- column type jsonb
  } deriving Generic
-- where Prefs has `instance HasCodec Prefs`
```

**Scope decision: `HasCodec`-only.** A plain-aeson (`ToJSON`/`FromJSON`) variant is a
possible follow-up, not built here.

## 2. `SqlJsonb` (`Manifest.Core.SqlType`)

Add the constructor and its two spellings:

```haskell
data SqlType = SqlBigInt | SqlText | SqlBool | SqlBigSerial | SqlJsonb
sqlTypeDDL  SqlJsonb = "JSONB"
sqlTypeLive SqlJsonb = "jsonb"     -- information_schema.columns.data_type reports "jsonb"
```

The migration engine (create-table, add-column, live-vs-declared diff) already routes
through `sqlTypeDDL`/`sqlTypeLive`, so a `jsonb` column is created and reconciled with no
migration-engine change beyond the new constructor.

## 3. JSONB query operators (`Manifest.Query`)

`Expr t = Expr ByteString [SqlParam]`, so the operators are thin renderers. The wrinkle:
`->` returns jsonb whose Haskell type is unknown, so introduce an opaque marker for that
intermediate plus a class for jsonb-valued expressions:

```haskell
data Jsonb                                   -- opaque: an untyped jsonb sub-document
class JsonbExpr e                            -- instances: Expr (Json a) and Expr Jsonb

(.@>)  :: Expr (Json a) -> Json a -> Expr Bool        -- containment:  lhs @> ?::jsonb
(.->)  :: JsonbExpr e => e -> Text -> Expr Jsonb      -- field/elem as jsonb (chainable)
(.->>) :: JsonbExpr e => e -> Text -> Expr Text       -- field/elem as text
infixl 8 .->, .->>
infix 4 .@>
```

- `(.@>) (Expr a pa) lit = Expr (a <> " @> ?::jsonb") (pa ++ [encode lit])` — the literal
  is a bound param cast to jsonb (`encode` of `Json a` produces the JSON text).
- `(.->) e k = Expr (raw e <> " -> " <> quoteLit k) (params e)` — the key is inline
  single-quoted via the existing `quoteLit` escaping (a structural selector, not user
  data); the `JsonbExpr` class exposes `raw`/`params` accessors over `Expr (Json a)` and
  `Expr Jsonb`.
- `(.->>) e k = Expr (raw e <> " ->> " <> quoteLit k) (params e)`, result `Expr Text`.

**Scope decision: `.->>` returns `Expr Text`** (compares directly with `val "dark"`); a
missing key yields SQL NULL, which simply fails the comparison (conventional behaviour).

Usage (a projected column carries a `:: Expr (Json a)` annotation, because the `#label`
projection's value type is not fixed by the label alone):

```haskell
runQuery $ do
  u <- from @User
  where_ ((u ^. #userPrefs :: Expr (Json Prefs)) .->> "theme" .== val "dark")
  pure u

containment: (u ^. #userPrefs :: Expr (Json Prefs)) .@> Json (Prefs Dark [])
chaining:    (u ^. #userPrefs :: Expr (Json Prefs)) .-> "window" .->> "title"
```

## 4. Umbrella exports (`Manifest.hs`)

Re-export `Json(..)`, the operators (`.@>`/`.->`/`.->>`), `Jsonb`, `JsonbExpr`, and
`HasCodec` (from autodocodec), so a jsonb column is declarable against `import Manifest`
plus `import Autodocodec` (to write the `HasCodec` instance).

---

## 5. Dependency (the gating risk)

This needs `autodocodec` + `autodocodec-aeson` (and transitively `aeson` and its closure:
scientific, vector, etc.) — a substantially larger closure than slice 1's `profunctors`.
Adding it is the make-or-break step.

**The plan must verify the dependency resolves and builds under zinc FIRST**, before any
feature code, via `zinc add autodocodec-aeson` (the mechanism established in the
profunctors follow-up: `zinc add` freezes the git closure into `zinc.lock`, then the
package goes into `[build.lib].depends`). If the closure does not resolve under zinc,
STOP and reassess — there is no cheap fallback (aeson is the heavy part regardless; an
in-house JSON codec is a much larger effort and out of scope).

---

## 6. Scope & testing

**In scope:** §1 the `Json a` column + `DbType` via autodocodec; §2 `SqlJsonb`; §3 the
`@>`/`->`/`->>` operators; §4 umbrella exports.

**Testing** (ephemeral Postgres via the existing harness, plus pure unit tests):

- a `Prefs` record with a hand-written `HasCodec` round-trips through a `jsonb` column
  (`add` then `get` returns an equal value; `save` updates it);
- a nested / sum-type structure round-trips;
- `.@>` containment filters to the right rows;
- `.->>` field extraction filters (`#userPrefs .->> "theme" .== val "dark"`);
- `.->` chaining renders and runs;
- a `Maybe (Json a)` column round-trips a `Nothing` (SQL NULL) and a `Just`;
- a pure unit test that `dbType @(Json Prefs)` encodes/decodes byte-correctly and reports
  `cSqlType = SqlJsonb`.

**Out of scope:** path operators (`#>`/`#>>`), GIN indexing, the plain-aeson
`ToJSON`/`FromJSON` column variant, and the non-binary `json` type (only `jsonb`).
