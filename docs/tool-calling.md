---
title: Tool calling
nav_order: 5
---

# Tool calling

crucible's native tool-calling lets the model drive a loop: you advertise a set
of `Tool` values, ask a question, and the model issues calls, receives results,
and keeps going until it produces a text answer. You write the tool functions in
Haskell; the loop bookkeeping (serialising calls, running handlers, feeding
results back) is handled by `runToolAgent`.

## Constructing tools

### The record toolbox (recommended)

The most concise way to build a set of tools is a record type whose field names
become tool names and whose field types are the handler contracts. Derive
`Generic` and pass the value to `tools`:

```haskell
{-# LANGUAGE DeriveGeneric #-}

import GHC.Generics (Generic)
import Effectful (Eff)
import Crucible.Codec.Generic (HasCodec (codec), genericCodec)
import Crucible.Tool.Generic (tools)
import Crucible.Chat (runToolAgent)

data Loc = Loc { locCity :: Text } deriving (Show, Generic)
instance HasCodec Loc where codec = genericCodec

data Sky = Sky { forecast :: Text } deriving (Show, Generic)
instance HasCodec Sky where codec = genericCodec

data SupportTools es = SupportTools
  { get_weather  :: Loc -> Eff es Sky
  , current_time :: Eff es TimeResult  -- zero-arg form
  } deriving (Generic)

supportTools :: SupportTools es
supportTools = SupportTools
  { get_weather  = \(Loc city) -> pure (Sky ("sunny in " <> city))
  , current_time = pure (TimeResult "noon")
  }

agent = runToolAgent (tools supportTools)
```

`tools` has type:

```haskell
tools :: forall f es. (Generic (f es), GTools (Rep (f es)) es) => f es -> [Tool es]
```

The toolbox type must be parameterised by the effect row `es` (for example
`data MyTools es = ...`). The `es` in the argument and the `es` in the returned
list are the same, so GHC can always infer the concrete row from context.

Each record field is turned into one `Tool`:

- A field of type `i -> Eff es o` (where `i` and `o` both have `HasCodec`)
  becomes a tool whose name is the field name, whose input schema is derived
  from `codec @i`, and whose output is encoded through `codec @o`.
- A field of type `Eff es o` (zero-arg) becomes a tool with an empty-object
  input schema. The handler accepts any object the model sends, including extra
  keys, and ignores the args entirely.

The record form carries several compile-time guarantees:

- **Name uniqueness.** Haskell's field uniqueness rule makes duplicate tool
  names in one record impossible. Combine two records with `tools a ++ tools b`;
  first match wins in dispatch.
- **Total stubs.** A test value must implement every field. The compiler
  rejects a partial record literal.
- **TypeError on non-handler fields.** A field whose type is neither
  `i -> Eff es o` nor `Eff es o` triggers a compile-time `TypeError` naming
  the offending field and showing the expected shape.
- **Names are legal field names.** The tool name is taken from the record field
  name at compile time via `GHC.TypeLits.symbolVal`. For tool names that are
  not legal Haskell identifiers (for example `"refund/v2"`), use `toolWith` or
  `rawTool` instead.

### Single tool via `tool @"name"` (type-level name)

For a standalone tool, `tool @"name"` derives both the input schema and the
output codec from `HasCodec`:

```haskell
import Crucible.Tool (tool)
import GHC.TypeLits ()  -- for the TypeApplication syntax

weather :: Tool es
weather = tool @"get_weather" (\(Loc city) -> pure (Sky ("sunny in " <> city)))
```

The name is a GHC `Symbol` supplied via `TypeApplications`. The schema is
derived from `codec @Loc` and the result encoded through `codec @Sky`. The full
signature is:

```haskell
tool :: forall name i o es. (KnownSymbol name, HasCodec i, HasCodec o)
     => (i -> Eff es o) -> Tool es
```

### `toolWith` (explicit codecs)

When the handler argument or result type does not have a `HasCodec` instance,
or when you want an irregular tool name, use `toolWith`:

```haskell
toolWith :: ToolName -> JSONCodec i -> JSONCodec o -> (i -> Eff es o) -> Tool es
```

The schema is derived from the input codec via `schemaValue`. Example with an
ad-hoc object codec:

```haskell
import Crucible.Codec (object, field, str)
import Crucible.Tool (toolWith)

cityCodec :: JSONCodec Text
cityCodec = object (field "city" id str)

weather :: Tool es
weather = toolWith "get_weather" cityCodec str
  (\city -> pure ("sunny in " <> city))
```

### `rawTool` (escape hatch)

`rawTool` accepts a hand-written JSON Schema and a handler that works directly
with `Value`. Use it when the schema cannot be derived from a codec, for
example when the model produces heterogeneous output:

```haskell
rawTool :: ToolName -> Value -> (Value -> Eff es Value) -> Tool es
```

```haskell
import qualified Data.Aeson as A
import Crucible.Tool (rawTool)

weatherSchema :: Value
weatherSchema = A.object
  [ "type"       A..= A.String "object"
  , "properties" A..= A.object
      [ "city" A..= A.object ["type" A..= A.String "string"] ]
  , "required"   A..= A.toJSON [A.String "city"]
  ]

weatherTool :: Tool es
weatherTool = rawTool "get_weather" weatherSchema
  (\_ -> pure (A.String "It is 26C and sunny."))
```

`rawTool n sch` is equivalent to `Tool n sch anyValue anyValue`: the input and
output codecs are both the identity `anyValue` codec, so there is no decode
step on the way in and no encode step on the way out.

## Error feedback

`invoke` is the single point where JSON crosses the boundary. It decodes the
model's args through the input codec; on failure it returns
`Left (BadArgs name decodeError schema)`. On success it runs the handler and
encodes the result through the output codec (this step is total: the output
codec cannot produce a malformed result).

The loop renders a `BadArgs` or `UnknownTool` failure via `renderToolError` and
feeds the result back to the model as a `tool_result` content block:

```
tool issue_refund: arguments did not decode: key "amountCents" not found
expected schema: {"type":"object","properties":{"amountCents":{"type":"integer"},"orderId":{"type":"string"}},"required":["amountCents","orderId"]}
you sent: {"orderId":"1234","amount":5900}
```

The rendered message includes the decode error, the expected schema, and the
exact args the model sent. The model can read all three and produce a corrected
call on the next turn.

Handler exceptions are not caught: they propagate out of the loop. The error
policy covers the JSON boundary only. A handler that throws will exit the
agent, which is the right behaviour when an exception signals a genuine
infrastructure failure rather than a malformed request.

## The tool-agent loop

`runToolAgent` drives the full request-run-result cycle:

```haskell
runToolAgent
  :: (Chat :> es)
  => [Tool es]
  -> Text
  -> Eff es (Either ChatError Text)
```

The loop, in plain terms:

1. Send the question and the tool list to the model.
2. If the model returns one or more `tool_use` blocks, dispatch each to the
   matching tool's handler and collect the results.
3. Feed the results back as `tool_result` content blocks and repeat from step 1.
4. When the model returns a plain text reply with no `tool_use` blocks, return
   `Right text`.

Unknown-tool requests and undecodable arguments are fed back as error
`tool_result` values so the model can self-correct; a transient hallucinated
tool name rarely survives the next round.

## Capping the loop

`runToolAgent` is capped at `defaultMaxIterations` (10):

```haskell
defaultMaxIterations :: Int
defaultMaxIterations = 10

runToolAgent  :: (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)
runToolAgentN :: (Chat :> es) => Int -> [Tool es] -> Text -> Eff es (Either ChatError Text)
```

`runToolAgent = runToolAgentN defaultMaxIterations`. If the cap is reached
without a final text reply the result is `Left (ToolLoopExceeded cap)`. Raise
the cap with `runToolAgentN n` for tasks that legitimately chain many tool
calls; lower it for budget-sensitive paths.

## Worked example

The canonical demo from `app/Main.hs`, using a record toolbox:

```haskell
import qualified Data.Text as T
import Effectful (Eff, runEff)
import GHC.Generics (Generic)
import qualified Crucible.LLM.Anthropic as Anthropic
import Crucible.Chat (runToolAgent)
import Crucible.Codec.Generic (HasCodec (codec), genericCodec)
import Crucible.Tool.Generic (tools)
import Crucible.Usage (Usage (..), usTotalTokens, Rates (..), estimateCost)

data WeatherQ = WeatherQ { city :: T.Text } deriving (Show, Generic)
instance HasCodec WeatherQ where codec = genericCodec

data WeatherTools es = WeatherTools
  { get_weather :: WeatherQ -> Eff es T.Text }
  deriving (Generic)

weatherBox :: WeatherTools es
weatherBox = WeatherTools { get_weather = \_ -> pure "It is 26C and sunny." }

(toolAns, usage) <- runEff
  ( Anthropic.usageChat cfg
      (runToolAgent (tools weatherBox)
        "Use the tool to get the weather in Brisbane, then tell me.") )

case toolAns of
  Right a  -> putStrLn (T.unpack a)
  Left err -> print err
```

`Anthropic.usageChat` discharges the `Chat` effect against the live Anthropic
API and returns the result alongside cumulative `Usage`: input and output
tokens summed across every round of the tool loop. For straight results without
token accounting, use `Anthropic.runChat` instead.

## Listing available tools

`toolsHelp :: [Tool es] -> Text` returns a human-readable summary of the tools
in a list, useful for system prompts that tell the model what capabilities are
available before the conversation begins.

## Further reading

The `Chat` effect and its interpreters (scripted, live, cassette) are described
in [Effects](effects.md). Token accounting across tool-loop rounds is covered in
[Usage & cassettes](usage-and-cassettes.md). To stream the final assistant
response as it arrives while the tool loop runs normally, see
[Streaming](streaming.md).
