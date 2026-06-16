# Crucible: live-path robustness (`runLLMAnthropic`)

**Goal.** Make the live Anthropic interpreter production-worthy without changing
the `LLM` effect's shape: typed errors (no silent raw-body fallback), automatic
retry-with-backoff on transient failures, a request timeout, and a shared TLS
`Manager`. First of the "productionize the live path" (direction A) sub-projects;
native tool-calling, streaming, and usage/cost are separate, later specs.

**Non-goals (YAGNI).** No change to `complete :: [Message] -> Eff es Text` or to
the pure interpreters (`runLLMScripted`/`runLLMCassette`). No streaming, no native
tool-calling, no usage capture. No honoring of the `Retry-After` header (we rely
on jittered exponential backoff). No hand-rolled backoff math — use the `retry`
library.

## Design decisions

1. **Error surface:** the live interpreter *throws* a typed `AnthropicError`
   (an `Exception`) on failure; the effect still returns `Text`, so the pure
   interpreters and all consumers (`runAgent`, `call`) are untouched. Callers
   handle failures with `try`/`catch` in IO. (Idiomatic — http-client already
   throws `HttpException`.)
2. **Retries:** use `Control.Retry` (`recovering` + a `RetryPolicy`). Retry
   network/connection/timeout errors, HTTP 429, and 5xx; do not retry other 4xx
   (permanent) or a malformed 2xx. Jittered exponential backoff, capped, with a
   retry limit. `Retry-After` is ignored.
3. **Timeout & Manager:** one shared TLS `Manager` per `runLLMAnthropic`
   invocation, configured with a response timeout; closed over for every
   `Complete` (today it creates `newTlsManager` per call).
4. **Library over hand-rolling:** `retry` owns backoff/jitter/limits; we own only
   the error classification (which is pure and testable).

## New dependency

`retry` (`Control.Retry`). Its only non-boot transitive dependency is `random`,
already present in the workspace lock from the http-client-tls cascade. Add
`retry` to the workspace `[dependencies]` (resolve via `zinc add retry`) and to
the library's `depends` in `zinc.toml`.

## Types & config (`Crucible.LLM.Anthropic`)

```haskell
-- exported
data AnthropicError
  = AnthropicHttpError   HttpException   -- network / connection / timeout
  | AnthropicStatusError Int Text        -- non-2xx: status code + response body
  | AnthropicNoContent   Text            -- 2xx but no text content block (raw body)
  deriving (Show)

instance Exception AnthropicError
```

`AnthropicConfig` gains three fields (existing fields unchanged):

```haskell
data AnthropicConfig = AnthropicConfig
  { acApiKey          :: Text
  , acModel           :: Text
  , acMaxTokens       :: Int
  , acTimeoutSecs     :: Int   -- request timeout      (default 60)
  , acMaxRetries      :: Int   -- transient retries    (default 3)
  , acBaseDelayMicros :: Int   -- backoff base, micros (default 500_000)
  }
```

`defaultAnthropicConfig :: Text -> AnthropicConfig` keeps its signature and sets
`acTimeoutSecs = 60`, `acMaxRetries = 3`, `acBaseDelayMicros = 500_000`.

A module constant caps the backoff, e.g. `maxBackoffMicros = 30_000_000` (30 s).

## Behaviour

**`runLLMAnthropic` / `recordLLMAnthropic`:** build one `Manager` from
`tlsManagerSettings` with `managerResponseTimeout = responseTimeoutMicro
(acTimeoutSecs cfg * 1_000_000)`; pass it (and `cfg`) to the per-call helper.

**Per-`Complete` helper** `anthropicComplete :: AnthropicConfig -> Manager -> [Message] -> IO Text`:

```haskell
recovering
  (capDelay maxBackoffMicros (fullJitterBackoff (acBaseDelayMicros cfg))
     <> limitRetries (acMaxRetries cfg))
  [ \_ -> Handler (\(_ :: HttpException)  -> pure True)
  , \_ -> Handler (\(e :: AnthropicError) -> pure (isRetryable e)) ]
  (\_ -> doRequest)
```

`doRequest :: IO Text`:
1. POST the request (built as today: headers `x-api-key`, `anthropic-version`,
   `content-type`; body = `encode (requestJson cfg msgs)`) via `httpLbs`. A
   network/timeout failure throws `HttpException` (propagates to the handler).
2. http-client's default `checkResponse` does not throw on non-2xx, so inspect
   `statusCode (responseStatus resp)`:
   - `2xx` → `extractText body`: `Right t` → return `t`; `Left _` → throw
     `AnthropicNoContent body`.
   - `429` or `>= 500` → throw `AnthropicStatusError code body` (retryable).
   - any other (4xx) → throw `AnthropicStatusError code body` (permanent).

`isRetryable :: AnthropicError -> Bool`
- `AnthropicStatusError s _ = s == 429 || s >= 500`
- `AnthropicHttpError _`     = `True`   (also caught by the `HttpException` handler before wrapping; kept for completeness)
- `AnthropicNoContent _`     = `False`

After retries are exhausted, `recovering` rethrows the last exception — so the
caller sees a typed `AnthropicError` (or `HttpException`) and can `try` it.

`requestJson`, `extractText`, the headers, and the cassette format are unchanged.
`recordLLMAnthropic` calls the same `anthropicComplete`, so it inherits timeout,
retries, and typed errors automatically.

## Testing

The `retry` combinators are trusted (tested upstream); the IO loop is thin glue.
Pure unit tests cover the only pure policy logic, in `test/Spec.hs`:

- `isRetryable`:
  - `AnthropicStatusError 429 ""` → `True`
  - `AnthropicStatusError 500 ""` → `True`
  - `AnthropicStatusError 503 ""` → `True`
  - `AnthropicStatusError 400 ""` → `False`
  - `AnthropicStatusError 401 ""` → `False`
  - `AnthropicStatusError 404 ""` → `False`
  - `AnthropicNoContent ""`       → `False`

(`isRetryable` is exported for this; `AnthropicError` is exported with its
constructors.)

The live smoke exe (`app/Main.hs`) continues to demonstrate the live path
(record/replay + typed-fn) end-to-end; it builds and links unchanged. The pure
interpreters and the `LLM`/`Function`/`Agent` modules are untouched, so the rest
of the suite stays green.

## Self-review

- **Placeholders:** none.
- **Consistency:** errors are thrown (Decision 1) so `complete :: -> Text` and all
  consumers are unchanged; `recordLLMAnthropic` reuses `anthropicComplete` so it
  inherits the behaviour; `requestJson`/`extractText` unchanged.
- **Scope:** one module + a new dep + pure tests — a single implementation plan.
- **Ambiguity:** "transient" is pinned to network/timeout/429/5xx via
  `isRetryable` + the `HttpException` handler; everything else is permanent.
- **Dependency risk:** `retry` pulls only `random`, already locked — low.
