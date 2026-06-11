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

## Why

Code that talks to a language model tends to accumulate the same problems.
The model returns text, so every call site grows its own parsing: strip the
markdown fence, find the JSON, hope the keys match, and handle the day the
model phrases its reply differently. The schema described in the prompt, the
parser, and the application type are three separate artifacts that drift
apart silently. Tool handlers re-implement argument validation by hand and
smuggle errors back as strings. And because every test needs a live API key,
the test suite is slow, costly, and nondeterministic, so the agent logic
mostly goes untested.

crucible's answer is one codec per type and an interpreter per environment.
A single `HasCodec` instance drives the schema the model is shown, the
decoder its reply goes through, and a tool's argument and result handling,
so the three artifacts cannot drift. Replies that fail to decode are re-asked
with the parse error, and tool mistakes are fed back with the expected
schema, so the model corrects itself instead of crashing your program. The
same agent code runs against a scripted interpreter in CI, a recorded
cassette for regression tests, or a live provider (Anthropic or OpenAI) in
production; switching is one line at the program's edge, not a rewrite.

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
  and `Emit` (streaming deltas). `LLM` and `Chat` each come with scripted, live
  (Anthropic and OpenAI), and cassette interpreters.
- **Typed skills**: declare a `Skill` with input/output codecs; the output
  schema is injected into the prompt and the reply tolerantly decoded. Attach
  test cases with `withTests`, run them with `testSkill`, and hill-climb the
  instruction against them with `improveSkill`.
- **Typed tool-calling**: declare a toolbox as a record of plain handlers;
  field names become tool names, arguments are decoded and results encoded
  through codecs, and the model drives a capped, self-correcting
  request→run→result loop (`runToolAgent`).
- **Streaming**: server-sent events surfaced as an `Emit` effect; print tokens
  live while still getting the assembled result + token `Usage`. For row-based
  data, `Crucible.Rows` decodes JSONL output into typed rows as each line
  completes.
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
- [Typed functions](typed-functions.md): `skill`/`call`, structured
  instructions, codecs, schema injection, tolerant decode, retries, few-shot
  examples, `improveSkill`.
- [Evals](evals.md): expectations, checklists, the judge, voting, calibration.
- [Tool calling](tool-calling.md): record toolboxes, `runToolAgent`, the loop,
  the cap, tool schemas and errors.
- [Streaming](streaming.md): the `Emit` effect and the streaming interpreters.
- [Usage & cassettes](usage-and-cassettes.md): token accounting and
  record/replay.
- [The live interpreter](live-interpreter.md): `AnthropicConfig`, errors and
  retries, the wire path.
