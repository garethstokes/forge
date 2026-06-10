---
title: Usage & cassettes
nav_order: 7
---

# Usage & cassettes

Two concerns that sit at opposite ends of the development cycle: token
accounting during production runs, and deterministic replay during CI. crucible
addresses both through the `Usage` type and the cassette interpreter pair.

## Token usage

`Usage` is a record of the tokens consumed by a call or a sequence of calls:

```haskell
data Usage = Usage
  { inputTokens  :: Int
  , outputTokens :: Int
  }
```

`Usage` is a `Monoid`: `mempty` is zero tokens and `mappend` sums them
component-wise. The usage-returning interpreters accumulate a single `Usage`
across every call inside the `Eff` computation, including every round of a
tool-agent loop, and return it alongside the result:

```haskell
Anthropic.usage     :: (IOE :> es) => AnthropicConfig -> Eff (LLM:es)  a -> Eff es (a, Usage)
Anthropic.usageChat :: (IOE :> es) => AnthropicConfig -> Eff (Chat:es) a -> Eff es (a, Usage)
```

A convenience accessor covers the common case:

```haskell
usTotalTokens :: Usage -> Int
usTotalTokens u = u.inputTokens + u.outputTokens
```

## Cost estimation

`estimateCost` converts a `Usage` into an estimated dollar figure:

```haskell
data Rates = Rates
  { inputPerMTok  :: Double
  , outputPerMTok :: Double
  }

estimateCost :: Rates -> Usage -> Double
```

`Rates` is caller-supplied: no prices are baked into the library. Anthropic
publishes per-million-token rates on their pricing page; pass them as
`Rates inputRate outputRate`. From `app/Main.hs`:

```haskell
import Crucible.Usage (Usage (..), usTotalTokens, Rates (..), estimateCost)
import qualified Crucible.LLM.Anthropic as Anthropic

(toolAns, usage) <- runEff
  ( Anthropic.usageChat cfg
      (runToolAgent [weatherTool]
        "Use the tool to get the weather in Brisbane, then tell me.") )

-- Illustrative per-MTok rates (not authoritative pricing).
let rates = Rates 1.0 5.0
    usageIn  = let Usage { inputTokens  = n } = usage in n
    usageOut = let Usage { outputTokens = n } = usage in n
putStrLn
  ( "usage: " <> show usageIn <> " in + "
      <> show usageOut <> " out = "
      <> show (usTotalTokens usage) <> " tokens"
      <> "; est. cost $" <> show (estimateCost rates usage) )
```

Because `Usage` is a `Monoid` you can accumulate costs across multiple
computations with `mconcat`.

## Cassettes

A cassette is a plain text file, one JSON-encoded response per line, written by
a live run and replayed deterministically later: no network, same bytes every
time. There are two cassette pairs, one for each effect:

| Record | Replay | Covers |
|--------|--------|--------|
| `Anthropic.record path cfg` | `Anthropic.replay path` | `LLM` / `complete` |
| `Anthropic.recordChat path cfg` | `Anthropic.replayChat path` | `Chat` / `runToolAgent` |

The `record*` interpreters behave identically to their live counterparts (they
issue real network calls) but tee each response to the cassette file in call
order. The `replay*` interpreters read the file once and pop responses back in
the same order, with no network access.

## The record/replay slider

`app/Main.hs` demonstrates the full cycle for the chat path:

```haskell
import qualified Crucible.LLM.Anthropic as Anthropic
import Crucible.Chat (runToolAgent)

let chatCassette = "/tmp/crucible-chat-cassette.jsonl"
    weatherTool3 = Tl.Tool "get_weather" weatherSchema
      (\_ -> pure (A.String "It is 26C and sunny."))
    toolQuestion = "Use the tool to get the weather in Brisbane, then tell me."

writeFile chatCassette ""  -- fresh cassette

-- live: hits the network, writes each response to the cassette
recordedAns <- runEff
  ( Anthropic.recordChat chatCassette cfg
      (runToolAgent [weatherTool3] toolQuestion) )

-- replay: reads the cassette, no network required
replayedAns <- runEff
  ( Anthropic.replayChat chatCassette
      (runToolAgent [weatherTool3] toolQuestion) )

case (recordedAns, replayedAns) of
  (Right a, Right b) | a == b ->
    putStrLn ("chat cassette OK: " <> T.unpack a)
  _ -> putStrLn "chat cassette: MISMATCH"
```

The workflow for CI:

1. During development, run with `Anthropic.recordChat` (or `Anthropic.record`)
   to capture real model responses.
2. Commit the cassette file alongside the test.
3. In CI, swap to `Anthropic.replayChat` (or `Anthropic.replay`). The test runs
   hermetically with no API key and no network dependency.

The cassette file is the slider: pull it one way for a live eval, the other for
a hermetic regression test. Because the file is plain JSONL it diffs cleanly in
version control when model outputs change.

## Further reading

The streaming interpreters also return `Usage`; the details are in
[Streaming](streaming.md). For config and retry settings that affect how many
tokens are consumed per call, see [Getting started](getting-started.md) and
[The live interpreter](live-interpreter.md).
