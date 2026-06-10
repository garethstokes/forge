---
title: Home
nav_order: 1
---

# crucible

crucible is a typed LLM-agent substrate for Haskell, built on
[`effectful`](https://hackage.haskell.org/package/effectful). It models an agent
as a small set of capabilities (talking to a model, calling tools, streaming,
recording), each a dynamic effect you discharge with an interpreter you choose:
scripted for tests, live for production, a cassette for hermetic replay.

Declare a skill once: a typed input, a typed output, a prompt template. The
output type's JSON schema rides the prompt; the reply is decoded back into your
type, with bad replies re-asked automatically.

```haskell
data Verdict = Verdict { sentiment :: Text, confidence :: Double }
  deriving (Show, Generic)
instance HasCodec Verdict where codec = genericCodec

classify :: Skill Text Verdict
classify = skill "classify" str codec
  (\review -> [text|Classify the sentiment of this product review: ${review}|])
```

Then pick an interpreter at the edge. The same `call` runs live, streams
token-by-token, or replays a recording, without touching the skill:

```haskell
main :: IO ()
main = do
  cfg <- defaultAnthropicConfig <$> getKey

  -- live: structured output, typed on arrival
  Right v <- runEff (Anthropic.run cfg (call classify "Arrived broken. Refund please."))
  print v.sentiment                   -- "negative"
  print v.confidence                  -- 0.98

  -- record once, then replay with no network: a hermetic test from a real run
  _ <- runEff (Anthropic.record "run.jsonl" cfg (call classify review))
  r <- runEff (Anthropic.replay "run.jsonl"     (call classify review))
```

## What's in the box

- **Effects**: `LLM` (`complete`), `Chat` (`converse`/`runToolAgent`), `Tools`,
  and `Emit` (streaming deltas). `LLM` and `Chat` each come with scripted, live,
  and cassette interpreters.
- **Typed skills**: declare a `Skill` with input/output codecs; the output
  schema is injected into the prompt and the reply tolerantly decoded.
- **Native tool-calling**: advertise tools and let the model drive a
  request→run→result loop (`runToolAgent`), capped and self-correcting.
- **Streaming**: server-sent events surfaced as an `Emit` effect; print tokens
  live while still getting the assembled result + token `Usage`.
- **Usage & cost**: a `Usage` monoid summed across calls, plus a pure
  `estimateCost`.
- **Cassettes**: record a live conversation and replay it deterministically, so
  one recorded run serves as both a live eval and a hermetic test.
- **Codecs**: one autodocodec `HasCodec` per type drives prompt schemas, tool
  `input_schema`, and JSON encode/decode.

## Pages

- [Getting started](getting-started.md): config, a first live call, a typed
  function, a cassette replay.
- [Effects](effects.md): the capability effects and their interpreters.
- [Typed functions](typed-functions.md): `skill`/`call`, codecs, schema
  injection, tolerant decode, retries.
- [Tool calling](tool-calling.md): `runToolAgent`, the loop, the cap, tool
  schemas.
- [Streaming](streaming.md): the `Emit` effect and the streaming interpreters.
- [Usage & cassettes](usage-and-cassettes.md): token accounting and
  record/replay.
- [The live interpreter](live-interpreter.md): `AnthropicConfig`, errors and
  retries, the wire path.
