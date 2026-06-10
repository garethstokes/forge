---
title: Home
nav_order: 1
---

# crucible

crucible is a typed LLM-agent substrate for Haskell, built on
[`effectful`](https://hackage.haskell.org/package/effectful). It models an agent
as a small set of capabilities — talking to a model, calling tools, streaming,
recording — each a dynamic effect you discharge with an interpreter you choose:
scripted for tests, live for production, a cassette for hermetic replay.

```haskell
-- a typed skill: a prompt in, a decoded value out
data Sentiment = Sentiment { sentLabel :: Text } deriving (Show, Generic)
instance HasCodec Sentiment where codec = genericCodec

classify :: Skill Text Sentiment
classify = skill "classify" str codec
  (\s -> [text|Classify the sentiment as positive, negative, or neutral for: ${s}|])

main :: IO ()
main = do
  cfg <- defaultAnthropicConfig <$> getKey
  r <- runEff (Anthropic.run cfg (call classify "I absolutely love this!"))
  print r   -- Right (Sentiment {sentLabel = "positive"})
```

## What's in the box

- **Effects** — `LLM` (`complete`), `Chat` (`converse`/`runToolAgent`), `Tools`,
  and `Emit` (streaming deltas), each with scripted, live, and cassette
  interpreters.
- **Typed skills** — declare a `Skill` with input/output codecs; the output
  schema is injected into the prompt and the reply tolerantly decoded.
- **Native tool-calling** — advertise tools and let the model drive a
  request→run→result loop (`runToolAgent`), capped and self-correcting.
- **Streaming** — server-sent events surfaced as an `Emit` effect; print tokens
  live while still getting the assembled result + token `Usage`.
- **Usage & cost** — a `Usage` monoid summed across calls, plus a pure
  `estimateCost`.
- **Cassettes** — record a live conversation and replay it deterministically,
  the slider between a live eval and a hermetic test.
- **Codecs** — one autodocodec `HasCodec` per type drives prompt schemas, tool
  `input_schema`, and JSON encode/decode (and makes the type persistable by
  sibling project [manifest](https://github.com/garethstokes/manifest)).

## Pages

- [Getting started](getting-started.md) — config, a first live call, a typed
  function, a cassette replay.
- [Effects](effects.md) — the capability effects and their interpreters.
- [Typed functions](typed-functions.md) — `skill`/`call`, codecs, schema
  injection, tolerant decode, retries.
- [Tool calling](tool-calling.md) — `runToolAgent`, the loop, the cap, tool
  schemas.
- [Streaming](streaming.md) — the `Emit` effect and the streaming interpreters.
- [Usage & cassettes](usage-and-cassettes.md) — token accounting and
  record/replay.
- [The live interpreter](live-interpreter.md) — `AnthropicConfig`, robustness,
  the wire path.
