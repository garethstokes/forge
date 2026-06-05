# Crucible M4: Codec.Generic (HasCodec + genericCodec) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** An opt-in `Crucible.Codec.Generic` module: a `HasCodec` typeclass (canonical codec per type) + `genericCodec` deriving schema+decoder+encoder together via GHC Generics, so leaf records/enums derive with no hand-written getters. Derived codecs are the same `Codec a` as hand-written ones and round-trip identically.

**Architecture:** A new module `Crucible.Codec.Generic` sitting on `Crucible.Codec`. This is the ONLY module that uses GHC.Generics; the core stays Generics-free. See spec §6 (Derive). Zero non-boot deps (GHC.Generics ships with `base`).

**Tech Stack:** GHC 9.6.5 via `nix develop`; zinc. `base`, `text` only. Run zinc as `nix develop --command zinc <...>`.

**Already built & green (M0–M3):** full JSON layer + `Crucible.Schema (Schema(..), renderSchema)` + `Crucible.Codec` (`Codec(..)` with `codecSchema/codecDecode/codecEncode`; `str int bool float list' nullable' enum`; `ObjectCodec(..)`, `field`, `object`; `Variant(..)`, `oneOfC`). `Crucible.Json.Decode as D` exports `string int bool float field list nullable oneOf succeed failD andThen decodeValue decodeString`. Test harness + `Spec.hs` (`module Main`, OverloadedStrings) all green. Member `zinc.toml` lib/test depends include `base text crucible`.

**Beads:** M4 = `crucible-tu9`. Claim at start; close at end.

> **Implementer note:** GHC.Generics has fiddly ergonomics (the `undefined :: S1 ... x` idioms, kind signatures, `M1 D/C/S` tags, `Rec0 = K1 R`). The code below is the intended design and should be close to compiling, but expect to nudge type annotations, add `{-# LANGUAGE #-}` pragmas, or adjust the `selName`/`conName` proxies until GHC is happy. The TESTS are the contract — make them green. Required extensions you will likely need: `DeriveGeneric, DefaultSignatures, FlexibleContexts, FlexibleInstances, TypeOperators, TypeApplications, ScopedTypeVariables, AllowAmbiguousTypes, KindSignatures, MultiParamTypeClasses` (and `OverloadedStrings`).

---

## Task 1: `HasCodec` class + base instances

**Files:** Create `packages/crucible/src/Crucible/Codec/Generic.hs`; modify `Spec.hs`.

First: `bd update crucible-tu9 --claim`.

- [ ] **Step 1: Failing tests**

In `Spec.hs` add `import Crucible.Codec.Generic (HasCodec(..), genericCodec)` and:
```haskell
  , check "HasCodec Text schema"   SStr        (codecSchema (codec :: Codec Text))
  , check "HasCodec Int encode"    (JNumber 7.0) (codecEncode (codec :: Codec Int) 7)
  , check "HasCodec [Bool] schema" (SArr SBool) (codecSchema (codec :: Codec [Bool]))
  , check "HasCodec Maybe schema"  (SOpt SNum)  (codecSchema (codec :: Codec (Maybe Double)))
```
Run `nix develop --command zinc test` → FAIL (module not found).

- [ ] **Step 2: Implement the class + base instances**

`packages/crucible/src/Crucible/Codec/Generic.hs` (start with just the class + base instances + a stub `genericCodec` to be filled in Task 2):
```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE KindSignatures #-}
module Crucible.Codec.Generic
  ( HasCodec(..)
  , genericCodec
  , GCodec    -- exported so `default` signature + deriving works
  ) where

import Data.Text (Text)
import GHC.Generics
import Crucible.Schema (Schema(..))
import Crucible.Json.Value (Value(..))
import qualified Crucible.Codec as C
import Crucible.Codec (Codec(..))

-- | The canonical codec for a type. Used by the generic deriver to resolve
-- nested fields by type. Provide instances by hand OR via `genericCodec`.
class HasCodec a where
  codec :: Codec a
  default codec :: (Generic a, GCodec (Rep a)) => Codec a
  codec = genericCodec

instance HasCodec Text   where codec = C.str
instance HasCodec Int    where codec = C.int
instance HasCodec Bool   where codec = C.bool
instance HasCodec Double where codec = C.float
instance HasCodec a => HasCodec [a]       where codec = C.list' (codec @a)
instance HasCodec a => HasCodec (Maybe a) where codec = C.nullable' (codec @a)
```
And the generic machinery (filled here so the module compiles; tested in later tasks):
```haskell
-- | Build schema + decoder + encoder from a type's Generic Rep.
genericCodec :: forall a. (Generic a, GCodec (Rep a)) => Codec a
genericCodec = Codec (gschema @(Rep a))
                     (to <$> gdecode)
                     (gencode . from)

class GCodec (f :: * -> *) where
  gschema :: Schema
  gdecode :: Crucible.Json.Decode.Decoder (f x)
  gencode :: f x -> Value
```
> Import `Crucible.Json.Decode` qualified (e.g. `import qualified Crucible.Json.Decode as D`) and use `D.Decoder`, `D.field`, `D.list`, `D.string`, `D.andThen`, `D.succeed`, `D.failD`, `D.oneOf` in the instances below. The class signature above uses a fully-qualified `Decoder` for clarity — alias it.

Leave the `GCodec` *instances* for Task 2/3 but add a single trivial instance so Task 1 compiles, OR (cleaner) implement all instances now and let Task 2/3 just add tests. Either is fine; do not leave the class instance-less if `genericCodec` is referenced. **Simplest: implement all GCodec instances now (Task 2 + Task 3 code), commit base-instances test here, and let later tasks add derive tests.**

- [ ] **Step 3:** Add `text` already present. Run `nix develop --command zinc test` → the 4 base checks PASS.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(m4): HasCodec class + base instances"
```

---

## Task 2: `GCodec` for records (single constructor) + derive a record

**Files:** Modify `Crucible/Codec/Generic.hs`, `Spec.hs`.

- [ ] **Step 1: Failing test — derived record matches hand-written**

In `Spec.hs` (reuse `Forecast` from M3, which already has a hand-written `forecastCodec`):
```haskell
instance HasCodec Forecast    -- derived via genericCodec (Forecast already derives Generic? add it)
```
Ensure `Forecast` has `deriving (Eq, Show, Generic)` (add `Generic` and `import GHC.Generics (Generic)` to `Spec.hs`). Then:
```haskell
  , check "derived record schema == hand-written"
      (codecSchema forecastCodec)
      (codecSchema (codec :: Codec Forecast))
  , check "derived record round-trips"
      (Right (Forecast "Cairns" 31.0 True))
      (decodeValue (codecDecode (codec :: Codec Forecast))
                   (codecEncode (codec :: Codec Forecast) (Forecast "Cairns" 31.0 True)))
```
Run → FAIL.

- [ ] **Step 2: Implement the record GCodec instances**

Add to `Crucible/Codec/Generic.hs`:
```haskell
-- Datatype wrapper: descend.
instance GCodec f => GCodec (M1 D c f) where
  gschema = gschema @f
  gdecode = M1 <$> gdecode
  gencode (M1 x) = gencode x

-- Single constructor = record: an object built from its product of selectors.
instance GProd f => GCodec (M1 C c f) where
  gschema = SObj (gpFields @f)
  gdecode = M1 <$> gpDecode
  gencode (M1 x) = JObject (gpEncode x)

-- Products of named selectors.
class GProd (f :: * -> *) where
  gpFields :: [(Text, Schema)]
  gpDecode :: D.Decoder (f x)
  gpEncode :: f x -> [(Text, Value)]

instance (GProd a, GProd b) => GProd (a :*: b) where
  gpFields = gpFields @a ++ gpFields @b
  gpDecode = (:*:) <$> gpDecode <*> gpDecode
  gpEncode (a :*: b) = gpEncode a ++ gpEncode b

instance (Selector s, HasCodec t) => GProd (M1 S s (K1 r t)) where
  gpFields = [ (sel, codecSchema (codec @t)) ]
  gpDecode = M1 . K1 <$> D.field sel (codecDecode (codec @t))
  gpEncode (M1 (K1 v)) = [ (sel, codecEncode (codec @t) v) ]

-- helper to read the selector name (lives near the instance):
-- sel :: Text  -- computed from selName; see note
```
> The selector name: `sel = Data.Text.pack (selName (undefined :: M1 S s (K1 r t) x))`. Because `sel` is used in three methods of the same instance, define it once via a `where`/`let` in each method, or a top-level helper `selNameT :: forall s. Selector s => Text`. The cleanest is a helper:
> ```haskell
> selNameT :: forall s f x. Selector s => Text
> selNameT = Data.Text.pack (selName (undefined :: M1 S s f x))
> ```
> and call `selNameT @s` in each method. Adjust until GHC accepts the proxy type.

- [ ] **Step 3: Run** → PASS (derived schema equals hand-written, round-trip works). Iterate on Generics ergonomics until green.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(m4): genericCodec for records"
```

---

## Task 3: `GCodec` for enums (sum of nullary constructors) + derive an enum

**Files:** Modify `Crucible/Codec/Generic.hs`, `Spec.hs`.

- [ ] **Step 1: Failing test**

In `Spec.hs` ensure `Sky` derives `Generic` (add it), and `instance HasCodec Sky`. Then:
```haskell
  , check "derived enum schema"  (SEnum ["Clear","Cloudy","Storm"]) (codecSchema (codec :: Codec Sky))
  , check "derived enum encode"  (JString "Storm")                  (codecEncode (codec :: Codec Sky) Storm)
  , check "derived enum decode"  (Right Cloudy)                     (decodeValue (codecDecode (codec :: Codec Sky)) (JString "Cloudy"))
```
> NOTE: derived enum tags are the CONSTRUCTOR NAMES (`"Clear"`, `"Cloudy"`, `"Storm"`), capitalised — unlike the hand-written `skyCodec` from M3 which used lowercase `"clear"` etc. That divergence is expected and fine: derivation uses constructor names; customise by hand-writing when you need different tags. Keep both codecs in the tests to show they differ intentionally.

Run → FAIL.

- [ ] **Step 2: Implement the enum GCodec instances**

Add to `Crucible/Codec/Generic.hs`:
```haskell
import Control.Applicative ((<|>))

-- Sum of constructors = enum.
instance (GSum a, GSum b) => GCodec (a :+: b) where
  gschema = SEnum (gsNames @(a :+: b))
  gdecode = D.andThen
              (\n -> case gsDecode n of Just v -> D.succeed v; Nothing -> D.failD ("unknown variant: " ++ show n))
              D.string
  gencode = JString . gsEncode

class GSum (f :: * -> *) where
  gsNames  :: [Text]
  gsDecode :: Text -> Maybe (f x)   -- Just if a constructor name matches
  gsEncode :: f x -> Text

instance (GSum a, GSum b) => GSum (a :+: b) where
  gsNames = gsNames @a ++ gsNames @b
  gsDecode n = (L1 <$> gsDecode n) <|> (R1 <$> gsDecode n)
  gsEncode (L1 x) = gsEncode x
  gsEncode (R1 x) = gsEncode x

instance Constructor c => GSum (M1 C c U1) where
  gsNames    = [ conNameT @c ]
  gsDecode n = if n == conNameT @c then Just (M1 U1) else Nothing
  gsEncode _ = conNameT @c

conNameT :: forall c f x. Constructor c => Text
conNameT = Data.Text.pack (conName (undefined :: M1 C c f x))
```
> Same proxy caveat as `selNameT`. Adjust the `undefined :: M1 C c f x` annotation until `conName` resolves.

- [ ] **Step 3: Run** → PASS. Iterate until green.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(m4): genericCodec for nullary-sum enums"
```

---

## Task 4: Nested derive (composition) + close M4

**Files:** Modify `Spec.hs`.

- [ ] **Step 1: Failing test — a record whose fields are themselves derived**

In `Spec.hs`:
```haskell
data Station = Station { name :: Text, latest :: Forecast, conditions :: Sky }
  deriving (Eq, Show, Generic)
instance HasCodec Station

stationVal :: Station
stationVal = Station "Eagle Farm" (Forecast "Brisbane" 26.0 False) Cloudy
```
checks:
```haskell
  , check "nested derived schema"
      (SObj [ ("name", SStr)
            , ("latest", SObj [("city", SStr), ("tempC", SNum), ("rainy", SBool)])
            , ("conditions", SEnum ["Clear","Cloudy","Storm"]) ])
      (codecSchema (codec :: Codec Station))
  , check "nested derived round-trips"
      (Right stationVal)
      (decodeValue (codecDecode (codec :: Codec Station))
                   (codecEncode (codec :: Codec Station) stationVal))
```
Run → should PASS with NO new implementation (the `GProd (M1 S s (K1 r t))` instance calls `codec @t`, which dispatches through `HasCodec` to the derived `Forecast`/`Sky` codecs). If it does not, the bug is in the recursion — fix `Crucible.Codec.Generic`, not the test.

- [ ] **Step 2: Run** → PASS.

- [ ] **Step 3: Commit + close M4**

```bash
git add -A && git commit -m "test(m4): nested genericCodec composition"
```
Run: `bd close crucible-tu9 --reason="HasCodec + genericCodec derive schema/decode/encode for records, nullary-sum enums, and nested compositions; derived==hand-written round-trips green"`

---

## Self-Review

**Spec coverage (§6 Derive):** `HasCodec` + base instances (Task 1); `genericCodec` records (Task 2); enums (Task 3); nested composition (Task 4). Core stays Generics-free — all Generics confined to `Crucible.Codec.Generic`. ✓
**Placeholder scan:** Task 1 instructs implementing the full `GCodec` machinery up front (cleanest) to avoid an instance-less class; the `selNameT`/`conNameT` proxy helpers are flagged as ergonomics that may need annotation nudging — guided implementation, not silent gaps. The single-line schema/encode expectations are exact.
**Type consistency:** `HasCodec`/`codec`/`genericCodec`/`GCodec`(`gschema`/`gdecode`/`gencode`)/`GProd`(`gpFields`/`gpDecode`/`gpEncode`)/`GSum`(`gsNames`/`gsDecode`/`gsEncode`) consistent across tasks. Derived codecs produce the same `Codec a` type as `Crucible.Codec`, so they compose in `field`/`list'`/`oneOfC`. Derived enum tags = constructor names (capitalised) — intentionally differing from M3's hand-written lowercase `skyCodec`; both kept to document the difference.
**Caveats (not failures):** GHC.Generics proxy idioms may need iteration (flagged). Sum-with-fields (tagged unions carrying data) is NOT covered — only nullary-sum enums; tagged-union derivation is deferred (hand-write via `oneOfC`/`Variant`, as the `Decision`/tool codecs will at M6/M9). Records with zero fields encode as `{}` (add `instance GProd U1` if such a type appears; not needed by these tests).
