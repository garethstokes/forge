---
title: The live interpreter
nav_order: 8
---

# The live interpreter

The live interpreter is the Anthropic-specific layer that translates crucible's
effect algebra into HTTP requests. It handles configuration, connection
management, error classification, and retry logic. Everything above it
(`complete`, `call`, `runToolAgent`) is interpreter-agnostic and unchanged.

## AnthropicConfig

`AnthropicConfig` holds every tuning knob for the live interpreter:

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `apiKey` | `Text` | (required) | Anthropic API key (`sk-ant-…`). |
| `model` | `Text` | `claude-haiku-4-5-20251001` | Model identifier sent as `model` in each request. |
| `maxTokens` | `Int` | `1024` | `max_tokens` per request. |
| `timeoutSecs` | `Int` | `60` | Per-request HTTP timeout in seconds. |
| `maxRetries` | `Int` | `3` | Maximum retry attempts for retryable errors. |
| `baseDelayMicros` | `Int` | `500000` | Base backoff delay in microseconds (500 ms). |
| `streamIdleSecs` | `Int` | `60` | Streaming idle timeout: if no chunk arrives within this many seconds the stream is abandoned with `AnthropicStreamTimeout`. |

`defaultAnthropicConfig :: Text -> AnthropicConfig` fills every field except
`apiKey` with the defaults above. Override individual fields with record
update:

```haskell
import Crucible.LLM.Anthropic (defaultAnthropicConfig)
import qualified Data.Text as T

let cfg = (defaultAnthropicConfig (T.pack key))
      { model     = "claude-opus-4-5-20251001"
      , maxTokens = 4096
      }
```

## The wire path

`Anthropic.run` and `Anthropic.runChat` both POST to `/v1/messages` on the
Anthropic API. The differences are at the content-block level:

- **`LLM` path**: sends a flat `[Message]` list; the first text content block
  of the response is returned as `Text`.
- **`Chat` path**: sends structured content with `tool_use` / `tool_result`
  blocks; the response is parsed into a `Turn` carrying assembled text and any
  tool-use requests, which the `runToolAgent` loop then acts on.

`Anthropic.stream` and `Anthropic.streamChat` (from
`Crucible.LLM.Anthropic.Stream`) use the same endpoint with
`"stream": true` and process the server-sent event stream, emitting each delta
via `Emit`. See [Streaming](streaming.md).

The cassette interpreters (`Anthropic.replay`, `Anthropic.replayChat`) are the
deterministic counterpart: they read pre-recorded responses from a file instead
of hitting the network, making them zero-dependency drop-ins for CI. See
[Usage & cassettes](usage-and-cassettes.md).

## Error types

`AnthropicError` is a typed sum of every failure mode the live interpreter can
produce:

```haskell
data AnthropicError
  = AnthropicHttpError HttpException  -- connection-level failure (network, TLS)
  | AnthropicStatusError Int Text     -- non-2xx response: status code + body
  | AnthropicNoContent Text           -- 2xx response with no usable content block
  | AnthropicStreamTimeout Int        -- idle timeout during streaming (microseconds)
```

`isRetryable :: AnthropicError -> Bool` classifies errors for the retry loop:

| Error | Retryable? |
|-------|------------|
| `AnthropicHttpError` | Yes (connection reset, DNS failure, etc.). |
| `AnthropicStatusError 429 _` | Yes (rate limit). |
| `AnthropicStatusError 5xx _` | Yes (server error). |
| `AnthropicStatusError 4xx _` | No (bad request, auth failure, etc.). |
| `AnthropicNoContent` | No (the model returned nothing usable). |
| `AnthropicStreamTimeout _` | No (retry at the call site with a fresh request). |

## Retry behaviour

When a retryable error occurs the interpreter waits before trying again. The
wait is jittered exponential backoff: the base delay is `baseDelayMicros`,
growing exponentially per attempt with full jitter applied, so concurrent
clients do not retry in a thundering herd on a 429. Each individual delay is
capped at 30 s. Retries stop after `maxRetries` attempts; on exhaustion the
error is re-thrown.

The request timeout (`timeoutSecs`) and the streaming idle timeout
(`streamIdleSecs`) are both enforced independently: a request that hangs at
the HTTP level is killed after `timeoutSecs`; a streaming response that stalls
mid-generation without producing a chunk for `streamIdleSecs` seconds raises
`AnthropicStreamTimeout` (carrying the idle window in microseconds). Setting
`streamIdleSecs` to zero or a negative value disables the idle guard. The
streaming interpreters apply the retry policy only to opening the connection;
nothing has been emitted at that point, so retrying is safe. A mid-stream
failure is not retried.

## The OpenAI interpreter

`Crucible.LLM.OpenAI` is the OpenAI twin, with the same qualified grammar:
`OpenAI.run`, `OpenAI.usage`, `OpenAI.record`, `OpenAI.replay` discharge
`LLM`; `OpenAI.runChat`, `OpenAI.usageChat`, `OpenAI.recordChat`,
`OpenAI.replayChat` discharge `Chat` with native tool-calling; and
`OpenAI.stream` / `OpenAI.streamChat` (from `Crucible.LLM.OpenAI.Stream`,
imported under the same alias) stream with `Emit`, all against
`POST /v1/chat/completions`. Swapping providers is a one-line change at the
`runEff` edge:

```haskell
import qualified Crucible.LLM.OpenAI as OpenAI
import qualified Crucible.LLM.OpenAI.Stream as OpenAI

let cfg = defaultOpenAIConfig (T.pack key)   -- model "gpt-4o-mini" by default
r <- runEff (OpenAI.run cfg (call classify "I absolutely love this!"))
```

`OpenAIConfig` carries the same knobs as `AnthropicConfig`: `apiKey`, `model`,
`maxTokens` (sent as `max_completion_tokens`), `timeoutSecs`, `maxRetries`,
`baseDelayMicros`, `streamIdleSecs`. Errors mirror too: `OpenAIHttpError`,
`OpenAIStatusError`, `OpenAINoContent`, `OpenAIStreamTimeout`, with the same
`isRetryable` classification and the same jittered backoff.

The cassette format is provider-neutral (it is crucible's own turn
serialization, defined in `Crucible.Chat`), so a conversation recorded with
`Anthropic.recordChat` replays under `OpenAI.replayChat` and vice versa.

## Fallback and round-robin

The `Provider` record carries the provider name, model id, and per-call functions:

```haskell
data Provider = Provider
  { name     :: Text
  , model    :: Text
  , complete :: [Message] -> IO (Text, Usage)
  , converse :: [(ToolName, Value)] -> [Chat.Message] -> IO (Turn, Usage)
  }
```

Each function carries the provider's own retry policy, so a member inside a
fallback chain behaves exactly as it would alone: the chain only advances when
the member's internal retries have given up.

Build a `Provider` with either constructor:

```haskell
import qualified Crucible.LLM.Anthropic as Anthropic
import qualified Crucible.LLM.OpenAI   as OpenAI

aProvider <- Anthropic.provider acfg
oProvider <- OpenAI.provider   ocfg
```

Here `acfg` and `ocfg` are the Anthropic and OpenAI configs from the sections
above.

Both constructors allocate one shared TLS manager for that provider. You can
also construct a `Provider` directly, which is useful for stubs or custom
dispatch strategies.

### Fallback combinators

`Crucible.LLM.Fallback` exports eight functions, used qualified:

| Combinator                     | Discharges | Returns                      |
|--------------------------------|------------|------------------------------|
| `Fallback.run`                 | `LLM`      | result                       |
| `Fallback.usage`               | `LLM`      | result + accumulated `Usage` |
| `Fallback.runChat`             | `Chat`     | result                       |
| `Fallback.usageChat`           | `Chat`     | result + accumulated `Usage` |
| `Fallback.roundRobin`          | `LLM`      | result                       |
| `Fallback.roundRobinUsage`     | `LLM`      | result + accumulated `Usage` |
| `Fallback.roundRobinChat`      | `Chat`     | result                       |
| `Fallback.roundRobinUsageChat` | `Chat`     | result + accumulated `Usage` |

Example using the `LLM` path:

```haskell
import qualified Crucible.LLM.Fallback as Fallback

providers <- sequence [Anthropic.provider acfg, OpenAI.provider ocfg]
answer <- runEff (Fallback.run providers (complete msgs))
```

### Semantics

Fallback is per call, not per program. Each call to `complete` or `converse`
tries the members in order. The chain advances on any synchronous member
failure -- a misconfigured member (bad API key, wrong base URL) falls through
to a healthy one instead of wedging the chain. Effects already performed
(such as tool calls from a previous loop turn) are never replayed: the chain
only advances before the member produces a result.

When every member fails, `FallbackExhausted` (the sole constructor of
`FallbackError`) is thrown, carrying each member's rendered error in the
order tried. An empty member list throws `FallbackExhausted []` immediately
on the first call.

### Round-robin

Fallback treats the list as a primary with backups; round-robin spreads load
and rate-limit pressure across members instead.
`Fallback.roundRobin` and its siblings rotate the starting member per call.
An `IORef` counter created when the interpreter starts advances by one for
each call, so successive calls distribute across members. A failing member
still falls through to the rest of the list, wrapping around if needed.

### Observing the chain

`Crucible.LLM.CallLog` (used qualified) instruments a provider list without
touching fallback internals. Create a handle, decorate the members, run the
chain, then drain:

```haskell
import Crucible.LLM.CallLog (CallEntry (..))
import qualified Crucible.LLM.CallLog as CallLog

lg        <- CallLog.new
providers <- map (CallLog.logging lg) <$>
               sequence [ Anthropic.provider acfg, OpenAI.provider ocfg ]
answer    <- runEff (Fallback.run providers (complete msgs))
entries   <- CallLog.drain lg
```

Each `CallEntry` has four fields:

| Field        | Type              | Meaning                                          |
|--------------|-------------------|--------------------------------------------------|
| `provider`   | `Text`            | The member's `name`.                             |
| `model`      | `Text`            | The model id used for that attempt.              |
| `durationMs` | `Int`             | Wall-clock time from call start to finish, in ms.|
| `outcome`    | `Either Text Usage` | `Left` rendered error, or `Right` usage on success. |

Failed member attempts are recorded before the exception is rethrown, so the
entries arrive in tried order. The entry with a `Right` outcome is the member
that answered; every preceding `Left` entry is one that fell through. The full
walk is reconstructable from a single drain.

`drain` reads and clears the handle, so distinct phases of a longer program
can collect their own windows without cross-contamination. For a single
provider, wrap it in a singleton chain: `Fallback.run [CallLog.logging lg p]`.

### Limits

- Streaming stays single-provider; the fallback combinators cover `LLM` and
  `Chat` only.
- Cassettes record at the provider level (inside each member), not at the
  chain level.
- Which member answered is not part of the result value; decorate the chain
  with `CallLog.logging` (above) to observe the walk.

## Embeddings

The `Embed` effect turns a `Text` value into a `[Double]` vector. The effect
has one operation:

```haskell
embed :: (Embed :> es) => Text -> Eff es [Double]
```

Two live interpreters ship. Both are used qualified.

### OpenAI.runEmbed

```haskell
import qualified Crucible.LLM.OpenAI as OpenAI

vec <- runEff (OpenAI.runEmbed cfg (embed "some text"))
```

`OpenAI.runEmbed` calls the OpenAI `POST /v1/embeddings` endpoint. It reads
the `embedModel` field from `OpenAIConfig`; `defaultOpenAIConfig` sets this
to `"text-embedding-3-small"`. Override it with a record update:

```haskell
let cfg = (defaultOpenAIConfig key) { embedModel = "text-embedding-3-large" }
```

### Voyage.runEmbed

```haskell
import qualified Crucible.LLM.Voyage as Voyage

vec <- runEff (Voyage.runEmbed (Voyage.defaultVoyageConfig (T.pack voyageApiKey))
                 (embed "some text"))
```

`Voyage.runEmbed` calls the Voyage AI `POST /v1/embeddings` endpoint.
`defaultVoyageConfig` takes the API key and sets the model to
`"voyage-3.5-lite"`. Voyage is an embeddings-only provider; it discharges
`Embed` but not `LLM` or `Chat`. Anthropic has no embeddings endpoint and
points customers to Voyage for that use case.

A conventional way to supply the key:

```haskell
mVoyKey <- lookupEnv "VOYAGE_API_KEY"
case mVoyKey of
  Nothing  -> putStrLn "VOYAGE_API_KEY not set"
  Just key -> do
    vec <- runEff (Voyage.runEmbed (Voyage.defaultVoyageConfig (T.pack key))
                    (embed "crucible embeds with Voyage"))
    print (length vec)
```

### Tests and programs without similarity cases

`runEmbedScripted vecs` pops canned `[Double]` vectors from a list on each
`embed` call. Use it in tests alongside `runLLMScripted` to keep the suite
offline and deterministic. An exhausted script yields `[]`.

`Embed.none` discharges `Embed` for programs that have no
`Crucible.Eval.SimilarTo` cases. It errors with a clear message on first
use, making the omission visible rather than silent. Wrap existing
`runEval` / `scoreM` callers with it as a one-line migration:

```haskell
result <- runEff (Anthropic.run cfg (Embed.none (runEval id pure cases)))
```

### Limits

- No usage variants for `Embed`: nothing consumes embedding token counts
  yet, so there is no `usageEmbed` counterpart to `usage`. Added on demand.
- No cassette support: `runEmbedScripted` is the test-layer counterpart;
  there is no file-backed cassette for embeddings yet.
- No fallback chains: `Embed` has no `Fallback.runEmbed` combinator yet.
  Wire a single interpreter at the edge for now.

## Further reading

Config setup and the first live call are walked through in [Getting
started](getting-started.md). Streaming-specific interpreter usage is in
[Streaming](streaming.md).
