---
title: Streaming
nav_order: 6
---

# Streaming

The standard `Anthropic.run` and `Anthropic.runChat` interpreters wait for the
complete response before returning. Streaming interpreters instead surface each
token chunk as it arrives, so your application can print or forward partial
output without waiting for the full generation. The assembled result and token
`Usage` are still returned at the end — nothing is lost, output just arrives
sooner.

## The Emit effect

Streaming is wired through the `Emit` effect. Each arriving token chunk is
handed to:

```haskell
emit :: (Emit :> es) => Text -> Eff es ()
```

The streaming interpreters call `emit` for every server-sent delta. You choose
what happens to those deltas by picking an `Emit` interpreter at the program
edge:

| Interpreter    | Behaviour |
|----------------|-----------|
| `runEmitIO`    | Pass each delta to an `IO` sink: `(Text -> IO ()) -> Eff (Emit:es) a -> Eff es a`. The standard choice for live applications — print each chunk as it arrives. |
| `ignoreEmit`   | Discard all deltas: `Eff (Emit:es) a -> Eff es a`. Useful when you want the streaming interpreter's efficiency but do not need incremental output. |
| `runEmitList`  | Collect deltas in arrival order alongside the result: `Eff (Emit:es) a -> Eff es (a, [Text])`. The natural choice for tests — inspect the exact chunks the model produced. |

`Emit` is orthogonal to `LLM` and `Chat`. Swapping between the three `Emit`
interpreters does not touch the rest of your effect stack.

## The streaming interpreters

Two streaming interpreters live in `Crucible.LLM.Anthropic.Stream`, used
qualified under the same `Anthropic` alias:

```haskell
import qualified Crucible.LLM.Anthropic.Stream as Anthropic

Anthropic.stream
  :: (IOE :> es, Emit :> es)
  => AnthropicConfig
  -> Eff (LLM : es) a
  -> Eff es (a, Usage)

Anthropic.streamChat
  :: (IOE :> es, Emit :> es)
  => AnthropicConfig
  -> Eff (Chat : es) a
  -> Eff es (a, Usage)
```

Both behave like their non-streaming counterparts (`Anthropic.run`,
`Anthropic.runChat`) but emit token deltas via `Emit` as each chunk arrives from
the server. The assembled `Text` (or `Either ChatError Text` for the Chat path)
is returned together with cumulative `Usage` once the stream closes.

## Worked example

The `app/Main.hs` smoke test demonstrates the text path:

```haskell
import qualified Data.Text.IO as TIO
import System.IO (hFlush, stdout)
import Effectful (runEff)
import Crucible.Emit (runEmitIO)
import qualified Crucible.LLM.Anthropic.Stream as Anthropic
import Crucible.LLM (complete)

-- deltas are printed as they arrive; the assembled Text is in `streamed`
(streamed, sUsage) <- runEff
  ( runEmitIO (\t -> TIO.putStr t >> hFlush stdout)
      (Anthropic.stream cfg (complete prompt)) )
```

The tool-agent path is the same shape — substitute `Anthropic.streamChat` and
`runToolAgent`:

```haskell
import qualified Crucible.LLM.Anthropic.Stream as Anthropic
import Crucible.Chat (runToolAgent)

(toolStream, tUsage) <- runEff
  ( runEmitIO (\t -> TIO.putStr t >> hFlush stdout)
      (Anthropic.streamChat cfg
        (runToolAgent [weatherTool]
          "Use the tool to get the weather in Brisbane, then tell me.")) )
```

During each tool-loop round the model's text reply is streamed live; tool-call
execution itself is synchronous (the handler runs between rounds). The final
result is returned exactly as it would be from `Anthropic.runChat`.

## Streaming and typed skills

Typed skills (`call`) run under the `LLM` effect, so they compose with the
streaming path without changes: pass `call classify input` where you would pass
`complete prompt`. The token chunks are emitted as they arrive; the assembled
text is decoded through the output codec at the end. Incremental typed decoding
— decoding partial JSON as chunks arrive — is out of scope.

## Further reading

Token totals returned by the streaming interpreters are the same `Usage` type
described in [Usage & cassettes](usage-and-cassettes.md). The `Emit` effect
table and the non-streaming interpreters are in [Effects](effects.md). For
mid-stream idle timeout and other connection-level settings see [The live
interpreter](live-interpreter.md).
