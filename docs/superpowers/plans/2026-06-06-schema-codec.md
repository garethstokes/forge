# Crucible M3: Schema + renderSchema + bidirectional Codec — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** A `Schema` ADT with `renderSchema` (for prompt injection) and a bidirectional `Codec a` (schema + decoder + encoder) with the `ObjectCodec o a` applicative builder, sum support via `oneOfC`/`Variant`, and round-trip tests.

**Architecture:** `Crucible.Schema` (pure ADT + renderer) and `Crucible.Codec` (sits on the existing `Crucible.Json.{Value,Decode,Encode}`). Zero non-boot deps. See spec `docs/specs/2026-06-05-crucible-design.md` §6.

**Tech Stack:** GHC 9.6.5 via `nix develop`; zinc. Only `base`, `text`. Run zinc as `nix develop --command zinc <...>`.

**Already built & green (M0–M2):** `Crucible.Json.Value (Value(..))`, `Crucible.Json.Parse (parse)`, `Crucible.Json.Encode (encode)`, `Crucible.Json.Decode` (`Decoder`, `Error(..)`, `Crumb(..)`, `string/bool/int/float/null_/value/field/at/index/list/nullable/oneOf/succeed/failD/andThen/decodeValue/decodeString`). Test harness in `packages/crucible/test/{Harness,Spec}.hs`; `Spec.hs` is `module Main`, `{-# LANGUAGE OverloadedStrings #-}`, imports Value/Parse/Encode/Decode + Data.Text. Member `zinc.toml`: lib depends `["base","text"]`, test depends `["base","text","crucible"]` — new `src/Crucible/*` modules are auto-visible to tests.

**Beads:** M3 = `crucible-rs5`. Claim at Task 1: `bd update crucible-rs5 --claim`. Close at the end.

---

## Task 1: `Crucible.Schema` (ADT + renderSchema)

**Files:** Create `packages/crucible/src/Crucible/Schema.hs`; modify `packages/crucible/test/Spec.hs`.

- [ ] **Step 1: Failing tests**

In `Spec.hs` add `import Crucible.Schema` and:
```haskell
  , check "render string"   "string"                          (renderSchema SStr)
  , check "render number"   "number"                          (renderSchema SNum)
  , check "render boolean"  "boolean"                         (renderSchema SBool)
  , check "render optional" "string | null"                   (renderSchema (SOpt SStr))
  , check "render array"    "[number]"                        (renderSchema (SArr SNum))
  , check "render enum"     "\"clear\" | \"cloudy\" | \"storm\"" (renderSchema (SEnum ["clear","cloudy","storm"]))
  , check "render object"   "{\"city\": string, \"tempC\": number}"
      (renderSchema (SObj [("city", SStr), ("tempC", SNum)]))
  , check "render oneOf"    "number | string"                 (renderSchema (SOneOf [SNum, SStr]))
```
Run `nix develop --command zinc test` → FAIL (module not found).

- [ ] **Step 2: Implement Schema**

`packages/crucible/src/Crucible/Schema.hs`:
```haskell
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Schema (Schema(..), renderSchema) where

import Data.Text (Text)
import qualified Data.Text as T

-- | A structural description of a type, injected into prompts.
data Schema
  = SObj   [(Text, Schema)]
  | SArr   Schema
  | SEnum  [Text]
  | SOneOf [Schema]
  | SStr
  | SNum
  | SBool
  | SOpt   Schema
  deriving (Eq, Show)

-- | Compact, deterministic, single-line rendering (multi-line pretty is a later refinement).
renderSchema :: Schema -> Text
renderSchema SStr        = "string"
renderSchema SNum        = "number"
renderSchema SBool       = "boolean"
renderSchema (SOpt s)    = renderSchema s <> " | null"
renderSchema (SArr s)    = "[" <> renderSchema s <> "]"
renderSchema (SEnum xs)  = T.intercalate " | " (map quote xs)
renderSchema (SOneOf ss) = T.intercalate " | " (map renderSchema ss)
renderSchema (SObj fs)   =
  "{" <> T.intercalate ", " [ quote k <> ": " <> renderSchema v | (k, v) <- fs ] <> "}"

quote :: Text -> Text
quote s = "\"" <> s <> "\""
```

- [ ] **Step 3: Run** → PASS. `nix develop --command zinc test`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(m3): Crucible.Schema ADT + renderSchema"
```

---

## Task 2: `Crucible.Codec` primitives + list'/nullable'/enum

**Files:** Create `packages/crucible/src/Crucible/Codec.hs`; modify `Spec.hs`.

- [ ] **Step 1: Failing tests**

In `Spec.hs` add `import qualified Crucible.Codec as C` and `import Crucible.Codec (Codec(..))`, plus a sample enum:
```haskell
data Sky = Clear | Cloudy | Storm deriving (Eq, Show)

skyCodec :: Codec Sky
skyCodec = C.enum [("clear", Clear), ("cloudy", Cloudy), ("storm", Storm)]
```
and checks:
```haskell
  , check "prim schema str"  SStr            (codecSchema C.str)
  , check "prim encode int"  (JNumber 5.0)   (codecEncode C.int 5)
  , check "prim decode bool" (Right True)    (decodeValue (codecDecode C.bool) (JBool True))
  , check "list schema"      (SArr SNum)     (codecSchema (C.list' C.float))
  , check "list encode"      (JArray [JNumber 1.0, JNumber 2.0]) (codecEncode (C.list' C.float) [1, 2])
  , check "nullable schema"  (SOpt SStr)     (codecSchema (C.nullable' C.str))
  , check "nullable encode Nothing" JNull    (codecEncode (C.nullable' C.str) Nothing)
  , check "enum schema"      (SEnum ["clear","cloudy","storm"]) (codecSchema skyCodec)
  , check "enum encode"      (JString "storm") (codecEncode skyCodec Storm)
  , check "enum decode"      (Right Cloudy)  (decodeValue (codecDecode skyCodec) (JString "cloudy"))
  , check "enum decode bad"  True            (either (const True) (const False)
                                                (decodeValue (codecDecode skyCodec) (JString "nope")))
```
(`decodeValue` is from `Crucible.Json.Decode`, already imported as `D`; use `D.decodeValue`. If not imported, add it.) Run → FAIL.

- [ ] **Step 2: Implement Codec (primitives + list'/nullable'/enum)**

`packages/crucible/src/Crucible/Codec.hs`:
```haskell
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Codec
  ( Codec(..)
  , str, int, bool, float
  , list', nullable', enum
  -- ObjectCodec + sum support added in later tasks:
  , ObjectCodec(..), field, object
  , Variant(..), oneOfC
  ) where

import Data.Text (Text)
import Crucible.Schema (Schema(..))
import Crucible.Json.Value (Value(..))
import qualified Crucible.Json.Decode as D
import Crucible.Json.Decode (Decoder)

-- | Bidirectional: schema (for prompts) + decoder + encoder, in one value.
data Codec a = Codec
  { codecSchema :: Schema
  , codecDecode :: Decoder a
  , codecEncode :: a -> Value
  }

str :: Codec Text
str = Codec SStr D.string JString

int :: Codec Int
int = Codec SNum D.int (JNumber . fromIntegral)

bool :: Codec Bool
bool = Codec SBool D.bool JBool

float :: Codec Double
float = Codec SNum D.float JNumber

list' :: Codec a -> Codec [a]
list' (Codec s d e) = Codec (SArr s) (D.list d) (JArray . map e)

nullable' :: Codec a -> Codec (Maybe a)
nullable' (Codec s d e) = Codec (SOpt s) (D.nullable d) (maybe JNull e)

-- | An enum over a finite tagged set. Needs Eq for the encode-side reverse lookup.
enum :: Eq a => [(Text, a)] -> Codec a
enum pairs = Codec (SEnum (map fst pairs)) dec enc
  where
    dec = D.string `D.andThen` \t -> case lookup t pairs of
            Just a  -> D.succeed a
            Nothing -> D.failD ("unknown variant: " ++ show t)
    enc a = case [ k | (k, v) <- pairs, v == a ] of
              (k:_) -> JString k
              []    -> JNull   -- unreachable for a total enum table
```
> The `ObjectCodec`/`field`/`object`/`Variant`/`oneOfC` names are in the export list but get their definitions in Tasks 3–4. To keep this task compiling on its own, ADD their definitions now as written in Tasks 3 and 4 (it is fine to implement all of Codec.hs at once); the tests for them just arrive in later tasks. If you prefer strict TDD, temporarily trim the export list to only the primitives for this task and re-add in Task 3 — either is acceptable, but do not leave dangling exports.

- [ ] **Step 3: Run** → PASS. `nix develop --command zinc test`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(m3): Codec primitives + list'/nullable'/enum"
```

---

## Task 3: `ObjectCodec` + `field`/`object` (record round-trip)

**Files:** Modify `packages/crucible/src/Crucible/Codec.hs`, `Spec.hs`.

- [ ] **Step 1: Failing tests with a record**

In `Spec.hs`:
```haskell
data Forecast = Forecast { city :: Text, tempC :: Double, rainy :: Bool } deriving (Eq, Show)

forecastCodec :: Codec Forecast
forecastCodec = C.object $
  Forecast
    <$> C.field "city"  city  C.str
    <*> C.field "tempC" tempC C.float
    <*> C.field "rainy" rainy C.bool
```
checks:
```haskell
  , check "record schema"
      (SObj [("city", SStr), ("tempC", SNum), ("rainy", SBool)])
      (codecSchema forecastCodec)
  , check "record encode"
      (JObject [("city", JString "Brisbane"), ("tempC", JNumber 27.5), ("rainy", JBool False)])
      (codecEncode forecastCodec (Forecast "Brisbane" 27.5 False))
  , check "record decode"
      (Right (Forecast "Brisbane" 27.5 False))
      (decodeValue (codecDecode forecastCodec)
        (JObject [("city", JString "Brisbane"), ("tempC", JNumber 27.5), ("rainy", JBool False)]))
  , check "record round-trips through text"
      (Right (Forecast "Hobart" 9.0 True))
      (decodeString (codecDecode forecastCodec)
        (encode (codecEncode forecastCodec (Forecast "Hobart" 9.0 True))))
```
(`decodeString` from `D`, `encode` from `Crucible.Json.Encode` — already imported.) Run → FAIL (or already compiles if you implemented ObjectCodec in Task 2; in that case the checks should pass and you can proceed to commit).

- [ ] **Step 2: Implement ObjectCodec + field + object** (in `Codec.hs`)

```haskell
-- | Builds an object's field-schemas and decoder covariantly, and its encoder
-- contravariantly (o is the type being encoded; a the type decoded; they unify at `object`).
data ObjectCodec o a = ObjectCodec
  { ocFields :: [(Text, Schema)]
  , ocDecode :: Decoder a
  , ocEncode :: o -> [(Text, Value)]
  }

instance Functor (ObjectCodec o) where
  fmap f (ObjectCodec fs d e) = ObjectCodec fs (fmap f d) e

instance Applicative (ObjectCodec o) where
  pure x = ObjectCodec [] (pure x) (const [])
  ObjectCodec f1 d1 e1 <*> ObjectCodec f2 d2 e2 =
    ObjectCodec (f1 ++ f2) (d1 <*> d2) (\o -> e1 o ++ e2 o)

-- | A single object field. The getter (o -> f) supplies the encode direction.
field :: Text -> (o -> f) -> Codec f -> ObjectCodec o f
field name getter (Codec s d e) =
  ObjectCodec [(name, s)] (D.field name d) (\o -> [(name, e (getter o))])

-- | Close an object: o and a unify to the record type.
object :: ObjectCodec a a -> Codec a
object (ObjectCodec fs d e) = Codec (SObj fs) d (\a -> JObject (e a))
```

- [ ] **Step 3: Run** → PASS. `nix develop --command zinc test`.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(m3): ObjectCodec applicative builder (field/object), record round-trip"
```

---

## Task 4: `Variant` + `oneOfC` (sum round-trip)

**Files:** Modify `packages/crucible/src/Crucible/Codec.hs`, `Spec.hs`.

- [ ] **Step 1: Failing tests with a sum**

In `Spec.hs`:
```haskell
data Shape = Circle Double | Rect Double Double deriving (Eq, Show)

circleCodec :: Codec Double                      -- {"r": number}
circleCodec = C.object (C.field "r" id C.float)

rectCodec :: Codec (Double, Double)              -- {"w": number, "h": number}
rectCodec = C.object ((,) <$> C.field "w" fst C.float <*> C.field "h" snd C.float)

shapeCodec :: Codec Shape
shapeCodec = C.oneOfC
  [ C.Variant (codecSchema circleCodec)
              (Circle <$> codecDecode circleCodec)
              (\s -> case s of Circle r   -> Just (codecEncode circleCodec r);       _ -> Nothing)
  , C.Variant (codecSchema rectCodec)
              (uncurry Rect <$> codecDecode rectCodec)
              (\s -> case s of Rect w h   -> Just (codecEncode rectCodec (w, h));     _ -> Nothing)
  ]
```
checks:
```haskell
  , check "sum schema"
      (SOneOf [SObj [("r", SNum)], SObj [("w", SNum), ("h", SNum)]])
      (codecSchema shapeCodec)
  , check "sum encode circle" (JObject [("r", JNumber 2.0)]) (codecEncode shapeCodec (Circle 2))
  , check "sum decode rect"
      (Right (Rect 3.0 4.0))
      (decodeValue (codecDecode shapeCodec) (JObject [("w", JNumber 3), ("h", JNumber 4)]))
  , check "sum round-trips"
      (Right (Circle 2.0))
      (decodeValue (codecDecode shapeCodec) (codecEncode shapeCodec (Circle 2)))
```
Run → FAIL (unless already implemented in Task 2).

- [ ] **Step 2: Implement Variant + oneOfC** (in `Codec.hs`)

```haskell
-- | One arm of a sum: its schema, its decoder, and a partial encoder
-- (Nothing = "not my constructor").
data Variant a = Variant Schema (Decoder a) (a -> Maybe Value)

-- | A tagged/structural union. Decode tries each arm in order; encode uses the
-- first arm whose matcher fires.
oneOfC :: [Variant a] -> Codec a
oneOfC vs =
  Codec (SOneOf [ s | Variant s _ _ <- vs ])
        (D.oneOf  [ d | Variant _ d _ <- vs ])
        (\a -> case [ v | Variant _ _ enc <- vs, Just v <- [enc a] ] of
                 (v:_) -> v
                 []    -> JNull)   -- unreachable if the variant set is total
```

- [ ] **Step 3: Run** → PASS. `nix develop --command zinc test`.

- [ ] **Step 4: Commit + close M3**

```bash
git add -A && git commit -m "feat(m3): Variant + oneOfC sum codecs, round-trip"
```
Run: `bd close crucible-rs5 --reason="Schema+renderSchema and bidirectional Codec (primitives, list'/nullable'/enum, ObjectCodec field/object, Variant/oneOfC); round-trip tests green"`

---

## Self-Review

**Spec coverage (§6):** `Schema`+`renderSchema` (Task 1); `Codec` + primitives + `list'`/`nullable'`/`enum` (Task 2); `ObjectCodec`/`field`/`object` (Task 3); `Variant`/`oneOfC` (Task 4). ✓
**Placeholder scan:** Task 2 Step 2 flags that `ObjectCodec`/`Variant`/`oneOfC` are exported before their Task 3/4 definitions, with an explicit instruction (implement all at once, or trim exports) — a sequencing note, not a silent gap. No other gaps.
**Type consistency:** `Codec(..)` accessors `codecSchema`/`codecDecode`/`codecEncode`; `ObjectCodec(..)` `ocFields`/`ocDecode`/`ocEncode`; `field :: Text -> (o -> f) -> Codec f -> ObjectCodec o f`; `object :: ObjectCodec a a -> Codec a`; `Variant`/`oneOfC` consistent across tasks and tests. `enum` requires `Eq a` (used by `skyCodec`, `Sky` derives Eq). `Codec` is intentionally NOT a `Functor` (encode is contravariant) — sums use explicit `Variant` matchers, not `<$>` on `Codec`.
**Caveats (not failures):** `renderSchema` is single-line compact; multi-line pretty deferred. `JNumber` integral values render as `2.0` (tests account for it). `oneOfC` encode falls back to `JNull` only for a non-total variant set (shouldn't occur in practice).
