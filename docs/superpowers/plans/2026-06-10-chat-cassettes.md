# Chat Cassettes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record a live native-tool-calling conversation to a cassette and replay it hermetically (no network) — the `Chat` analogue of the existing `LLM` cassettes.

**Architecture:** Add `turnContentJson` (encode a `Turn` to the API content shape via the existing `blockJson`, round-tripping through `parseTurn`), then `recordChatAnthropic` (live `Chat` interpreter that tees each `Turn` to a file) and `runChatCassette` (file-backed `runChatScripted`). All in `Crucible.LLM.Anthropic`, mirroring `recordLLMAnthropic`/`runLLMCassette`.

**Tech Stack:** Haskell GHC 9.6.5, `effectful`, in-repo `Crucible.Json`/`Crucible.Chat`. Build/test via `nix develop . --command zinc {build,test}`.

---

## Background for the implementer

- **Spec:** `docs/superpowers/specs/2026-06-10-chat-cassettes-design.md`.
- **Test harness:** `test/Harness.hs` — `check :: (Eq a, Show a) => String -> a -> a -> IO Bool`, `runChecks :: [IO Bool] -> IO ()`. `test/Spec.hs` is one `runChecks [ ... ]` list in `main`; a list element may be a `do` block doing IO before calling `check`. Run the WHOLE suite with `nix develop . --command zinc test`; pass prints `ALL PASS` / `1 test suite(s) passed`.
- **Existing pattern to mirror** (`src/Crucible/LLM/Anthropic.hs`): `recordLLMAnthropic`/`runLLMCassette` (one JSON line per call, append order; replay pops via `reinterpret (evalState …)`). `converseOnce :: AnthropicConfig -> Manager -> [(ToolName,Schema)] -> [ChatMsg] -> IO (Turn, Usage)` is the shared live round-trip. `blockJson :: Block -> Value` and `parseTurn :: Text -> Either D.Error Turn` already exist. `Crucible.Chat (Block(..), Turn(..), ToolUse(..), Chat(..))` is imported in the module. Imports already present: `qualified Data.Text as T`, `qualified Data.Text.IO as TIO`, `qualified Crucible.Json.Decode as D`, `Effectful.Dispatch.Dynamic (interpret, reinterpret)`, `Effectful.State.Static.Local (evalState, get, put, …)`, `Crucible.Json.Encode (encode)`, `Crucible.Json.Value (Value(..))`.
- `Crucible.Chat.Turn` derives `Eq, Show`; `ToolUse` derives `Eq, Show`.
- **Test fixture** (`test/Spec.hs`): `weatherToolC :: Tl.Tool es = Tl.Tool "get_weather" (SObj [("city", SStr)]) (\_ -> pure (JString "Sunny in Brisbane!"))`. `runToolAgent` / `Turn(..)` / `ToolUse(..)` / `ChatError(..)` are already imported from `Crucible.Chat`; `encode` and `Value(..)` are imported. `Effectful (Eff, runPureEff)` is imported (no `runEff` yet).
- **Commit footer:** end every commit body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: `turnContentJson` — Turn → cassette JSON

**Files:** Modify `src/Crucible/LLM/Anthropic.hs`; Test `test/Spec.hs`.

- [ ] **Step 1: Write the failing tests.** In `test/Spec.hs`, add `turnContentJson` to the existing `Crucible.LLM.Anthropic` import (the line listing `parseTurn`, `parseUsage`, etc.). Add these checks to the `runChecks` list:

```haskell
  -- crucible-dak: Turn JSON round-trip
  , check "turnContentJson: round-trips text + tool_use"
      (Right (Turn "Let me check." [ToolUse "tu_1" "get_weather" (JObject [("city", JString "Brisbane")])]))
      (parseTurn (encode (turnContentJson
        (Turn "Let me check." [ToolUse "tu_1" "get_weather" (JObject [("city", JString "Brisbane")])]))))
  , check "turnContentJson: round-trips text-only"
      (Right (Turn "Hello." []))
      (parseTurn (encode (turnContentJson (Turn "Hello." []))))
  , check "turnContentJson: round-trips tool-only"
      (Right (Turn "" [ToolUse "u" "f" (JObject [])]))
      (parseTurn (encode (turnContentJson (Turn "" [ToolUse "u" "f" (JObject [])]))))
```

- [ ] **Step 2: Run suite to verify it fails.** `nix develop . --command zinc test` → build failure (`turnContentJson` not in scope / not exported).

- [ ] **Step 3: Implement.** In `src/Crucible/LLM/Anthropic.hs`:

(a) Add `turnContentJson` to the module export list (e.g. after `parseTurn`).

(b) Add the definition near the other wire encoders (e.g. just above `blockJson`, or anywhere at top level — Haskell definition order doesn't matter):

```haskell
-- | Encode a 'Turn' to the Anthropic content shape (reusing 'blockJson'), for
-- recording to a chat cassette. Round-trips: @parseTurn (encode (turnContentJson t)) == Right t@.
turnContentJson :: Turn -> Value
turnContentJson (Turn t uses) =
  JObject [("content", JArray (map blockJson blocks))]
  where
    blocks = [TextBlock t | not (T.null t)] ++ map ToolUseBlock uses
```

- [ ] **Step 4: Run suite to verify it passes.** `nix develop . --command zinc test` → the three round-trip checks `ok`, `ALL PASS`.

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/LLM/Anthropic.hs test/Spec.hs
git commit -m "$(printf 'feat(chat): turnContentJson — Turn to cassette JSON (round-trips via parseTurn)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: `recordChatAnthropic` + `runChatCassette`

**Files:** Modify `src/Crucible/LLM/Anthropic.hs`; Test `test/Spec.hs`.

Context — the LLM cassette functions this mirrors:
```haskell
recordLLMAnthropic path cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret (\_ (Complete msgs) -> liftIO $ do { reply <- anthropicComplete cfg mgr msgs; TIO.appendFile path (encode (JString reply) <> "\n"); pure reply }) action

runLLMCassette path action = do
  contents <- liftIO (TIO.readFile path)
  let replies = [ either (const ln) id (D.decodeString D.string ln) | ln <- T.lines contents, not (T.null ln) ]
  reinterpret (evalState replies) (\_ -> \case Complete _ -> do { rs <- get; case rs of (x:xs) -> put xs >> pure x; [] -> pure "" }) action
```

- [ ] **Step 1: Write the failing test (hermetic replay).** In `test/Spec.hs`:

(a) Add `runEff` to the existing `Effectful (Eff, runPureEff)` import → `Effectful (Eff, runEff, runPureEff)`. Add `import qualified Data.Text.IO as TIO`. Add `runChatCassette` to the `Crucible.LLM.Anthropic` import.

(b) Add this `do`-block check to the `runChecks` list:

```haskell
  -- crucible-dak: hermetic cassette replay drives a tool loop
  , do let cassettePath = "/tmp/crucible-chat-cassette-test.jsonl"
           cassette =
             encode (turnContentJson (Turn "" [ToolUse "u1" "get_weather" (JObject [("city", JString "Brisbane")])])) <> "\n"
             <> encode (turnContentJson (Turn "Sunny in Brisbane!" [])) <> "\n"
       TIO.writeFile cassettePath cassette
       r <- runEff (runChatCassette cassettePath (runToolAgent [weatherToolC] "weather in Brisbane?"))
       check "runChatCassette: replays a tool loop to the final answer"
         (Right "Sunny in Brisbane!")
         r
```

- [ ] **Step 2: Run suite to verify it fails.** `nix develop . --command zinc test` → build failure (`runChatCassette` not exported).

- [ ] **Step 3: Implement.** In `src/Crucible/LLM/Anthropic.hs`:

(a) Add `recordChatAnthropic` and `runChatCassette` to the module export list.

(b) Add the definitions (e.g. just after `runChatAnthropic`):

```haskell
-- | Like 'runChatAnthropic', but also TEE each assistant 'Turn' to a cassette
-- file (one content-JSON line, appended in call order). Replays via
-- 'runChatCassette'.
recordChatAnthropic :: (IOE :> es) => FilePath -> AnthropicConfig -> Eff (Chat : es) a -> Eff es a
recordChatAnthropic path cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Converse specs msgs) -> liftIO $ do
        (turn, _u) <- converseOnce cfg mgr specs msgs
        TIO.appendFile path (encode (turnContentJson turn) <> "\n")
        pure turn)
    action

-- | Replay a cassette recorded by 'recordChatAnthropic': each 'Converse' pops
-- the next recorded 'Turn' in order (a file-backed 'runChatScripted').
-- Deterministic; no network. Exhausting the cassette yields @Turn "" []@.
runChatCassette :: (IOE :> es) => FilePath -> Eff (Chat : es) a -> Eff es a
runChatCassette path action = do
  contents <- liftIO (TIO.readFile path)
  let turns =
        [ either (const (Turn "" [])) id (parseTurn ln)
        | ln <- T.lines contents
        , not (T.null ln)
        ]
  reinterpret (evalState turns) (\_ -> \case
    Converse _ _ -> do
      ts <- get
      case ts of
        (t : rest) -> put rest >> pure t
        []         -> pure (Turn "" []))
    action
```

- [ ] **Step 4: Build + run the suite.** `nix develop . --command zinc build` → exit 0, no warnings. `nix develop . --command zinc test` → the replay check `ok`, `ALL PASS`. (The hermetic test proves `runChatCassette` drives a full tool loop: the first popped turn requests `get_weather`, `weatherToolC` runs and its result is fed back, the second popped turn is the final text answer. `recordChatAnthropic` is network-bound — verified by build here and exercised live in Task 3.)

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/LLM/Anthropic.hs test/Spec.hs
git commit -m "$(printf 'feat(chat): recordChatAnthropic + runChatCassette (record/replay tool-calling)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: live record/replay demo

**Files:** Modify `app/Main.hs`.

Context: `app/Main.hs` already imports `Crucible.LLM.Anthropic (… runChatAnthropic …)`, `Crucible.Chat (runToolAgent)`, `Crucible.Tool as Tl`, `Crucible.Schema (Schema(SObj, SStr))`, `Crucible.Json.Value (Value(JString))`, `Effectful (runEff)`, `Data.Text as T`, `Data.Text.IO as TIO`. It has a streaming tool-agent demo near the end of the `Just key -> do` block using a `weatherTool2` fixture.

- [ ] **Step 1: Add imports.** In `app/Main.hs`, add `recordChatAnthropic` and `runChatCassette` to the existing `Crucible.LLM.Anthropic` import block:

```haskell
  , recordChatAnthropic
  , runChatCassette
```

- [ ] **Step 2: Append the cassette demo.** At the END of the `Just key -> do` block (after the existing streaming-tool demo), at the same indentation as the other demo statements, append:

```haskell
      -- Chat cassette: record a live tool-agent run, then replay it (no network).
      let chatCassette = "/tmp/crucible-chat-cassette.jsonl"
          weatherTool3 = Tl.Tool "get_weather" (SObj [("city", SStr)])
            (\_ -> pure (JString "It is 26C and sunny."))
          toolQuestion = "Use the tool to get the weather in Brisbane, then tell me."
      TIO.writeFile chatCassette ""  -- fresh cassette
      recordedAns <- runEff (recordChatAnthropic chatCassette cfg (runToolAgent [weatherTool3] toolQuestion))
      replayedAns <- runEff (runChatCassette chatCassette (runToolAgent [weatherTool3] toolQuestion))
      case (recordedAns, replayedAns) of
        (Right a, Right b)
          | a == b    -> TIO.putStrLn ("chat cassette: OK replay matches — " <> a)
          | otherwise -> TIO.putStrLn ("chat cassette: MISMATCH — live=" <> a <> " replay=" <> b)
        _ -> TIO.putStrLn "chat cassette: a run failed"
```

- [ ] **Step 3: Build.** `nix develop . --command zinc build` → exit 0.

- [ ] **Step 4: Run the live demo.** The binary reads `ANTHROPIC_API_KEY` from the environment (`.env` is gitignored — never print/commit it). Run:

```bash
nix develop . --command bash -c 'set -a; . ./.env; set +a; BIN=$(find .zinc/build -type f -name crucible-anthropic | head -1); "$BIN"'
```

Expected: a final line `chat cassette: OK replay matches — <answer>`, confirming the recorded tool-agent conversation replays to the same answer with no network on the replay pass. PASTE the actual `chat cassette:` line. If the live call fails for an environment reason (no network/key), report DONE_WITH_CONCERNS noting the build succeeded but the live run could not be verified — do NOT fake output.

- [ ] **Step 5: Confirm suite green + commit.** `nix develop . --command zinc test` → `1 test suite(s) passed`.

```bash
git add app/Main.hs
git commit -m "$(printf 'feat(chat): live chat-cassette record/replay demo\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Self-Review

**1. Spec coverage:**
- `turnContentJson` (exported; reuse `blockJson`; round-trips via `parseTurn`) → Task 1. ✅
- `recordChatAnthropic` (tee each Turn via `converseOnce` + `turnContentJson`) → Task 2. ✅
- `runChatCassette` (file-backed `runChatScripted`; exhausted → `Turn "" []`; unparseable line → `Turn "" []`) → Task 2. ✅
- Tests: round-trip (text+tool/text-only/tool-only) + hermetic replay driving a tool loop → Tasks 1-2. ✅
- Live record/replay demo → Task 3. ✅
- No new deps; non-goals respected (no usage on replay — `runChatCassette` returns `a`; no streaming cassette; API content-shape format). ✅

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. The Task 3 run note describes the live-invocation fallback, not a code placeholder.

**3. Type consistency:** `turnContentJson :: Turn -> Value` used in Tasks 1-3; `recordChatAnthropic :: FilePath -> AnthropicConfig -> Eff (Chat:es) a -> Eff es a` and `runChatCassette :: FilePath -> Eff (Chat:es) a -> Eff es a` consistent across definition, exports, tests, and demo. `parseTurn :: Text -> Either D.Error Turn` consumes `encode (turnContentJson t)`; `Turn`/`ToolUse` Eq make the round-trip and replay assertions valid. `converseOnce`'s `(Turn, Usage)` is used via the tuple pattern `(turn, _u)`. ✅
