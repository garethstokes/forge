---
title: Effects
nav_order: 3
---

# Effects

crucible models each agent capability as a dynamic `effectful` effect. A function
that talks to a model carries `LLM :> es` in its constraint; one that calls tools
carries `Chat :> es`; one that emits streaming deltas carries `Emit :> es`. The
constraint is the capability list: the type says exactly what the function can
do, and you choose the interpreter at the program edge (scripted for tests, live
for production, cassette for hermetic replay) without touching the logic inside.

## The LLM effect

`LLM` is the text-completion capability. Its only smart constructor is:

```haskell
complete :: (LLM :> es) => [Message] -> Eff es Text
```

A `Message` is `Message { role :: Role, content :: Text }`. `Role` is one of
`System`, `User`, `Assistant`, or `Tool`. That is the entire surface area of `LLM`;
every interpreter speaks the same contract.

**Pure (tests):** `runLLMScripted :: [Text] -> Eff (LLM:es) a -> Eff es a` pops
canned replies in order. No IO, no network, deterministic:

```haskell
import Effectful (runPureEff)
import Crucible.LLM (Message (..), Role (..), complete, runLLMScripted)

result :: Text
result = runPureEff (runLLMScripted ["pong"] (complete msgs))
-- result = "pong"  (no network)
```

**Live:** `Anthropic.run :: (IOE :> es) => AnthropicConfig -> Eff (LLM:es) a -> Eff es a` discharges `LLM` against the real Anthropic Messages API. Same call,
different interpreter at the edge:

```haskell
import qualified Crucible.LLM.Anthropic as Anthropic

result <- runEff (Anthropic.run cfg (complete msgs))
```

`Anthropic.usage` is the same live path but also returns the summed token
`Usage` alongside the result. See [Usage & cassettes](usage-and-cassettes.md).

**Cassette (replay):** `Anthropic.replay :: (IOE :> es) => FilePath -> Eff (LLM:es) a -> Eff es a` replays a previously recorded cassette. Pairs with
`Anthropic.record` to lock in real responses for deterministic CI. See
[Usage & cassettes](usage-and-cassettes.md).

The logic (building `msgs`, calling `complete`, decoding the reply) is identical
in all three cases. You choose the interpreter once, at `runEff`.

## The Chat effect

`Chat` is the structured, tool-aware conversation capability. Where `LLM` works with
flat `[Message]` and returns `Text`, `Chat` works with content blocks and returns a
`Turn` (assembled text plus any tool-use requests):

```haskell
converse :: (Chat :> es) => [(ToolName, Value)] -> [Chat.Message] -> Eff es Turn
```

Most callers do not call `converse` directly. `runToolAgent` drives the
request→run→result loop for you, capped at `defaultMaxIterations` (10):

```haskell
runToolAgent  :: (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)
runToolAgentN :: (Chat :> es) => Int -> [Tool es] -> Text -> Eff es (Either ChatError Text)
```

On loop exhaustion both return `Left (ToolLoopExceeded cap)`. See
[Tool calling](tool-calling.md) for the loop mechanics and tool construction.

**Scripted (tests):** `runChatScripted :: [Turn] -> Eff (Chat:es) a -> Eff es a`
pops canned `Turn` values. An exhausted script yields a text-only empty `Turn` so
loops terminate cleanly.

**Live:** `Anthropic.runChat` (plain result) and `Anthropic.usageChat` (result plus
`Usage`) discharge `Chat` against the Anthropic API with native tool-calling
(`tool_use` / `tool_result` content blocks).

**Cassette:** `Anthropic.recordChat` / `Anthropic.replayChat` mirror the `LLM`
cassette pair for full tool-agent conversations. See [Usage & cassettes](usage-and-cassettes.md).

## The Emit effect

`Emit` is the streaming-delta capability. Streaming interpreters call `emit` once
per token chunk as it arrives from the server; the caller picks the consumer:

```haskell
emit :: (Emit :> es) => Text -> Eff es ()
```

| Interpreter    | Behaviour |
|----------------|-----------|
| `runEmitIO`    | Pass each delta to an IO sink (e.g. `\t -> putStr t >> hFlush stdout`). |
| `ignoreEmit`   | Discard all deltas (result is still assembled by the streamer). |
| `runEmitList`  | Collect deltas in arrival order alongside the result (for tests). |

`Emit` is orthogonal to `LLM` and `Chat`: the streaming interpreters
(`Anthropic.stream`, `Anthropic.streamChat`, from
`Crucible.LLM.Anthropic.Stream`) carry both an `Emit` constraint and produce
the same assembled `Text`/`(Either ChatError Text)` result the non-streaming
paths do, plus the summed `Usage`. See [Streaming](streaming.md).

## Effect summary

| Effect | Smart constructor | Interpreters |
|--------|-------------------|--------------|
| `LLM`  | `complete`        | `runLLMScripted` · `Anthropic.run` · `Anthropic.usage` · `Anthropic.record` · `Anthropic.replay` · `Anthropic.stream` |
| `Chat` | `converse`        | `runChatScripted` · `Anthropic.runChat` · `Anthropic.usageChat` · `Anthropic.recordChat` · `Anthropic.replayChat` · `Anthropic.streamChat` |
| `Emit` | `emit`            | `runEmitIO` · `ignoreEmit` · `runEmitList` |
| `Tools`| `callTool`        | `runTools` (dispatch to a `[Tool es]` list; `CallTool` returns `Either ToolError Value`; unknown tools report the available names) |

The `stream`/`streamChat` interpreters additionally require `Emit :> es`; they
live in `Crucible.LLM.Anthropic.Stream` and are conventionally imported under
the same `Anthropic` alias. The `Tools` effect serves the text-path agent loop
in `Crucible.Agent` (`runAgent`); the `Chat` tool loop dispatches tools
directly, so most callers never see it.

`Tool` values are built in one of three ways: via the Generic record-toolbox
derivation (`Crucible.Tool.Generic.tools`), via the type-level-name constructor
(`tool @"name"`), or via `toolWith` / `rawTool` for irregular names and
hand-written schemas. `runTools` routes each `CallTool` request to the matching
`Tool` by name; an unknown name returns `Left (UnknownTool name availableNames)`
so the model can self-correct. See [Tool calling](tool-calling.md) for the full
construction and loop details.

## Swapping interpreters

The interpreter is the only thing that changes between a unit test and a
production call. The logic in the middle (prompt construction, `call`,
`runToolAgent`, codec decode) is interpreter-agnostic. A contrived side-by-side:

```haskell
-- hermetic: no IO, no network
let pure_result = runPureEff
      ( runLLMScripted ["pong"]
          (complete [Message System "Be terse.", Message User "Ping?"]) )

-- live: real network
live_result <- runEff
  ( Anthropic.run cfg
      (complete [Message System "Be terse.", Message User "Ping?"]) )
```

Both lines call the same `complete`; only the interpreters at the edge differ. The same pattern applies to `runToolAgent` with `runChatScripted` vs
`Anthropic.runChat`, and to any `Skill` with `call`. See [The live
interpreter](live-interpreter.md) for the Anthropic-specific details.
