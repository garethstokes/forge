# Crucible DevEx Overhaul — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A behaviour-preserving naming/ergonomics overhaul: `LlmFn`→`Skill`, drop record-field prefixes (record-dot), module-qualified interpreter names, typed `DecodeError`, `SAP`→`Decode`, a type-driven `tool`, and `ChatMsg`→`Chat.Message`.

**Architecture:** Surface-only. Each task is a mechanical, behaviour-preserving rename/addition that keeps the build + suite green (unlike the aeson migration). One branch; the user manual + public-repo push are the final tasks.

**Tech Stack:** Haskell GHC 9.10.1 (built-in `OverloadedRecordDot`/`NoFieldSelectors`/`DuplicateRecordFields`). Build/test via `nix develop . --command zinc {build,test}`.

---

## Background for the implementer

- **Spec:** `docs/superpowers/specs/2026-06-10-devex-overhaul-design.md`.
- These are **behaviour-preserving renames** — every task ends with `nix develop . --command zinc build` (exit 0) + `zinc test` (`1 test suite(s) passed`). A rename touches many call sites; the compiler enumerates them — fix each to green. The *content* (prompts, wire JSON, effects) never changes.
- **`NoFieldSelectors` consequence:** field names stop being functions, so every *field-as-getter* use becomes a record-dot section `(.field)`. The hand-written codecs are the main ones: `C.field "city" city C.str` → `C.field "city" (.city) C.str`; `object (ToolCall <$> field "tool" tcName str <*> field "args" tcArgs anyValue)` → `… (.name) … (.args) …`; `field "vPass" vPass bool` → `field "pass" (.pass) bool`; `field "answer" id str` is unaffected (`id`, not a selector). `genericCodec` uses GHC.Generics, not selectors — unaffected.
- **`ChatMsg` is a positional constructor** (`data ChatMsg = ChatMsg Role [Block]`), so item 7 is a pure type+constructor rename (no field work).
- **Reserved-word snag:** `Result`'s `resCase` field can't become `case` (keyword) — use `case'`.
- **Commit footer:** end every commit body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: drop record-field prefixes (record-dot)

**Files:** `src/Crucible/LLM/Anthropic.hs`, `Usage.hs`, `Function.hs`, `Tool.hs`, `Chat.hs`, `Eval.hs`, `LLM/Anthropic/Stream.hs`, and all readers (`Agent.hs`, `Decision.hs`, `Example.hs`, `app/Main.hs`, `test/Spec.hs`).

- [ ] **Step 1: add pragmas.** To every module that *defines* a renamed record add `{-# LANGUAGE DuplicateRecordFields #-}` and `{-# LANGUAGE NoFieldSelectors #-}`; to every module that *reads* fields add `{-# LANGUAGE OverloadedRecordDot #-}`. (Many modules both define and read — add all three.)

- [ ] **Step 2: rename the fields** per this table (constructor names and positional order unchanged):

| record | renames |
|---|---|
| `AnthropicConfig` | `acApiKey→apiKey, acModel→model, acMaxTokens→maxTokens, acTimeoutSecs→timeoutSecs, acMaxRetries→maxRetries, acBaseDelayMicros→baseDelayMicros, acStreamIdleSecs→streamIdleSecs` |
| `Usage` | `usInputTokens→inputTokens, usOutputTokens→outputTokens` |
| `Rates` | `rInputPerMTok→inputPerMTok, rOutputPerMTok→outputPerMTok` |
| `LlmFn` (Function) | `fnName→name, fnInstruction→instruction, fnInput→input, fnOutput→output, fnRetries→retries` |
| `Tool` | `toolName→name, toolSchema→schema, toolRun→run` |
| `ToolCall` | `tcName→name, tcArgs→args` |
| `ToolUse` | `tuId→id, tuName→name, tuArgs→args` |
| `Turn` | `turnText→text, turnToolUses→toolUses` |
| `Verdict` (Eval) | `vPass→pass, vWhy→why` |
| `Case` (Eval) | `caseInput→input, caseName→name` (keep `expect`) |
| `Score` (Eval) | `scoreValue→value` (keep `rationale`) |
| `Result` (Eval) | `resCase→case', resOutput→output, resScore→score` |
| `Report` (Eval) | keep `results, passRate, meanScore` (no prefixes) |
| `StreamAcc` | `saText→text, saPartial→partial, saTools→tools, saUsage→usage` |

`Message { role, content }` is already prefix-free — unchanged.

- [ ] **Step 3: convert field-as-getter uses to record-dot.** Build (`zinc build`) and fix each error: every place a renamed field was used *as a function* becomes `(.field)` or `x.field`. Key sites: the hand-written codecs (`forecastCodec`, `toolCallCodec`, `agentCodec`/`answerCodec`, `verdictCodec`), `toolsHelp`, `runToolAgent`'s `turnText`/`turnToolUses`/`tuName`/`tuId`/`tuArgs`/`toolName`/`toolRun`, `estimateCost`/`usTotalTokens` reading `usInputTokens`→`.inputTokens`, `fnPrompt`/`call` reading `fnOutput`→`.output` etc., `openStream`/`postMessages` reading `acApiKey`→`cfg.apiKey`, the Stream loop reading `saUsage`→`.usage`, and the Main/test call sites. Repeat until `zinc build` exit 0.

- [ ] **Step 4: build + suite green.** `nix develop . --command zinc build` → exit 0. `nix develop . --command zinc test` → `1 test suite(s) passed`. (Any failing test asserting via the old field name updates to `.field`.)

- [ ] **Step 5: commit.**

```bash
git add -A
git commit -m "$(printf 'refactor(devex): drop record-field prefixes; record-dot access\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: `LlmFn` → `Skill`; module `Crucible.Function` → `Crucible.Skill`

**Files:** `git mv src/Crucible/Function.hs src/Crucible/Skill.hs`; readers (`Agent.hs`? no — Agent uses Decision; `app/Main.hs`, `test/Spec.hs`, `Example.hs` if it uses llmFn — it doesn't; only Main/tests).

- [ ] **Step 1: move + rename the module.** `git mv src/Crucible/Function.hs src/Crucible/Skill.hs`. In the file: `module Crucible.Skill (Skill(..), skill, call, withRetries, prompt) where`. Rename the type `LlmFn`→`Skill`, the constructor `LlmFn`→`Skill`, `llmFn`→`skill`, `fnPrompt`→`prompt`. (`call`, `withRetries` keep their names.)

- [ ] **Step 2: update importers.** `app/Main.hs` and `test/Spec.hs`: `import Crucible.Function (LlmFn, llmFn, call, …)` → `import Crucible.Skill (Skill, skill, call, withRetries, prompt, …)`; uses `LlmFn`→`Skill`, `llmFn`→`skill`, `fnPrompt`→`prompt`. (zinc auto-discovers the new module; remove the old path.)

- [ ] **Step 3: build + suite green; commit.**

```bash
git add -A
git commit -m "$(printf 'refactor(devex): LlmFn -> Skill (Crucible.Function -> Crucible.Skill)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: module-qualified interpreter names

**Files:** `src/Crucible/LLM/Anthropic.hs` (rename + re-export streams), `LLM/Anthropic/Stream.hs` (unchanged exports), `app/Main.hs`, `test/Spec.hs`.

- [ ] **Step 1: rename the interpreter exports** in `Crucible.LLM.Anthropic` and their definitions:

| old | new |
|---|---|
| `runLLMAnthropic` | `run` |
| `runChatAnthropic` | `runChat` |
| `runLLMAnthropicUsage` | `usage` |
| `runChatAnthropicUsage` | `usageChat` |
| `recordLLMAnthropic` | `record` |
| `runLLMCassette` | `replay` |
| `recordChatAnthropic` | `recordChat` |
| `runChatCassette` | `replayChat` |

- [ ] **Step 2: re-export the streaming interpreters.** In `Crucible.LLM.Anthropic`, add to the export list and re-export from the Stream module so `Anthropic.stream`/`Anthropic.streamChat` resolve under one qualified import:

```haskell
import Crucible.LLM.Anthropic.Stream (runLLMAnthropicStream, runChatAnthropicStream)
-- in the export list, re-export under the new names:
--   , stream, streamChat
stream :: (IOE :> es, Emit :> es) => AnthropicConfig -> Eff (LLM : es) a -> Eff es (a, Usage)
stream = runLLMAnthropicStream
streamChat :: (IOE :> es, Emit :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es (a, Usage)
streamChat = runChatAnthropicStream
```
(Leave the `.Stream` module's own exports as-is; these are thin re-export aliases. Adjust the `import`s/`IOE`/`Emit`/`LLM`/`Chat` as already present.)

- [ ] **Step 3: update call sites to qualified form.** In `app/Main.hs` and `test/Spec.hs`, change `import Crucible.LLM.Anthropic (runLLMAnthropic, …)` to `import qualified Crucible.LLM.Anthropic as Anthropic` (keep `AnthropicConfig`/`AnthropicError`/`defaultAnthropicConfig`/`isRetryable` available — either via the qualified import as `Anthropic.AnthropicConfig` or a small unqualified import for the types). Rewrite uses: `runLLMAnthropic cfg` → `Anthropic.run cfg`, `runChatAnthropicUsage` → `Anthropic.usageChat`, `runLLMAnthropicStream` → `Anthropic.stream`, `recordLLMAnthropic` → `Anthropic.record`, `runLLMCassette` → `Anthropic.replay`, `recordChatAnthropic` → `Anthropic.recordChat`, `runChatCassette` → `Anthropic.replayChat`, etc. The `Stream` module import in Main (`runLLMAnthropicStream`,`runChatAnthropicStream`) is dropped in favour of `Anthropic.stream`/`streamChat`.

- [ ] **Step 4: build + suite green; commit.**

```bash
git add -A
git commit -m "$(printf 'refactor(devex): module-qualified Anthropic interpreters (run/usage/stream/record/replay)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 4: typed `DecodeError`

**Files:** `src/Crucible/SAP.hs` (still named SAP until Task 5), `src/Crucible/Skill.hs`, `Agent.hs`, `Eval.hs`, `test/Spec.hs`.

- [ ] **Step 1: add the type + retarget `decodeLLM`.** In `src/Crucible/SAP.hs` add:

```haskell
data DecodeError = DecodeError { message :: Text, raw :: Text }
  deriving (Eq, Show)

decodeLLM :: JSONCodec a -> Text -> Either DecodeError a
decodeLLM c t =
  case A.eitherDecode (LB.fromStrict (TE.encodeUtf8 (stripToJson t))) of
    Left err -> Left (DecodeError (T.pack err) t)
    Right v  -> either (\e -> Left (DecodeError (T.pack e) t)) Right
                       (AT.parseEither (parseJSONVia c) (v :: Value))
```
Export `DecodeError(..)`. (Module needs `DuplicateRecordFields`/`NoFieldSelectors` since `message`/`raw` are dotted fields, and `qualified Data.Aeson.Types as AT`.)

- [ ] **Step 2: thread it through callers.** `Skill.call :: … -> Eff es (Either DecodeError o)`; its retry loop uses `err.message` where it built the reprompt from the string (`[text|Your reply did not parse: ${m}…|]` with `m = err.message`), and `Left err` returns the `DecodeError`. `Agent.runAgent`: `decodeLLM codec raw` now `Either DecodeError _`; reprompt uses `err.message`. `Eval.judge`: `Left e -> Score 0.0 ("judge parse error: " <> e.message)`.

- [ ] **Step 3: add a test.** In `test/Spec.hs`:

```haskell
  , check "decodeLLM: malformed reply -> Left DecodeError carrying the raw text"
      (Left True)
      (case decodeLLM C.str "not json at all" of
         Left e  -> Left (e.raw == "not json at all")
         Right _ -> Right ())
```
Update any existing test that matched the old `Either String` decode result.

- [ ] **Step 4: build + suite green; commit.**

```bash
git add -A
git commit -m "$(printf 'feat(devex): typed DecodeError {message, raw} for call/decodeLLM\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 5: `Crucible.SAP` → `Crucible.Decode`

**Files:** `git mv src/Crucible/SAP.hs src/Crucible/Decode.hs`; importers (`Skill.hs`, `Agent.hs`, `Eval.hs`, `test/Spec.hs`).

- [ ] **Step 1:** `git mv src/Crucible/SAP.hs src/Crucible/Decode.hs`; change the module header to `module Crucible.Decode (stripToJson, decodeLLM, DecodeError(..)) where`. Update every `import Crucible.SAP …` → `import Crucible.Decode …`.

- [ ] **Step 2: build + suite green; commit.**

```bash
git add -A
git commit -m "$(printf 'refactor(devex): Crucible.SAP -> Crucible.Decode\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 6: type-driven `tool` constructor (additive)

**Files:** `src/Crucible/Tool.hs`, `test/Spec.hs`.

- [ ] **Step 1: add `tool`.** In `src/Crucible/Tool.hs`, keep the raw `Tool` constructor; add:

```haskell
-- imports: Crucible.Codec (schemaValue), Crucible.Codec.Generic (HasCodec, codec),
--          Crucible.Decode (decodeLLM), Autodocodec (JSONCodec), Data.Aeson (Value), qualified Data.Aeson as A
-- | Build a tool whose JSON-Schema is derived from its argument type and whose
-- arguments are decoded for you. A decode failure is surfaced as an error
-- 'Value' (the existing tool error convention).
tool :: forall a es. HasCodec a => Text -> (a -> Eff es Value) -> Tool es
tool nm run' = Tool nm (schemaValue (codec @a)) $ \args ->
  case AT.parseEither (parseJSONVia (codec @a)) args of
    Right a  -> run' a
    Left err -> pure (A.String ("bad tool args: " <> T.pack err))
```
Add `tool` to the export list. (Uses `parseJSONVia`/`AT.parseEither` on the aeson `Value` args directly — the args arrive as a `Value`, no text-stripping needed.)

- [ ] **Step 2: add a test.** In `test/Spec.hs` (define a tiny `HasCodec` arg type or reuse one):

```haskell
data Loc = Loc { city :: Text } deriving (Show, Generic)
instance HasCodec Loc where codec = genericCodec
-- check: the derived tool's schema is an object, and it runs on decoded args
  , check "tool: type-driven constructor derives object schema + decodes args"
      (Just (String "object"), A.String "sunny in Hobart")
      ( let t = Tl.tool "weather" (\(Loc c) -> pure (A.String ("sunny in " <> c))) :: Tl.Tool '[]
        in ( schemaType (Tl.schema t)
           , runPureEff (Tl.run t (object ["city" .= String "Hobart"])) ) )
```
(Adjust `Tl.run`/`Tl.schema` to the record-dot field access from Task 1; `runPureEff` since the tool body is pure here.)

- [ ] **Step 3: build + suite green; commit.**

```bash
git add -A
git commit -m "$(printf 'feat(devex): type-driven tool constructor (schema derived, args decoded)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 7: `ChatMsg` → `Message` (in `Crucible.Chat`)

**Files:** `src/Crucible/Chat.hs`, importers (`LLM/Anthropic.hs`, `app/Main.hs`?, `test/Spec.hs`).

- [ ] **Step 1: rename the type + constructor.** In `src/Crucible/Chat.hs`: `data Message = Message Role [Block]` (was `ChatMsg`); export `Message(..)` (was `ChatMsg(..)`); update internal uses (`runToolAgent` builds `Message User [...]`). Update the `Converse :: [(ToolName, Value)] -> [Message] -> Chat m Turn` signature and `converse`.

- [ ] **Step 2: update importers with qualification.** `Crucible.LLM.Anthropic` uses `ChatMsg` (in `chatRequestJson`/`chatMsgJson`/`converseOnce`) — import `Crucible.Chat` qualified (or import `Message` from Chat hiding/qualified to avoid clash with `Crucible.LLM.Message`). The cleanest: in modules that use BOTH message types, `import qualified Crucible.Chat as Chat` and write `Chat.Message`. `test/Spec.hs` likewise (`ChatMsg(..)` in its Chat import → `Message` qualified, or alias). Resolve the `Message` name clash via qualification.

- [ ] **Step 3: build + suite green; commit.**

```bash
git add -A
git commit -m "$(printf 'refactor(devex): Chat ChatMsg -> Message (used qualified as Chat.Message)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 8: update the user manual + all docs snippets

**Files:** `docs/*.md` (`index`, `getting-started`, `effects`, `typed-functions`, `tool-calling`, `streaming`, `usage-and-cassettes`, `live-interpreter`).

- [ ] **Step 1: apply the name map to every snippet.** Across all manual pages: `LlmFn`→`Skill`, `llmFn`→`skill`; the interpreter names → `Anthropic.run`/`runChat`/`usage`/`usageChat`/`stream`/`streamChat`/`record`/`replay`/`recordChat`/`replayChat` (show the `import qualified Crucible.LLM.Anthropic as Anthropic`); record fields → record-dot (`usage.inputTokens`, `cfg.model`, `turn.text`, `tool.name`); `Either String`→`Either DecodeError` (and `err.message`); `Crucible.SAP`→`Crucible.Decode`; show the type-driven `tool` in `tool-calling.md`; `Crucible.Function`→`Crucible.Skill`. The `typed-functions.md` page's `Skill` type name and `call … :: Either DecodeError o`.

- [ ] **Step 2: link/symbol sanity.** Re-grep the docs for any stale `LlmFn`/`llmFn`/`runLLMAnthropic`/`acApiKey`/`Crucible.SAP`/`ChatMsg` and fix. Cross-links unchanged.

- [ ] **Step 3: commit.**

```bash
git add docs/
git commit -m "$(printf 'docs(site): update manual snippets to the new DevEx names\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 9: live verify + push

**Files:** none (verification + publish).

- [ ] **Step 1: live smoke run.** `nix develop . --command zinc build` (exit 0), then (key from `.env`, never echo it):

```bash
nix develop . --command bash -c 'set -a; . ./.env; set +a; BIN=$(find .zinc/build -type f -name crucible-anthropic | head -1); "$BIN"'
```
Expected: the renamed demo runs end-to-end unchanged (typed fn → a sentiment word, tool agent, usage, streaming, both cassettes). Paste output. If env-blocked, report DONE_WITH_CONCERNS (build + suite green, live unverified).

- [ ] **Step 2: merge to master + push** (the repo is public; push rebuilds Pages). This is handled by `superpowers:finishing-a-development-branch` (merge to master) followed by `git push origin master`; confirm `gh api repos/garethstokes/crucible/pages/builds/latest` rebuilds.

---

## Self-Review

**1. Spec coverage:** Skill rename + module → Task 2. Field prefixes/record-dot → Task 1. Module-qualified interpreters (+ stream re-export, chat-suffix grammar, record/replay) → Task 3. DecodeError → Task 4. SAP→Decode → Task 5. type-driven tool (additive) → Task 6. ChatMsg→Chat.Message → Task 7. Manual update → Task 8. Live verify + push → Task 9. ✅ All spec items mapped.

**2. Placeholder scan:** No TBD/TODO. The rename tasks legitimately say "fix each compile error to green" — for a behaviour-preserving rename the compiler enumerates the sites and each task ends green; the mapping tables + representative edits are the complete spec of the change. Novel code (DecodeError, tool, stream re-export) is spelled out.

**3. Type/name consistency:** field renames match the spec table exactly (incl. `resCase→case'` keyword dodge, `Score.value`, `Verdict.pass/why`); interpreter names match the spec grammar (text unsuffixed / chat `…Chat` / record–replay); `Skill(..), skill, call, withRetries, prompt` consistent across Tasks 2/4/8; `DecodeError { message, raw }` consistent in Tasks 4/5/8; `tool :: HasCodec a => Text -> (a -> Eff es Value) -> Tool es` consistent in Task 6/8; `Chat.Message` consistent in Tasks 7/8. ✅
