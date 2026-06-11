# Provider Fallback and Round-Robin Design Spec

**Date:** 2026-06-12
**Status:** Approved design, pending implementation
**Tracker:** `crucible-3sj`.
**Research basis:** `docs/superpowers/research/2026-06-11-baml-review.md` item 1.
**Scope:** new `src/Crucible/LLM/Provider.hs` and `src/Crucible/LLM/Fallback.hs`; `provider` constructors in `src/Crucible/LLM/Anthropic.hs` and `src/Crucible/LLM/OpenAI.hs`; `test/Spec.hs`; `app/Main.hs` (one live fallback proof); `docs/live-interpreter.md`.

## Motivation

A transient provider outage today fails the program once that provider's
internal retry budget exhausts. BAML treats multi-provider resilience as a
client strategy (fallback, round-robin); crucible's equivalent belongs at
the `runEff` edge, where interpreters already live. The key constraint:
fallback must happen PER CALL, not per interpreter, because re-running a
program under a second interpreter would replay every effect already
performed.

## Decisions taken during design

- Scope: both effect paths (`LLM` and `Chat`). Streaming stays
  single-provider (a mid-stream fallback would re-emit deltas).
- Advance policy: after a member's own internal retries give up, advance on
  ANY failure (BAML semantics). A misconfigured member (401) falls through
  to a healthy one; every member error is collected for the terminal
  exception.
- Round-robin ships in this cycle (same list, rotating start index).
- Chain-level retry (re-running the exhausted chain) is an explicit
  non-goal; each member already retried internally.

## Design

### 1. `Crucible.LLM.Provider` (new leaf module)

```haskell
-- | A named provider as a pair of per-call functions. The functions carry
-- the provider's own retry policy (full-jitter backoff per its retryable
-- classification), so member-level behaviour is exactly what the provider
-- does alone. Build with 'Crucible.LLM.Anthropic.provider' or
-- 'Crucible.LLM.OpenAI.provider', or construct directly for stubs and
-- custom strategies.
data Provider = Provider
  { name     :: Text
  , complete :: [Message] -> IO (Text, Usage)
  , converse :: [(ToolName, Value)] -> [Chat.Message] -> IO (Turn, Usage)
  }
```

Imports only shared types (`Crucible.LLM` Message, `Crucible.Chat` Turn and
Message, `Crucible.Tool` ToolName, `Crucible.Usage`). No effect machinery.

### 2. Constructors in the provider modules

```haskell
-- Crucible.LLM.Anthropic
provider :: AnthropicConfig -> IO Provider
-- Crucible.LLM.OpenAI
provider :: OpenAIConfig -> IO Provider
```

Each creates its shared TLS manager once and closes over config + manager,
delegating to the existing private internals (`anthropicCompleteUsage` /
`converseOnce` and the OpenAI twins), which stay private. `name` is
"anthropic" / "openai". Both modules already import everything Provider
needs; the module graph stays acyclic (Provider is beneath both).

### 3. `Crucible.LLM.Fallback` (new module, used qualified)

```haskell
-- | Every member failed. Carries (provider name, rendered error) in the
-- order tried.
newtype FallbackError = FallbackExhausted [(Text, Text)]
  deriving (Eq, Show)
instance Exception FallbackError

run       :: (IOE :> es) => [Provider] -> Eff (LLM  : es) a -> Eff es a
usage     :: (IOE :> es) => [Provider] -> Eff (LLM  : es) a -> Eff es (a, Usage)
runChat   :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es a
usageChat :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es (a, Usage)

roundRobin          :: (IOE :> es) => [Provider] -> Eff (LLM  : es) a -> Eff es a
roundRobinUsage     :: (IOE :> es) => [Provider] -> Eff (LLM  : es) a -> Eff es (a, Usage)
roundRobinChat      :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es a
roundRobinUsageChat :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es (a, Usage)
```

Per-call semantics, shared by all eight:

- Try members starting at index s, in list order, wrapping for round-robin;
  each attempt is `try @SomeException` around the member's function.
- On failure, record `(p.name, T.pack (show e))` and advance to the next
  member.
- If all members fail, `throwIO (FallbackExhausted collected)` with errors
  in the order tried.
- Fallback strategies always start at s = 0. Round-robin keeps an `IORef
  Int` created when the interpreter starts; each CALL takes
  `s = i \`mod\` length ps` and increments i (so consecutive calls start
  one member further along), and a failing member still advances through
  the remaining list, wrapping.
- The empty provider list throws `FallbackExhausted []` on the first call
  (documented; constructing the interpreter does not throw).
- `usage`/`usageChat` accumulate the answering member's `Usage` into a
  running total (reinterpret + State, same shape as the single-provider
  usage interpreters). Non-usage variants discard it.
- A single-member list behaves exactly like that provider alone, except a
  terminal failure arrives wrapped in `FallbackExhausted`.

## Demo (`app/Main.hs`)

One live proof in the Anthropic section's flow (requires both keys, which
the demo already has):

```haskell
      providers <- (\a o -> [a, o])
        <$> Anthropic.provider (defaultAnthropicConfig "junk-key")
        <*> OpenAI.provider ocfg
      fb <- runEff (Fallback.run providers (complete prompt))
      TIO.putStrLn ("fallback: " <> fb <> " (first member cannot succeed; answered by second)")
```

The junk-key member fails fast (401 is non-retryable inside the member;
advance-on-any-failure does the rest) and the real OpenAI member answers.
Cost: one failed HTTP call. Place it inside the OpenAI-key-gated block so
key absence skips it cleanly.

## Manual (`docs/live-interpreter.md`)

A "## Fallback and round-robin" section after the OpenAI section: the
Provider record and both constructors; the eight combinators with one
LLM-path example; semantics in plain terms (member retries first, then
advance on any failure; a misconfigured member falls through rather than
wedging the chain; per-call, never per-program); `FallbackExhausted`
carrying every member's error; the limits: streaming stays single-provider,
cassettes record at the provider level not the chain level, and
"which member answered" observability is tracked separately (the CallLog
work). House style: no emdashes, no hype, no manifest mentions.

## Testing (hermetic; fake providers, no LLM scripting)

Fake providers are plain records:
`Provider "good" (\_ -> pure ("ok", Usage 1 2)) (\_ _ -> pure (Turn "t" [], Usage 3 4))`,
failing fakes throw `userError`, counting fakes bump an `IORef` to record
invocation. Checks (all `runEff`, IO-backed):

- First member answers; second never invoked (counter stays 0).
- First member throws; second answers; result is the second's; first's
  counter is 1.
- Both throw: `try` catches `FallbackExhausted [(n1, e1), (n2, e2)]` with
  names in tried order (Eq-comparable; rendered errors checked by infix).
- `usage` over two calls accumulates Usage (e.g. 1+1 in, 2+2 out).
- Chat path: `runChat`/`usageChat` mirror the first three checks via
  `converse` fakes (use `runToolAgent` or direct `converse` with a canned
  Turn).
- Round-robin rotation: two healthy counting fakes, three sequential
  `complete` calls -> invocation counts (2, 1) and first call answered by
  member 0, second by member 1, third by member 0 again (capture answer
  text per member to assert order).
- Round-robin failure wrap: start index 1 with member 1 throwing -> member
  0 answers (wrapping proven).
- Empty list: first call throws `FallbackExhausted []`.
- Live: the demo fallback line before merge.

## Non-goals

- Chain-level retry of an exhausted provider list.
- Weighted, priority, health-checked, or circuit-breaking strategies
  (custom `Provider` records are the escape hatch).
- Streaming fallback.
- Chain-aware cassette recording (provider-level cassettes are unchanged;
  member-answered observability belongs to the CallLog bead crucible-c11).
