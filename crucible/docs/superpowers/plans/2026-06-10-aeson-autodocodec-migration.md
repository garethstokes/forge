# aeson + autodocodec Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace crucible's hand-rolled JSON + codec/schema layer with aeson (`Data.Aeson.Value` everywhere) and autodocodec (codec + JSON Schema), in one coordinated migration; delete `Crucible.Json`, `Crucible.Schema`.

**Architecture:** A slim `Crucible.Codec` facade re-exports autodocodec combinators under crucible's existing names (`str`/`object`/`field`/…) to minimise consumer churn; `Crucible.Codec.Generic` is retargeted to emit an autodocodec `JSONCodec` from GHC.Generics; every JSON site moves to `Data.Aeson.Value`. Schema for tool `input_schema`/prompts comes from `autodocodec-schema` (`toJSON (jsonSchemaVia codec)`).

**Tech Stack:** Haskell GHC 9.10.1, aeson 2.3.0.0, autodocodec 0.5.0.0, autodocodec-schema 0.2.0.1 (all verified to build under zinc on 9.10.1). Build/test via `nix develop . --command zinc {build,test}`.

---

## ⚠️ Read this first: this is an atomic migration, not per-task-green TDD

The `Value` type is load-bearing across the whole codebase. **The build will NOT compile green until the foundation + every consumer is converted (Task 8).** Tasks 1–7 are coordinated edits that leave the tree red; do them in order, then drive the remaining compile errors to zero in Task 8. Per-task `zinc test` gates do **not** apply until Task 8. The implementer should expect red intermediate builds and use `nix develop . --command zinc build 2>&1 | grep error` to track remaining work.

Do this on one branch. Commit per task (even with a red build) so progress is reviewable; the green gate, full suite, and live smoke run are Tasks 8–9.

## Verified API reference (use these exact names)

**aeson** (`Data.Aeson`, `Data.Aeson.KeyMap as KM`, `Data.Aeson.Key as K`, `Data.Vector as V`, `Data.Scientific`):
- `data Value = Object Object | Array Array | String Text | Number Scientific | Bool Bool | Null`; `Object = KeyMap Value`, `Array = Vector Value`.
- Build: `object [ "k" .= v, ... ] :: Value`; `(.=) :: ToJSON v => Key -> v -> Pair`; `toJSON`; `String t`; `Number (fromInteger n)` / `Number (realToFrac d)`; `Bool b`; `Null`; `Array (V.fromList xs)`.
- Parse/decode: `decode`/`eitherDecode :: ByteString -> …`; `withObject "n" (\o -> o .: "k") :: Value -> Parser a`; `.:`/`.:?`; `parseEither :: (a -> Parser b) -> a -> Either String b`; `parseMaybe`.
- Text round-trips: `Data.Aeson.encode :: ToJSON a => a -> LB.ByteString`; for a `Value` to strict `Text`, use `TE.decodeUtf8 . LB.toStrict . encode`. To parse strict `Text` to `Value`: `eitherDecode (LB.fromStrict (TE.encodeUtf8 t)) :: Either String Value`.

**autodocodec** (`Autodocodec`): `JSONCodec a = ValueCodec a a`; `JSONObjectCodec a = ObjectCodec a a`; `class HasCodec a where codec :: JSONCodec a`. Combinators: `textCodec`, `boolCodec`, `scientificCodec`, `valueCodec :: JSONCodec Value`, `listCodec`, `maybeCodec`, `object :: Text -> ObjectCodec i o -> ValueCodec i o`, `requiredFieldWith' :: Text -> ValueCodec i o -> ObjectCodec i o`, `(.=) :: ObjectCodec oi o -> (ni -> oi) -> ObjectCodec ni o`, `stringConstCodec :: Eq c => NonEmpty (c, Text) -> JSONCodec c`, `disjointEitherCodec :: Codec ctx i1 o1 -> Codec ctx i2 o2 -> Codec ctx (Either i1 i2) (Either o1 o2)`, `dimapCodec`, `bimapCodec`. Encode/decode with a codec **value**: `toJSONVia :: ValueCodec a void -> a -> Value`, `parseJSONVia :: ValueCodec void a -> Value -> Parser a`. `HasCodec Int`/`Double`/`Text`/`Bool`/`Maybe`/`[]`/`Value` instances exist.

**autodocodec-schema** (`Autodocodec.Schema`): `jsonSchemaVia :: ValueCodec i o -> JSONSchema`; `jsonSchemaViaCodec :: HasCodec a => JSONSchema`; `instance ToJSON JSONSchema` (so `toJSON (jsonSchemaVia c) :: Value` is the JSON-Schema document).

---

### Task 1: dependency + the `Crucible.Codec` facade

**Files:** Modify `zinc.toml`; rewrite `src/Crucible/Codec.hs`.

- [ ] **Step 1: add the schema dep.** Run `nix develop . --command zinc add autodocodec-schema` (resolves + freezes the lock; verified to build). Then add `"autodocodec-schema"` to `[build.lib] depends` and to `[build.test.spec] depends` in `zinc.toml`. (aeson + autodocodec are already present from SP2.)

- [ ] **Step 2: rewrite `Crucible.Codec` as a thin autodocodec facade.** Replace the entire body of `src/Crucible/Codec.hs` with re-exports under crucible's existing names so most consumers compile unchanged:

```haskell
{-# LANGUAGE TypeApplications #-}
module Crucible.Codec
  ( JSONCodec, ObjectCodec
  , str, int, bool, float, list', nullable', enum
  , object, field, anyValue
  , schemaValue, schemaText
  ) where

import Data.Aeson (Value)
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LB
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Autodocodec
  ( JSONCodec, ObjectCodec, codec, textCodec, boolCodec, valueCodec
  , listCodec, maybeCodec, stringConstCodec, requiredFieldWith', (.=) )
import qualified Autodocodec as AC
import Autodocodec.Schema (jsonSchemaVia)

str :: JSONCodec Text
str = textCodec
bool :: JSONCodec Bool
bool = boolCodec
int :: JSONCodec Int
int = codec
float :: JSONCodec Double
float = codec
anyValue :: JSONCodec Value
anyValue = valueCodec

list' :: JSONCodec a -> JSONCodec [a]
list' = listCodec
nullable' :: JSONCodec a -> JSONCodec (Maybe a)
nullable' = maybeCodec

-- | crucible's old @enum [(tag, value)]@, on autodocodec.
enum :: Eq a => [(Text, a)] -> JSONCodec a
enum pairs = stringConstCodec (NE.fromList [ (a, t) | (t, a) <- pairs ])

-- | A single object field bundling its getter (crucible's old @field@).
field :: Text -> (o -> f) -> JSONCodec f -> ObjectCodec o f
field k getter c = requiredFieldWith' k c .= getter

-- | Close an applicative object codec (crucible's old @object@). A fixed schema
-- name is fine for our flat tool/output schemas.
object :: ObjectCodec a a -> JSONCodec a
object = AC.object "object"

-- | The JSON-Schema document for a codec, as an aeson Value (tool input_schema).
schemaValue :: JSONCodec a -> Value
schemaValue = A.toJSON . jsonSchemaVia

-- | The schema rendered as compact JSON text (for prompt injection).
schemaText :: JSONCodec a -> Text
schemaText = TE.decodeUtf8 . LB.toStrict . A.encode . schemaValue
```

(Notes: crucible's old `int` rendered via `fromIntegral`; autodocodec's `HasCodec Int` is bounded-integral — equivalent for our values. `oneOfC`/`Variant` are intentionally dropped; the only sum consumer, `Decision`, is rewritten directly with `disjointEitherCodec` in Task 4.)

- [ ] **Step 3: commit (red build expected).**

```bash
git add zinc.toml zinc.lock src/Crucible/Codec.hs
git commit -m "$(printf 'migrate(codec): autodocodec-schema dep + Crucible.Codec autodocodec facade\n\n[atomic migration: tree red until the green gate]\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: retarget `Crucible.Codec.Generic` to emit a `JSONCodec`

**Files:** Rewrite `src/Crucible/Codec/Generic.hs`.

The current module derives `(Schema, Decoder, Value)` from `Rep` via `GCodec`/`GProd`/`GSum`. Retarget it to build an autodocodec `JSONCodec` from `Rep`: records → an applicative `ObjectCodec` of `requiredFieldWith'` fields; nullary sums → `stringConstCodec`. Re-export autodocodec's `HasCodec`.

- [ ] **Step 1: rewrite the module.** Replace `src/Crucible/Codec/Generic.hs` with:

```haskell
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
-- | Generic derivation of an autodocodec 'JSONCodec' from GHC.Generics, so
-- @instance HasCodec T where codec = genericCodec@ works for records and
-- nullary-constructor enums. The ONLY module here using GHC.Generics.
module Crucible.Codec.Generic
  ( HasCodec (..)
  , genericCodec
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics
import Autodocodec
  ( JSONCodec, ObjectCodec, HasCodec (codec), requiredFieldWith'
  , stringConstCodec, dimapCodec, (.=) )
import qualified Autodocodec as AC

-- | Build a 'JSONCodec' for any single-record or nullary-sum 'Generic' type.
genericCodec :: forall a. (Generic a, GCodec (Rep a)) => JSONCodec a
genericCodec = dimapCodec to from (gcodec @(Rep a))

class GCodec (f :: * -> *) where
  gcodec :: JSONCodec (f x)

-- datatype wrapper: delegate
instance GCodec f => GCodec (M1 D c f) where
  gcodec = dimapCodec M1 unM1 (gcodec @f)

-- single constructor with named fields = record -> object
instance (Constructor c, GProd f) => GCodec (M1 C c f) where
  gcodec = dimapCodec M1 unM1 (AC.object (conNameT @c) (gprod @f))

-- sum of nullary constructors = enum -> stringConstCodec
instance (GNullary (a :+: b)) => GCodec (a :+: b) where
  gcodec = stringConstCodec (gvariants @(a :+: b))

class GProd (f :: * -> *) where
  gprod :: ObjectCodec (f x) (f x)

instance (GProd a, GProd b) => GProd (a :*: b) where
  gprod = (:*:) <$> lmapFst (gprod @a) <*> lmapSnd (gprod @b)
    where
      lmapFst c = c .= (\(a :*: _) -> projL a)   -- see note below
      lmapSnd c = c .= (\(_ :*: b) -> projR b)

-- NOTE on the product instance: the applicative ObjectCodec needs each field's
-- getter to project from the WHOLE product. The implementer should build this
-- with autodocodec's `.=` over `requiredFieldWith'`, projecting the relevant
-- factor; the standard pattern is:
--   gprod = (:*:) <$> (gfield @a .= prodL) <*> (gfield @b .= prodR)
-- where `prodL (a :*: _) = a` etc. Implement `GProd` for a single selector and
-- compose via `:*:` using these projections. (Spelled out concretely in Step 2.)

instance (Selector s, HasCodec t) => GProd (M1 S s (K1 r t)) where
  gprod = dimapCodec (M1 . K1) (\(M1 (K1 v)) -> v)
            (requiredFieldWith' (selNameT @s) codec)

class GNullary (f :: * -> *) where
  gvariants :: NonEmpty (f x, Text)
instance (GNullary a, GNullary b) => GNullary (a :+: b) where
  gvariants = fmap (\(x,t)->(L1 x,t)) (gvariants @a) <> fmap (\(x,t)->(R1 x,t)) (gvariants @b)
instance Constructor c => GNullary (M1 C c U1) where
  gvariants = (M1 U1, conNameT @c) :| []

selNameT :: forall s. Selector s => Text
selNameT = T.pack (selName (undefined :: M1 S s f x))
conNameT :: forall c. Constructor c => Text
conNameT = T.pack (conName (undefined :: M1 C c f x))
```

- [ ] **Step 2: make `GProd` for `:*:` compile correctly.** The applicative-over-product needs each field codec to read from the whole product. Implement the `(:*:)` instance using autodocodec's `.=` with explicit projections (replace the sketch above):

```haskell
instance (GProd a, GProd b) => GProd (a :*: b) where
  gprod =
    (:*:)
      <$> mapObjectInput (\(a :*: _) -> a) (gprod @a)
      <*> mapObjectInput (\(_ :*: b) -> b) (gprod @b)

-- helper: contramap an ObjectCodec's input (lmap) — autodocodec's `.=` is `flip lmap`.
mapObjectInput :: (i -> i') -> ObjectCodec i' o -> ObjectCodec i o
mapObjectInput f c = c .= f
```

(If GHC reports the `dimapCodec (M1 . K1) …` selector instance doesn't unify with `mapObjectInput`, adjust the single-selector `GProd` instance to return `ObjectCodec (M1 S s (K1 r t) x) t` and reassemble; the implementer drives this to compile. Verify with: a record like `Forecast {city,tempC,rainy}` derives and round-trips — exercised by the Task 8 tests.)

- [ ] **Step 3: commit (red build expected).**

```bash
git add src/Crucible/Codec/Generic.hs
git commit -m "$(printf 'migrate(codec): retarget genericCodec to emit an autodocodec JSONCodec\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: delete `Crucible.Json.*` and `Crucible.Schema`; rewrite `SAP`

**Files:** Delete `src/Crucible/Json/{Value,Parse,Encode,Decode}.hs`, `src/Crucible/Schema.hs`; rewrite `src/Crucible/SAP.hs`.

- [ ] **Step 1: delete the modules.**

```bash
git rm src/Crucible/Json/Value.hs src/Crucible/Json/Parse.hs src/Crucible/Json/Encode.hs src/Crucible/Json/Decode.hs src/Crucible/Schema.hs
```

- [ ] **Step 2: rewrite `Crucible.SAP`** to decode messy LLM text through a codec **value** on aeson. Keep `stripToJson` verbatim (it is pure text→text). Replace `decodeLLM`:

```haskell
module Crucible.SAP (stripToJson, decodeLLM) where

import Data.Aeson (Value)
import qualified Data.Aeson as A
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy as LB
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Autodocodec (JSONCodec, parseJSONVia)

-- stripToJson :: Text -> Text   -- UNCHANGED (copy the existing body verbatim)

-- | Strip JSON out of LLM prose, parse it, and decode through the codec.
decodeLLM :: JSONCodec a -> Text -> Either String a
decodeLLM c t =
  case A.eitherDecode (LB.fromStrict (TE.encodeUtf8 (stripToJson t))) of
    Left err  -> Left err
    Right v   -> parseEither (parseJSONVia c) (v :: Value)
```

(Note the error type changes from `Crucible.Json.Decode.Error` to `String`. Every `decodeLLM` caller — `Function.call`, `Agent.runAgent`, `Eval.judge` — must switch its error handling from `D.message err` to the `String` directly; covered in Tasks 4–5.)

- [ ] **Step 3: commit (red build expected).**

```bash
git add -A
git commit -m "$(printf 'migrate(json): delete Crucible.Json + Crucible.Schema; SAP on aeson+autodocodec\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 4: domain consumers — `Function`, `Decision`, `Tool`, `Eval`, `Agent`, `Example`

**Files:** Modify `src/Crucible/Function.hs`, `Decision.hs`, `Tool.hs`, `Eval.hs`, `Agent.hs`, `Example.hs`.

Apply these exact changes (each module currently imports `Crucible.Codec`/`Schema`/`Json`):

- [ ] **Step 1: `Function`.** `fnInput :: JSONCodec i`, `fnOutput :: JSONCodec o` (was `Codec`). `fnPrompt` injects the schema via `schemaText (fnOutput fn)` (replacing `renderSchema (codecSchema …)`) and encodes the input via aeson over `toJSONVia (fnInput fn) input`:

```haskell
-- imports: Crucible.Codec (schemaText), Autodocodec (toJSONVia), Crucible.SAP (decodeLLM)
fnPrompt fn input =
  [ Message System ("Respond ONLY with JSON matching this schema:\n" <> schemaText (fnOutput fn))
  , Message User (fnInstruction fn input <> "\n\nInput:\n" <> jsonText (toJSONVia (fnInput fn) input)) ]
  where jsonText = TE.decodeUtf8 . LB.toStrict . Data.Aeson.encode
```

`call`: `decodeLLM (fnOutput fn) raw :: Either String o`; on `Left err` feed `err` (a `String`, `T.pack`'d) back; the `Left` return type of `call` becomes `Either String o`.

- [ ] **Step 2: `Decision`.** Rewrite `decisionCodec` with autodocodec's disjoint either (no `oneOfC`):

```haskell
-- imports: Autodocodec (JSONCodec, disjointEitherCodec, dimapCodec)
decisionCodec :: JSONCodec tool -> JSONCodec answer -> JSONCodec (Decision tool answer)
decisionCodec toolC ansC =
  dimapCodec
    (either CallTool Done)
    (\d -> case d of CallTool t -> Left t; Done a -> Right a)
    (disjointEitherCodec toolC ansC)
```

- [ ] **Step 3: `Tool`.** `tcArgs :: Value` (aeson). `anyValue` now from `Crucible.Codec` (= `valueCodec`). `toolCallCodec` keeps the same shape (`object (ToolCall <$> field "tool" tcName str <*> field "args" tcArgs anyValue)`) — compiles against the facade. **`toolSchema :: Value`** (aeson JSON-Schema), was `Schema`. `toolRun :: Value -> Eff es Value` (aeson). Update `toolsHelp` to render schema with `schemaText`-style or drop the per-tool schema text if it used `renderSchema` (use the tool's `toolSchema` Value encoded to text).

- [ ] **Step 4: `Eval`.** `verdictCodec` compiles against the facade (`object (Verdict <$> field "vPass" vPass bool <*> field "vWhy" vWhy str)`). `judge`: `decodeLLM verdictCodec raw :: Either String Verdict`; on `Left e` use `T.pack e` (was `D.message e`).

- [ ] **Step 5: `Agent`.** `startAgent` schema text via `schemaText codec` (was `renderSchema (codecSchema codec)`). `runAgent`: `decodeLLM codec raw :: Either String _`; `Left err` → `T.pack err`. Tool result encoding `encode res` (was `Crucible.Json.encode`) → aeson: `jsonText res` (the `TE.decodeUtf8 . LB.toStrict . Data.Aeson.encode` helper).

- [ ] **Step 6: `Example`.** Tool fixtures: `toolSchema` becomes an aeson JSON-Schema `Value` literal, e.g. `object ["type" .= String "object", "properties" .= object ["city" .= object ["type" .= String "string"]], "required" .= toJSON [String "city"]]` — OR define an args type with `HasCodec` and use `schemaValue (codec @Args)`. Tool bodies that decoded args via `D.decodeValue (D.field "city" D.string)` → aeson: `parseMaybe (withObject "" (.: "city")) args`. `answerCodec`/`demoCodec` compile against the facade + new `decisionCodec`.

- [ ] **Step 7: commit (red build expected).**

```bash
git add -A
git commit -m "$(printf 'migrate(domain): Function/Decision/Tool/Eval/Agent/Example onto aeson+autodocodec\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 5: wire layer — `Chat`, `LLM.Anthropic`, `LLM.Anthropic.Stream`, cassettes

**Files:** Modify `src/Crucible/Chat.hs`, `src/Crucible/LLM/Anthropic.hs`, `src/Crucible/LLM/Anthropic/Stream.hs`.

This is the bulk of the wire rewrite — every hand-rolled `JObject`/`JString`/`D.field` becomes aeson. Mapping rules:

| crucible (delete) | aeson |
|---|---|
| `JObject [("k", v)]` | `object [ "k" .= v ]` (or `A.Object (KM.fromList [(K.fromText "k", v)])`) |
| `JString t` | `String t` |
| `JNumber n` (whole) | `Number (fromIntegral n)` |
| `JArray xs` | `Array (V.fromList xs)` or `toJSON xs` |
| `JBool b` / `JNull` | `Bool b` / `Null` |
| `D.field "k" d` (decode) | inside `withObject "_" $ \o -> o .: "k"` |
| `D.string`/`D.int`/`D.value` | `(.: "k")` with the field's `FromJSON`, or `o .: "k" :: Parser Value` |
| `encode v` (Value→Text) | `TE.decodeUtf8 (LB.toStrict (A.encode v))` |
| `parse t` (Text→Value) | `A.eitherDecode (LB.fromStrict (TE.encodeUtf8 t))` |

- [ ] **Step 1: `Chat`.** `import Data.Aeson (Value)` (drop `Crucible.Json.Value`, `Crucible.Schema`). `ToolUse`'s `tuArgs :: Value`; `Block`'s `ToolResultBlock ToolUseId Value`; `Converse :: [(ToolName, Value)] -> [ChatMsg] -> Chat m Turn` (schema as aeson JSON-Schema `Value`). `specs = [(toolName t, toolSchema t) | …]` — now `toolSchema :: Value`, compiles.

- [ ] **Step 2: `LLM.Anthropic` wire builders/parsers → aeson.** Rewrite `requestJson`, `chatRequestJson` (its `toolSpec n s = object ["name" .= String n, "input_schema" .= s]` where `s :: Value`), `chatMsgJson`, `blockJson`, `turnContentJson` using `object`/`.=`/`String`/`toJSON`. Rewrite `parseTurn`, `parseUsage`, `extractText` using aeson `withObject`/`.:`/`.:?`/`parseEither`. Example — `parseUsage`:

```haskell
parseUsage :: Text -> Usage
parseUsage t = either (const mempty) id $ do
  v <- A.eitherDecode (LB.fromStrict (TE.encodeUtf8 t))
  A.parseEither (A.withObject "resp" $ \o -> do
    u <- o .: "usage"
    Usage <$> u .: "input_tokens" <*> u .: "output_tokens") v
```

`parseTurn` returns `Either String Turn` now (was `Either D.Error Turn`); update its callers (`runChatAnthropic`/`converseOnce`/`runChatCassette`) to the `String` error. The cassette `turnContentJson`/`parseTurn` round-trip is preserved (Task 8 keystone test).

- [ ] **Step 3: `LLM.Anthropic.Stream`.** `parseEvent`/`classify` build/read aeson `Value` (the SSE `data:` payload parsed via `A.eitherDecode`; field reads via `withObject`/`.:`/`.:?`). `stepAcc`'s `EvToolJson` reassembly parses the accumulated partial-JSON to an aeson `Value` (`A.eitherDecode`, `Null` on failure). `StreamAcc`/`PartialTool` carry aeson `Value`. `splitFrames` is byte-level — **unchanged**.

- [ ] **Step 4: commit (red build expected).**

```bash
git add -A
git commit -m "$(printf 'migrate(wire): Chat/Anthropic/Stream/cassettes onto aeson\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 6: `app/Main.hs`

**Files:** Modify `app/Main.hs`.

- [ ] **Step 1:** `str`/`codec` imports stay (from the facade / `Autodocodec`). Tool fixtures: `Tl.Tool "get_weather" (schemaValue (codec @…))` or an aeson JSON-Schema `Value` literal; tool bodies return aeson `String "It is 26C and sunny."` (was `JString`). The `Sentiment` demo: `instance HasCodec Sentiment where codec = genericCodec` (was the empty instance). Build the exe target later (Task 8).

- [ ] **Step 2: commit (red build expected).**

```bash
git add app/Main.hs
git commit -m "$(printf 'migrate(app): Main demo onto aeson+autodocodec\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 7: `test/Spec.hs` literal rewrite

**Files:** Modify `test/Spec.hs` (and `test/Harness.hs` if it touches JSON — it does not).

Apply the Task-5 mapping table to all ~104 `J*` literals, preserving every assertion's meaning. Representative conversions:

```haskell
-- before:  JObject [("city", JString "Brisbane")]
-- after:   object [ "city" .= String "Brisbane" ]
-- before:  parse "{\"a\":1}"            -- :: Either String Value
-- after:   A.eitherDecode "{\"a\":1}"   -- :: Either String Value  (lazy ByteString literal via OverloadedStrings)
-- before:  Right (Turn "Hi" [])         (parseTurn …)   -- Either D.Error Turn
-- after:   Right (Turn "Hi" [])         (parseTurn …)   -- Either String Turn
```

Update imports: drop `Crucible.Json.*`, `Crucible.Schema`; import `Data.Aeson`, `Autodocodec`. Replace `schemaToJson (SObj …)` assertions with `schemaValue`-based assertions on the autodocodec JSON-Schema shape (the exact JSON-Schema object autodocodec emits for that codec — capture it by running the codec, then lock it in). Codec round-trip tests use `toJSONVia`/`parseJSONVia`.

- [ ] **Step 1: rewrite the literals + imports + schema assertions.**
- [ ] **Step 2: commit (red build still possible until Task 8).**

```bash
git add test/Spec.hs
git commit -m "$(printf 'migrate(test): rewrite JSON literals + assertions onto aeson+autodocodec\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 8: drive the build green + suite

**Files:** any — this is the convergence task.

- [ ] **Step 1: iterate to a clean build.** Run `nix develop . --command zinc build`; fix each compile error in turn (residual `Crucible.Json`/`Schema`/`Codec` references, `Either D.Error` → `Either String`, `Value` constructor mismatches, the `GProd` generic instance, ambiguous `Number`/`Scientific` literals). Repeat until exit 0. Expect several iterations.
- [ ] **Step 2: run the suite.** `nix develop . --command zinc test` → `1 test suite(s) passed`. Fix any failing assertion (most failures will be schema-shape assertions whose expected value must be set to what autodocodec emits — confirm the shape is a valid JSON Schema, then lock it).
- [ ] **Step 3: add the round-trip + schema test.** In `test/Spec.hs`, add: a `HasCodec` round-trip for a sample record (`parseJSONVia codec . toJSONVia codec == id`); and an assertion that `schemaValue (codec @SampleArgs)` is a JSON-Schema object (`"type" = "object"`, has `properties`). Re-run the suite green.
- [ ] **Step 4: commit.**

```bash
git add -A
git commit -m "$(printf 'migrate: build green + suite green on aeson+autodocodec; codec round-trip test\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 9: live smoke run

**Files:** none (verification).

- [ ] **Step 1: build the exe + run live.** `nix develop . --command zinc build` (exit 0), then run the binary with the key (do NOT echo it):

```bash
nix develop . --command bash -c 'set -a; . ./.env; set +a; BIN=$(find .zinc/build -type f -name crucible-anthropic | head -1); "$BIN"'
```

Expected: the full demo passes end-to-end on the new JSON stack — `typed fn:` a sentiment word, the tool agent answer, usage line, streaming lines, and **both** cassette `OK replay matches` lines. Paste the output. If the live call fails for an environment reason (no network/key), report DONE_WITH_CONCERNS (build + suite green, live unverified).

- [ ] **Step 2: final commit (if any verification fixups).** Otherwise nothing to commit — Task 8 already captured the code.

---

## Self-Review

**1. Spec coverage:**
- One JSON type (aeson), `Crucible.Json`/`Schema` deleted → Tasks 3, 5–8. ✅
- Domain codec = autodocodec `JSONCodec`; facade + retargeted generics → Tasks 1–2. ✅
- Adopt autodocodec `HasCodec`; `codec = genericCodec` → Task 2 (+ Main, tests). ✅
- Schema as pre-rendered aeson JSON-Schema `Value` on Tool/Chat (`schemaValue`); prompt text via `schemaText` → Tasks 1, 4, 5. ✅
- `autodocodec-schema` dep → Task 1. ✅
- Per-module map (SAP/Function/Tool/Chat/Anthropic/Stream/Decision/Agent/Example/Eval/Main/tests) → Tasks 3–7. ✅
- Green gate + live smoke run + round-trip/schema test → Tasks 8–9. ✅
- Non-goal (no manifest persistence link) respected. ✅

**2. Placeholder scan:** No TBD/TODO. The `GProd (:*:)` instance is the one place needing implementer iteration to typecheck (Task 2 Step 2 gives the concrete pattern + the verification); this is flagged honestly, not a hidden placeholder. The bulk literal rewrite (Task 7) is given as a mapping table + representative examples — appropriate for a mechanical transform of ~104 sites.

**3. Type consistency:** `JSONCodec` replaces `Codec` consistently; `decodeLLM :: JSONCodec a -> Text -> Either String a` and every caller switched to `String` errors (Tasks 3–5); `parseTurn :: Text -> Either String Turn`; `toolSchema :: Value`, `Converse :: [(ToolName, Value)]`, `tuArgs :: Value` all aeson; facade names (`str`/`object`/`field`/`enum`/`anyValue`/`schemaValue`/`schemaText`) used identically across Tasks 1, 4, 5, 7. ✅
