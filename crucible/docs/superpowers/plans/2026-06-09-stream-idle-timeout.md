# Streaming Idle-Timeout Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Abort a stalled mid-stream SSE read with a typed error instead of hanging, bounded by a configurable per-chunk idle window.

**Architecture:** Add `acStreamIdleSecs` to `AnthropicConfig` and an `AnthropicStreamTimeout` error constructor. In the stream module, wrap each `brRead` in `System.Timeout.timeout` via a small exported `timedRead` helper; thread the idle window (micros) through `streamLoop` from both interpreters.

**Tech Stack:** Haskell GHC 9.6.5, `base` (`System.Timeout`, `Control.Concurrent`), in-repo modules. Build/test via `nix develop . --command zinc {build,test}`.

---

## Background for the implementer

- **Spec:** `docs/superpowers/specs/2026-06-09-stream-idle-timeout-design.md`.
- **Test harness:** `test/Harness.hs` — `check :: (Eq a, Show a) => String -> a -> a -> IO Bool`, `runChecks :: [IO Bool] -> IO ()`. `test/Spec.hs` is one `runChecks [ ... ]` list in `main`. Each list element has type `IO Bool`, so an element may be a `do` block that performs IO before calling `check` (used below to test an IO-throwing helper). Run the WHOLE suite with `nix develop . --command zinc test`; pass prints `ALL PASS` and `1 test suite(s) passed`.
- `AnthropicError` has **no `Eq`** (it wraps `HttpException`, which isn't `Eq`) — so the timeout case is asserted by pattern-match, not `==`.
- `test/Spec.hs` already imports `Crucible.LLM.Anthropic (AnthropicError(..), isRetryable, defaultAnthropicConfig, chatRequestJson, parseTurn, parseUsage)` and `qualified Data.ByteString.Char8 as BC`.
- `Crucible.LLM.Anthropic.Stream` already imports `AnthropicConfig (..)` and `AnthropicError (..)` (all constructors), so `acStreamIdleSecs` and `AnthropicStreamTimeout` need no import change there.
- **Commit footer:** end every commit body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: config field + error constructor (`Crucible.LLM.Anthropic`)

**Files:** Modify `src/Crucible/LLM/Anthropic.hs`; Test `test/Spec.hs`.

Context — current `AnthropicError`, `isRetryable`, `AnthropicConfig`, and `defaultAnthropicConfig`:

```haskell
data AnthropicError
  = AnthropicHttpError   HttpException
  | AnthropicStatusError Int Text
  | AnthropicNoContent   Text
  deriving (Show)

isRetryable :: AnthropicError -> Bool
isRetryable (AnthropicHttpError _)     = True
isRetryable (AnthropicStatusError s _) = s == 429 || s >= 500
isRetryable (AnthropicNoContent _)     = False

data AnthropicConfig = AnthropicConfig
  { acApiKey          :: Text
  , acModel           :: Text
  , acMaxTokens       :: Int
  , acTimeoutSecs     :: Int
  , acMaxRetries      :: Int
  , acBaseDelayMicros :: Int
  }
  deriving (Eq, Show)

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

`AnthropicConfig (..)` and `AnthropicError (..)` are already exported from the module, so adding a field / constructor needs no export-list change.

- [ ] **Step 1: Write the failing tests.** In `test/Spec.hs`, add `acStreamIdleSecs` to the existing `Crucible.LLM.Anthropic` import (the line listing `defaultAnthropicConfig` etc.). Then add these checks to the `runChecks` list:

```haskell
  -- crucible-mgs: stream idle timeout config + error
  , check "config: default stream idle is 60s"
      (60 :: Int)
      (acStreamIdleSecs (defaultAnthropicConfig "k"))
  , check "isRetryable: stream timeout is not retryable"
      False
      (isRetryable (AnthropicStreamTimeout 1000))
```

- [ ] **Step 2: Run suite to verify it fails.** `nix develop . --command zinc test` → build failure (`acStreamIdleSecs` / `AnthropicStreamTimeout` not in scope).

- [ ] **Step 3: Implement.** In `src/Crucible/LLM/Anthropic.hs`:

(a) Add the `AnthropicStreamTimeout` constructor to `AnthropicError` (and update the haddock's wording is optional — leave it):

```haskell
data AnthropicError
  = AnthropicHttpError    HttpException
  | AnthropicStatusError  Int Text
  | AnthropicNoContent    Text
  | AnthropicStreamTimeout Int  -- ^ no chunk within the idle window (microseconds)
  deriving (Show)
```

(b) Add the `isRetryable` case (a mid-stream timeout fires past the retry boundary, so it propagates):

```haskell
isRetryable (AnthropicHttpError _)      = True
isRetryable (AnthropicStatusError s _)  = s == 429 || s >= 500
isRetryable (AnthropicNoContent _)      = False
isRetryable (AnthropicStreamTimeout _)  = False
```

(c) Add the `acStreamIdleSecs` field to the `AnthropicConfig` record (place it after `acBaseDelayMicros`):

```haskell
  , acBaseDelayMicros :: Int  -- ^ backoff base delay, microseconds
  , acStreamIdleSecs  :: Int  -- ^ mid-stream per-chunk idle timeout, seconds
  }
  deriving (Eq, Show)
```

(d) Set it in `defaultAnthropicConfig` (after `acBaseDelayMicros = 500000`):

```haskell
    , acBaseDelayMicros = 500000
    , acStreamIdleSecs = 60
    }
```

- [ ] **Step 4: Run suite to verify it passes.** `nix develop . --command zinc test` → both new checks `ok`; `ALL PASS`. (The build also re-checks every existing `AnthropicConfig`/`AnthropicError` use site; `defaultAnthropicConfig` is the only record literal, so nothing else needs the new field.)

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/LLM/Anthropic.hs test/Spec.hs
git commit -m "$(printf 'feat(stream): acStreamIdleSecs config + AnthropicStreamTimeout error\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: timed read + loop wiring (`Crucible.LLM.Anthropic.Stream`)

**Files:** Modify `src/Crucible/LLM/Anthropic/Stream.hs`; Test `test/Spec.hs`.

Context — current `streamLoop` (note `chunk <- liftIO (brRead br)`) and the two interpreters that call `streamLoop` as the third `bracket` argument:

```haskell
streamLoop :: (IOE :> es, Emit :> es) => Response BodyReader -> Eff es StreamAcc
streamLoop resp = go emptyAcc BS.empty
  where
    br = responseBody resp
    go acc buf = do
      chunk <- liftIO (brRead br)
      ...
-- runLLMAnthropicStream / runChatAnthropicStream each do:
        acc <- bracket
                 (liftIO (openStream cfg mgr (addStream (... cfg ...))))
                 (liftIO . responseClose)
                 streamLoop
```

`Stream.hs` already imports `Control.Exception (handle, throwIO)`, `Data.ByteString (ByteString)` / `qualified … as BS`, and `AnthropicError (..)` / `AnthropicConfig (..)` from `Crucible.LLM.Anthropic`.

- [ ] **Step 1: Write the failing tests.** In `test/Spec.hs`:

(a) Add imports:

```haskell
import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Crucible.LLM.Anthropic.Stream (timedRead)
```

(If `Crucible.LLM.Anthropic.Stream` is already imported with a list, add `timedRead` to that list instead of a new line. If `Control.Exception` is already imported, add `try` to its list.)

(b) Add these checks to the `runChecks` list (each is a `do` block of type `IO Bool`):

```haskell
  -- crucible-mgs: timedRead
  , do r <- timedRead 200000 (pure (BC.pack "hi"))
       check "timedRead: fast read passes through" (BC.pack "hi") r
  , do r <- try (timedRead 1000 (threadDelay 50000 >> pure (BC.pack "x")))
            :: IO (Either AnthropicError BC.ByteString)
       check "timedRead: idle timeout fires"
         (Just 1000)
         (case r of Left (AnthropicStreamTimeout n) -> Just (n :: Int); _ -> Nothing)
  , do r <- timedRead 0 (pure (BC.pack "x"))
       check "timedRead: non-positive disables the guard" (BC.pack "x") r
```

- [ ] **Step 2: Run suite to verify it fails.** `nix develop . --command zinc test` → build failure (`timedRead` not exported).

- [ ] **Step 3: Implement.** In `src/Crucible/LLM/Anthropic/Stream.hs`:

(a) Add the import:

```haskell
import System.Timeout (timeout)
```

(b) Add `timedRead` to the module export list (e.g. after `stepAcc`):

```haskell
  , stepAcc
  , timedRead
  , runLLMAnthropicStream
```

(c) Add the helper (place it just above `streamLoop`):

```haskell
-- | Read one chunk, bounding the wait by @micros@. A non-positive @micros@
-- disables the guard. On timeout, throw 'AnthropicStreamTimeout'.
timedRead :: Int -> IO ByteString -> IO ByteString
timedRead micros readChunk
  | micros <= 0 = readChunk
  | otherwise   =
      timeout micros readChunk >>= maybe (throwIO (AnthropicStreamTimeout micros)) pure
```

(d) Change `streamLoop` to take a leading idle-micros argument and use `timedRead`. Replace its signature and the binding/read line:

```haskell
streamLoop :: (IOE :> es, Emit :> es) => Int -> Response BodyReader -> Eff es StreamAcc
streamLoop idleMicros resp = go emptyAcc BS.empty
  where
    br = responseBody resp
    go acc buf = do
      chunk <- liftIO (timedRead idleMicros (brRead br))
```

(Leave the rest of `go`/`emitFrames`/`isWs` exactly as-is.)

(e) Update BOTH interpreters' `bracket` calls to pass the idle window. In `runLLMAnthropicStream` and `runChatAnthropicStream`, change the third `bracket` argument from `streamLoop` to:

```haskell
                 (streamLoop (acStreamIdleSecs cfg * 1000000))
```

- [ ] **Step 4: Build + run the suite.** `nix develop . --command zinc build` → exit 0, no warnings. `nix develop . --command zinc test` → the three `timedRead` checks `ok`, `ALL PASS` (`1 test suite(s) passed`).

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/LLM/Anthropic/Stream.hs test/Spec.hs
git commit -m "$(printf 'feat(stream): bound mid-stream reads with timedRead idle timeout\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Self-Review

**1. Spec coverage:**
- `acStreamIdleSecs` field (default 60) → Task 1 (c,d). ✅
- `AnthropicStreamTimeout Int` (micros) + `isRetryable … = False` → Task 1 (a,b). ✅
- `timedRead` (exported; non-positive disables; throws on timeout) → Task 2 (c). ✅
- `streamLoop` gains idle-micros param + uses `timedRead`; both interpreters pass `acStreamIdleSecs cfg * 1000000` → Task 2 (d,e). ✅
- `System.Timeout` import; no new deps → Task 2 (a). ✅
- Tests: config default, isRetryable, timedRead fast/timeout/disabled → Tasks 1-2. ✅
- Non-goals respected: no retry/resume (isRetryable False, thrown past retry boundary), no total deadline (per-read only), blocking path untouched. ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output.

**3. Type consistency:** `acStreamIdleSecs :: Int` (seconds) → `* 1000000` → `idleMicros :: Int` → `timedRead :: Int -> IO ByteString -> IO ByteString` → `AnthropicStreamTimeout Int` (micros), and the test asserts `1000`. `streamLoop :: Int -> Response BodyReader -> Eff es StreamAcc` matches both updated call sites. `AnthropicError(..)`/`AnthropicConfig(..)` already exported and imported in both Spec.hs and Stream.hs. ✅
