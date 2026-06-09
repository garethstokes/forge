# Crucible: SSE streaming for the live Anthropic path

**Goal.** Stream Anthropic responses token-by-token over server-sent events (SSE)
for both the text path (`LLM`/`complete`) and the chat path (`Chat`/`converse`),
delivering deltas as they arrive while still returning the fully-assembled
`Text`/`Turn`, and capturing token `Usage`. Third of the "productionize the live
path" (direction A) sub-projects (robustness, native tool-calling, and
usage-capture shipped first).

**Why a first-class `Emit` effect (not a callback).** The existing `LLM`
(`Complete -> Text`) and `Chat` (`Converse -> Turn`) effects return a complete
value. Streaming needs incremental delivery, but we keep those effects unchanged
and add a *parallel* effect, `Emit`, that yields text deltas. The streaming
interpreters require `(IOE :> es, Emit :> es)` and `emit` each delta; the caller
chooses how to consume deltas (print, collect, ignore) by picking an `Emit`
interpreter. Deltas thus become composable and the existing call surface
(`complete`/`llmFn`/`runAgent`/`converse`/`runToolAgent`) is untouched — you opt
into streaming purely by choosing the interpreter.

**Non-goals (YAGNI).** No change to `LLM`/`Chat`/`Message`/`Turn`/`Block` or any
existing interpreter. No streaming cassettes. No `Emit` on the non-streaming
path. No mid-stream retry/resume (retry covers only the pre-stream open). No SSE
`event:`-line dispatch — we key off each `data` JSON's self-describing `type`
field. No backpressure/cancellation beyond a bracketed `responseClose`.

## Design decisions

1. **`Emit` effect for deltas** — provider-agnostic; `emit :: Text -> Eff es ()`.
   Interpreters: `runEmitIO` (live sink), `ignoreEmit` (discard), `runEmitList`
   (collect, for tests).
2. **Pure SSE core + thin IO loop** — frame splitting, event parsing, and
   accumulation are pure and fully unit-testable; only the byte-reading loop is
   `IO`/`Eff`.
3. **Both interpreters return `(a, Usage)`** — matching the accumulator
   variants; usage is read from the stream's `message_start` (input) and
   `message_delta` (output) events.
4. **Retry pre-stream only** — transient failures (HTTP error, 429, 5xx) before
   any byte is emitted reopen the response; once streaming begins, errors
   propagate (no double-emit). The existing response timeout governs
   time-to-headers, which streaming respects.
5. **Byte-level frame buffering** — the read buffer is a strict `ByteString`;
   complete frames (delimited by a blank line `\n\n`) are split off the buffer
   and only then UTF-8-decoded, so a multibyte character split across two
   network chunks is never mis-decoded.

## Module layout

- **`Crucible.Emit`** (new) — the `Emit` effect + three interpreters.
- **`Crucible.LLM.Anthropic.Stream`** (new) — Anthropic SSE: `StreamEvent`,
  `splitFrames`, `parseEvent`, `StreamAcc`/`stepAcc`, `openStream`, and the two
  streaming interpreters. A separate module keeps `Anthropic.hs` focused.
- **`Crucible.LLM.Anthropic`** — export the helpers `Stream` reuses
  (`newAnthropicManager`, `requestJson`); `AnthropicConfig`/`AnthropicError`/
  `isRetryable`/`parseUsage`/`chatRequestJson` are already exported. No
  behaviour change.
- **`app/Main.hs`**, **`test/Spec.hs`** — live demo + pure checks.

New modules are auto-discovered by zinc. No new external dependencies: the
streaming primitives (`responseOpen`/`responseClose`/`brRead`) are in the already
-vendored `http-client`; strict `Data.ByteString` is already a (transitive)
dependency used by `Anthropic.hs`. (The plan verifies `bytestring` is in the lib
`depends`; add it only if a build error demands it.)

## `Crucible.Emit`

```haskell
data Emit :: Effect where
  Emit :: Text -> Emit m ()
type instance DispatchOf Emit = Dynamic

emit :: (Emit :> es) => Text -> Eff es ()
emit = send . Emit

-- | Run each delta through an IO sink (e.g. @putStr . T.unpack@).
runEmitIO :: (IOE :> es) => (Text -> IO ()) -> Eff (Emit : es) a -> Eff es a

-- | Discard all deltas (the result is still fully assembled by the streamer).
ignoreEmit :: Eff (Emit : es) a -> Eff es a

-- | Collect deltas in arrival order alongside the result (for tests).
runEmitList :: Eff (Emit : es) a -> Eff es (a, [Text])
```

`runEmitList` accumulates via a local `State [Text]` (snoc, or prepend then
reverse) so the returned list is in emit order.

## Anthropic SSE shapes (reference)

A `stream:true` request yields `text/event-stream`. Each event is a frame ending
in a blank line; the line of interest is `data: {json}`. We dispatch on the JSON's
`type`:

- `message_start` → `message.usage.input_tokens` (→ `EvUsageIn`)
- `content_block_start` with `content_block.type == "tool_use"` →
  `index`, `content_block.id`, `content_block.name` (→ `EvToolStart`)
- `content_block_delta` with `delta.type == "text_delta"` → `delta.text`
  (→ `EvText`)
- `content_block_delta` with `delta.type == "input_json_delta"` →
  `delta.partial_json` at `index` (→ `EvToolJson`)
- `content_block_stop` → `index` (→ `EvBlockStop`)
- `message_delta` → `usage.output_tokens` (→ `EvUsageOut`)
- anything else (`ping`, `message_stop`, text `content_block_start`) → `EvOther`

`message_delta.usage.output_tokens` is the cumulative output count; `EvUsageOut`
*sets* (not adds) the output field. `EvUsageIn` sets the input field.

## `Crucible.LLM.Anthropic.Stream`

### Pure core

```haskell
data StreamEvent
  = EvText      Text                       -- a text delta
  | EvToolStart Int ToolUseId ToolName     -- tool_use block opened at index
  | EvToolJson  Int Text                   -- partial-JSON fragment for index
  | EvBlockStop Int
  | EvUsageIn   Int
  | EvUsageOut  Int
  | EvOther
  deriving (Eq, Show)

-- | Split complete SSE frames (blank-line-delimited) off the buffer; return the
-- frames and the unconsumed remainder. No blank line yet -> ([], wholeBuffer).
splitFrames :: ByteString -> ([ByteString], ByteString)

-- | Parse one frame's @data:@ payload into a 'StreamEvent' (decoding the JSON
-- and dispatching on its @type@). A frame without a usable @data:@ JSON, or an
-- unrecognised type, is 'EvOther'.
parseEvent :: ByteString -> StreamEvent

-- | Running accumulation across a stream.
data StreamAcc = StreamAcc
  { saText    :: Text                 -- concatenated text deltas
  , saPartial :: [(Int, PartialTool)] -- in-progress tool_use blocks by index
  , saTools   :: [ToolUse]            -- completed tool_uses, in index order
  , saUsage   :: Usage
  }

data PartialTool = PartialTool ToolUseId ToolName Text  -- id, name, accumulated JSON

emptyAcc :: StreamAcc            -- StreamAcc "" [] [] mempty

-- | Fold one event into the accumulator. On EvText, append to saText. On
-- EvToolStart, open a PartialTool. On EvToolJson, append the fragment. On
-- EvBlockStop, if a PartialTool exists at that index, parse its accumulated JSON
-- (mempty/JObject [] on parse failure) into 'tuArgs' and move it to saTools. On
-- EvUsageIn/EvUsageOut, set the usage field. EvOther is identity.
stepAcc :: StreamAcc -> StreamEvent -> StreamAcc
```

`saText` is projected to the LLM result; `Turn saText saTools` to the Chat
result; `saUsage` is returned by both. Emitting happens in the IO loop (on
`EvText`), not from the pure fold.

### IO loop + interpreters

```haskell
-- | Open a stream:true POST with retry on transient PRE-stream failure. Retries
-- 'responseOpen' + status check (consuming+closing the body and throwing a
-- retryable 'AnthropicStatusError' on non-2xx); returns the live 2xx response
-- (caller must stream + close it). Nothing is emitted before this returns.
openStream :: AnthropicConfig -> Manager -> Value -> IO (Response BodyReader)

runLLMAnthropicStream
  :: (IOE :> es, Emit :> es)
  => AnthropicConfig -> Eff (LLM : es) a -> Eff es (a, Usage)

runChatAnthropicStream
  :: (IOE :> es, Emit :> es)
  => AnthropicConfig -> Eff (Chat : es) a -> Eff es (a, Usage)
```

Both build one shared `Manager`, then `reinterpret (runState mempty)` over a
`State Usage`. Per operation:

1. Build the request via `requestJson`/`chatRequestJson`, add `("stream", JBool
   True)` (helper `addStream :: Value -> Value`).
2. `resp <- liftIO (openStream cfg mgr body)`.
3. Stream-read loop in `Eff` (bracketed so `responseClose` always runs): keep a
   `ByteString` buffer; repeatedly `liftIO (brRead (responseBody resp))`; append;
   `splitFrames`; for each frame `parseEvent` → `stepAcc`, and on `EvText t`
   `emit t`; stop when `brRead` returns empty (EOF), then process any final
   buffered frame. Result: the final `StreamAcc`.
4. `modify (<> saUsage acc)`; return `saText acc` (LLM) or
   `Turn (saText acc) (saTools acc)` (Chat).

The loop is shared between the two interpreters, parameterised only by the
request body and the projection of `StreamAcc` to the operation's return type.

## Testing

Pure/hermetic, in `test/Spec.hs`:

- **splitFrames:** a buffer `"data: {..A..}\n\ndata: {..B..}\n\ndata: {..par"`
  → `(["data: {..A..}", "data: {..B..}"], "data: {..par")`; a buffer with no
  `\n\n` → `([], buffer)`.
- **parseEvent:** a `content_block_delta`/`text_delta` frame → `EvText "Hello"`;
  `message_start` → `EvUsageIn 25`; `message_delta` → `EvUsageOut 7`;
  `content_block_start`/`tool_use` → `EvToolStart 0 "tu_1" "get_weather"`;
  `input_json_delta` → `EvToolJson 0 "{\"city\":"`; unknown → `EvOther`.
- **stepAcc text stream:** fold `[EvUsageIn 25, EvText "Hel", EvText "lo",
  EvUsageOut 2]` from `emptyAcc` → `saText == "Hello"`, `saUsage == Usage 25 2`.
- **stepAcc tool stream:** fold `[EvToolStart 0 "tu_1" "get_weather",
  EvToolJson 0 "{\"city\":", EvToolJson 0 "\"Brisbane\"}", EvBlockStop 0]`
  → `saTools == [ToolUse "tu_1" "get_weather" (JObject [("city", JString
  "Brisbane")])]`.
- **Emit:** `runPureEff (runEmitList (emit "a" >> emit "b"))` → `((), ["a","b"])`;
  `ignoreEmit` discards (result preserved).
- **Keystone (full body):** a recorded Anthropic SSE body (a `ByteString`
  literal) for both a text response and a tool-use response, run through
  `splitFrames`→`parseEvent`→`stepAcc`, asserting the final `saText`/`saTools`/
  `saUsage`. (The streaming IO loop and `openStream` are exercised by the live
  demo — consistent with how the rest of the live path is tested.)

Live demo (`app/Main.hs`): one streaming completion via
`runEmitIO (putStr . T.unpack)` so tokens print as they arrive (then a newline),
then a streaming tool-agent; print the captured `Usage` after each.

## Self-review

- **Placeholders:** none.
- **Consistency:** `(a, Usage)` return mirrors the accumulator variants and
  effectful's `runState` shape; `Turn`/`ToolUse` reused from `Crucible.Chat`;
  `ToolName` from `Crucible.Tool`; `Usage` from `Crucible.Usage`; `Value`/`JObject`
  from `Crucible.Json`. `emit`/`Emit` mirror `complete`/`LLM`'s effect idiom.
- **Scope:** two new modules + helper exports + demo + tests. Larger than prior
  sub-projects (≈7–8 plan tasks) but one coherent capability (SSE streaming), so
  one spec/plan. The pure SSE core is isolated and independently testable.
- **Ambiguity:** retry is pinned to pre-stream-only; usage `output_tokens` is a
  set (cumulative), not an add; frame buffering is byte-level; the `Emit` effect
  is the sole delta channel and the `LLM`/`Chat` effects are explicitly unchanged.
- **Dependency risk:** none — http-client streaming primitives and `bytestring`
  are already available; no new deps.
