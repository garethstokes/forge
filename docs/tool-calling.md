---
title: Tool calling
nav_order: 5
---

# Tool calling

crucible's native tool-calling lets the model drive a loop: you advertise a set
of `Tool` values, ask a question, and the model issues calls, receives results,
and keeps going until it produces a text answer. You write the tool functions in
Haskell; the loop bookkeeping — serialising calls, running handlers, feeding
results back — is handled by `runToolAgent`.

## Constructing a tool

A `Tool es` bundles three things:

```haskell
data Tool es = Tool
  { toolName   :: ToolName
  , toolSchema :: Value          -- JSON Schema sent as input_schema
  , toolRun    :: Value -> Eff es Value
  }
```

`toolName` is the string the model will use to invoke the tool. `toolSchema` is
the JSON Schema object advertised to the model as the tool's `input_schema`; the
model produces a `Value` conforming to that schema, and that same `Value` is
passed to `toolRun`. `toolRun` returns an Aeson `Value` that becomes the
`tool_result` content block fed back to the model.

The schema is plain Aeson. You can build it with `A.object` literals or derive
it from a codec with `schemaValue :: JSONCodec a -> Value` from
`Crucible.Codec`:

```haskell
-- manual schema
weatherSchema :: Value
weatherSchema = A.object
  [ "type"       A..= A.String "object"
  , "properties" A..= A.object
      [ "city" A..= A.object ["type" A..= A.String "string"] ]
  , "required"   A..= A.toJSON [A.String "city"]
  ]

-- or from a codec (recommended for non-trivial inputs)
-- toolSchema = schemaValue (codec @WeatherArgs)
```

`toolRun` runs in the same `Eff es` stack as the agent, so it can carry any
effects you have wired in — IO, database access, other LLM calls.

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
`tool_result` values so the model can self-correct — a transient hallucinated
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
import Crucible.LLM.Anthropic (runChatAnthropicUsage, defaultAnthropicConfig)
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
  ( runChatAnthropicUsage cfg
      (runToolAgent [weatherTool]
        "Use the tool to get the weather in Brisbane, then tell me.") )

case toolAns of
  Right a  -> putStrLn (T.unpack a)
  Left err -> print err
```

`runChatAnthropicUsage` discharges the `Chat` effect against the live Anthropic
API and returns the result alongside cumulative `Usage` — input and output
tokens summed across every round of the tool loop. For straight results without
token accounting, use `runChatAnthropic` instead.

## Listing available tools

`toolsHelp :: [Tool es] -> Text` returns a human-readable summary of the tools
in a list — useful for system prompts that tell the model what capabilities are
available before the conversation begins.

## Further reading

The `Chat` effect and its interpreters (scripted, live, cassette) are described
in [Effects](effects.md). Token accounting across tool-loop rounds is covered in
[Usage & cassettes](usage-and-cassettes.md). To stream the final assistant
response as it arrives while the tool loop runs normally, see
[Streaming](streaming.md).
