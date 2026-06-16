# Typed-function eDSL (`Crucible.Function`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a typed LLM *function* — `LlmFn i o` declared once, invoked with `call` — that injects the output schema, renders the input, calls the model, and tolerantly decodes the result with retry-on-failure.

**Architecture:** One new module `Crucible.Function`, composing existing primitives only (`Codec`, `renderSchema`, `encode`, `decodeLLM`, the `LLM` effect). `call :: (LLM :> es) => …` is interpreter-agnostic (scripted / cassette / live Anthropic). No new deps, no JSON/HTTP machinery. Spec: `docs/superpowers/specs/2026-06-08-typed-function-edsl-design.md`.

**Tech Stack:** Haskell (GHC 9.6.5), effectful, zinc. Build/test: `nix develop . --command zinc <build|test>`. The flat layout puts sources in `src/`, tests in `test/Spec.hs` (Harness-based: `check name expected actual`), and the test binary at `.zinc/build/spec`.

**Notes for the implementer:**
- Modules are auto-discovered from `source-dirs` (no module list to edit); creating `src/Crucible/Function.hs` is enough — **no `zinc.toml` change**.
- The umbrella module `Crucible` exports nothing; consumers import `Crucible.Function` directly (matching `Crucible.LLM` etc.).
- `zinc test` exits non-zero if any `check` fails or anything fails to compile. To see individual `ok`/`FAIL` lines, run the binary directly: `nix develop . --command .zinc/build/spec`.
- Existing test conventions in `test/Spec.hs`: it already imports the effectful runners (`runPureEff`) and `runLLMScripted`, and uses `check :: (Eq a, Show a) => String -> a -> a -> IO Bool` from `Harness`.

---

### Task 1: `Crucible.Function` — type, constructors, single-shot `call`

**Files:**
- Create: `src/Crucible/Function.hs`
- Modify: `test/Spec.hs` (add import + checks to the existing `runChecks [...]` list)

- [ ] **Step 1: Write the failing tests**

In `test/Spec.hs`, add the import near the other `Crucible.*` imports:

```haskell
import Crucible.Function (LlmFn, llmFn, withRetries, fnPrompt, call, fnOutput)
```

Ensure these are also imported (add any that are missing):

```haskell
import Crucible.LLM (Message(..), Role(..), complete, runLLMScripted)
import Crucible.Codec (str, codecSchema)
import Crucible.Schema (renderSchema)
import Crucible.Json.Encode (encode)
import Crucible.Codec (codecEncode)
import qualified Data.Text as T
import Effectful (runPureEff)
```

Add a top-level sample function (place it near the other test fixtures, after the imports / `main =`):

```haskell
classifyFn :: LlmFn T.Text T.Text
classifyFn = llmFn "classify" str str (\s -> "Classify the sentiment of: " <> s)
```

Add these checks into the `runChecks [ ... ]` list (e.g. after the existing eval checks):

```haskell
  , check "llmFn: happy path decodes the reply"
      (Right "positive")
      (runPureEff (runLLMScripted ["\"positive\""] (call classifyFn "I love it")))
  , check "llmFn: single bad reply -> Left"
      True
      (either (const True) (const False)
        (runPureEff (runLLMScripted ["not json"] (call (withRetries 0 classifyFn) "x"))))
  , check "fnPrompt: system message carries the output schema"
      True
      (case fnPrompt classifyFn "hi" of
         (Message System s : _) ->
           T.isPrefixOf "Respond ONLY with JSON" s
             && T.isInfixOf (renderSchema (codecSchema (fnOutput classifyFn))) s
         _ -> False)
  , check "fnPrompt: user message carries instruction + rendered input"
      True
      (case fnPrompt classifyFn "hi" of
         (_ : Message User u : _) ->
           T.isInfixOf "Classify the sentiment of: hi" u && T.isInfixOf "\"hi\"" u
         _ -> False)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop . --command zinc test`
Expected: FAIL — compile error, `Could not find module 'Crucible.Function'`.

- [ ] **Step 3: Create the module (single-shot `call`)**

Create `src/Crucible/Function.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | Typed LLM functions: declare an 'LlmFn' once (input type, output type, and a
-- task instruction) and 'call' it for a typed, structured result. The output
-- schema is injected into the prompt and the reply is tolerantly decoded against
-- the output 'Codec'. 'call' needs only @LLM :> es@, so it runs under the
-- scripted, cassette, and live Anthropic interpreters unchanged.
module Crucible.Function
  ( LlmFn (..)
  , llmFn
  , withRetries
  , fnPrompt
  , call
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Effectful

import Crucible.Codec (Codec (..))
import qualified Crucible.Json.Decode as D
import Crucible.Json.Encode (encode)
import Crucible.LLM (LLM, Message (..), Role (..), complete)
import Crucible.SAP (decodeLLM)
import Crucible.Schema (renderSchema)

-- | A declared LLM function: a task instruction plus input/output codecs.
data LlmFn i o = LlmFn
  { fnName        :: Text        -- ^ for introspection / evals
  , fnInstruction :: i -> Text   -- ^ the task (may reference input fields)
  , fnInput       :: Codec i     -- ^ used to render the input value into the prompt
  , fnOutput      :: Codec o     -- ^ schema injection + tolerant decode
  , fnRetries     :: Int         -- ^ decode-failure retries
  }

-- | Construct an 'LlmFn'; @fnRetries@ defaults to 2.
llmFn :: Text -> Codec i -> Codec o -> (i -> Text) -> LlmFn i o
llmFn name inC outC instr =
  LlmFn { fnName = name, fnInstruction = instr, fnInput = inC, fnOutput = outC, fnRetries = 2 }

-- | Override the decode-failure retry budget.
withRetries :: Int -> LlmFn i o -> LlmFn i o
withRetries n fn = fn { fnRetries = n }

-- | The seed messages 'call' sends for a given input: a System message carrying
-- the output-schema contract, and a User message with the instruction plus the
-- rendered input. Exposed for introspection/debugging and tested directly.
fnPrompt :: LlmFn i o -> i -> [Message]
fnPrompt fn input =
  [ Message System ("Respond ONLY with JSON matching this schema:\n" <> renderSchema (codecSchema (fnOutput fn)))
  , Message User (fnInstruction fn input <> "\n\nInput:\n" <> encode (codecEncode (fnInput fn) input))
  ]

-- | Run a typed function: build the prompt, call the model once, and decode the
-- reply against the output codec. (Retry-on-failure is added in a later task.)
call :: (LLM :> es) => LlmFn i o -> i -> Eff es (Either D.Error o)
call fn input = do
  raw <- complete (fnPrompt fn input)
  pure (decodeLLM (fnOutput fn) raw)
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop . --command zinc test`
Expected: PASS — `1 test suite(s) passed`. (To see the new `ok` lines: `nix develop . --command .zinc/build/spec`.)

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Function.hs test/Spec.hs
git commit -m "feat(fn): Crucible.Function — LlmFn + single-shot call + fnPrompt"
```

---

### Task 2: retry-with-feedback in `call`

**Files:**
- Modify: `src/Crucible/Function.hs` (rewrite `call`)
- Modify: `test/Spec.hs` (add two checks)

- [ ] **Step 1: Write the failing tests**

Add to the `runChecks [ ... ]` list:

```haskell
  , check "llmFn: retries on a bad reply then succeeds"
      (Right "positive")
      (runPureEff (runLLMScripted ["not json", "\"positive\""] (call classifyFn "I love it")))
  , check "llmFn: exhausts retries -> Left"
      True
      (either (const True) (const False)
        (runPureEff (runLLMScripted ["bad", "bad"] (call (withRetries 1 classifyFn) "x"))))
```

- [ ] **Step 2: Run to verify the retry test fails**

Run: `nix develop . --command zinc test`
Expected: FAIL — the "retries on a bad reply then succeeds" check fails (single-shot `call` returns `Left` on the first bad reply, so actual is `Left …`, expected `Right "positive"`).

- [ ] **Step 3: Rewrite `call` with the retry loop**

In `src/Crucible/Function.hs`, replace the `call` definition with:

```haskell
-- | Run a typed function: build the prompt, call the model, and decode the reply
-- against the output codec. On a decode failure, re-ask with the parse error fed
-- back (up to 'fnRetries' times); on exhaustion return 'Left'.
call :: (LLM :> es) => LlmFn i o -> i -> Eff es (Either D.Error o)
call fn input = loop (fnRetries fn) (fnPrompt fn input)
  where
    loop n msgs = do
      raw <- complete msgs
      case decodeLLM (fnOutput fn) raw of
        Right o -> pure (Right o)
        Left err
          | n <= 0    -> pure (Left err)
          | otherwise ->
              loop (n - 1)
                ( msgs
                    ++ [ Message Assistant raw
                       , Message User
                           ( "Your reply did not parse: "
                               <> T.pack (D.message err)
                               <> ". Respond with valid JSON only."
                           )
                       ]
                )
```

- [ ] **Step 4: Run to verify all tests pass**

Run: `nix develop . --command zinc test`
Expected: PASS — `1 test suite(s) passed` (happy, single-shot-Left via `withRetries 0`, retry, exhaustion, and both `fnPrompt` checks).

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Function.hs test/Spec.hs
git commit -m "feat(fn): retry-with-feedback in call (structured-output enforcement)"
```

---

### Task 3: live typed-function demo in the smoke exe

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a typed-function live call**

In `app/Main.hs`, add these imports:

```haskell
import Crucible.Function (llmFn, call)
import Crucible.Codec (str)
import qualified Crucible.Json.Decode as D
import Crucible.LLM.Anthropic (runLLMAnthropic)
```

Then, inside the `Just key -> do` block, after the existing cassette replay lines (before or after the `if live == replayed …` block), add:

```haskell
      let classify = llmFn "classify" str str
            (\s -> "Reply with one word — positive, negative, or neutral — for: " <> s)
      typed <- runEff (runLLMAnthropic cfg (call classify "I absolutely love this!"))
      case typed of
        Right o  -> TIO.putStrLn ("typed fn: " <> o)
        Left err -> TIO.putStrLn ("typed fn decode error: " <> T.pack (D.message err))
```

(If `import qualified Data.Text as T` is not already present in `app/Main.hs`, add it.)

- [ ] **Step 2: Build to verify it compiles**

Run: `nix develop . --command zinc build`
Expected: PASS — `.zinc/build/crucible-anthropic` produced, exit 0.

- [ ] **Step 3: (Optional) run live**

Run:
```bash
set -a; . ./.env; set +a
nix develop . --command env ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" .zinc/build/crucible-anthropic
```
Expected: prints `live: …`, `replay: …`, `OK: cassette replay matches live`, and `typed fn: positive` (one-word sentiment). This makes one paid API call; skip if undesired — the build in Step 2 already proves the typed-function path compiles end-to-end.

- [ ] **Step 4: Commit**

```bash
git add app/Main.hs
git commit -m "feat(fn): typed-function live demo in the smoke exe"
```

---

## Self-Review

**Spec coverage:**
- Decision 1 (template + auto schema) → `fnPrompt` (System: output schema; User: instruction + rendered input). Task 1.
- Decision 2 (template = `i -> Text`) → `fnInstruction :: i -> Text`. Task 1.
- Decision 3 (retry-with-feedback → `Either`) → `call` loop returning `Eff es (Either D.Error o)`. Task 2.
- Decision 4 (declarative `LlmFn` + `call`) → the record + `llmFn`/`withRetries`/`call`. Task 1.
- Interpreter-agnostic property → `call :: (LLM :> es) =>`, tested via `runLLMScripted`; demoed via `runLLMAnthropic` (Task 3).
- Eval-ready property → `LlmFn` is a named value with codecs (satisfied by the type; no separate task needed).
- Tests (happy / retry / exhaustion / schema-injection) → Tasks 1–2.

**Placeholder scan:** none — every step has full code/commands.

**Type consistency:** `LlmFn`/`llmFn`/`withRetries`/`fnPrompt`/`fnOutput`/`call` names and signatures match across the module, tests, and demo. `call` returns `Either D.Error o` (`D.Error` = `Crucible.Json.Decode.Error`, the type `decodeLLM` returns). `fnPrompt` is defined in Task 1 and reused (not redefined) in Task 2's `call`.
