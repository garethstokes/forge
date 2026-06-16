# Crucible: streaming idle-timeout guard

**Goal.** Bound the wait for the next chunk during an active SSE stream, so a
server that returns 2xx headers and then stalls aborts with a typed error
instead of hanging forever (`crucible-mgs`).

**Why.** The TLS manager's `responseTimeout` governs *time-to-headers*
(`openStream` succeeds once headers arrive); it does not bound the per-chunk
read in `streamLoop`. A stalled mid-stream connection would block indefinitely.
This adds a per-read idle timeout — distinct from the existing `acTimeoutSecs`
request timeout.

**Non-goals (YAGNI).** No mid-stream retry/resume (a timeout propagates, as with
any post-open streaming error). No total-stream deadline (only inter-chunk
idle). No change to the blocking path or `acTimeoutSecs`.

## Design decisions

1. **Dedicated config knob** — `acStreamIdleSecs :: Int` on `AnthropicConfig`,
   default `60`. Inter-chunk idle is conceptually distinct from time-to-headers,
   so it is independently tunable.
2. **Typed error** — `AnthropicStreamTimeout Int` (idle window in
   **microseconds**, matching the `…Micros` convention), added to
   `AnthropicError`. `isRetryable` returns `False` for it: the timeout fires
   inside `streamLoop`, past the pre-stream retry boundary, so it propagates
   (consistent with "no mid-stream retry").
3. **`timeout`-wrapped read** — each `brRead` is wrapped in
   `System.Timeout.timeout`; a non-positive window disables the guard (escape
   hatch for slow models / very large `max_tokens`).

## Components

### `Crucible.LLM.Anthropic`
- Add `acStreamIdleSecs :: Int` to the `AnthropicConfig` record; set it to `60`
  in `defaultAnthropicConfig`. (`defaultAnthropicConfig` is the only constructor
  of `AnthropicConfig`; no other literal needs updating.)
- Add `AnthropicStreamTimeout Int` to `AnthropicError`; add
  `isRetryable (AnthropicStreamTimeout _) = False`.

### `Crucible.LLM.Anthropic.Stream`
```haskell
-- | Read one chunk, bounding the wait by @micros@. A non-positive @micros@
-- disables the guard. On timeout, throw 'AnthropicStreamTimeout'.
timedRead :: Int -> IO ByteString -> IO ByteString
timedRead micros readChunk
  | micros <= 0 = readChunk
  | otherwise   = timeout micros readChunk >>=
                    maybe (throwIO (AnthropicStreamTimeout micros)) pure
```
`timedRead` is exported (for testing). `streamLoop` gains a leading `Int`
idle-micros parameter and reads via `timedRead idleMicros (brRead br)` in place
of the bare `brRead br`; nothing else in the loop changes. Both interpreters
(`runLLMAnthropicStream`, `runChatAnthropicStream`) compute
`idleMicros = acStreamIdleSecs cfg * 1000000` and pass it to `streamLoop`.

New imports in `Stream.hs`: `System.Timeout (timeout)`; add
`AnthropicStreamTimeout` via the existing `AnthropicError (..)` import (already
imports all constructors); add `acStreamIdleSecs` via the existing
`AnthropicConfig (..)` import.

## Error handling

A mid-stream idle timeout throws `AnthropicStreamTimeout idleMicros` from
`timedRead`, which propagates out of `streamLoop`; the surrounding `bracket`
still runs `responseClose` on the open response. Because the timeout is past the
`openStream` retry boundary and partial deltas may already have been emitted, it
is not retried (`isRetryable` = `False`).

## Testing

Hermetic and fast, in `test/Spec.hs` (each list element is an `IO Bool` that may
do IO before calling `check`; `AnthropicError` has no `Eq` because
`HttpException` is not `Eq`, so the timeout case is checked by pattern-match):

- **fast read passes through:** `timedRead 200000 (pure "hi")` → `"hi"`.
- **idle timeout fires:** `timedRead 1000 (threadDelay 50000 >> pure "x")` →
  `Left (AnthropicStreamTimeout 1000)`, asserted as
  `(case r of Left (AnthropicStreamTimeout n) -> Just n; _ -> Nothing) == Just 1000`
  after `try`. (1 ms window vs a 50 ms read.)
- **guard disabled:** `timedRead 0 (pure "x")` → `"x"`.

`streamLoop` itself stays verified by the existing live streaming demo, which
runs well within the idle window. No new external dependencies (`System.Timeout`
and `Control.Concurrent` are in `base`).

## Self-review

- **Placeholders:** none.
- **Consistency:** `acStreamIdleSecs` (seconds) → `idleMicros = * 1000000`
  threaded into `streamLoop`/`timedRead` (micros); `AnthropicStreamTimeout`
  carries micros, matching the error message and the test's `1000`. `isRetryable`
  stays total (new case added).
- **Scope:** one config field + one error constructor + one IO helper + a
  one-line `streamLoop` change + three unit tests. One small plan.
- **Ambiguity:** the window is inter-chunk idle (reset each read), not a total
  deadline; non-positive disables; timeout is non-retryable and propagates past
  a bracketed close.
- **Dependency risk:** none — `base` only.
