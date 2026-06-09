# Token-Usage Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture Anthropic's per-response token counts and surface the summed total to callers of the live path, with an optional pure cost helper.

**Architecture:** A new pure `Crucible.Usage` module (`Usage` Monoid + `estimateCost`). The live Anthropic interpreters gain a `parseUsage` reader over the response body they already fetch, DRY round-trip helpers returning `(payload, Usage)`, and additive opt-in accumulator interpreters (`runLLMAnthropicUsage` / `runChatAnthropicUsage`) that sum usage into a local `State Usage` and return `(a, Usage)`. Existing interpreters keep their signatures and behaviour.

**Tech Stack:** Haskell, GHC 9.6.5, `effectful` (`reinterpret`, `Effectful.State.Static.Local`: `runState`/`modify`), in-repo `Crucible.Json` decoders (`D.int`, `D.field`, `D.decodeString`). Build/test via `nix develop . --command zinc {build,test}`. No new dependencies.

---

## Background for the implementer

- **Spec:** `docs/superpowers/specs/2026-06-09-usage-capture-design.md`.
- **Test harness:** `test/Harness.hs` exports `check :: (Eq a, Show a) => String -> a -> a -> IO Bool` and `runChecks :: [IO Bool] -> IO ()`. Tests live in `test/Spec.hs` as a list literal passed to `runChecks` in `main`. To add a test you add a `check "name" expected actual` element to that list. The whole suite runs with `nix develop . --command zinc test`; a pass prints `ALL PASS` and `1 test suite(s) passed`, a failure prints `FAILURES`.
- **There is no per-test runner** — you run the full suite each time. "Verify it fails" means: add the `check`/import, run `zinc test`, and observe a *build* failure (undefined name) or a `FAIL <name>` line.
- **Anthropic response shape:** every `/v1/messages` 2xx body has a top-level `usage` object, e.g. `{"content":[...],"usage":{"input_tokens":12,"output_tokens":7}}`.
- **Decoders available** (`src/Crucible/Json/Decode.hs`): `int :: Decoder Int`, `field :: Text -> Decoder a -> Decoder a`, `decodeString :: Decoder a -> Text -> Either Error a`, and `Decoder` is `Applicative`.
- **Do NOT edit `zinc.toml`** — library modules under `src/` are auto-discovered; a new `src/Crucible/Usage.hs` needs no manifest entry, and no new dependency is required.
- **Commit message footer:** end every commit body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File structure

- **Create `src/Crucible/Usage.hs`** — pure, provider-agnostic: `Usage(..)`, `Semigroup`/`Monoid Usage`, `usTotalTokens`, `Rates(..)`, `estimateCost`. (Task 1)
- **Modify `src/Crucible/LLM/Anthropic.hs`** — add `parseUsage` (Task 2); add `anthropicCompleteUsage` / `converseOnce` helpers, refactor `anthropicComplete` / `runChatAnthropic` onto them, add `runLLMAnthropicUsage` / `runChatAnthropicUsage`, extend exports/imports (Task 3). (Task 2)
- **Modify `app/Main.hs`** — run the tool-agent demo through `runChatAnthropicUsage`, print summed usage + an example cost. (Task 4)
- **Modify `test/Spec.hs`** — pure checks for `Usage`/`estimateCost` (Task 1) and `parseUsage` (Task 2).

---

### Task 1: `Crucible.Usage` — pure type, Monoid, cost helper

**Files:**
- Create: `src/Crucible/Usage.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Write the failing tests**

In `test/Spec.hs`, add this import alongside the other `Crucible.*` imports (near line 18):

```haskell
import Crucible.Usage (Usage(..), usTotalTokens, Rates(..), estimateCost)
```

Then add these `check`s to the `runChecks [ ... ]` list in `main` (place them at the end of the list, immediately before the closing `]`; prefix the first one with a leading comma as the list requires):

```haskell
  -- A#4: Usage Monoid + cost helper
  , check "usage: semigroup sums fields"
      (Usage 4 6)
      (Usage 1 2 <> Usage 3 4)
  , check "usage: mempty is identity"
      (Usage 5 9)
      (mempty <> Usage 5 9)
  , check "usage: total tokens"
      (14 :: Int)
      (usTotalTokens (Usage 5 9))
  , check "estimateCost: per-MTok rates"
      (18.0 :: Double)
      (estimateCost (Rates 3 15) (Usage 1000000 1000000))
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `nix develop . --command zinc test`
Expected: build failure — `Could not find module 'Crucible.Usage'` (the module does not exist yet).

- [ ] **Step 3: Create the module**

Create `src/Crucible/Usage.hs`:

```haskell
-- | Provider-agnostic token-usage accounting for the live LLM path.
--
-- 'Usage' is a 'Monoid' whose '<>' sums token counts, so accumulating usage
-- across many API calls is just '<>' / 'mconcat'. 'estimateCost' is a pure
-- helper the caller parameterises with 'Rates' — no prices are baked in here,
-- because they go stale and vary by tier/cache/batch.
module Crucible.Usage
  ( Usage (..)
  , usTotalTokens
  , Rates (..)
  , estimateCost
  ) where

-- | Input and output token counts from a single response, or summed across many.
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

-- | Per-million-token rates. Anthropic quotes prices per MTok, so these are
-- "dollars (or any unit) per 1,000,000 tokens".
data Rates = Rates
  { rInputPerMTok  :: !Double
  , rOutputPerMTok :: !Double
  }

-- | Estimated cost in the rates' currency: each token count divided by one
-- million, multiplied by its rate, summed.
estimateCost :: Rates -> Usage -> Double
estimateCost (Rates ri ro) (Usage i o) =
  fromIntegral i / 1e6 * ri + fromIntegral o / 1e6 * ro
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `nix develop . --command zinc test`
Expected: `ok   usage: semigroup sums fields`, `ok usage: mempty is identity`, `ok usage: total tokens`, `ok estimateCost: per-MTok rates`, then `ALL PASS` / `1 test suite(s) passed`.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Usage.hs test/Spec.hs
git commit -m "$(printf 'feat(usage): Usage Monoid + estimateCost helper\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: `parseUsage` — read usage from a response body

**Files:**
- Modify: `src/Crucible/LLM/Anthropic.hs` (exports near lines 20-31; imports; new function)
- Test: `test/Spec.hs`

- [ ] **Step 1: Write the failing tests**

In `test/Spec.hs`, extend the existing `Crucible.LLM.Anthropic` import (line 32) to add `parseUsage`:

```haskell
import Crucible.LLM.Anthropic (AnthropicError(..), isRetryable, defaultAnthropicConfig, chatRequestJson, parseTurn, parseUsage)
```

Add these `check`s to the `runChecks` list (end of the list, before the closing `]`):

```haskell
  -- A#4: parseUsage
  , check "parseUsage: reads input/output tokens"
      (Usage 12 7)
      (parseUsage "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"usage\":{\"input_tokens\":12,\"output_tokens\":7}}")
  , check "parseUsage: missing usage -> mempty"
      (mempty :: Usage)
      (parseUsage "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}")
```

(`Usage` is already imported via Task 1's import line.)

- [ ] **Step 2: Run the suite to verify it fails**

Run: `nix develop . --command zinc test`
Expected: build failure — `Variable not in scope: parseUsage` (or `Module 'Crucible.LLM.Anthropic' does not export 'parseUsage'`).

- [ ] **Step 3: Implement `parseUsage`**

In `src/Crucible/LLM/Anthropic.hs`:

(a) Add the import for the `Usage` type. Place it with the other `Crucible.*` imports (e.g. after the `Crucible.Tool` import near line 72):

```haskell
import Crucible.Usage (Usage (..))
```

(b) Add `parseUsage` to the module export list (the `( ... ) where` block at lines 20-31). Add it after `parseTurn`:

```haskell
  , parseTurn
  , parseUsage
  , runChatAnthropic
```

(c) Add the function definition. Place it directly after `parseTurn`'s definition (after the `rblock` decoder block, end of file is fine):

```haskell
-- | Read the @usage@ object from a /v1/messages response body. A body without
-- a well-formed @usage@ yields 'mempty' — usage is telemetry, not correctness.
parseUsage :: Text -> Usage
parseUsage =
  either (const mempty) id
    . D.decodeString
        (D.field "usage"
          (Usage <$> D.field "input_tokens"  D.int
                 <*> D.field "output_tokens" D.int))
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `nix develop . --command zinc test`
Expected: `ok   parseUsage: reads input/output tokens`, `ok parseUsage: missing usage -> mempty`, then `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/LLM/Anthropic.hs test/Spec.hs
git commit -m "$(printf 'feat(usage): parseUsage reads token counts from response body\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: Accumulator interpreters (DRY refactor)

This task is a behaviour-preserving refactor plus two additive interpreters. There is no new pure unit test (the accumulators are bound to live IO/network); the verification is that **the build succeeds and the existing suite stays green** (proving the refactor preserved behaviour), and the new interpreters typecheck. Task 4 exercises them end-to-end.

**Files:**
- Modify: `src/Crucible/LLM/Anthropic.hs`

- [ ] **Step 1: Extend the State import**

In `src/Crucible/LLM/Anthropic.hs`, the current line (43) is:

```haskell
import Effectful.State.Static.Local (evalState, get, put)
```

Replace it with:

```haskell
import Effectful.State.Static.Local (evalState, get, modify, put, runState)
```

- [ ] **Step 2: Add the DRY round-trip helpers**

Still in `Anthropic.hs`, add a usage-aware text helper and refactor `anthropicComplete` onto it. Replace the existing `anthropicComplete` definition (currently lines ~220-223):

```haskell
-- | One text round-trip: POST the messages, then extract @content[0].text@; a
-- 2xx body without that shape throws 'AnthropicNoContent'.
anthropicComplete :: AnthropicConfig -> Manager -> [Message] -> IO Text
anthropicComplete cfg mgr msgs = do
  body <- postMessages cfg mgr (requestJson cfg msgs)
  either (\_ -> throwIO (AnthropicNoContent body)) pure (extractText body)
```

with:

```haskell
-- | One text round-trip, with usage: POST the messages, extract
-- @content[0].text@ (throwing 'AnthropicNoContent' if absent), and read the
-- usage from the same body.
anthropicCompleteUsage :: AnthropicConfig -> Manager -> [Message] -> IO (Text, Usage)
anthropicCompleteUsage cfg mgr msgs = do
  body <- postMessages cfg mgr (requestJson cfg msgs)
  text <- either (\_ -> throwIO (AnthropicNoContent body)) pure (extractText body)
  pure (text, parseUsage body)

-- | One text round-trip, discarding usage (the original behaviour).
anthropicComplete :: AnthropicConfig -> Manager -> [Message] -> IO Text
anthropicComplete cfg mgr msgs = fst <$> anthropicCompleteUsage cfg mgr msgs
```

- [ ] **Step 3: Add the chat round-trip helper and refactor `runChatAnthropic`**

Add a `converseOnce` helper and route the existing `runChatAnthropic` through it. Replace the current `runChatAnthropic` definition (lines ~175-182):

```haskell
runChatAnthropic :: (IOE :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es a
runChatAnthropic cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Converse specs msgs) -> liftIO $ do
        body <- postMessages cfg mgr (chatRequestJson cfg specs msgs)
        either (\_ -> throwIO (AnthropicNoContent body)) pure (parseTurn body))
    action
```

with:

```haskell
-- | One chat round-trip, with usage: POST the conversation + tool specs, parse
-- the assistant 'Turn' (throwing 'AnthropicNoContent' if malformed), and read
-- the usage from the same body.
converseOnce :: AnthropicConfig -> Manager -> [(ToolName, Schema)] -> [ChatMsg] -> IO (Turn, Usage)
converseOnce cfg mgr specs msgs = do
  body <- postMessages cfg mgr (chatRequestJson cfg specs msgs)
  turn <- either (\_ -> throwIO (AnthropicNoContent body)) pure (parseTurn body)
  pure (turn, parseUsage body)

runChatAnthropic :: (IOE :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es a
runChatAnthropic cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Converse specs msgs) -> liftIO (fst <$> converseOnce cfg mgr specs msgs))
    action
```

- [ ] **Step 4: Add the two accumulator interpreters**

Add these directly after `runChatAnthropic`:

```haskell
-- | Like 'runLLMAnthropic', but sum the token usage across every 'Complete' and
-- return the total alongside the result. Additive opt-in; the underlying API
-- calls are identical to 'runLLMAnthropic'.
runLLMAnthropicUsage :: (IOE :> es) => AnthropicConfig -> Eff (LLM : es) a -> Eff es (a, Usage)
runLLMAnthropicUsage cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  reinterpret (runState mempty)
    (\_ (Complete msgs) -> do
        (text, u) <- liftIO (anthropicCompleteUsage cfg mgr msgs)
        modify (<> u)
        pure text)
    action

-- | Like 'runChatAnthropic', but sum the token usage across every 'Converse'
-- (e.g. each step of a 'runToolAgent' loop) and return the total alongside the
-- result. Additive opt-in.
runChatAnthropicUsage :: (IOE :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es (a, Usage)
runChatAnthropicUsage cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  reinterpret (runState mempty)
    (\_ (Converse specs msgs) -> do
        (turn, u) <- liftIO (converseOnce cfg mgr specs msgs)
        modify (<> u)
        pure turn)
    action
```

- [ ] **Step 5: Export the new interpreters**

Add both to the module export list (the `( ... ) where` block). Place them after `runChatAnthropic`:

```haskell
  , runChatAnthropic
  , runLLMAnthropicUsage
  , runChatAnthropicUsage
```

- [ ] **Step 6: Build and run the full suite**

Run: `nix develop . --command zinc build`
Expected: exit 0, no errors.

Run: `nix develop . --command zinc test`
Expected: `ALL PASS` / `1 test suite(s) passed` — every pre-existing check (including the Task 1/2 usage checks) still passes, proving the `anthropicComplete` / `runChatAnthropic` refactor is behaviour-preserving.

- [ ] **Step 7: Commit**

```bash
git add src/Crucible/LLM/Anthropic.hs
git commit -m "$(printf 'feat(usage): accumulator interpreters runLLMAnthropicUsage/runChatAnthropicUsage\n\nDRY round-trip helpers (anthropicCompleteUsage/converseOnce) shared with the\nexisting interpreters; behaviour of runLLMAnthropic/runChatAnthropic unchanged.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 4: Live demo — print summed usage + example cost

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add imports**

In `app/Main.hs`, add `runChatAnthropicUsage` to the existing `Crucible.LLM.Anthropic` import block (which currently lists `runChatAnthropic` near line 24):

```haskell
  , runChatAnthropic
  , runChatAnthropicUsage
```

And add a new import for the usage helpers (place with the other `Crucible.*` imports, e.g. after the `Crucible.Chat` import near line 31):

```haskell
import Crucible.Usage (Usage (..), usTotalTokens, Rates (..), estimateCost)
```

- [ ] **Step 2: Switch the tool-agent demo to the usage interpreter**

In `app/Main.hs`, replace the final tool-agent block (currently lines ~64-69):

```haskell
      let weatherTool = Tl.Tool "get_weather" (SObj [("city", SStr)])
            (\_ -> pure (JString "It is 26C and sunny."))
      toolAns <- runEff (runChatAnthropic cfg (runToolAgent [weatherTool] "Use the tool to get the weather in Brisbane, then tell me."))
      case toolAns of
        Right a  -> TIO.putStrLn ("tool agent: " <> a)
        Left err -> TIO.putStrLn ("tool agent error: " <> T.pack (show err))
```

with:

```haskell
      let weatherTool = Tl.Tool "get_weather" (SObj [("city", SStr)])
            (\_ -> pure (JString "It is 26C and sunny."))
      (toolAns, usage) <- runEff (runChatAnthropicUsage cfg (runToolAgent [weatherTool] "Use the tool to get the weather in Brisbane, then tell me."))
      case toolAns of
        Right a  -> TIO.putStrLn ("tool agent: " <> a)
        Left err -> TIO.putStrLn ("tool agent error: " <> T.pack (show err))
      -- Illustrative per-MTok rates (not authoritative pricing).
      let rates = Rates 1.0 5.0
      TIO.putStrLn
        ( "usage: " <> T.pack (show (usInputTokens usage)) <> " in + "
            <> T.pack (show (usOutputTokens usage)) <> " out = "
            <> T.pack (show (usTotalTokens usage)) <> " tokens"
            <> "; est. cost $" <> T.pack (show (estimateCost rates usage)) )
```

- [ ] **Step 3: Build**

Run: `nix develop . --command zinc build`
Expected: exit 0, no errors.

- [ ] **Step 4: Run the live demo (verifies end-to-end accumulation)**

Run: `set -a; . ./.env; set +a; nix develop . --command zinc proxy .zinc/build/crucible-anthropic 2>/dev/null || nix develop . --command bash -c 'set -a; . ./.env; set +a; .zinc/build/crucible-anthropic'`

(The binary reads `ANTHROPIC_API_KEY` from the environment; `.env` holds the key and is gitignored. If the exact run command differs in this repo, run the built `crucible-anthropic` executable with `ANTHROPIC_API_KEY` exported.)

Expected: the existing demo lines print, plus a final line like `usage: 420 in + 38 out = 458 tokens; est. cost $0.00061` (numbers will vary). The presence of non-zero token counts confirms the accumulator captured and summed usage from the live tool-loop.

- [ ] **Step 5: Commit**

```bash
git add app/Main.hs
git commit -m "$(printf 'feat(usage): demo prints summed token usage + example cost\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Self-Review

**1. Spec coverage:**
- `Usage` Monoid + `usTotalTokens` + `Rates` + `estimateCost` → Task 1. ✅
- Cost as pure caller-parameterised helper (per-MTok, no baked prices) → Task 1 (`estimateCost`/`Rates`). ✅
- `parseUsage` (graceful `mempty` on missing) → Task 2. ✅
- DRY `(payload, Usage)` helpers + behaviour-preserving refactor of existing interpreters → Task 3 (Steps 2-3). ✅
- Accumulator interpreters `runLLMAnthropicUsage` / `runChatAnthropicUsage` returning `(a, Usage)` → Task 3 (Step 4). ✅
- New exports (`parseUsage`, both interpreters) → Task 2 Step 3b, Task 3 Step 5. ✅
- Tests: parseUsage present/absent, Monoid, estimateCost → Tasks 1-2. ✅
- Live demo prints summed usage + cost → Task 4. ✅
- No new deps / no `zinc.toml` change → stated in Background; only `Effectful.State.Static.Local` (existing dep) import widened. ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. The Task 4 Step 4 run command notes a fallback because the exact exe-launch incantation can vary — this is a runtime-invocation note, not a code placeholder.

**3. Type consistency:** `Usage(..)` constructor + fields `usInputTokens`/`usOutputTokens` and `Rates(..)` fields `rInputPerMTok`/`rOutputPerMTok` are used identically in Tasks 1, 2, 4. `parseUsage :: Text -> Usage`, `anthropicCompleteUsage :: ... -> IO (Text, Usage)`, `converseOnce :: ... -> IO (Turn, Usage)`, `runLLMAnthropicUsage`/`runChatAnthropicUsage :: ... -> Eff es (a, Usage)` are consistent across definition, export, and call sites. `reinterpret (runState mempty)` returns `(a, s)` = `(a, Usage)`, matching the signatures. ✅
