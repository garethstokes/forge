# Provider Fallback and Round-Robin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-call multi-provider resilience: a `Provider` record, constructors on both provider modules, and eight `Fallback` combinators (fallback + round-robin, LLM + Chat, plain + usage).

**Architecture:** Spec at `docs/superpowers/specs/2026-06-12-provider-fallback-design.md` (tracker `crucible-3sj`). Two new leaf modules (`Crucible.LLM.Provider`, `Crucible.LLM.Fallback`); the provider constructors reuse each module's private per-call internals. Tests need no LLM scripting (fake providers are plain records).

**Tech Stack:** Haskell GHC 9.12.2, effectful. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). On exit 137 retry once; second 137 = BLOCKED. Judge success by exit status or the "1 test suite(s) passed" line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/provider-fallback` from master; work in place, no worktrees.
- House style: prefix-free fields, `OverloadedRecordDot`, `NoFieldSelectors`. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Read first: `src/Crucible/LLM/Anthropic.hs` (private `anthropicCompleteUsage :: AnthropicConfig -> Manager -> [Message] -> IO (Text, Usage)` and `converseOnce :: AnthropicConfig -> Manager -> [(ToolName, Value)] -> [Chat.Message] -> IO (Turn, Usage)`; exported `newAnthropicManager`) and `src/Crucible/LLM/OpenAI.hs` (the same shapes: `openaiCompleteUsage`, `converseOnce`, `newOpenAIManager`).
- `Crucible.LLM.Message` and `Crucible.Chat.Message` are different types; the Provider module imports Chat qualified.
- The suite passes with 227 checks.

---

### Task 1: Provider + constructors + Fallback module (green gate)

**Files:**
- Create: `src/Crucible/LLM/Provider.hs`
- Create: `src/Crucible/LLM/Fallback.hs`
- Modify: `src/Crucible/LLM/Anthropic.hs` (export + define `provider`)
- Modify: `src/Crucible/LLM/OpenAI.hs` (export + define `provider`)

- [ ] **Step 1: create `src/Crucible/LLM/Provider.hs`:**

```haskell
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | A named provider as a pair of per-call functions. The functions carry
-- the provider's own retry policy (full-jitter backoff per its retryable
-- classification), so member-level behaviour under a fallback chain is
-- exactly what the provider does alone. Build with
-- 'Crucible.LLM.Anthropic.provider' or 'Crucible.LLM.OpenAI.provider', or
-- construct directly for stubs and custom strategies.
module Crucible.LLM.Provider
  ( Provider (..)
  ) where

import Data.Aeson (Value)
import Data.Text (Text)

import qualified Crucible.Chat as Chat
import Crucible.Chat (Turn)
import Crucible.LLM (Message)
import Crucible.Tool (ToolName)
import Crucible.Usage (Usage)

data Provider = Provider
  { name     :: Text
  , complete :: [Message] -> IO (Text, Usage)
  , converse :: [(ToolName, Value)] -> [Chat.Message] -> IO (Turn, Usage)
  }
```

- [ ] **Step 2: constructors in the provider modules.** In `src/Crucible/LLM/Anthropic.hs`, add `provider` to the export list, `import Crucible.LLM.Provider (Provider (..))`, and:

```haskell
-- | Package this provider for 'Crucible.LLM.Fallback' chains: one shared
-- TLS manager, per-call functions carrying the full retry policy.
provider :: AnthropicConfig -> IO Provider
provider cfg = do
  mgr <- newAnthropicManager cfg
  pure Provider
    { name = "anthropic"
    , complete = anthropicCompleteUsage cfg mgr
    , converse = converseOnce cfg mgr
    }
```

In `src/Crucible/LLM/OpenAI.hs`, the same with `newOpenAIManager` / `openaiCompleteUsage` / its `converseOnce` and `name = "openai"`. The per-call internals stay private in both modules.

- [ ] **Step 3: create `src/Crucible/LLM/Fallback.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Multi-provider resilience at the runEff edge, used qualified:
-- @Fallback.run@, @Fallback.roundRobinChat@, and friends. Fallback happens
-- PER CALL: each 'Complete' or 'Converse' tries the members in order
-- (round-robin rotates the starting member per call), advancing on ANY
-- member failure after that member's own internal retries give up. A
-- misconfigured member falls through to a healthy one. When every member
-- fails, 'FallbackExhausted' carries each member's rendered error in the
-- order tried. Streaming stays single-provider; cassettes record at the
-- provider level, not the chain level.
module Crucible.LLM.Fallback
  ( FallbackError (..)
  , run
  , usage
  , runChat
  , usageChat
  , roundRobin
  , roundRobinUsage
  , roundRobinChat
  , roundRobinUsageChat
  ) where

import Control.Exception (Exception, SomeException, throwIO, try)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret)
import Effectful.State.Static.Local (modify, runState)

import Crucible.Chat (Chat (..))
import Crucible.LLM (LLM (..))
import Crucible.LLM.Provider (Provider (..))
import Crucible.Usage (Usage)

-- | Every member failed: (provider name, rendered error), in tried order.
newtype FallbackError = FallbackExhausted [(Text, Text)]
  deriving (Eq, Show)

instance Exception FallbackError

-- | Try members starting at index s (wrapping), advancing on any failure.
attempt :: Int -> [Provider] -> (Provider -> IO r) -> IO r
attempt s ps act
  | null ps   = throwIO (FallbackExhausted [])
  | otherwise = go (rotate s ps) []
  where
    rotate i xs = let k = i `mod` length xs in drop k xs ++ take k xs
    go [] errs = throwIO (FallbackExhausted (reverse errs))
    go (p : rest) errs = do
      r <- try @SomeException (act p)
      case r of
        Right v -> pure v
        Left e  -> go rest ((p.name, T.pack (show e)) : errs)

-- | A counter that yields 0, 1, 2, ... across calls.
nextIndex :: IORef Int -> IO Int
nextIndex ref = atomicModifyIORef' ref (\i -> (i + 1, i))

run :: (IOE :> es) => [Provider] -> Eff (LLM : es) a -> Eff es a
run ps = interpret $ \_ -> \case
  Complete msgs -> liftIO (fst <$> attempt 0 ps (\p -> p.complete msgs))

usage :: (IOE :> es) => [Provider] -> Eff (LLM : es) a -> Eff es (a, Usage)
usage ps = reinterpret (runState mempty) $ \_ -> \case
  Complete msgs -> do
    (t, u) <- liftIO (attempt 0 ps (\p -> p.complete msgs))
    modify (<> u)
    pure t

runChat :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es a
runChat ps = interpret $ \_ -> \case
  Converse specs msgs -> liftIO (fst <$> attempt 0 ps (\p -> p.converse specs msgs))

usageChat :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es (a, Usage)
usageChat ps = reinterpret (runState mempty) $ \_ -> \case
  Converse specs msgs -> do
    (t, u) <- liftIO (attempt 0 ps (\p -> p.converse specs msgs))
    modify (<> u)
    pure t

roundRobin :: (IOE :> es) => [Provider] -> Eff (LLM : es) a -> Eff es a
roundRobin ps action = do
  ref <- liftIO (newIORef 0)
  interpret (\_ -> \case
    Complete msgs -> liftIO $ do
      s <- nextIndex ref
      fst <$> attempt s ps (\p -> p.complete msgs)) action

roundRobinUsage :: (IOE :> es) => [Provider] -> Eff (LLM : es) a -> Eff es (a, Usage)
roundRobinUsage ps action = do
  ref <- liftIO (newIORef 0)
  reinterpret (runState mempty) (\_ -> \case
    Complete msgs -> do
      s <- liftIO (nextIndex ref)
      (t, u) <- liftIO (attempt s ps (\p -> p.complete msgs))
      modify (<> u)
      pure t) action

roundRobinChat :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es a
roundRobinChat ps action = do
  ref <- liftIO (newIORef 0)
  interpret (\_ -> \case
    Converse specs msgs -> liftIO $ do
      s <- nextIndex ref
      fst <$> attempt s ps (\p -> p.converse specs msgs)) action

roundRobinUsageChat :: (IOE :> es) => [Provider] -> Eff (Chat : es) a -> Eff es (a, Usage)
roundRobinUsageChat ps action = do
  ref <- liftIO (newIORef 0)
  reinterpret (runState mempty) (\_ -> \case
    Converse specs msgs -> do
      s <- liftIO (nextIndex ref)
      (t, u) <- liftIO (attempt s ps (\p -> p.converse specs msgs))
      modify (<> u)
      pure t) action
```

- [ ] **Step 4: build + suite green.** `... zinc build` → exit 0 (zinc auto-discovers both modules); `... zinc test` → `1 test suite(s) passed`, 227 ok (nothing existing changed behaviour).

- [ ] **Step 5: commit.**

```bash
git add src/Crucible/LLM/Provider.hs src/Crucible/LLM/Fallback.hs src/Crucible/LLM/Anthropic.hs src/Crucible/LLM/OpenAI.hs
git commit -m "$(printf 'feat(llm): Provider record + fallback/round-robin interpreter combinators\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: tests (fake providers, no LLM scripting)

**Files:**
- Modify: `test/Spec.hs`

- [ ] **Step 1: imports.** Add `import Crucible.LLM.Provider (Provider (..))`, `import qualified Crucible.LLM.Fallback as Fallback`, `import qualified Crucible.LLM.Anthropic as Anthropic` exists already; extend `Data.IORef` import (add if absent: `import Data.IORef (newIORef, modifyIORef', readIORef)`), and ensure `Control.Exception` provides `try` (already imported) plus `ioError`/`userError` come from Prelude.

- [ ] **Step 2: add fixtures + checks** (after the kappa CI checks). Fake constructors used by several checks; define near the other fixtures:

```haskell
-- crucible-3sj: fake providers for fallback tests (count invocations)
goodProvider :: Text -> IORef Int -> Text -> Provider
goodProvider nm c out = Provider nm
  (\_ -> modifyIORef' c (+ 1) >> pure (out, Usage 1 2))
  (\_ _ -> modifyIORef' c (+ 1) >> pure (Turn out [], Usage 1 2))

badProvider :: Text -> IORef Int -> Provider
badProvider nm c = Provider nm
  (\_ -> modifyIORef' c (+ 1) >> ioError (userError "down"))
  (\_ _ -> modifyIORef' c (+ 1) >> ioError (userError "down"))
```

Checks (the harness's IO-form `do` checks):

```haskell
  -- crucible-3sj: provider fallback + round-robin
  , do c1 <- newIORef 0; c2 <- newIORef 0
       r <- runEff (Fallback.run [goodProvider "a" c1 "from-a", goodProvider "b" c2 "from-b"] (complete []))
       n2 <- readIORef c2
       check "fallback: first member answers, second untouched" ("from-a", 0 :: Int) (r, n2)
  , do c1 <- newIORef 0; c2 <- newIORef 0
       r <- runEff (Fallback.run [badProvider "a" c1, goodProvider "b" c2 "from-b"] (complete []))
       n1 <- readIORef c1
       check "fallback: failing member advances to the next" ("from-b", 1 :: Int) (r, n1)
  , do c1 <- newIORef 0; c2 <- newIORef 0
       r <- try (runEff (Fallback.run [badProvider "a" c1, badProvider "b" c2] (complete [])))
       check "fallback: exhaustion collects every member error in order"
         (Just (["a", "b"], True))
         (case r of
            Left (Fallback.FallbackExhausted errs) ->
              Just (map fst errs, all (T.isInfixOf "down" . snd) errs)
            Right (_ :: Text) -> Nothing)
  , do c1 <- newIORef 0
       (rs, u) <- runEff (Fallback.usage [goodProvider "a" c1 "ok"]
                    (do x <- complete []; y <- complete []; pure (x, y)))
       check "fallback: usage accumulates across calls" (("ok", "ok"), Usage 2 4) (rs, u)
  , do c1 <- newIORef 0; c2 <- newIORef 0
       r <- runEff (Fallback.runChat [badProvider "a" c1, goodProvider "b" c2 "from-b"]
              (converse [] []))
       check "fallback: chat path advances too" (Turn "from-b" []) r
  , do c1 <- newIORef 0; c2 <- newIORef 0
       let ps = [goodProvider "a" c1 "from-a", goodProvider "b" c2 "from-b"]
       (r1, r2, r3) <- runEff (Fallback.roundRobin ps
                         (do x <- complete []; y <- complete []; z <- complete []; pure (x, y, z)))
       (n1, n2) <- (,) <$> readIORef c1 <*> readIORef c2
       check "roundRobin: rotates the starting member per call"
         (("from-a", "from-b", "from-a"), (2 :: Int, 1 :: Int))
         ((r1, r2, r3), (n1, n2))
  , do c1 <- newIORef 0; c2 <- newIORef 0
       let ps = [goodProvider "a" c1 "from-a", badProvider "b" c2]
       (r1, r2) <- runEff (Fallback.roundRobin ps
                      (do x <- complete []; y <- complete []; pure (x, y)))
       check "roundRobin: failure wraps back around the list"
         ("from-a", "from-a") (r1, r2)
  , do r <- try (runEff (Fallback.run [] (complete [])))
       check "fallback: empty provider list throws immediately"
         (Just (Fallback.FallbackExhausted []))
         (case r of
            Left e -> Just e
            Right (_ :: Text) -> Nothing)
  , do p <- Anthropic.provider (defaultAnthropicConfig "k")
       q <- OpenAI.provider (defaultOpenAIConfig "k")
       check "providers: constructors carry their names" ("anthropic", "openai") (p.name, q.name)
```

Notes: `complete []` under these interpreters never touches the network (fakes only); the constructor check creates managers but makes no calls. If `try`'s type ambiguity bites, annotate as shown via the `Right (_ :: Text)` pattern (and `Right (_ :: Turn)` where the action returns a Turn).

- [ ] **Step 3: run the suite.** `... zinc test` → `1 test suite(s) passed`, 236 ok lines.

- [ ] **Step 4: commit.**

```bash
git add test/Spec.hs
git commit -m "$(printf 'test(llm): fallback/round-robin coverage with fake providers\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: demo + live smoke + docs

**Files:**
- Modify: `app/Main.hs`
- Modify: `docs/live-interpreter.md`

- [ ] **Step 1: demo.** In `app/Main.hs`, inside the OpenAI-key-gated block (after the OpenAI chat cassette section), add (imports: `import qualified Crucible.LLM.Fallback as Fallback`; `Anthropic.provider`/`OpenAI.provider` come via the existing qualified imports):

```haskell
          -- Fallback: a junk-key member fails fast; the chain recovers.
          providers <- (\a o -> [a, o])
            <$> Anthropic.provider (defaultAnthropicConfig "junk-key")
            <*> OpenAI.provider ocfg
          fb <- runEff (Fallback.run providers (complete prompt))
          TIO.putStrLn ("fallback: " <> fb <> " (first member cannot succeed; answered by second)")
```

- [ ] **Step 2: build + live smoke.** (Keys in `.env`, gitignored; NEVER print them.)

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: existing output plus a `fallback: pong (first member cannot succeed; answered by second)` line; exit 0. The junk-key member costs one failed HTTP call (401 is non-retryable inside the member).

- [ ] **Step 3: docs.** In `docs/live-interpreter.md`, add `## Fallback and round-robin` after the OpenAI section: the `Provider` record and both constructors; the eight combinators with one LLM-path example (`Fallback.run [a, o] (call classify ...)`); semantics in plain terms (each member runs its own retry policy first; the chain advances on any member failure, so a misconfigured member falls through rather than wedging the chain; fallback is per call, never per program); `FallbackExhausted` carrying every member's error in tried order; round-robin as the same list with a rotating start; the limits (streaming stays single-provider; cassettes record at the provider level, not the chain level; which-member-answered observability is tracked separately as CallLog work). House style: no emdashes/endashes, no hype, no manifest mentions; `grep -n '—\|–' docs/live-interpreter.md` empty.

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/live-interpreter.md
git commit -m "$(printf 'docs(site)+demo: provider fallback chains, proven live\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: merge + publish + close

**Files:** none.

- [ ] **Step 1: full suite.** `... zinc test` → `1 test suite(s) passed`.
- [ ] **Step 2: merge + push.** Via `superpowers:finishing-a-development-branch` (the user historically picks "merge back to master locally"); after merge: suite on master, `git push`, Pages build reaches `built`.
- [ ] **Step 3: close the bead.**

```bash
bd close crucible-3sj --reason="Shipped: Provider record, Anthropic/OpenAI provider constructors, eight Fallback combinators (fallback + round-robin, LLM + Chat, plain + usage), FallbackExhausted diagnostics, 9 fake-provider tests, live junk-key fallback proof, live-interpreter.md section."
```

---

## Self-Review

**1. Spec coverage:** Provider record + leaf module → Task 1 Step 1. Constructors with shared manager + private internals → Step 2. Eight combinators, per-call attempt walk, advance-on-any, error collection in tried order, IORef rotation, empty-list throw, usage accumulation → Step 3 + Task 2 checks. Single-member behaviour falls out of the walk (covered implicitly by the one-member usage check). Demo junk-key proof gated on the OpenAI key → Task 3. Docs section incl. limits and CallLog cross-reference → Task 3. Non-goals absent. ✅

**2. Placeholder scan:** none; Task 1 Step 2 describes the OpenAI constructor as "the same with ..." while naming every substituted identifier, which is a complete substitution, not a gap. ✅

**3. Type consistency:** `attempt :: Int -> [Provider] -> (Provider -> IO r) -> IO r` used by all eight combinators; `Provider` positional construction (name, complete, converse) matches the record order in both fixtures and constructors; `FallbackExhausted [(Text, Text)]` Eq-compared in the empty-list check and pattern-matched in the exhaustion check; round-robin expectations (a, b, a / counts 2, 1) match the `nextIndex` semantics (0, 1, 2 mod 2). ✅
