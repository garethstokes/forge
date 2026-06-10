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

## Further reading

Config setup and the first live call are walked through in [Getting
started](getting-started.md). Streaming-specific interpreter usage is in
[Streaming](streaming.md).
