# Crucible: token-usage capture for the live Anthropic path

**Goal.** Surface the token counts Anthropic returns on every response
(`usage.input_tokens` / `usage.output_tokens`) to callers of the live path, and
provide an optional pure cost helper that the caller parameterises with rates.
Fourth of the "productionize the live path" (direction A) sub-projects — the
quick win (robustness and native tool-calling shipped first).

**Why additive accumulator interpreters (not an effect-signature change).** The
`LLM` (`Complete :: [Message] -> LLM m Text`) and `Chat`
(`Converse :: ... -> Chat m Turn`) effect signatures are correct as-is; usage is
a property of the live interpreter's HTTP round-trip, not of the abstract
effect. So usage is surfaced as a *side-output of the live interpreter*: new
opt-in interpreter variants that sum usage across every call and return the
total alongside the result. The existing `runLLMAnthropic` / `runChatAnthropic`
keep their signatures; nothing at the existing call sites breaks.

**Non-goals (YAGNI).** No built-in price table (prices go stale, vary by
tier/cache/batch) — cost is a pure helper the caller feeds rates into. No
per-call (non-accumulated) variant. No usage in the pure/scripted interpreters
(they make no API calls, so there is nothing to report). No cache/batch token
fields yet (only `input_tokens` / `output_tokens`). No streaming usage
(streaming is sub-project A#3).

## Design decisions

1. **Provider-agnostic `Usage` type with a `Monoid`** — the `Monoid` instance
   *is* the accumulation; summing across calls is `<>` / `mconcat`.
2. **Cost as a pure caller-parameterised helper** — `estimateCost :: Rates ->
   Usage -> Double`; rates are per-million-tokens (MTok), matching how Anthropic
   quotes prices. No prices baked into the library.
3. **Accumulator interpreter variants** — `runLLMAnthropicUsage` /
   `runChatAnthropicUsage` return `Eff es (a, Usage)`; existing interpreters
   untouched.
4. **DRY single-round-trip helpers** — each path's one request is factored into
   a helper returning `(payload, Usage)`; both the plain and the usage
   interpreter share it, so the plain path's observable behaviour is unchanged.
5. **Graceful parse** — a response body missing `usage` yields `mempty`, never
   an error (usage is telemetry, not correctness).

## Module layout

- **`Crucible.Usage`** (new, pure, provider-agnostic): `Usage`, its
  `Semigroup`/`Monoid`, `usTotalTokens`, `Rates`, `estimateCost`.
- **`Crucible.LLM.Anthropic`**: add `parseUsage`, the `(payload, Usage)`
  helpers, and the two accumulator interpreters; refactor the existing
  interpreters onto the shared helpers.
- **`app/Main.hs`**: demo printing the summed usage + an example cost.
- **`test/Spec.hs`**: pure checks for `parseUsage`, the `Monoid`, `estimateCost`.

New module is auto-discovered by zinc (no `zinc.toml` change). No new
dependencies — `runState`/`modify` come from the already-imported
`Effectful.State.Static.Local`; parsing uses the in-repo `Crucible.Json`
decoders (`D.int` exists).

## `Crucible.Usage`

```haskell
data Usage = Usage
  { usInputTokens  :: !Int
  , usOutputTokens :: !Int
  }
  deriving (Eq, Show)

instance Semigroup Usage where
  Usage a b <> Usage c d = Usage (a + c) (b + d)

instance Monoid Usage where
  mempty = Usage 0 0

-- | Total tokens billed (input + output).
usTotalTokens :: Usage -> Int
usTotalTokens (Usage i o) = i + o

-- | Per-million-token rates (Anthropic quotes prices per MTok).
data Rates = Rates
  { rInputPerMTok  :: !Double
  , rOutputPerMTok :: !Double
  }

-- | Estimated cost in the rates' currency: tokens / 1e6 * rate, summed.
estimateCost :: Rates -> Usage -> Double
estimateCost (Rates ri ro) (Usage i o) =
  fromIntegral i / 1e6 * ri + fromIntegral o / 1e6 * ro
```

## `Crucible.LLM.Anthropic`: parser, helpers, accumulators

```haskell
-- | Pull usage out of a /v1/messages response body. Missing -> mempty.
parseUsage :: Text -> Usage
parseUsage = either (const mempty) id . D.decodeString
  (D.field "usage" (Usage <$> D.field "input_tokens"  D.int
                          <*> D.field "output_tokens" D.int))

-- | One text round-trip, with usage. POST the messages, extract content[0].text
-- (throwing AnthropicNoContent if absent), and read the usage from the same body.
anthropicCompleteUsage :: AnthropicConfig -> Manager -> [Message] -> IO (Text, Usage)

-- | One chat round-trip, with usage. POST the conversation + tool specs, parse
-- the Turn (throwing AnthropicNoContent if malformed), and read the usage.
converseOnce :: AnthropicConfig -> Manager -> [(ToolName, Schema)] -> [ChatMsg] -> IO (Turn, Usage)

-- Existing interpreters refactored onto the helpers (behaviour unchanged):
--   anthropicComplete cfg mgr msgs = fst <$> anthropicCompleteUsage cfg mgr msgs
--   runChatAnthropic   converse = fst <$> converseOnce ...

-- | Usage-accumulating opt-in variants: reinterpret into a local State Usage,
-- modify (<> u) per call, return the total alongside the result.
runLLMAnthropicUsage  :: (IOE :> es) => AnthropicConfig -> Eff (LLM  : es) a -> Eff es (a, Usage)
runChatAnthropicUsage :: (IOE :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es (a, Usage)
```

Sketch of an accumulator (chat shown; LLM is the same shape):

```haskell
runChatAnthropicUsage cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  reinterpret (runState mempty)
    (\_ (Converse specs msgs) -> do
        (turn, u) <- liftIO (converseOnce cfg mgr specs msgs)
        modify (<> u)
        pure turn)
    action
```

New exports from `Crucible.LLM.Anthropic`: `parseUsage`,
`runLLMAnthropicUsage`, `runChatAnthropicUsage`.

## Testing

Pure/hermetic, in `test/Spec.hs` (no network):

- **parseUsage (present):** a sample body
  `{"content":[...],"usage":{"input_tokens":12,"output_tokens":7}}` →
  `Usage 12 7`.
- **parseUsage (absent):** a body with no `usage` field → `mempty`
  (`Usage 0 0`).
- **Monoid (the accumulation):** `Usage 1 2 <> Usage 3 4 == Usage 4 6`;
  `mempty <> u == u`.
- **estimateCost:** `estimateCost (Rates 3 15) (Usage 1000000 1000000) == 18.0`.

The accumulator wiring (`reinterpret` / `runState` / `modify`) is standard
effectful plumbing bound to live IO; it is exercised end-to-end by the Main demo
rather than a network mock — consistent with the rest of the live path (parsers
tested pure; interpreters exercised in `Main`).

Live: extend `app/Main.hs` to run one call through `runChatAnthropicUsage`,
printing the summed `Usage` and `estimateCost` with illustrative per-MTok rates.

## Self-review

- **Placeholders:** none.
- **Consistency:** `(a, Usage)` return mirrors effectful's `runState` shape;
  `Usage` is a `Monoid` so accumulation needs no bespoke logic; `Rates` units
  (per-MTok) match Anthropic's pricing convention and the test's `18.0`.
- **Scope:** one new pure module + parser + two accumulator interpreters
  (sharing DRY round-trip helpers that also de-duplicate the existing
  interpreters) + tests + demo — one implementation plan.
- **Ambiguity:** "missing usage" is pinned to `mempty`; cost prices are
  explicitly the caller's responsibility; the existing interpreters are
  explicitly untouched in signature and behaviour.
- **Dependency risk:** none — no new external deps.
