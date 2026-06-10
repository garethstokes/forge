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

## Constructing a tool

### The type-driven constructor (recommended)

The easiest way to build a tool is with the `tool` smart constructor. Define a
`HasCodec` instance for your argument type and `tool` derives the JSON Schema for
you, decodes the model's arguments, and surfaces decode failures as an error
`Value` (the model's self-correction cue):

```haskell
import Crucible.Tool (tool)
import Crucible.Codec.Generic (HasCodec (codec), genericCodec)
import GHC.Generics (Generic)

data Loc = Loc { locCity :: Text } deriving (Show, Generic)
instance HasCodec Loc where codec = genericCodec

weather :: Tool es
weather = tool "get_weather" (\(Loc c) -> pure (A.String ("sunny in " <> c)))
```

The schema is derived from `Loc`'s codec via `schemaValue (codec @Loc)`. The
`Value` the model sends is decoded into a `Loc` before your handler runs; bad
args produce an error `Value` (`"bad tool args: …"`) that the model sees as a
`tool_result` and can recover from.

### The raw constructor (escape hatch)

When you need full control over the schema or want to handle the raw `Value`
yourself, use the `Tool` constructor directly:

```haskell
data Tool es = Tool
  { name   :: ToolName
  , schema :: Value          -- JSON Schema sent as input_schema
  , run    :: Value -> Eff es Value
  }
```

`name` is the string the model will use to invoke the tool. `schema` is the JSON
Schema object advertised to the model as the tool's `input_schema`; the model
produces a `Value` conforming to that schema, and that same `Value` is passed to
`run`. `run` returns an Aeson `Value` that becomes the `tool_result` content block
fed back to the model.

The schema is plain Aeson. You can build it with `A.object` literals or derive
it from a codec with `schemaValue :: JSONCodec a -> Value` from `Crucible.Codec`:

```haskell
-- manual schema
weatherSchema :: Value
weatherSchema = A.object
  [ "type"       A..= A.String "object"
  , "properties" A..= A.object
      [ "city" A..= A.object ["type" A..= A.String "string"] ]
  , "required"   A..= A.toJSON [A.String "city"]
  ]

weatherTool :: Tool es
weatherTool = Tl.Tool "get_weather" weatherSchema
  (\_ -> pure (A.String "It is 26C and sunny."))

-- or derive the schema from a codec (recommended for non-trivial inputs)
-- Tool "get_weather" (schemaValue (codec @WeatherArgs)) myHandler
```

`run` runs in the same `Eff es` stack as the agent, so it can carry any
effects you have wired in: IO, database access, other LLM calls.

## The tool-agent loop

`runToolAgent` drives the full request→run→result cycle:

```haskell
runToolAgent
  :: (Chat :> es)
  => [Tool es]
  -> Text
  -> Eff es (Either ChatError Text)
```

The loop, in plain terms:

1. Send the question and the tool list to the model.
2. If the model returns one or more `tool_use` blocks, dispatch each to its
   matching `toolRun` handler and collect the results.
3. Feed the results back as `tool_result` content blocks and repeat from step 1.
4. When the model returns a plain text reply with no `tool_use` blocks, return
   `Right text`.

Unknown-tool requests and handler exceptions are fed back as error
`tool_result` values so the model can self-correct; a transient hallucinated
tool name rarely survives the next round.

## Capping the loop

`runToolAgent` is capped at `defaultMaxIterations` (10):

```haskell
defaultMaxIterations :: Int
defaultMaxIterations = 10

runToolAgent  ::        (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)
runToolAgentN :: Int -> (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)
```

`runToolAgent = runToolAgentN defaultMaxIterations`. If the cap is reached
without a final text reply the result is `Left (ToolLoopExceeded cap)`. Raise
the cap with `runToolAgentN n` for tasks that legitimately chain many tool
calls; lower it for budget-sensitive paths.

## Worked example

The canonical demo from `app/Main.hs`:

```haskell
import qualified Data.Aeson as A
import Effectful (runEff)
import qualified Crucible.LLM.Anthropic as Anthropic
import Crucible.Chat (runToolAgent)
import qualified Crucible.Tool as Tl
import Crucible.Usage (Usage (..), usTotalTokens, Rates (..), estimateCost)

let weatherSchema = A.object
      [ "type"       A..= A.String "object"
      , "properties" A..= A.object
          [ "city" A..= A.object ["type" A..= A.String "string"] ]
      , "required"   A..= A.toJSON [A.String "city"]
      ]
    weatherTool = Tl.Tool "get_weather" weatherSchema
      (\_ -> pure (A.String "It is 26C and sunny."))

(toolAns, usage) <- runEff
  ( Anthropic.usageChat cfg
      (runToolAgent [weatherTool]
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
