# Crucible: migrate to aeson + autodocodec (single all-at-once)

**Goal.** Replace crucible's hand-rolled JSON (`Crucible.Json.*`) and codec/schema
layer (`Crucible.Codec`, `Crucible.Schema`, `Crucible.Codec.Generic`) with
**aeson** (`Data.Aeson.Value` as the one JSON type) and **autodocodec** (codec +
JSON Schema), in one coordinated change. This is SP3 of the manifest-interop epic
(`crucible-f0a`), folding in SP4 (wire migration) — `Crucible.Json` is deleted.

**Why.** Manifest persists any type with an autodocodec `HasCodec` instance as a
`jsonb` column. `Crucible.Codec` is a hand-rolled reimplementation of autodocodec
(codec = encode + decode + schema). Converging onto autodocodec makes crucible's
domain types both prompt/tool-schema sources *and* manifest-persistable, and
gives general aeson ecosystem interop. GHC is already aligned (9.10.1, SP1) and
aeson + autodocodec are already available (SP2).

**Scope decision (settled in brainstorming).** Full, single-pass migration — one
`Value` type, `Crucible.Json` deleted, no temporary bridge. The user accepted the
green-build cost (an atomic type swap builds green only at the end).

## Design decisions

1. **One JSON type: `Data.Aeson.Value`.** `Crucible.Json.{Value,Parse,Encode,
   Decode}` are deleted; every site uses aeson.
2. **Domain codec = autodocodec `JSONCodec`.** `Crucible.Codec`/`Crucible.Schema`
   are removed; codecs become `Autodocodec.JSONCodec`, schemas come from
   `autodocodec-schema`.
3. **Adopt autodocodec's `HasCodec`.** Crucible re-exports `Autodocodec.HasCodec`
   (resolving the name collision with crucible's old class). `Crucible.Codec.Generic`
   keeps GHC.Generics derivation but **retargeted to emit a `JSONCodec`**, used as
   `instance HasCodec T where codec = genericCodec` (the current empty instance
   becomes a one-liner). Because it is autodocodec's class, such types are
   directly manifest-persistable.
4. **Schema carried as a pre-rendered aeson JSON-Schema `Value`.** `Tool` and the
   `Chat` `Converse` op carry the tool `input_schema` as an aeson `Value`
   (`toJSON (jsonSchemaViaCodec @a)`), not an autodocodec `JSONSchema` — simplest
   at the wire.
5. **Prompt schema text via autodocodec-schema's renderer.** Accepted observable
   change: the schema text injected into `llmFn` prompts will be formatted by
   autodocodec-schema rather than the old `renderSchema`.
6. **New dependency: `autodocodec-schema`** (NorfairKing, plain Haskell). aeson +
   autodocodec landed in SP2; this adds the schema renderer (a small fresh build —
   manifest doesn't render schemas, so it isn't pre-cached).

## Codec / schema mapping

| crucible (now) | autodocodec (target) |
|---|---|
| `Codec a { codecSchema, codecDecode, codecEncode }` | `JSONCodec a` (carries schema + `ToJSON` + `FromJSON`) |
| `str` / `int` / `bool` / `float` | `textCodec` / integer codec / `boolCodec` / scientific codec |
| `object` / `field` (`ObjectCodec`) | `object` / `requiredField` / `.=` (autodocodec `ObjectCodec`, applicative) |
| `enum [(Text,a)]` | `stringConstCodec` |
| `oneOfC` / `Variant` | autodocodec disjoint-union combinators |
| `codecSchema :: Schema` | `jsonSchemaViaCodec` / `jsonSchemaVia codec` |
| `renderSchema :: Schema -> Text` (prompt) | autodocodec-schema text renderer |
| `schemaToJson :: Schema -> Value` (tool input_schema) | `toJSON (jsonSchemaViaCodec @a)` → aeson `Value` |

Codec *values* (not `HasCodec` constraints) are still passed where the current
API passes them (e.g. `fnInput`/`fnOutput`), using autodocodec's
`toJSONVia` / `parseJSONVia` / `eitherDecodeJSONVia codec`.

## Per-module migration map

- **Delete:** `src/Crucible/Json/{Value,Parse,Encode,Decode}.hs`, `src/Crucible/
  Codec.hs`, `src/Crucible/Schema.hs`. Replace `src/Crucible/Codec/Generic.hs`
  with the retargeted generic `JSONCodec` derivation (re-exporting
  `Autodocodec.HasCodec`).
- **`Crucible.SAP`:** `decodeLLM :: JSONCodec a -> Text -> Either String a` =
  `eitherDecodeJSONVia codec . encodeToLazyText`-equiv over `stripToJson` output.
  `stripToJson :: Text -> Text` is kept verbatim (it operates on text).
- **`Crucible.Function`:** `fnInput :: JSONCodec i`, `fnOutput :: JSONCodec o`;
  `fnPrompt` injects the schema (text renderer over `fnOutput`) and encodes the
  input via `toJSONVia (fnInput fn)` → aeson `encode`. `call` decodes via
  `decodeLLM`.
- **`Crucible.Tool`:** `toolSchema :: Value` (aeson JSON-Schema), `tcArgs ::
  Value` (aeson), `toolRun :: Value -> Eff es Value`. `toolCallCodec`/`anyValue`
  → autodocodec (`anyValue` = `valueCodec`/`JSONCodec Value`).
- **`Crucible.Chat`:** `Converse :: [(ToolName, Value)] -> [ChatMsg] -> Chat m
  Turn` (schema as aeson JSON-Schema `Value`); `Block`'s `tuArgs :: Value`
  (aeson); the `ToolResultBlock` `Value` is aeson.
- **`Crucible.LLM.Anthropic`:** every wire builder/parser → aeson — `requestJson`,
  `chatRequestJson`, `parseTurn`, `parseUsage`, `blockJson`, `extractText`,
  `turnContentJson`, the cassette encode/decode — using aeson `Object`
  (`Data.Aeson.KeyMap`), `.=`, `object`, `withObject`, `.:`, `.:?`.
- **`Crucible.LLM.Anthropic.Stream`:** `parseEvent`/`classify`/`stepAcc` build and
  read aeson `Value`s (the `input_json_delta` reassembly parses to aeson `Value`);
  `splitFrames` is unchanged (byte-level). `tuArgs`/`StreamAcc` carry aeson.
- **`Crucible.Decision`:** `decisionCodec` → autodocodec `JSONCodec`.
- **`Crucible.Agent` / `Crucible.Example` / `Crucible.Eval`:** codecs/tools/JSON
  updated to aeson + autodocodec.
- **`app/Main.hs`:** `str`/`codec`/`JString` etc. → autodocodec/aeson equivalents.
- **`test/Spec.hs` + `test/Harness.hs`:** every `Crucible.Json.Value` literal
  (`JObject`/`JString`/`JNumber`/`JArray`/`JBool`/`JNull`) rewritten to aeson
  (`object [...]` / `String` / `Number` / `Array` / `Bool` / `Null`). This is the
  bulk of the diff. Assertions stay semantically identical.

## Implementation strategy (the green-build reality)

The `Value` type is atomic — `Crucible.Codec` is built on `Crucible.Json`, and that
type flows through every JSON site. The build is **red mid-migration** and green
only when every site is converted. So this plan deviates from strict
per-task-green TDD: it is one coordinated branch whose tasks are grouped by layer —

1. **Foundation:** add `autodocodec-schema`; the retargeted `Crucible.Codec.Generic`
   (generic `JSONCodec` + `HasCodec` re-export); helper for `schemaToJson`-equiv
   (`jsonSchemaViaCodec` → `Value`) and the prompt text renderer.
2. **Domain consumers:** `SAP`, `Function`, `Tool`, `Decision`.
3. **Wire:** `Chat`, `Anthropic`, `Stream`, cassettes.
4. **Edges:** `Agent`/`Example`/`Eval`, `Main`, then the test suite.
5. **Delete** `Crucible.Json.*`, `Crucible.Codec`, `Crucible.Schema`.

**Green-build is the milestone gate at the end of conversion** (`nix develop .
--command zinc build` exit 0), then `zinc test`, then a **live smoke run** of the
whole path. Compile-error fixup is driven iteratively with `zinc build`.

## Testing

- **Re-point** every existing pure test to aeson literals, preserving assertions:
  schema generation (was `schemaToJson`), `parseTurn` round-trips, the SSE
  keystone, the chat/LLM cassettes, codec round-trips, `llmFn` flows,
  `turnContentJson`.
- **Add:** an autodocodec round-trip (`toJSONViaCodec`→`eitherDecodeJSONViaCodec`)
  for a sample domain type; an assertion that `jsonSchemaViaCodec @Args` renders a
  JSON-Schema object (`{"type":"object",…}`) that the tool `input_schema` path
  emits (Anthropic-acceptable).
- **Live smoke run** (`crucible-anthropic`) must pass end-to-end: typed-fn, tool
  agent, usage, streaming, both cassettes — proving the rebuilt JSON path works on
  the wire.

## Non-goals

- **Not** building the manifest persistence link (SP5). SP3 only makes crucible's
  types autodocodec-`HasCodec` (manifest-*ready*), not actually persisted.
- No effect/agent semantic changes; behaviour preserved except the
  intentionally-reformatted prompt schema text.

## Risks

- Largest change in the repo's history; the SSE `parseEvent`/`stepAcc` and the
  cassettes are subtle and must round-trip exactly on aeson.
- The test suite is heavily JSON-literal-based — a large, mechanical but
  error-prone rewrite. Mitigated by keeping assertions semantically identical.
- `genericCodec` retargeting must reproduce the current field/enum schema shape
  closely enough that tool `input_schema` and decoding stay correct.

## Self-review

- **Placeholders:** none.
- **Consistency:** one `Value` (aeson) everywhere; `HasCodec` is autodocodec's,
  with `genericCodec` as the derivation helper; schema carried as aeson
  JSON-Schema `Value` on `Tool`/`Chat`; codec *values* flow via `…Via codec`.
- **Scope:** single all-at-once migration (user-chosen) — large but one coherent
  transformation; sequenced by layer with an end-of-conversion green gate.
- **Ambiguity:** the schema-text reformatting is called out as the one accepted
  observable change; everything else is behaviour-preserving.
- **Dependency risk:** one new dep (`autodocodec-schema`); same toolchain/registry
  as autodocodec, low risk.
