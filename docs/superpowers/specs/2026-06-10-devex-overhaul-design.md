# Crucible: developer-experience naming overhaul

**Goal.** A surface-only DevEx pass over crucible's public API, applying
Elm/Go/Rust/Elixir naming sensibilities: rename `LlmFn` → `Skill`, drop the
record-field prefixes (record-dot access), collapse the combinatorial
interpreter names into a module-qualified scheme, add a type-driven `tool`
constructor, restore a typed decode error, and rename the opaque `SAP` module.
Behaviour is unchanged throughout — only names, field access, and one additive
helper.

**Why.** The API is shipped and documented but carries Haskell-era ergonomics a
Go/Rust/Elm/Elixir developer would flag: Hungarian field prefixes
(`usInputTokens`), a combinatorial name explosion (`run{LLM,Chat}Anthropic{,Usage,
Stream}`), a stringly-typed error (`Either String`), and an acronym module name
(`SAP`). GHC 9.10 (already in use) supports the record-dot machinery that removes
the prefixes.

## Decisions (all user-confirmed)

### 1. `LlmFn` → `Skill`; module `Crucible.Function` → `Crucible.Skill`
```haskell
data Skill i o                       -- was LlmFn
skill :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> Skill i o   -- was llmFn
call :: (LLM :> es) => Skill i o -> i -> Eff es (Either DecodeError o)
withRetries :: Int -> Skill i o -> Skill i o
prompt :: Skill i o -> i -> [Message]   -- was fnPrompt
```
Exports of `Crucible.Skill`: `Skill(..), skill, call, withRetries, prompt`.

### 2. Interpreters → module-qualified short
`import qualified Crucible.LLM.Anthropic as Anthropic`. Grammar: **text path
unsuffixed, chat path `…Chat`; record/replay pair.**

| old | new |
|---|---|
| `runLLMAnthropic` | `Anthropic.run` |
| `runChatAnthropic` | `Anthropic.runChat` |
| `runLLMAnthropicUsage` | `Anthropic.usage` |
| `runChatAnthropicUsage` | `Anthropic.usageChat` |
| `runLLMAnthropicStream` | `Anthropic.stream` |
| `runChatAnthropicStream` | `Anthropic.streamChat` |
| `recordLLMAnthropic` | `Anthropic.record` |
| `runLLMCassette` | `Anthropic.replay` |
| `recordChatAnthropic` | `Anthropic.recordChat` |
| `runChatCassette` | `Anthropic.replayChat` |

The two streaming interpreters (currently in `Crucible.LLM.Anthropic.Stream`) are
**re-exported from `Crucible.LLM.Anthropic`** so `Anthropic.stream` /
`Anthropic.streamChat` resolve under the single qualified import. The internal
SSE machinery (`splitFrames`/`parseEvent`/`StreamAcc`/…) stays in the `.Stream`
module. Internal helpers `requestJson`/`chatRequestJson`/`messagesRequest`/
`withAnthropicRetry`/`parseTurn`/`parseUsage`/`turnContentJson`/
`newAnthropicManager` keep their names (not user-facing prose).

### 3. Type-driven `tool` (additive)
```haskell
-- Crucible.Tool
tool :: HasCodec a => Text -> (a -> Eff es Value) -> Tool es
-- schema = schemaValue (codec @a); args decoded via decodeLLM-style parse;
-- a decode failure of the tool's args is surfaced as an error Value (the
-- existing Tool error convention).
```
The raw `Tool { name, schema, run }` constructor stays exported as the escape
hatch for hand-written schemas / dynamic tools.

### 4. Drop field prefixes via record-dot
Add `{-# LANGUAGE DuplicateRecordFields #-}`, `{-# LANGUAGE NoFieldSelectors #-}`
to record-defining modules, and `{-# LANGUAGE OverloadedRecordDot #-}` to
modules that *read* fields. Fields lose their prefixes; access becomes `value.field`;
field-as-function uses (`fnName s`) become `(.field)` / `s.field`. Shared field
names (`name`, `args`, `text`, `usage`) across records are fine under
`DuplicateRecordFields`/`NoFieldSelectors`.

| record | before → after |
|---|---|
| `AnthropicConfig` | `acApiKey…` → `apiKey, model, maxTokens, timeoutSecs, maxRetries, baseDelayMicros, streamIdleSecs` |
| `Usage` | `usInputTokens, usOutputTokens` → `inputTokens, outputTokens` |
| `Rates` | `rInputPerMTok, rOutputPerMTok` → `inputPerMTok, outputPerMTok` |
| `Skill` (was LlmFn) | `fnName…` → `name, instruction, input, output, retries` |
| `Tool` | `toolName, toolSchema, toolRun` → `name, schema, run` |
| `ToolUse` | `tuId, tuName, tuArgs` → `id, name, args` |
| `ToolCall` | `tcName, tcArgs` → `name, args` |
| `Turn` | `turnText, turnToolUses` → `text, toolUses` |
| `Verdict` (Eval) | `vPass, vWhy` → `pass, why` |
| `StreamAcc` | `saText, saPartial, saTools, saUsage` → `text, partial, tools, usage` |
| `Eval` records (`Case`/`Score`/`Result`/`Report`) | drop their prefixes to the bare field name |

`Message { role, content }` already has no prefix — unchanged. `usTotalTokens` /
`estimateCost` / etc. keep their names (they are functions, not fields), but read
the renamed fields via record-dot.

### 5. Typed decode error
```haskell
-- Crucible.Decode
data DecodeError = DecodeError { message :: Text, raw :: Text }
  deriving (Eq, Show)
decodeLLM :: JSONCodec a -> Text -> Either DecodeError a
```
`call` returns `Eff es (Either DecodeError o)`; `Agent.runAgent` / `Eval.judge`
render `err.message` and may inspect `err.raw`. The `raw` field carries the
model's reply that failed to parse (useful for debugging/evals).

### 6. `Crucible.SAP` → `Crucible.Decode`
Houses `decodeLLM`, `stripToJson`, `DecodeError`. The acronym module name is gone.

### 7. `ChatMsg` → `Message` (in `Crucible.Chat`)
Renamed to `Message`, used qualified as `Chat.Message` (distinct from
`Crucible.LLM.Message`). Chat-path code imports `Crucible.Chat` qualified. The
record/blocks (`Block`, `ToolUse`, `Turn`) are unchanged except for the
field-prefix drop.

## Per-module impact

- **Renamed modules:** `Crucible.Function` → `Crucible.Skill`; `Crucible.SAP` →
  `Crucible.Decode`.
- **Record-prefix drop + pragmas:** every record-defining module (`LLM.Anthropic`,
  `Usage`, `Skill`, `Tool`, `Chat`, `Eval`, `Anthropic.Stream`) and every reader.
- **Interpreter renames:** `Crucible.LLM.Anthropic` (rename + re-export the two
  stream interpreters); all call sites (`app/Main.hs`, tests).
- **`tool` + raw ctor:** `Crucible.Tool`.
- **`DecodeError`:** `Crucible.Decode`, threaded through `Skill.call`,
  `Agent.runAgent`, `Eval.judge`.
- **Consumers updated:** `Agent`, `Decision`, `Example`, `Eval`, `app/Main.hs`,
  `test/Spec.hs`, and **the user manual** (`docs/*.md` — every snippet uses the
  new names).

## Sequencing (one branch; each task keeps the build + suite green)

Behaviour-preserving renames, so each step compiles green (unlike the aeson
migration):

1. Field-prefix drop + record-dot (records + readers).
2. `LlmFn` → `Skill`, module `Function` → `Skill`.
3. Interpreter module-qualified renames (+ stream re-export).
4. `DecodeError` (typed error through `call`/`runAgent`/`judge`).
5. `Crucible.SAP` → `Crucible.Decode`.
6. Additive `tool` constructor.
7. `ChatMsg` → `Chat.Message`.
8. Update the user manual + all `docs/*.md` snippets to the new names.
9. Build + full suite + **live smoke run**; commit; **push to the public repo**
   (rebuilds Pages).

## Testing / verification

- Each task: `nix develop . --command zinc build` (exit 0) + `zinc test`
  (`1 test suite(s) passed`). Renames are mechanical and behaviour-preserving, so
  green is expected at every step.
- Add a small test for the type-driven `tool` (a `HasCodec`-args tool runs and its
  schema is an object) and for `DecodeError` (a malformed reply yields a
  `Left DecodeError` whose `raw` is the input).
- Final **live smoke run** of `app/Main.hs` (renamed) end-to-end.
- Manual snippets updated; site pushed and Pages rebuild confirmed.

## Non-goals

- No behaviour change (same prompts, same wire JSON, same effects) — surface only.
- No GHC bump; autodocodec/aeson unchanged; no new external dependency
  (record-dot is built-in to GHC 9.10).
- Not redesigning the effect substrate or the interpreter set — only renaming it.
- Not building SP5 / manifest persistence.

## Self-review

- **Placeholders:** none. Every rename has a concrete target; the Eval record
  field renames are specified as "drop prefix to bare name" (the plan enumerates
  the exact fields).
- **Consistency:** the interpreter grammar (text unsuffixed / chat `…Chat` /
  record–replay) is uniform; field names lose prefixes uniformly; `DecodeError`
  is the single error type for both `call` and `decodeLLM`.
- **Scope:** large but one coherent surface overhaul; sequenced into green passes
  on one branch with the docs updated once at the end.
- **Ambiguity:** shared field names are handled by `DuplicateRecordFields` +
  `NoFieldSelectors` (access via record-dot); `Chat.Message` vs `LLM.Message`
  resolved by qualified import (confirmed).
- **Dependency risk:** none — record-dot extensions are built in; behaviour-
  preserving so the suite + live run are the safety net.
