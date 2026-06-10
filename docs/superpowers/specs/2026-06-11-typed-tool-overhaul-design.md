# Typed Tool Overhaul — Design Spec

**Date:** 2026-06-11
**Status:** Approved design, pending implementation
**Scope:** `Crucible.Tool` (rewrite), new `Crucible.Tool.Generic`, `Crucible.Chat` loop integration, `Crucible.Agent` text path, call sites (`app/Main.hs`, `test/Spec.hs`), manual (`docs/tool-calling.md`, `docs/effects.md`).

## Motivation

The current toolbox entry erases both ends of every tool to `Value`:

```haskell
data Tool es = Tool
  { name   :: ToolName
  , schema :: Value
  , run    :: Value -> Eff es Value
  }
```

Three problems:

1. Both ends are untyped. The type-driven `tool` constructor (added in the DevEx
   overhaul) decodes the input, but the output is still a hand-built `Value`
   with no codec discipline.
2. Decode failures travel through the success channel as
   `A.String "bad tool args: ..."`, a stringly convention each tool must
   remember, instead of a policy the loop states once.
3. The erasure happens in user code: raw tools hand-roll
   `parseMaybe (withObject ...)` per tool.

`Value` cannot disappear entirely: a toolbox is heterogeneous (`[Tool es]`)
and the wire is JSON for every provider. The fix is to move the erasure
inside the library behind an existential that carries its codecs, and derive
whole toolboxes from records of plain functions so the user-facing code is
nothing but the handlers.

On profunctors (explored during design): the handler `i -> Eff es o` is
already a profunctor (`Star (Eff es)`), so `dimap` on handlers is free before
construction. A lawful `Profunctor` instance on the codec-carrying record is
impossible: codecs are invariant (both directions needed, as in autodocodec's
`dimapCodec to from`), and one-directional functions cannot rebuild a JSON
schema. The library therefore exposes no `Profunctor` instance and documents
why.

## Design

### 1. Core: `Crucible.Tool`

```haskell
data Tool es where
  Tool ::
    { name   :: ToolName
    , schema :: Value          -- input JSON Schema as advertised on the wire
    , input  :: JSONCodec i
    , output :: JSONCodec o
    , run    :: i -> Eff es o
    } -> Tool es
```

- `name` and `schema` do not mention the existential variables, so record-dot
  projection (`t.name`, `t.schema`) keeps working; `input`/`output`/`run` are
  reachable only by pattern matching, and `invoke` is their only consumer.
- The raw form is a special case, not the foundation:
  `rawTool n sch = Tool n sch anyValue anyValue` (`anyValue :: JSONCodec Value`).

Constructors, happy path first:

```haskell
-- name as a type-level Symbol; schema derived from the input codec
tool :: forall name i o es. (KnownSymbol name, HasCodec i, HasCodec o)
     => (i -> Eff es o) -> Tool es
-- usage: tool @"get_weather" $ \(Loc city) -> pure (Sky ("sunny in " <> city))

-- explicit codecs, term-level name (irregular names, no-typeclass types)
toolWith :: ToolName -> JSONCodec i -> JSONCodec o -> (i -> Eff es o) -> Tool es

-- escape hatch: hand-written schema, Value in and out (today's shape)
rawTool :: ToolName -> Value -> (Value -> Eff es Value) -> Tool es
```

`tool` derives `schema` via `schemaValue (codec @i)`.

Structured errors and single-point dispatch:

```haskell
data ToolError
  = UnknownTool ToolName [ToolName]         -- requested, available
  | BadArgs     ToolName DecodeError Value  -- tool, decode failure, its schema
  deriving (Eq, Show)

invoke :: Tool es -> Value -> Eff es (Either ToolError Value)
renderToolError :: ToolError -> Text
```

- `invoke (Tool n _ inC outC f) v`: decode `v` through `inC`
  (failure: `Left (BadArgs n (DecodeError msg raw) schema)` where `raw` is the
  offending args rendered as JSON text); on success run `f` and encode the
  result through `outC` with `toJSONVia` (total; the result half of the
  boundary has no failure path).
- `renderToolError` is the model-facing feedback, stated once: the error, the
  expected schema (compact JSON), and the args echoed back. Example:

  ```
  tool issue_refund: arguments did not decode: key "amountCents" not found
  expected schema: {"type":"object","properties":{...},"required":[...]}
  you sent: {"orderId":"1234","amount":5900}
  ```

  For `UnknownTool`: the unknown name plus the available names.
- Handler exceptions are NOT caught; they propagate as today. The loop's
  error policy covers wire-boundary failures only.

The `Tools` effect upgrades to the same error type:

```haskell
data Tools :: Effect where
  CallTool :: ToolName -> Value -> Tools m (Either ToolError Value)
```

`runTools` dispatches via `invoke` and produces `UnknownTool` with the
available names. `ToolCall`, `toolCallCodec`, `toolsHelp`, `anyValue` are
unchanged (toolsHelp still renders `t.name` + `t.schema`).

### 2. Record derivation: `Crucible.Tool.Generic`

A toolbox is declared as a single-constructor record whose field names are
the tool names and whose field types are the contracts; the value is nothing
but the handlers:

```haskell
data SupportTools es = SupportTools
  { get_weather  :: Loc        -> Eff es Sky
  , lookup_order :: OrderQuery -> Eff es Order
  , current_time :: Eff es TimeResult          -- zero-arg form
  } deriving (Generic)

tools :: (Generic t, GTools (Rep t) es) => t -> [Tool es]
```

`GTools` walks the `Rep` (same technique as `Crucible.Codec.Generic`'s
`genericCodec`, which already harvests `'MetaSel` Symbols):

- Field `i -> Eff es o` with `HasCodec i, HasCodec o`: one `Tool`; name from
  the selector Symbol, schema `schemaValue (codec @i)`.
- Field `Eff es o` with `HasCodec o` (zero-arg tool): one `Tool` whose input
  codec is a private `unitCodec :: JSONCodec ()` (an empty object codec,
  schema `{"type":"object","properties":{}}`). Decoding `()` accepts ANY
  object the model sends (including invented keys); a zero-arg tool must not
  fail on enthusiastic argument guessing.
- Tool order = field order (deterministic advertised list and `toolsHelp`).

Failure shapes get `TypeError` instances naming the field:

| Shape | Message (sketch) |
|---|---|
| Non-handler field (e.g. `Int`) | `Toolbox field "retries" is not a tool handler. Expected i -> Eff es o or Eff es o, got Int` |
| Sum type | `A toolbox must be a single-constructor record` |
| Positional fields | `Toolbox fields must be named; the field name becomes the tool name` |
| Mismatched effect row | no custom instance; GHC's unification error already names the field |

Deliberate limits (documented, not worked around):

- Tool names are restricted to legal Haskell field names (snake_case is
  idiomatic for both providers). Irregular names use `toolWith`/`rawTool`.
- A missing `HasCodec` is a standard GHC instance error (it names the type;
  per-field interception is not possible).
- `tools a ++ tools b` keeps plain list semantics: duplicates are impossible
  within one record, possible across concatenations (first match wins in
  dispatch, as today). No checked merge in this cycle.

### 3. Loop integration

- `Chat.runToolAgentN`: replace the inline `filter`/`t.run u.args` dispatch
  with lookup + `invoke`; render `Left` via `renderToolError` into the
  `ToolResultBlock` (same self-correction loop, richer feedback). Unknown
  tool: `renderToolError (UnknownTool n available)`. The advertised specs
  list stays `[(t.name, t.schema) | t <- tools]`.
- `Agent.runAgent` (text path): the upgraded `CallTool` result renders
  through the same `renderToolError`.
- Provider modules (`Crucible.LLM.Anthropic`, `Crucible.LLM.OpenAI`, both
  Stream modules) change NOT AT ALL: the wire sees the same
  `tool_use`/`tool_result` blocks.

### 4. Migration (clean break, one branch)

No deprecation shims. All call sites migrate in the same branch:

- `test/Spec.hs`: raw fixtures (`weatherToolC`, `agentTools`) become
  `rawTool` one-liners or typed `tool @"..."` forms; the existing type-driven
  `tool` tests move to the Symbol form with a typed output.
- `app/Main.hs`: the three weather tool copies collapse to one
  `tool @"get_weather"` with a typed result, used by both providers' demos.
- `docs/tool-calling.md`: rewritten around the record toolbox (record first,
  `tool @"name"` second, `rawTool` as escape hatch); error-feedback section
  shows a real `renderToolError` message. `docs/effects.md`: `Tools` row
  updated. House style: no emdashes, no hype, no manifest mentions.

### 5. Testing

- All existing tool-loop tests keep their expected results (happy path is
  behaviour-preserving).
- New tests: `invoke` happy path (typed both ends); `BadArgs` carries the
  schema and the raw args; `UnknownTool` carries available names;
  `renderToolError` includes schema + echo; `tools` on a record fixture
  (names, order, zero-arg accepts `{}` and invented keys); `rawTool`
  equivalence with the old behaviour; loop-level: bad args fed back then
  model self-corrects (scripted), unknown tool fed back (scripted).
- Negative compile tests (the `TypeError` instances) are not runnable under
  zinc's test setup; the spec accepts this and the messages are exercised
  manually during development. Positive-path coverage stands in.
- Live smoke via the demo binary under both providers before merge.

### 6. Non-goals

- No `description` field on tools (touches both providers' request builders;
  follow-up issue).
- No checked cross-record toolbox merge.
- No `Profunctor` instance (impossible with codecs; documented).
- No change to the `Emit`/streaming layer or cassette formats.

## Error story summary

| Failure | Today | After |
|---|---|---|
| Non-handler field in toolbox | n/a (no toolbox type) | custom `TypeError` naming the field |
| Wrong handler type | error inside a list expression | field-level GHC error with domain names |
| Duplicate tool name | silent first-match dispatch | impossible within a record |
| Incomplete test stub | runtime "unknown tool" | missing-field compile error |
| Model sends bad args | per-tool `"bad tool args"` string in success channel | `BadArgs` with schema + raw echo, rendered once by loop policy |
| Unknown tool | `"unknown tool: X"` | `UnknownTool` with available names |
| Bad result shape | possible (hand-built `Value`) | unrepresentable (output codec) |
| Missing `HasCodec` | generic instance error | same (names the type) |
