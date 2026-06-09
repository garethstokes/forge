# Backlog Cleanups Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three independent low-risk cleanups — a configurable tool-loop cap, a DRY of the Anthropic HTTP plumbing, and an object-output Main demo.

**Architecture:** (1) Add `runToolAgentN` (cap param) to `Crucible.Chat`, make `runToolAgent` the default wrapper. (2) Extract `messagesRequest`/`withAnthropicRetry` into `Crucible.LLM.Anthropic` and route both `postMessages` and `openStream` through them. (3) Swap the Main `classify` demo to a record output that round-trips through SAP.

**Tech Stack:** Haskell GHC 9.6.5, `effectful`, `http-client`, in-repo `Crucible.Json`/`Crucible.Codec`. Build/test via `nix develop . --command zinc {build,test}`.

---

## Background for the implementer

- **Spec:** `docs/superpowers/specs/2026-06-09-cleanups-bundle-design.md`.
- **Test harness:** `test/Harness.hs` — `check :: (Eq a, Show a) => String -> a -> a -> IO Bool`, `runChecks :: [IO Bool] -> IO ()`. `test/Spec.hs` is one `runChecks [ ... ]` list in `main`. Run the WHOLE suite with `nix develop . --command zinc test`; pass prints `ALL PASS` and `1 test suite(s) passed`. No per-test runner.
- The three tasks are independent; order doesn't matter. Each commits separately.
- **Commit footer:** end every commit body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: `crucible-19f` — configurable tool-loop cap

**Files:** Modify `src/Crucible/Chat.hs`; Test `test/Spec.hs`.

Context: `src/Crucible/Chat.hs` currently has `runToolAgent :: (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)` which loops from `defaultMaxIterations` and, on exhaustion, returns `Left (ToolLoopExceeded defaultMaxIterations)` (hardcoded). `test/Spec.hs` already imports `runToolAgent` from `Crucible.Chat` and has a fixture tool `weatherToolC`.

- [ ] **Step 1: Write the failing test.** In `test/Spec.hs`, add `runToolAgentN` to the existing `Crucible.Chat` import (the multi-line import that lists `runToolAgent`). Then add this check to the `runChecks` list, immediately after the existing `"runToolAgent: exhausts the iteration cap -> Left"` check:

```haskell
  , check "runToolAgentN: custom cap is honoured and reported"
      (Left (ToolLoopExceeded 2))
      (runPureEff (runChatScripted
        (replicate 20 (Turn "" [ToolUse "u" "get_weather" (JObject [])]))
        (runToolAgentN 2 [weatherToolC] "x")))
```

- [ ] **Step 2: Run suite to verify it fails.** `nix develop . --command zinc test` → build failure (`runToolAgentN` not in scope / not exported).

- [ ] **Step 3: Implement.** In `src/Crucible/Chat.hs`:

(a) Add `runToolAgentN` to the module export list (next to `runToolAgent`).

(b) Replace the current `runToolAgent` definition (the whole `runToolAgent tools question = loop defaultMaxIterations ...` block, including its `where`) with a cap-taking version plus a default wrapper:

```haskell
-- | Like 'runToolAgent' but with an explicit iteration cap. On exhaustion
-- returns @Left ('ToolLoopExceeded' cap)@ — the actual budget used.
runToolAgentN :: (Chat :> es) => Int -> [Tool es] -> Text -> Eff es (Either ChatError Text)
runToolAgentN cap tools question = loop cap [ChatMsg User [TextBlock question]]
  where
    specs = [(toolName t, toolSchema t) | t <- tools]

    loop n msgs = do
      turn <- converse specs msgs
      if null (turnToolUses turn)
        then pure (Right (turnText turn))
        else
          if n <= 0
            then pure (Left (ToolLoopExceeded cap))
            else do
              results <- mapM runOne (turnToolUses turn)
              let assistant =
                    ChatMsg Assistant
                      ( [TextBlock (turnText turn) | not (T.null (turnText turn))]
                          ++ map ToolUseBlock (turnToolUses turn) )
                  userResults = ChatMsg User results
              loop (n - 1) (msgs ++ [assistant, userResults])

    runOne u = case filter ((== tuName u) . toolName) tools of
      (t : _) -> ToolResultBlock (tuId u) <$> toolRun t (tuArgs u)
      []      -> pure (ToolResultBlock (tuId u) (JString ("unknown tool: " <> tuName u)))

-- | Drive a native tool-calling loop to a final text answer, capped at
-- 'defaultMaxIterations'. See 'runToolAgentN' for a custom cap. Total: works
-- under the scripted and live interpreters alike (needs only @Chat :> es@).
runToolAgent :: (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)
runToolAgent = runToolAgentN defaultMaxIterations
```

(Keep the existing haddock above `defaultMaxIterations` as-is.)

- [ ] **Step 4: Run suite to verify it passes.** `nix develop . --command zinc test` → the new check `ok` (reports cap 2), and the existing `"runToolAgent: exhausts the iteration cap -> Left"` check still `ok` (reports cap 10, proving the wrapper still defaults to 10). `ALL PASS`.

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/Chat.hs test/Spec.hs
git commit -m "$(printf 'feat(chat): runToolAgentN configurable cap; ToolLoopExceeded reports actual budget\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: `crucible-gkw` — DRY the Anthropic HTTP plumbing

Behaviour-preserving refactor. No new tests; verification = build succeeds + existing suite stays green (the contract is "no observable change").

**Files:** Modify `src/Crucible/LLM/Anthropic.hs`; Modify `src/Crucible/LLM/Anthropic/Stream.hs`.

Context — current duplicated code:
- `Anthropic.hs` `postMessages` (≈ lines 228-255) does `recovering (capDelay maxBackoffMicros (fullJitterBackoff (acBaseDelayMicros cfg)) <> limitRetries (acMaxRetries cfg)) [\_ -> Handler (\(e::AnthropicError) -> pure (isRetryable e))] (\_ -> doRequest)` where `doRequest = handle (\(e::HttpException) -> throwIO (AnthropicHttpError e)) $ do { base <- parseRequest "https://api.anthropic.com/v1/messages"; let req = base { method="POST", requestHeaders=[x-api-key, anthropic-version, content-type], requestBody=RequestBodyLBS (LBS.fromStrict (TE.encodeUtf8 (encode bodyJson))) }; resp <- httpLbs req mgr; ... 2xx→body else throw AnthropicStatusError }`.
- `Stream.hs` `openStream` (≈ lines 176-203) and its local `maxBackoffMicros` (≈ lines 163-164) duplicate the same retry + request-building, plus an `accept: text/event-stream` header, using `responseOpen` and draining the body on non-2xx.

- [ ] **Step 1: Add the shared helpers to `Anthropic.hs`.** In `src/Crucible/LLM/Anthropic.hs`:

(a) Add `Request` to the `Network.HTTP.Client` import list (it currently imports `HttpException`, `Manager`, etc. but not `Request`).

(b) Add `messagesRequest` and `withAnthropicRetry` to the module export list.

(c) Add these definitions (e.g. just above `postMessages`):

```haskell
-- | Build the @POST \/v1\/messages@ request for a JSON body, with the shared
-- Anthropic headers. (The streaming path adds an @Accept@ header on top.)
messagesRequest :: AnthropicConfig -> Value -> IO Request
messagesRequest cfg bodyJson = do
  base <- parseRequest "https://api.anthropic.com/v1/messages"
  pure base
    { method = "POST"
    , requestHeaders =
        [ ("x-api-key", TE.encodeUtf8 (acApiKey cfg))
        , ("anthropic-version", "2023-06-01")
        , ("content-type", "application/json")
        ]
    , requestBody = RequestBodyLBS (LBS.fromStrict (TE.encodeUtf8 (encode bodyJson)))
    }

-- | Wrap an IO action in the shared retry policy: jittered exponential backoff
-- capped at 'maxBackoffMicros', up to 'acMaxRetries', retrying 'AnthropicError's
-- for which 'isRetryable' holds.
withAnthropicRetry :: AnthropicConfig -> IO a -> IO a
withAnthropicRetry cfg action =
  recovering
    (capDelay maxBackoffMicros (fullJitterBackoff (acBaseDelayMicros cfg))
       <> limitRetries (acMaxRetries cfg))
    [ \_ -> Handler (\(e :: AnthropicError) -> pure (isRetryable e)) ]
    (\_ -> action)
```

- [ ] **Step 2: Refactor `postMessages` onto the helpers.** Replace the existing `postMessages` definition with:

```haskell
postMessages :: AnthropicConfig -> Manager -> Value -> IO Text
postMessages cfg mgr bodyJson =
  withAnthropicRetry cfg $
    handle (\(e :: HttpException) -> throwIO (AnthropicHttpError e)) $ do
      req <- messagesRequest cfg bodyJson
      resp <- httpLbs req mgr
      let body = TE.decodeUtf8Lenient (LBS.toStrict (responseBody resp))
          code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then pure body
        else throwIO (AnthropicStatusError code body)
```

(Keep `postMessages`'s haddock.)

- [ ] **Step 3: Build `Anthropic.hs`.** `nix develop . --command zinc build` → exit 0, no new warnings. (`parseRequest`/`method`/`requestHeaders`/`requestBody`/`RequestBodyLBS` are still used by `messagesRequest`, so no import becomes unused here.)

- [ ] **Step 4: Refactor `openStream` in `Stream.hs`.** In `src/Crucible/LLM/Anthropic/Stream.hs`:

(a) Replace the `openStream` definition with:

```haskell
openStream :: AnthropicConfig -> Manager -> Value -> IO (Response BodyReader)
openStream cfg mgr bodyJson =
  withAnthropicRetry cfg $
    handle (\(e :: HttpException) -> throwIO (AnthropicHttpError e)) $ do
      base <- messagesRequest cfg bodyJson
      let req = base { requestHeaders = requestHeaders base ++ [("accept", "text/event-stream")] }
      resp <- responseOpen req mgr
      let code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then pure resp
        else do
          errBody <- drainBody (responseBody resp)
          responseClose resp
          throwIO (AnthropicStatusError code (TE.decodeUtf8Lenient errBody))
```

(b) Delete the local `maxBackoffMicros` definition (and its haddock) from `Stream.hs` — it now lives only in `Anthropic.hs`.

(c) Update the `Crucible.LLM.Anthropic` import in `Stream.hs` to add `messagesRequest` and `withAnthropicRetry`:

```haskell
import Crucible.LLM.Anthropic
  ( AnthropicConfig (..), AnthropicError (..), chatRequestJson, isRetryable
  , messagesRequest, newAnthropicManager, requestJson, withAnthropicRetry )
```

(d) Remove now-unused imports from `Stream.hs`: `Control.Retry (capDelay, fullJitterBackoff, limitRetries, recovering)`, `Control.Monad.Catch (Handler (Handler))`, `Crucible.Json.Encode (encode)`, `Data.ByteString.Lazy as LBS` (if no longer referenced), and the `Network.HTTP.Client` names that `openStream` no longer uses directly: `method`, `parseRequest`, `requestBody`, `RequestBodyLBS`. Keep `requestHeaders`, `responseOpen`, `responseClose`, `responseBody`, `responseStatus`, `brRead`, `BodyReader`, `Response`, `Manager`, `HttpException`. Keep `Control.Exception (handle, throwIO)`. Keep `Data.Text.Encoding as TE` (still used by `decodeUtf8Lenient`).

Note: don't guess — after editing, run the build and let GHC's `-Wunused-imports` warnings tell you exactly which imports to drop; remove precisely those.

- [ ] **Step 5: Build + run the suite.** `nix develop . --command zinc build` → exit 0, no warnings. `nix develop . --command zinc test` → `1 test suite(s) passed` (proves the refactor preserved behaviour for every existing test).

- [ ] **Step 6: Commit.**

```bash
git add src/Crucible/LLM/Anthropic.hs src/Crucible/LLM/Anthropic/Stream.hs
git commit -m "$(printf 'refactor(anthropic): share messagesRequest + withAnthropicRetry across blocking and streaming\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: `crucible-1cb` — object-output Main demo

**Files:** Modify `app/Main.hs`.

Context: the demo's `classify` uses a scalar `str` output codec, which the SAP extractor (`stripToJson`, which finds `{`/`[`) handles poorly, so live runs print `typed fn decode error: …`. Replace it with a record output. `app/Main.hs` currently imports `Crucible.Function (llmFn, call)`, `Crucible.Codec (str)`, and (around lines 62-67) has:

```haskell
      let classify = llmFn "classify" str str
            (\s -> "Reply with one word — positive, negative, or neutral — for: " <> s)
      typed <- runEff (runLLMAnthropic cfg (call classify "I absolutely love this!"))
      case typed of
        Right o  -> TIO.putStrLn ("typed fn: " <> o)
        Left err -> TIO.putStrLn ("typed fn decode error: " <> T.pack (D.message err))
```

- [ ] **Step 1: Add the language pragma + imports.** At the top of `app/Main.hs`, add `{-# LANGUAGE DeriveGeneric #-}` (with any other existing pragmas). Add imports:

```haskell
import GHC.Generics (Generic)
import Crucible.Codec.Generic (HasCodec (codec))
```

And extend the existing `Crucible.Function` import to also bring in the `LlmFn` type:

```haskell
import Crucible.Function (LlmFn, llmFn, call)
```

- [ ] **Step 2: Declare the record type.** Add a top-level type (near the top-level `prompt` value, outside `main`):

```haskell
data Sentiment = Sentiment { sentLabel :: Text } deriving (Show, Generic)
instance HasCodec Sentiment   -- default genericCodec
```

- [ ] **Step 3: Swap the demo to the object output.** Replace the `classify` demo block shown above with:

```haskell
      let classify :: LlmFn Text Sentiment
          classify = llmFn "classify" str codec
            (\s -> "Classify the sentiment as positive, negative, or neutral for: " <> s)
      typed <- runEff (runLLMAnthropic cfg (call classify "I absolutely love this!"))
      case typed of
        Right o  -> TIO.putStrLn ("typed fn: " <> sentLabel o)
        Left err -> TIO.putStrLn ("typed fn decode error: " <> T.pack (D.message err))
```

- [ ] **Step 4: Build.** `nix develop . --command zinc build` → exit 0. (If GHC reports `codec` is ambiguous, the explicit `classify :: LlmFn Text Sentiment` signature should resolve it; that signature is included above.)

- [ ] **Step 5: Run the live demo.** The binary reads `ANTHROPIC_API_KEY` from the environment (`.env` is gitignored — never print/commit it). Run:

```bash
nix develop . --command bash -c 'set -a; . ./.env; set +a; BIN=$(find .zinc/build -type f -name crucible-anthropic | head -1); "$BIN"'
```

Expected: the `typed fn:` line now prints a sentiment word (e.g. `typed fn: positive`) instead of a decode error. If the live call fails for an environment reason (no network/key), report DONE_WITH_CONCERNS noting the build succeeded but the live run could not be verified — do NOT fake output.

- [ ] **Step 6: Confirm the suite is still green + commit.** `nix develop . --command zinc test` → `1 test suite(s) passed`.

```bash
git add app/Main.hs
git commit -m "$(printf 'fix(demo): object-output typed-fn so the classify demo round-trips\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Self-Review

**1. Spec coverage:**
- 19f: `runToolAgentN` (cap param) + `runToolAgent` wrapper + `ToolLoopExceeded` reports actual cap + export + tests → Task 1. ✅
- gkw: `messagesRequest` + `withAnthropicRetry` extracted/exported; `postMessages` + `openStream` refactored; `maxBackoffMicros` deduped; unused imports pruned; behaviour-preserving (green suite) → Task 2. ✅
- 1cb: `Sentiment` record + `HasCodec` + object-output `classify` + live verification → Task 3. ✅
- No new deps; independent tasks. ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. The Task 2 Step 4d "let GHC warnings tell you which imports to drop" is a precise instruction (the candidate list is given) for a refactor where the exact unused set is build-determined — not a placeholder.

**3. Type consistency:** `runToolAgentN :: Int -> [Tool es] -> Text -> Eff es (Either ChatError Text)` and `runToolAgent = runToolAgentN defaultMaxIterations` are consistent; the test calls `runToolAgentN 2 [weatherToolC] "x"`. `messagesRequest :: AnthropicConfig -> Value -> IO Request` and `withAnthropicRetry :: AnthropicConfig -> IO a -> IO a` match both call sites (`postMessages`, `openStream`). `Sentiment`/`sentLabel`/`HasCodec`/`codec`/`LlmFn Text Sentiment` are consistent across declaration and use. ✅
