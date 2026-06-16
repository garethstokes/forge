# Crucible: native tool-calling via an additive `Chat` capability

**Goal.** Let agents use the Anthropic provider's *native* tool-calling
(`tool_use`/`tool_result` content blocks) instead of the current JSON-in-text
scheme — added as a new capability alongside the existing text path, so
`complete`, `llmFn`, and `runAgent` are untouched. Second of the "productionize
the live path" (direction A) sub-projects (robustness shipped first).

**Why additive (not a unified `Message` redesign).** `complete :: [Message] ->
Eff es Text` and `Message = Role + Text` are ideal for typed one-shot functions
(`llmFn`). A tool-using conversation is a genuinely different shape (block-based,
multi-turn). Treating it as its own capability keeps the simple path simple and
avoids a churn pass over M7–M9 + the eDSL. The two surfaces coexist: text
completion (`complete`/`llmFn`) vs tool-aware conversation (`Chat`/`runToolAgent`).

**Non-goals (YAGNI).** No change to `LLM`/`complete`/`Message`/`llmFn`/`runAgent`.
No chat cassettes (the text path already demos record/replay; blocks are richer
to serialize — defer). No streaming. No usage capture. No parallel-tool-execution
optimization (run requested tools in order).

## Design decisions

1. **Additive `Chat` capability** — new block types + a `Chat` effect; existing
   text path unchanged.
2. **Loop safety** — `runToolAgent` caps iterations (default 10) and feeds tool
   errors / unknown-tool names back to the model as error `tool_result`s so it
   can self-correct; the cap returns `Left (ToolLoopExceeded n)`.
3. **Total result** — `runToolAgent` returns `Eff es (Either ChatError Text)`
   (not `throw`), so it is total and runs under the pure scripted interpreter as
   well as live.
4. **Interpreters** — live `runChatAnthropic` + scripted `runChatScripted`
   (canned `Turn`s) for hermetic tests. Defer chat cassettes.

## Module layout

- **`Crucible.Chat`** (new, provider-agnostic): block/turn types, the `Chat`
  effect + `converse`, `ChatError`, `runChatScripted`, `runToolAgent`.
- **`Crucible.Schema`**: add `schemaToJson :: Schema -> Value`.
- **`Crucible.LLM.Anthropic`**: extract a shared HTTP core and add
  `runChatAnthropic` (the text `anthropicComplete` is refactored onto the shared
  core — same retry/timeout/error behaviour, no duplication).

## `Crucible.Chat`

```haskell
type ToolUseId = Text

data ToolUse = ToolUse
  { tuId   :: ToolUseId
  , tuName :: ToolName
  , tuArgs :: Value
  }
  deriving (Eq, Show)

data Block
  = TextBlock       Text
  | ToolUseBlock    ToolUse
  | ToolResultBlock ToolUseId Value   -- result (or error) for a prior tool_use
  deriving (Eq, Show)

data ChatMsg = ChatMsg Role [Block]   -- Role reused from Crucible.LLM
  deriving (Eq, Show)

-- | The assistant's reply: any text plus any tool_use requests.
data Turn = Turn
  { turnText     :: Text
  , turnToolUses :: [ToolUse]
  }
  deriving (Eq, Show)

-- | A tool-using conversation step. The interpreter is given the tool specs
-- (name + input schema) to advertise to the model, and the conversation so far.
data Chat :: Effect where
  Converse :: [(ToolName, Schema)] -> [ChatMsg] -> Chat m Turn
type instance DispatchOf Chat = Dynamic

converse :: (Chat :> es) => [(ToolName, Schema)] -> [ChatMsg] -> Eff es Turn
converse specs msgs = send (Converse specs msgs)

newtype ChatError = ToolLoopExceeded Int deriving (Eq, Show)
instance Exception ChatError

-- | Canned-turn interpreter for tests: each 'Converse' pops the next 'Turn'.
-- Exhausting the script yields a text-only empty 'Turn' (loop terminates).
runChatScripted :: [Turn] -> Eff (Chat : es) a -> Eff es a

-- | Drive a native tool-calling loop to a final text answer. Caps at
-- 'defaultMaxIterations'; unknown-tool / tool errors are fed back as error
-- tool_results so the model can recover.
runToolAgent :: (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)
```

`defaultMaxIterations :: Int = 10` (module constant).

**`runToolAgent` loop:**
1. `msgs0 = [ChatMsg User [TextBlock question]]`; `specs = [(toolName t, toolSchema t) | t <- tools]`.
2. Iterate (budget `n`, starting at `defaultMaxIterations`):
   - `turn <- converse specs msgs`.
   - If `turnToolUses turn` is empty → return `Right (turnText turn)`.
   - Else, if `n <= 0` → return `Left (ToolLoopExceeded defaultMaxIterations)`.
   - Else, for each `ToolUse u`: find a tool with `toolName == tuName u`;
     - found → `out <- toolRun t (tuArgs u)`; result block `ToolResultBlock (tuId u) out`.
     - not found → `ToolResultBlock (tuId u) (JString ("unknown tool: " <> tuName u))`.
   - Append the assistant turn `ChatMsg Assistant (assistantBlocks turn)` (its
     `TextBlock` if non-empty, plus a `ToolUseBlock` per `turnToolUses`) and the
     user turn `ChatMsg User [the tool_result blocks]`; recurse with `n - 1`.

A tool that wants to signal failure returns an error `Value` from `toolRun`
(e.g. `JString "bad args"`) — that already flows back as a `tool_result`; this is
the existing `Tool` convention, so no `Tools` effect is needed here.

## `Crucible.Schema`: `schemaToJson`

```haskell
schemaToJson :: Schema -> Value
```
Maps the `Schema` ADT to a JSON-Schema object suitable for Anthropic's tool
`input_schema`:
- `SStr` → `{"type":"string"}`; `SNum` → `{"type":"number"}`; `SBool` → `{"type":"boolean"}`
- `SArr s` → `{"type":"array","items": schemaToJson s}`
- `SObj kvs` → `{"type":"object","properties": {k: schemaToJson v | (k,v) <- kvs}, "required": [k | (k,v) <- kvs, not (isOpt v)]}`
- `SOpt s` → `schemaToJson s` (and its key is omitted from the object's `required`)

(`isOpt (SOpt _) = True; isOpt _ = False`. Match whatever the actual `Schema`
constructors are at implementation time; the above covers the set used by the
codecs.)

## `Crucible.LLM.Anthropic`: shared HTTP core + `runChatAnthropic`

Extract the manager + `recovering` retry + status→`AnthropicError` machinery into:
```haskell
postMessages :: AnthropicConfig -> Manager -> Value -> IO Value
```
which POSTs a JSON request body to `/v1/messages` with the existing headers,
retries transient failures, throws `AnthropicError` on permanent failure / bad
status, and returns the parsed response JSON as a `Value` (throwing
`AnthropicNoContent` if the body isn't valid JSON). The existing
`anthropicComplete` is refactored to `postMessages` + extract `content[0].text`
(same observable behaviour). Then:

```haskell
runChatAnthropic :: (IOE :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es a
```
- Builds one shared `Manager` up front (as `runLLMAnthropic` does).
- Each `Converse specs msgs`:
  - Request body: `{"model","max_tokens","messages": <blocks>, "tools": <specs>}` where
    each tool spec is `{"name": n, "input_schema": schemaToJson s}` and `messages`
    serialize `ChatMsg`/`Block`s to Anthropic's content-block JSON (`text`,
    `tool_use {id,name,input}`, `tool_result {tool_use_id,content}`).
  - `resp <- postMessages cfg mgr body`; parse the response `content` array into a
    `Turn` (concatenate `text` blocks → `turnText`; collect `tool_use` blocks →
    `turnToolUses`), via the in-repo `Crucible.Json` decoders.

## Testing

Pure/scripted (no network), in `test/Spec.hs`:
- **runToolAgent happy path:** `runChatScripted [Turn "" [ToolUse "u1" "get_weather" <args>], Turn "Sunny in Brisbane." []]` over a `[weatherTool]` → `Right "Sunny in Brisbane."` (asserts the tool ran and its result was fed back).
- **unknown tool:** first scripted `Turn` requests a tool not in the list → loop feeds an `unknown tool:` result back → second `Turn` returns text → `Right`.
- **tool error:** a tool whose `toolRun` returns an error `Value` → fed back → final text → `Right`.
- **iteration cap:** scripted interpreter always returns tool_use turns → `Left (ToolLoopExceeded 10)`.
- **schemaToJson:** `SObj [("city", SStr)]` → `{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}`; `SOpt` drops from required; `SArr SStr` → array. (Compare `Value`s.)

Live: extend `app/Main.hs` with one `runToolAgent` call (a small local tool) via
`runChatAnthropic`, printing the final answer.

## Self-review

- **Placeholders:** none.
- **Consistency:** `runToolAgent`'s `Either ChatError Text` matches the project's
  total-result style (`call`/`llmFn`); `converse` carries `(ToolName, Schema)`
  (no `es` in the GADT); `Tool`'s error-as-`Value` convention is reused.
- **Scope:** new `Crucible.Chat` module + `schemaToJson` + Anthropic chat
  interpreter (sharing the refactored HTTP core) + scripted interp + tests — one
  implementation plan. The HTTP-core extraction is a DRY refactor of code this
  work already touches, not unrelated churn.
- **Ambiguity:** "feed errors back" is pinned to error `tool_result`s; the cap is
  a `Left`, not an exception; the text path is explicitly untouched.
- **Dependency risk:** none — no new external deps.
