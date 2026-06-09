# Live-path robustness (`runLLMAnthropic`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the live Anthropic interpreter robust — typed errors, automatic retry-with-backoff on transient failures, a request timeout, and a shared TLS `Manager` — without changing the `LLM` effect or the pure interpreters.

**Architecture:** All changes live in `src/Crucible/LLM/Anthropic.hs`. Errors are *thrown* as a typed `AnthropicError` (so `complete :: [Message] -> Eff es Text` is unchanged). The retry loop uses the `Control.Retry` library (`recovering` + a jittered-exponential-backoff policy with a retry limit) — no hand-rolled backoff. Network `HttpException`s are wrapped into `AnthropicHttpError` so callers see a single error type.

**Tech Stack:** Haskell (GHC 9.6.5), effectful, `http-client`/`http-client-tls`, the new `retry` library, `http-types`, zinc. Build/test: `nix develop . --command zinc <build|test>` (a few minutes each). Test binary: `.zinc/build/spec`; `test/Spec.hs` is a `runChecks [ check name expected actual, ... ]` list (`check :: (Eq a, Show a) => String -> a -> a -> IO Bool`). Spec: `docs/superpowers/specs/2026-06-09-live-path-robustness-design.md`.

**Pre-verified facts (don't re-investigate):**
- `retry-0.9.3.1` + its new transitive `mtl-compat-0.2.2` vendor and build cleanly under zinc; `random` is already in the lock.
- The dep-add sequence is `zinc vendor ram-0.22.0` **then** `zinc add retry` — `ram` (an existing tag-less transitive) must be pinned first or the re-resolve fails on it.
- `http-types` is already in the lock (a transitive of http-client); it only needs adding to the library's `depends`.
- `Control.Retry` exports `recovering`, `RetryPolicyM`, `capDelay`, `fullJitterBackoff`, `limitRetries`, `RetryStatus`. `Handler(..)` comes from `Control.Monad.Catch`. `statusCode :: Status -> Int` from `Network.HTTP.Types.Status`; `responseStatus`, `newManager`, `managerResponseTimeout`, `responseTimeoutMicro`, `HttpException` from `Network.HTTP.Client`; `tlsManagerSettings` from `Network.HTTP.Client.TLS`.

---

### Task 1: Add the `retry` dependency

**Files:**
- Modify: `zinc.toml` (root `[dependencies]` via `zinc add`; library `[build.lib] depends`)
- Generated: `zinc.lock`

- [ ] **Step 1: Vendor `ram`, then add `retry`**

Run:
```bash
nix develop . --command zinc vendor ram-0.22.0 -y
nix develop . --command zinc add retry -y
```
Expected: both exit 0. The first prints `ram 0.22.0 (vendored)`; the second prints a resolution table including `retry`. (Skipping the `ram` vendor makes `zinc add retry` fail with `ram: … has no release tags`.)

- [ ] **Step 2: Add `retry` and `http-types` to the library depends**

In `zinc.toml`, the `[build.lib]` block's `depends` currently is:
```toml
depends = ["base", "text", "bytestring", "mtl", "effectful", "effectful-core", "http-client", "http-client-tls"]
```
Change it to:
```toml
depends = ["base", "text", "bytestring", "mtl", "effectful", "effectful-core", "http-client", "http-client-tls", "http-types", "retry"]
```

- [ ] **Step 3: Build to verify the deps compile**

Run: `nix develop . --command zinc build`
Expected: exit 0 (builds `retry`, `mtl-compat`, etc.; ends with `.zinc/build/crucible-anthropic`).

- [ ] **Step 4: Commit**

```bash
git add zinc.toml zinc.lock
git commit -m "build(fn): add retry + http-types deps for live-path robustness"
```
End the commit body with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 2: `AnthropicError` type + `isRetryable`

**Files:**
- Modify: `src/Crucible/LLM/Anthropic.hs` (exports, new type, new function)
- Modify: `test/Spec.hs` (import + checks)

- [ ] **Step 1: Write the failing tests**

In `test/Spec.hs`, add the import near the other `Crucible.*` imports:
```haskell
import Crucible.LLM.Anthropic (AnthropicError(..), isRetryable)
```
Add these checks to the `runChecks [ ... ]` list:
```haskell
  , check "isRetryable: 429"        True  (isRetryable (AnthropicStatusError 429 ""))
  , check "isRetryable: 500"        True  (isRetryable (AnthropicStatusError 500 ""))
  , check "isRetryable: 503"        True  (isRetryable (AnthropicStatusError 503 ""))
  , check "isRetryable: 400"        False (isRetryable (AnthropicStatusError 400 ""))
  , check "isRetryable: 401"        False (isRetryable (AnthropicStatusError 401 ""))
  , check "isRetryable: 404"        False (isRetryable (AnthropicStatusError 404 ""))
  , check "isRetryable: no-content" False (isRetryable (AnthropicNoContent ""))
```
(The `""` literals are `Text` — `test/Spec.hs` already enables `OverloadedStrings`. If a build error says otherwise, add `{-# LANGUAGE OverloadedStrings #-}` at the top of Spec.hs.)

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop . --command zinc test`
Expected: FAIL — `Module 'Crucible.LLM.Anthropic' does not export 'AnthropicError'/'isRetryable'`.

- [ ] **Step 3: Add the type, export it, and define `isRetryable`**

In `src/Crucible/LLM/Anthropic.hs`:

(a) Add to the module export list (currently ends `, runLLMCassette\n  ) where`):
```haskell
  , AnthropicError (..)
  , isRetryable
```

(b) Add these imports with the other imports:
```haskell
import Control.Exception (Exception)
import Network.HTTP.Client (HttpException)
```
(`Network.HTTP.Client` is already imported with an explicit list — add `HttpException` to that list instead of a second import line.)

(c) Add the type + classifier (place after the `import`s, before `AnthropicConfig`):
```haskell
-- | A typed live-path failure. Network/timeout errors are wrapped as
-- 'AnthropicHttpError'; a non-2xx response is 'AnthropicStatusError'; a 2xx body
-- with no text content block is 'AnthropicNoContent'. Thrown by the live
-- interpreter (the 'LLM' effect still returns 'Text'); callers 'try' it in IO.
data AnthropicError
  = AnthropicHttpError   HttpException
  | AnthropicStatusError Int Text
  | AnthropicNoContent   Text
  deriving (Show)

instance Exception AnthropicError

-- | Whether a failure is worth retrying: network/timeout errors and HTTP 429 /
-- 5xx are transient; other 4xx and a content-shape failure are permanent.
isRetryable :: AnthropicError -> Bool
isRetryable (AnthropicHttpError _)     = True
isRetryable (AnthropicStatusError s _) = s == 429 || s >= 500
isRetryable (AnthropicNoContent _)     = False
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop . --command zinc test`
Expected: PASS — `1 test suite(s) passed`. (`AnthropicError`/`isRetryable` are not yet used by `anthropicComplete`; a `-Wunused`-style note is fine, the build is not `-Werror`.)

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/LLM/Anthropic.hs test/Spec.hs
git commit -m "feat(fn): typed AnthropicError + isRetryable classifier"
```
End with the `Co-Authored-By` trailer.

---

### Task 3: Extend `AnthropicConfig` with timeout + retry settings

**Files:**
- Modify: `src/Crucible/LLM/Anthropic.hs` (`AnthropicConfig`, `defaultAnthropicConfig`)

- [ ] **Step 1: Add the three fields**

Replace the `AnthropicConfig` record (currently `acApiKey`/`acModel`/`acMaxTokens`) with:
```haskell
data AnthropicConfig = AnthropicConfig
  { acApiKey          :: Text
  , acModel           :: Text
  , acMaxTokens       :: Int
  , acTimeoutSecs     :: Int  -- ^ request timeout in seconds
  , acMaxRetries      :: Int  -- ^ retries on transient failures
  , acBaseDelayMicros :: Int  -- ^ backoff base delay, microseconds
  }
  deriving (Eq, Show)
```

- [ ] **Step 2: Update the default constructor**

Replace `defaultAnthropicConfig` with:
```haskell
-- | A config with sensible defaults (60s timeout, 3 retries, 0.5s backoff base);
-- supply the API key.
defaultAnthropicConfig :: Text -> AnthropicConfig
defaultAnthropicConfig key =
  AnthropicConfig
    { acApiKey = key
    , acModel = "claude-haiku-4-5-20251001"
    , acMaxTokens = 1024
    , acTimeoutSecs = 60
    , acMaxRetries = 3
    , acBaseDelayMicros = 500000
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `nix develop . --command zinc build`
Expected: exit 0. (The new fields are not used yet; `anthropicComplete` still uses the old logic. That's fine — Task 4 wires them in.)

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/LLM/Anthropic.hs
git commit -m "feat(fn): AnthropicConfig timeout + retry settings"
```
End with the `Co-Authored-By` trailer.

---

### Task 4: Robust `anthropicComplete` — shared timed `Manager` + retry loop

**Files:**
- Modify: `src/Crucible/LLM/Anthropic.hs` (`runLLMAnthropic`, `recordLLMAnthropic`, `anthropicComplete`, new `newAnthropicManager`, a constant; pragmas + imports)

- [ ] **Step 1: Add language pragmas + imports**

At the top of the file, add (the file already has `DataKinds`, `FlexibleContexts`, `GADTs`, `LambdaCase`, `OverloadedStrings`, `TypeOperators`):
```haskell
{-# LANGUAGE ScopedTypeVariables #-}
```
Add these imports (group with the existing ones):
```haskell
import Control.Exception (handle, throwIO)
import Control.Monad.Catch (Handler (Handler))
import Control.Retry (capDelay, fullJitterBackoff, limitRetries, recovering)
import Network.HTTP.Types.Status (statusCode)
```
Extend the existing `Network.HTTP.Client (...)` import list to also bring in:
`Manager, ManagerSettings (managerResponseTimeout), httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody, responseStatus, responseTimeoutMicro` — i.e. add `Manager`, `ManagerSettings (managerResponseTimeout)`, `newManager`, `responseStatus`, `responseTimeoutMicro` to what's already imported (`RequestBody (RequestBodyLBS)`, `httpLbs`, `method`, `parseRequest`, `requestBody`, `requestHeaders`, `responseBody`, and `HttpException` from Task 2).
Change the TLS import from `newTlsManager` to:
```haskell
import Network.HTTP.Client.TLS (tlsManagerSettings)
```
(Remove `newTlsManager` — it's replaced by `newManager`/`tlsManagerSettings`.)

- [ ] **Step 2: Add the backoff cap constant + manager builder**

Add near the top of the value definitions (e.g. just above `runLLMAnthropic`):
```haskell
-- | Upper bound on a single backoff delay (30s), so exponential growth is capped.
maxBackoffMicros :: Int
maxBackoffMicros = 30000000

-- | One TLS 'Manager' configured with the request timeout, shared across all
-- 'Complete's of a single interpreter invocation.
newAnthropicManager :: AnthropicConfig -> IO Manager
newAnthropicManager cfg =
  newManager
    tlsManagerSettings
      { managerResponseTimeout = responseTimeoutMicro (acTimeoutSecs cfg * 1000000) }
```

- [ ] **Step 3: Build the shared manager once in the interpreters**

Replace `runLLMAnthropic` with:
```haskell
-- | Interpret @LLM@ against the live Anthropic Messages API. One shared TLS
-- manager is created up front; each 'Complete' is one @POST \/v1\/messages@ with
-- timeout + retry. Failures throw 'AnthropicError'.
runLLMAnthropic :: (IOE :> es) => AnthropicConfig -> Eff (LLM : es) a -> Eff es a
runLLMAnthropic cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret (\_ (Complete msgs) -> liftIO (anthropicComplete cfg mgr msgs)) action
```
Replace `recordLLMAnthropic` with:
```haskell
recordLLMAnthropic :: (IOE :> es) => FilePath -> AnthropicConfig -> Eff (LLM : es) a -> Eff es a
recordLLMAnthropic path cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Complete msgs) -> liftIO $ do
        reply <- anthropicComplete cfg mgr msgs
        TIO.appendFile path (encode (JString reply) <> "\n")
        pure reply)
    action
```
(Note: `Complete` is the only constructor of `LLM`, so the lambda can match it directly; `LambdaCase` is no longer required for these two but stays enabled for `anthropicRole`.)

- [ ] **Step 4: Rewrite `anthropicComplete` with the retry loop**

Replace the entire `anthropicComplete` definition with:
```haskell
-- | One robust round-trip: retry transient failures (network/timeout, 429, 5xx)
-- with jittered exponential backoff up to 'acMaxRetries', then rethrow a typed
-- 'AnthropicError'. A non-retryable failure (other 4xx, or a 2xx with no text
-- content) is thrown immediately.
anthropicComplete :: AnthropicConfig -> Manager -> [Message] -> IO Text
anthropicComplete cfg mgr msgs =
  recovering
    (capDelay maxBackoffMicros (fullJitterBackoff (acBaseDelayMicros cfg))
       <> limitRetries (acMaxRetries cfg))
    [ \_ -> Handler (\(e :: AnthropicError) -> pure (isRetryable e)) ]
    (\_ -> doRequest)
  where
    doRequest :: IO Text
    doRequest = handle (\(e :: HttpException) -> throwIO (AnthropicHttpError e)) $ do
      base <- parseRequest "https://api.anthropic.com/v1/messages"
      let req =
            base
              { method = "POST"
              , requestHeaders =
                  [ ("x-api-key", TE.encodeUtf8 (acApiKey cfg))
                  , ("anthropic-version", "2023-06-01")
                  , ("content-type", "application/json")
                  ]
              , requestBody =
                  RequestBodyLBS (LBS.fromStrict (TE.encodeUtf8 (encode (requestJson cfg msgs))))
              }
      resp <- httpLbs req mgr
      let body = TE.decodeUtf8 (LBS.toStrict (responseBody resp))
          code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then either (\_ -> throwIO (AnthropicNoContent body)) pure (extractText body)
        else throwIO (AnthropicStatusError code body)
```
(`requestJson`, `extractText`, `anthropicRole` are unchanged.)

- [ ] **Step 5: Build + test**

Run: `nix develop . --command zinc build`
Expected: exit 0, `.zinc/build/crucible-anthropic` produced.
Run: `nix develop . --command zinc test`
Expected: `1 test suite(s) passed` (the `isRetryable` checks from Task 2 plus the whole existing suite).

- [ ] **Step 6: Commit**

```bash
git add src/Crucible/LLM/Anthropic.hs
git commit -m "feat(fn): robust anthropicComplete — shared timed manager + retry loop"
```
End with the `Co-Authored-By` trailer.

---

## Self-Review

**Spec coverage:**
- Decision 1 (throw typed `AnthropicError`, effect unchanged) → Task 2 (type + Exception instance) + Task 4 (`doRequest` throws; `complete`/pure interps untouched).
- Decision 2 (`Control.Retry`: retry network/429/5xx, not other 4xx; jittered backoff, capped, limited) → Task 1 (dep) + Task 4 (`recovering` + policy + `isRetryable`); `Retry-After` intentionally not honored.
- Decision 3 (shared timed `Manager`) → Task 3 (config) + Task 4 (`newAnthropicManager`, built once in both interpreters).
- Decision 4 (library over hand-rolling) → Task 4 uses `fullJitterBackoff`/`capDelay`/`limitRetries`; no custom backoff math.
- New dependency `retry` (+ `http-types`) → Task 1.
- Config fields (`acTimeoutSecs`/`acMaxRetries`/`acBaseDelayMicros`, defaults) → Task 3.
- Tests (`isRetryable` for 429/500/503/400/401/404/no-content) → Task 2. Live smoke exe still builds → Task 4 Step 5 (`zinc build`).

**Refinement vs spec:** network `HttpException` is wrapped into `AnthropicHttpError` inside `doRequest`, so the loop uses a single `AnthropicError` handler (not two) and callers catch one type. This is within spec intent — `AnthropicHttpError HttpException` exists precisely to carry network failures — and makes the variant load-bearing rather than dead.

**Placeholder scan:** none — every step has full code/commands.

**Type consistency:** `AnthropicError(..)`/`isRetryable` defined in Task 2 are used in Task 4; `acTimeoutSecs`/`acMaxRetries`/`acBaseDelayMicros` defined in Task 3 are used in Task 4 (`newAnthropicManager`, the policy). `anthropicComplete`'s new signature gains the `Manager` argument, and both call sites (`runLLMAnthropic`, `recordLLMAnthropic`) are updated in Task 4 to pass it. `maxBackoffMicros`, `newAnthropicManager` names match across steps.
