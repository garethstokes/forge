# Crucible — Design Spec (v2)

**Date:** 2026-06-05
**Status:** Approved design, in implementation
**Author:** Gareth (with Claude)

> v2 supersedes v1. v1 leaned on `aeson` + GHC-Generics `HasSchema`. M0 proved aeson is not
> viable under zinc's no-solver model (~20 transitive deps, lock never closed, 1hr+ build —
> see branch `spike/aeson-cascade-abandoned`). v2 pivots to a hand-rolled, zero-non-boot-dep
> JSON layer and an Elm-style bidirectional `Codec`.

## 1. Purpose

Crucible is an **exploration / learning vehicle**: an embedded Haskell eDSL for harnessing
prompts + tool calls, inspired by **BAML** (prompts as typed functions, schema-aligned parsing,
test blocks) and **12-factor-agents** (own your prompts/context, tools as structured outputs,
stateless control flow). Goal: **insight over polish**.

Built with **zinc** (git-native, Nix-assisted, no-solver). Lives at `~/code/garethstokes/crucible`.
GHC 9.6.5 via `nix develop`.

## 2. Hard constraint that shaped everything: dependencies

zinc has **no dependency solver** — every transitive dep is a manually git-pinned repo. M0
established that pulling `aeson`/`http-client` is unworkable. Therefore:

- **Zero non-boot dependencies** for the whole core. Only GHC boot libs (`base`, `text`,
  `bytestring`) — no `aeson`, `containers`-Map (use assoc lists), `vector`, etc.
- JSON is **hand-rolled**.
- HTTP (needed only at M8 for the Anthropic interpreter) is deferred; decided then (likely
  shell out to `curl`, or a minimal client).

## 3. The three agent patterns, unified (unchanged from v1)

Everything the model emits is a typed structured output. A tool call and a final answer are the
same kind of thing:

```haskell
data Decision tool answer = CallTool tool | Done answer
```

Prompt-as-typed-function produces a `Decision`; a pure reducer consumes it; tool dispatch executes
a `CallTool`. Pure core in the middle; effects (provider HTTP, tool IO) only at interpreter edges.

## 4. Architectural decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Delivery | Embedded eDSL, no codegen | Lean into the type system |
| Effect substrate | **effectful** | Agent's *type is a capability manifest*; least-privilege tools compiler-enforced |
| JSON | **Hand-rolled, zero-dep** | aeson unviable under zinc; bespoke fits an exploration vehicle |
| Decoder style | **Elm-style decoders-as-values** | No per-type typeclass for parsing; `Functor/Applicative/Monad` on `Decoder` = Elm `map/map2/andThen` |
| Type↔JSON | **Bidirectional `Codec a`** (schema + decode + encode) | One definition round-trips; encoder bundled (no standalone `Encoder` type) |
| Derivation | **`HasCodec` + `genericCodec`, from the start** | Optional Generics layer producing the same `Codec a`; derive leaves, hand-write orchestration |
| Provider | Anthropic + scripted + recording interpreters | One real backend; provider-agnosticism deferred |
| Tests | Dependency-light in-repo harness | Avoid zinc dep-wrangling over tasty/hspec |

### Note on "no crazy typeclasses"
Two distinct uses of typeclasses; we keep one and bound the other:
- **Kept (standard):** `Functor/Applicative/Monad` on `Decoder`, `Functor/Applicative` on the
  `ObjectCodec` builder. Ordinary instances; they ARE Elm's `map`/`map2`.
- **Bounded (opt-in):** `HasCodec a` (one method, the canonical codec) + the `GCodec (Rep a)`
  Generics machinery. Required for type-directed derivation (Generics dispatches on types, so
  resolving a nested field's codec is a typeclass lookup). Lives in its own module
  `Crucible.Codec.Generic`; the core never depends on it.

## 5. The JSON layer (`Crucible.Json.*`, zero non-boot deps)

```haskell
-- Value
data Value = JNull | JBool Bool | JNumber Double | JString Text
           | JArray [Value] | JObject [(Text, Value)]   -- assoc list: ordered, no containers
  deriving (Eq, Show)

-- Parse: hand-rolled recursive-descent parser combinator (own Parser newtype, no megaparsec)
parse :: Text -> Either String Value

-- Encode: Value builders + serializer (Elm Json.Encode style — no Encoder type)
jstring :: Text -> Value;  jint :: Int -> Value;  jbool :: Bool -> Value
jobject :: [(Text, Value)] -> Value;  jarray :: [Value] -> Value
encode :: Value -> Text;  encodePretty :: Int -> Value -> Text

-- Decode: Elm-style decoders as values
newtype Decoder a = Decoder { runD :: Value -> Either Error a }
data Error = Error { crumbs :: [Crumb], message :: String }
data Crumb = AtField Text | AtIndex Int
-- instances: Functor, Applicative (both decoders see the same Value), Monad (= andThen)
-- primitives: string int bool float null value
-- combinators: field at index list nullable oneOf succeed fail andThen
-- run: decodeValue, decodeString (parse then runD)
```

## 6. The `Codec` layer (`Crucible.Codec`)

Bidirectional: one value carries schema (for the prompt), decoder, and encoder.

```haskell
data Codec a = Codec { codecSchema :: Schema, codecDecode :: Decoder a, codecEncode :: a -> Value }

-- Object builder is parameterised by BOTH the type it encodes-from (o) and decodes-to (a);
-- they unify when the object is closed. Decoding is covariant (Applicative); encoding is
-- contravariant in o (monoidal concat of field-pairs) — which is why `field` takes a getter.
data ObjectCodec o a = ObjectCodec { ocFields :: [(Text, Schema)], ocDecode :: Decoder a, ocEncode :: o -> [(Text, Value)] }
instance Functor (ObjectCodec o)
instance Applicative (ObjectCodec o)   -- (++) fields, (<*>) decoders, (\o -> e1 o ++ e2 o) encoders

field    :: Text -> (o -> f) -> Codec f -> ObjectCodec o f
object   :: ObjectCodec a a -> Codec a
str int bool float :: Codec _
list' :: Codec a -> Codec [a];  nullable' :: Codec a -> Codec (Maybe a)
enum :: Eq a => [(Text, a)] -> Codec a
-- sums: a Variant carries (schema, decoder, a -> Maybe Value); oneOfC assembles them
data Variant a = Variant Schema (Decoder a) (a -> Maybe Value)
oneOfC :: [Variant a] -> Codec a
```

Records are clean (getters); sums pay a per-variant encode-matcher tax. Example:

```haskell
data Forecast = Forecast { city :: Text, tempC :: Double, rainy :: Bool }
forecastCodec = object $ Forecast <$> field "city" city str <*> field "tempC" tempC float <*> field "rainy" rainy bool
-- codecSchema → for the prompt; codecDecode → parse reply; codecEncode → few-shot / round-trip
```

### Schema (`Crucible.Schema`)
```haskell
data Schema = SObj [(Text, Schema)] | SArr Schema | SEnum [Text] | SOneOf [Schema]
            | SStr | SNum | SBool | SOpt Schema
renderSchema :: Schema -> Text   -- compact annotated example injected into prompts
```

### Derive (`Crucible.Codec.Generic`, opt-in)
```haskell
class HasCodec a where codec :: Codec a
instance HasCodec Text;  instance HasCodec Int;  instance HasCodec Bool;  instance HasCodec Double
instance HasCodec a => HasCodec [a];  instance HasCodec a => HasCodec (Maybe a)
genericCodec :: (Generic a, GCodec (Rep a)) => Codec a   -- derives schema+decode+encode together
-- Generics supplies field projections for free → no getters in derived codecs.
```

Derive leaves (`instance HasCodec Forecast where codec = genericCodec`); hand-write orchestration
(`Decision`, tool unions, lenient SAP). Both are the same `Codec a` and compose.

## 7. SAP (schema-aligned parsing) — typeclass-free

`decodeLLM codec = decodeString (codecDecode codec) . stripToJson`, where `stripToJson` removes
` ```json ` fences and surrounding prose. Leniency (oneOf/nullable/coercions) lives in the codecs.
No machinery.

## 8. The agent layer (unchanged from v1, now on `Codec` + `effectful`)

`Decision` codec built via `oneOfC` over tool codecs + answer codec. Pure
`reduce :: AgentState -> Decision ToolCall answer -> Step answer`. Control loop
`runAgent :: (LLM :> es, Tools :> es) => …` whose **type is the capability manifest**. LLM
interpreters: `runLLMAnthropic`, `runLLMScripted`, `recordLLM` (cassettes). Tool effect with
per-tool effect rows (authority creep = compile error). See §3–5 of v1 history; semantics intact.

## 9. Tests vs evals (unchanged)

- **Tests** = deterministic (scripted/cassette interpreters); failure = code broke.
- **Evals** = quality over a dataset, sampled, scored (live or cassette); regression = quality dropped.
- Cassettes (`recordLLM`) are the slider between them.
- In-repo dependency-light harness (`check`/`runChecks`); golden tests for parser/codec via
  expected-value equality (true golden *files* for messy SAP fixtures).

## 10. Build order

| # | Milestone |
|---|---|
| M0 | Scaffold + zero-dep test loop green (cascade reverted) |
| M1 | `Json.Value` + hand-rolled `Json.Parse` + golden tests |
| M2 | `Json.Encode` + `Json.Decode` (Elm-style) + tests |
| M3 | `Schema` + `renderSchema` + explicit `Codec`/`ObjectCodec` + round-trip tests |
| M4 | `Codec.Generic` (`HasCodec` + `genericCodec`) + derive round-trip tests |
| M5 | SAP layer (`stripToJson`, `decodeLLM`) + lenient codecs + messy-input golden tests |
| M6 | `Decision` + pure `reduce` + tests |
| M7 | `LLM` effect + scripted interpreter; loop on canned replies |
| M8 | Anthropic interpreter + `recordLLM` cassettes (HTTP approach decided here) |
| M9 | `Tools` effect + capability typing + one example agent |
| M10 | Eval harness (datasets, scorers, report, cassette replay) |

## 11. Risks

- **HTTP at M8** is the next unresolved dep risk (http-client cascades like aeson). Mitigation:
  shell out to `curl`, or a minimal hand-rolled client over `network`. Decided at M8, off the
  critical path until then.
- **Generics machinery** (`GCodec`) adds the only real type-level complexity; bounded to one
  opt-in module so it can't destabilise the core.
- **Hand-rolled parser correctness** (string escapes, unicode `\uXXXX`, number grammar) — covered
  by golden tests in M1.
