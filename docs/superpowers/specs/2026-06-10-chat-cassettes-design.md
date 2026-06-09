# Crucible: chat cassettes (record/replay for native tool-calling)

**Goal.** Record a live native-tool-calling conversation to a cassette file and
replay it deterministically with no network, so tool-loop conversations run
hermetically in tests/CI (`crucible-dak`). This is the `Chat` analogue of the
existing `LLM` cassettes (`recordLLMAnthropic`/`runLLMCassette`).

**Why mirror the LLM cassettes.** The text path already has a record→replay
"slider" between a live eval and a hermetic test; the chat path lacked it (a
deferred non-goal from the native-tool-calling spec). A `Turn` (text +
`tool_use`s) is richer than a text reply, but it already has wire encoders
(`blockJson`) and a decoder (`parseTurn`), so the cassette reuses them.

**Non-goals (YAGNI).** No usage capture on replay (`runChatCassette` returns
`a`, mirroring `runLLMCassette` — usage is a live concern). No streaming
cassette variant. No bespoke cassette schema — the cassette stores the API
content shape (`{"content":[…]}`), one Turn per line, so it round-trips through
the existing `parseTurn`.

## Design decisions

1. **Reuse the API content shape** — a recorded Turn is
   `{"content": [<text block?>, <tool_use blocks…>]}`, built with the existing
   `blockJson`, decoded with the existing `parseTurn`. No new codec.
2. **One Turn per line, append order** — exactly like the LLM cassette's one
   reply per line; replay pops them in call order.
3. **Replay mirrors `runChatScripted`** — a file-backed canned-Turn interpreter;
   an exhausted cassette yields `Turn "" []` (so a tool loop terminates).

## Components (all in `Crucible.LLM.Anthropic`)

### `turnContentJson` (exported, for testing + recording)

```haskell
-- | Encode a 'Turn' to the Anthropic content shape, reusing 'blockJson'.
-- Round-trips: @parseTurn (encode (turnContentJson t)) == Right t@.
turnContentJson :: Turn -> Value
turnContentJson (Turn t uses) =
  JObject [("content", JArray (map blockJson blocks))]
  where
    blocks = [TextBlock t | not (T.null t)] ++ map ToolUseBlock uses
```

Round-trip holds because `parseTurn` concatenates `text` blocks into `turnText`
(a single emitted text block reproduces it) and collects `tool_use` blocks into
`turnToolUses` (order preserved). An empty `turnText` emits no text block and
decodes back to `""`.

### `recordChatAnthropic` (exported)

```haskell
-- | Like 'runChatAnthropic', but also TEE each assistant 'Turn' to a cassette
-- file (one content-JSON line, appended in call order). Replays via
-- 'runChatCassette'.
recordChatAnthropic :: (IOE :> es) => FilePath -> AnthropicConfig -> Eff (Chat : es) a -> Eff es a
```

Builds one shared `Manager` up front (as `runChatAnthropic` does); each
`Converse specs msgs` calls the shared `converseOnce cfg mgr specs msgs` (taking
its `fst` — the `Turn`), appends `encode (turnContentJson turn) <> "\n"` to the
cassette, and returns the turn.

### `runChatCassette` (exported)

```haskell
-- | Replay a cassette recorded by 'recordChatAnthropic': each 'Converse' pops
-- the next recorded 'Turn' in order (a file-backed 'runChatScripted').
-- Deterministic; no network. Exhausting the cassette yields @Turn "" []@.
runChatCassette :: (IOE :> es) => FilePath -> Eff (Chat : es) a -> Eff es a
```

Reads the file, decodes each non-blank line via `parseTurn` (a line that fails
to parse falls back to `Turn "" []`), and pops the resulting `[Turn]` in order
through a local `State [Turn]` — structurally identical to `runLLMCassette` /
`runChatScripted`.

## Testing

Pure, in `test/Spec.hs`:
- **Round-trip:** `parseTurn (encode (turnContentJson t))` is `Right t` for
  (a) a Turn with text + a tool_use, (b) text-only, (c) tool_use-only.

Hermetic replay (an `IO Bool` element of the `runChecks` list — writes a temp
file, no network):
- Write a cassette with two lines via `turnContentJson`: a tool-use turn
  `Turn "" [ToolUse "u1" "get_weather" (JObject [("city", JString "Brisbane")])]`
  then a text turn `Turn "Sunny in Brisbane!" []`. Run
  `runEff (runChatCassette path (runToolAgent [weatherTool] "weather in Brisbane?"))`
  → `Right "Sunny in Brisbane!"`. This proves replay drives a full tool loop:
  the first popped turn triggers the tool, its result is fed back, and the
  second popped turn is the final text answer. (`weatherTool` is a local fixture
  whose `toolRun` returns a `Value`; the temp path is e.g.
  `/tmp/crucible-chat-cassette-test.jsonl`.)

Live demo (`app/Main.hs`, parity with the LLM cassette): record a live
tool-agent run to a cassette via `recordChatAnthropic`, replay it via
`runChatCassette`, and assert the replayed answer matches the live one.

No new external dependencies (`Data.Text.IO` append/read already used by the LLM
cassette; `parseTurn`/`blockJson`/`converseOnce` already in the module).

## Self-review

- **Placeholders:** none.
- **Consistency:** `recordChatAnthropic`/`runChatCassette` mirror
  `recordLLMAnthropic`/`runLLMCassette` in signature and structure; the cassette
  line format (`encode (turnContentJson turn)`) is decoded by the same
  `parseTurn` the live path uses; replay's exhaustion sentinel (`Turn "" []`)
  matches `runChatScripted`.
- **Scope:** one encoder helper + two interpreters + tests + a demo — one small
  plan.
- **Ambiguity:** cassette format is pinned to the API content shape; replay is
  Turn-only (no usage); an unparseable line degrades to an empty Turn (not an
  error), matching the cassette's "best-effort replay" intent.
- **Dependency risk:** none.
