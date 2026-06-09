# Native tool-calling (additive `Chat` capability) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native provider tool-calling — a new `Crucible.Chat` capability (content blocks, a `Chat` effect, `runToolAgent`) with a live `runChatAnthropic` interpreter — without touching the existing text path (`complete`/`llmFn`/`runAgent`).

**Architecture:** New provider-agnostic `Crucible.Chat` (block/turn types, `Chat` effect, scripted interpreter, `runToolAgent` loop). `Crucible.Schema` gains `schemaToJson`. `Crucible.LLM.Anthropic` is refactored to share an HTTP core (`postMessages`) between the existing text completion and a new `runChatAnthropic`. Composes existing primitives + the already-present deps; no new external deps.

**Tech Stack:** Haskell (GHC 9.6.5), effectful, http-client/retry, zinc. Build/test: `nix develop . --command zinc <build|test>` (a few min each). Test binary `.zinc/build/spec`; `test/Spec.hs` is `runChecks [ check name expected actual, ... ]` (`check :: (Eq a, Show a) => String -> a -> a -> IO Bool`), already enables `OverloadedStrings`, and already imports `runPureEff`, `Crucible.Json.Value (Value(..))`, `Crucible.Schema (...)`, `Crucible.LLM (Role(..), ...)`. Spec: `docs/superpowers/specs/2026-06-09-native-tool-calling-design.md`.

**Pre-verified facts:**
- `Schema` constructors: `SObj [(Text,Schema)] | SArr Schema | SEnum [Text] | SOneOf [Schema] | SStr | SNum | SBool | SOpt Schema | SAny`.
- `Tool es = Tool { toolName :: ToolName, toolSchema :: Schema, toolRun :: Value -> Eff es Value }`; `type ToolName = Text` (from `Crucible.Tool`).
- JSON decoders (`Crucible.Json.Decode`, imported qualified as `D` in the Anthropic module): `string,int,bool,float,value,field,index,list,nullable,oneOf,succeed,failD,andThen,decodeValue,decodeString`; `Decoder` is Applicative + Monad.
- `Value` ctors: `JNull,JBool Bool,JNumber Double,JString Text,JArray [Value],JObject [(Text,Value)]`.
- Modules auto-discovered (no zinc.toml change to add `Crucible.Chat`).

---

### Task 1: `Crucible.Schema.schemaToJson`

**Files:** Modify `src/Crucible/Schema.hs`; Modify `test/Spec.hs`.

- [ ] **Step 1: Write the failing tests**

In `test/Spec.hs`, add `schemaToJson` to the existing `Crucible.Schema (...)` import. Add checks (the `Value`/`JObject`/`SObj` names are already imported):
```haskell
  , check "schemaToJson: object with required field"
      (JObject
        [ ("type", JString "object")
        , ("properties", JObject [("city", JObject [("type", JString "string")])])
        , ("required", JArray [JString "city"]) ])
      (schemaToJson (SObj [("city", SStr)]))
  , check "schemaToJson: optional field dropped from required"
      (JObject
        [ ("type", JString "object")
        , ("properties", JObject [("note", JObject [("type", JString "string")])])
        , ("required", JArray []) ])
      (schemaToJson (SObj [("note", SOpt SStr)]))
  , check "schemaToJson: array of strings"
      (JObject [("type", JString "array"), ("items", JObject [("type", JString "string")])])
      (schemaToJson (SArr SStr))
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop . --command zinc test` → FAIL: `Crucible.Schema` does not export `schemaToJson`.

- [ ] **Step 3: Implement `schemaToJson`**

In `src/Crucible/Schema.hs`: add `schemaToJson` to the module export list (currently `module Crucible.Schema (Schema(..), renderSchema) where`); add the import `import Crucible.Json.Value (Value (..))`; add:
```haskell
-- | Render a 'Schema' as a JSON-Schema object (for an Anthropic tool's
-- @input_schema@). Optional object fields are omitted from @required@.
schemaToJson :: Schema -> Value
schemaToJson s = case s of
  SStr      -> JObject [("type", JString "string")]
  SNum      -> JObject [("type", JString "number")]
  SBool     -> JObject [("type", JString "boolean")]
  SArr e    -> JObject [("type", JString "array"), ("items", schemaToJson e)]
  SEnum vs  -> JObject [("type", JString "string"), ("enum", JArray (map JString vs))]
  SOneOf ss -> JObject [("anyOf", JArray (map schemaToJson ss))]
  SOpt e    -> schemaToJson e
  SAny      -> JObject []
  SObj kvs  ->
    JObject
      [ ("type", JString "object")
      , ("properties", JObject [(k, schemaToJson v) | (k, v) <- kvs])
      , ("required", JArray [JString k | (k, v) <- kvs, not (isOpt v)])
      ]
  where
    isOpt (SOpt _) = True
    isOpt _        = False
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop . --command zinc test` → `1 test suite(s) passed`.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Schema.hs test/Spec.hs
git commit -m "feat(chat): schemaToJson — Schema to JSON-Schema for tool input_schema"
```
End the commit body with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 2: `Crucible.Chat` — block types, `Chat` effect, scripted interpreter

**Files:** Create `src/Crucible/Chat.hs`; Modify `test/Spec.hs`.

- [ ] **Step 1: Write the failing test**

In `test/Spec.hs` add:
```haskell
import Crucible.Chat
  (Chat, converse, runChatScripted, Turn(..), ChatMsg(..), Block(..), ToolUse(..))
```
Add a check (`Role(..)` and `runPureEff` are already imported):
```haskell
  , check "runChatScripted: pops the canned turn"
      (Turn "hello" [])
      (runPureEff (runChatScripted [Turn "hello" []]
        (converse [] [ChatMsg User [TextBlock "hi"]])))
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop . --command zinc test` → FAIL: `Could not find module 'Crucible.Chat'`.

- [ ] **Step 3: Create the module**

Create `src/Crucible/Chat.hs`:
```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Native tool-calling as a block-based conversation capability, separate from
-- the text-only 'Crucible.LLM' path. A 'Chat' interpreter turns a conversation
-- (content blocks) plus tool specs into the assistant's 'Turn' (text + any
-- tool_use requests); 'runToolAgent' drives the request/run/result loop.
module Crucible.Chat
  ( ToolUseId
  , ToolUse (..)
  , Block (..)
  , ChatMsg (..)
  , Turn (..)
  , Chat (..)
  , converse
  , ChatError (..)
  , runChatScripted
  ) where

import Control.Exception (Exception)
import Data.Text (Text)

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret, send)
import Effectful.State.Static.Local (evalState, get, put)

import Crucible.Json.Value (Value)
import Crucible.LLM (Role)
import Crucible.Schema (Schema)
import Crucible.Tool (ToolName)

type ToolUseId = Text

-- | A model request to invoke a tool.
data ToolUse = ToolUse
  { tuId   :: ToolUseId
  , tuName :: ToolName
  , tuArgs :: Value
  }
  deriving (Eq, Show)

-- | A content block within a conversation message.
data Block
  = TextBlock       Text
  | ToolUseBlock    ToolUse
  | ToolResultBlock ToolUseId Value   -- ^ a result (or error) for a prior tool_use
  deriving (Eq, Show)

data ChatMsg = ChatMsg Role [Block]
  deriving (Eq, Show)

-- | The assistant's reply: any text, plus any tool_use requests.
data Turn = Turn
  { turnText     :: Text
  , turnToolUses :: [ToolUse]
  }
  deriving (Eq, Show)

-- | One tool-aware conversation step. The interpreter is given the tool specs
-- (name + input schema) to advertise, and the conversation so far.
data Chat :: Effect where
  Converse :: [(ToolName, Schema)] -> [ChatMsg] -> Chat m Turn
type instance DispatchOf Chat = Dynamic

converse :: (Chat :> es) => [(ToolName, Schema)] -> [ChatMsg] -> Eff es Turn
converse specs msgs = send (Converse specs msgs)

-- | A tool-loop failure: the iteration budget was exhausted.
newtype ChatError = ToolLoopExceeded Int
  deriving (Eq, Show)

instance Exception ChatError

-- | Canned-turn interpreter for tests: each 'Converse' pops the next 'Turn';
-- an exhausted script yields a text-only empty 'Turn' (so a loop terminates).
runChatScripted :: [Turn] -> Eff (Chat : es) a -> Eff es a
runChatScripted turns = reinterpret (evalState turns) $ \_ -> \case
  Converse _ _ -> do
    ts <- get
    case ts of
      (t : rest) -> put rest >> pure t
      []         -> pure (Turn "" [])
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop . --command zinc test` → `1 test suite(s) passed`.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Chat.hs test/Spec.hs
git commit -m "feat(chat): Chat effect + block types + scripted interpreter"
```
End with the `Co-Authored-By` trailer.

---

### Task 3: `runToolAgent` — the native tool loop

**Files:** Modify `src/Crucible/Chat.hs` (exports, imports, function); Modify `test/Spec.hs`.

- [ ] **Step 1: Write the failing tests**

In `test/Spec.hs`, extend the `Crucible.Chat (...)` import to also bring in `runToolAgent` and `ChatError(..)`. Add a sample tool fixture near the other fixtures (top-level):
```haskell
weatherToolC :: Tool es
weatherToolC = Tool "get_weather" (SObj [("city", SStr)]) (\_ -> pure (JString "Sunny in Brisbane!"))
```
(`Tool` and `pure` are in scope if `Crucible.Tool (Tool(..))` is imported — add it to Spec's imports if missing.)
Add checks:
```haskell
  , check "runToolAgent: runs the tool, then returns final text"
      (Right "Sunny in Brisbane!")
      (runPureEff (runChatScripted
        [ Turn "" [ToolUse "u1" "get_weather" (JObject [("city", JString "Brisbane")])]
        , Turn "Sunny in Brisbane!" [] ]
        (runToolAgent [weatherToolC] "weather in Brisbane?")))
  , check "runToolAgent: unknown tool fed back, then answers"
      (Right "done")
      (runPureEff (runChatScripted
        [ Turn "" [ToolUse "u1" "nonesuch" (JObject [])]
        , Turn "done" [] ]
        (runToolAgent [weatherToolC] "x")))
  , check "runToolAgent: exhausts the iteration cap -> Left"
      (Left (ToolLoopExceeded 10))
      (runPureEff (runChatScripted
        (replicate 20 (Turn "" [ToolUse "u" "get_weather" (JObject [])]))
        (runToolAgent [weatherToolC] "x")))
```
(Note: `runChatScripted` ignores its inputs and pops canned turns in order, so these exercise the loop's control flow — tool run, unknown-tool error-block, and the cap — deterministically. A tool that returns an *error* `Value` follows the identical "result block fed back" path as the happy case, so it needs no separate check.)

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop . --command zinc test` → FAIL: `Crucible.Chat` does not export `runToolAgent`.

- [ ] **Step 3: Implement `runToolAgent`**

In `src/Crucible/Chat.hs`:
(a) Add to the export list: `, runToolAgent` and `, defaultMaxIterations`.
(b) Extend imports: change `import Crucible.LLM (Role)` to `import Crucible.LLM (Role (Assistant, User))`; change `import Crucible.Json.Value (Value)` to `import Crucible.Json.Value (Value (..))`; change `import Crucible.Tool (ToolName)` to `import Crucible.Tool (Tool (..), ToolName)`; add `import qualified Data.Text as T`.
(c) Add:
```haskell
-- | Cap on tool-loop iterations, to bound a runaway model.
defaultMaxIterations :: Int
defaultMaxIterations = 10

-- | Drive a native tool-calling loop to a final text answer. Each round: ask
-- the model (advertising the tools), run any requested tools (unknown name or a
-- tool's own error 'Value' is fed back as a tool_result so the model can
-- recover), and continue until a text-only turn. Caps at 'defaultMaxIterations',
-- returning @Left ('ToolLoopExceeded' n)@. Total: works under the scripted and
-- live interpreters alike (needs only @Chat :> es@).
runToolAgent :: (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)
runToolAgent tools question = loop defaultMaxIterations [ChatMsg User [TextBlock question]]
  where
    specs = [(toolName t, toolSchema t) | t <- tools]

    loop n msgs = do
      turn <- converse specs msgs
      if null (turnToolUses turn)
        then pure (Right (turnText turn))
        else
          if n <= 0
            then pure (Left (ToolLoopExceeded defaultMaxIterations))
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop . --command zinc test` → `1 test suite(s) passed`.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Chat.hs test/Spec.hs
git commit -m "feat(chat): runToolAgent loop (cap + error-feedback)"
```
End with the `Co-Authored-By` trailer.

---

### Task 4: Refactor `anthropicComplete` onto a shared `postMessages` core

**Files:** Modify `src/Crucible/LLM/Anthropic.hs`.

- [ ] **Step 1: Extract `postMessages` and rewrite `anthropicComplete`**

In `src/Crucible/LLM/Anthropic.hs`, replace the current `anthropicComplete` definition (the whole `anthropicComplete … where doRequest = …` block) with the extracted core plus a thin `anthropicComplete`:
```haskell
-- | POST a JSON request body to @/v1/messages@ and return the raw 2xx response
-- body, retrying transient failures (network/timeout, 429, 5xx) with jittered
-- exponential backoff up to 'acMaxRetries'. A non-2xx response throws
-- 'AnthropicStatusError'; a network/timeout failure throws 'AnthropicHttpError'.
-- Shared by the text completion and the chat interpreter.
postMessages :: AnthropicConfig -> Manager -> Value -> IO Text
postMessages cfg mgr bodyJson =
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
                  RequestBodyLBS (LBS.fromStrict (TE.encodeUtf8 (encode bodyJson)))
              }
      resp <- httpLbs req mgr
      let body = TE.decodeUtf8Lenient (LBS.toStrict (responseBody resp))
          code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then pure body
        else throwIO (AnthropicStatusError code body)

-- | One text round-trip: POST the messages, then extract @content[0].text@; a
-- 2xx body without that shape throws 'AnthropicNoContent'.
anthropicComplete :: AnthropicConfig -> Manager -> [Message] -> IO Text
anthropicComplete cfg mgr msgs = do
  body <- postMessages cfg mgr (requestJson cfg msgs)
  either (\_ -> throwIO (AnthropicNoContent body)) pure (extractText body)
```
Leave `requestJson`, `anthropicRole`, `extractText`, `maxBackoffMicros`, `newAnthropicManager`, the interpreters, types, and config unchanged.

- [ ] **Step 2: Build + test (behaviour-preserving)**

Run: `nix develop . --command zinc build` → exit 0.
Run: `nix develop . --command zinc test` → `1 test suite(s) passed` (the text path's behaviour is unchanged; the `isRetryable` tests still pass).

- [ ] **Step 3: Commit**

```bash
git add src/Crucible/LLM/Anthropic.hs
git commit -m "refactor(chat): extract postMessages HTTP core from anthropicComplete"
```
End with the `Co-Authored-By` trailer.

---

### Task 5: Anthropic chat wire — request body + turn parser (pure)

**Files:** Modify `src/Crucible/LLM/Anthropic.hs` (exports, imports, pure functions); Modify `test/Spec.hs`.

- [ ] **Step 1: Write the failing tests**

In `test/Spec.hs`, add to the `Crucible.LLM.Anthropic (...)` import: `chatRequestJson`, `parseTurn`. (`Turn`/`ToolUse`/`ChatMsg`/`Block` are already imported from `Crucible.Chat`; `defaultAnthropicConfig` may already be imported — add if missing.) Add checks:
```haskell
  , check "parseTurn: text + tool_use"
      (Right (Turn "Let me check."
                [ToolUse "tu_1" "get_weather" (JObject [("city", JString "Brisbane")])]))
      (parseTurn "{\"content\":[{\"type\":\"text\",\"text\":\"Let me check.\"},{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"get_weather\",\"input\":{\"city\":\"Brisbane\"}}]}")
  , check "chatRequestJson: tools + message blocks"
      (JObject
        [ ("model", JString "claude-haiku-4-5-20251001")
        , ("max_tokens", JNumber 1024)
        , ("tools", JArray
            [ JObject [("name", JString "get_weather")
                      ,("input_schema", JObject
                          [ ("type", JString "object")
                          , ("properties", JObject [("city", JObject [("type", JString "string")])])
                          , ("required", JArray [JString "city"]) ])] ])
        , ("messages", JArray
            [ JObject [("role", JString "user")
                      ,("content", JArray [JObject [("type", JString "text"),("text", JString "hi")]])] ]) ])
      (chatRequestJson (defaultAnthropicConfig "k")
        [("get_weather", SObj [("city", SStr)])]
        [ChatMsg User [TextBlock "hi"]])
```

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop . --command zinc test` → FAIL: `Crucible.LLM.Anthropic` does not export `chatRequestJson`/`parseTurn`.

- [ ] **Step 3: Implement the wire functions**

In `src/Crucible/LLM/Anthropic.hs`:
(a) Add to the export list: `, chatRequestJson` and `, parseTurn`.
(b) Add imports:
```haskell
import Crucible.Chat (Block (..), ChatMsg (..), ToolUse (..), Turn (..))
import Crucible.Schema (schemaToJson)
import Crucible.Tool (ToolName)
```
(`Crucible.Schema` is currently not imported here; add it. `Schema` is needed for the type signature — import it too: `import Crucible.Schema (Schema, schemaToJson)`.)
(c) Add:
```haskell
-- | Build the @/v1/messages@ request body for a chat turn: the model + token
-- cap, the advertised @tools@ (each @{name, input_schema}@), and the
-- conversation @messages@ as content-block arrays.
chatRequestJson :: AnthropicConfig -> [(ToolName, Schema)] -> [ChatMsg] -> Value
chatRequestJson cfg specs msgs =
  JObject
    [ ("model", JString (acModel cfg))
    , ("max_tokens", JNumber (fromIntegral (acMaxTokens cfg)))
    , ("tools", JArray [ toolSpec n s | (n, s) <- specs ])
    , ("messages", JArray (map chatMsgJson msgs))
    ]
  where
    toolSpec n s = JObject [("name", JString n), ("input_schema", schemaToJson s)]

chatMsgJson :: ChatMsg -> Value
chatMsgJson (ChatMsg r blocks) =
  JObject [("role", JString (anthropicRole r)), ("content", JArray (map blockJson blocks))]

blockJson :: Block -> Value
blockJson (TextBlock t) =
  JObject [("type", JString "text"), ("text", JString t)]
blockJson (ToolUseBlock (ToolUse i n a)) =
  JObject [("type", JString "tool_use"), ("id", JString i), ("name", JString n), ("input", a)]
blockJson (ToolResultBlock i v) =
  JObject
    [ ("type", JString "tool_result")
    , ("tool_use_id", JString i)
    , ("content", resultText v)
    ]
  where
    resultText (JString s) = JString s
    resultText other       = JString (encode other)

-- | Parse a @/v1/messages@ response body into a 'Turn': concatenated @text@
-- blocks, plus every @tool_use@ block.
parseTurn :: Text -> Either D.Error Turn
parseTurn = D.decodeString (D.field "content" (toTurn <$> D.list rblock))
  where
    toTurn bs = Turn (T.concat [t | RText t <- bs]) [u | RUse u <- bs]

data RBlock = RText Text | RUse ToolUse | RSkip

rblock :: D.Decoder RBlock
rblock = D.field "type" D.string `D.andThen` \ty -> case ty of
  "text"     -> RText <$> D.field "text" D.string
  "tool_use" ->
    (\i n inp -> RUse (ToolUse i n inp))
      <$> D.field "id" D.string
      <*> D.field "name" D.string
      <*> D.field "input" D.value
  _ -> D.succeed RSkip
```
(`RBlock`/`rblock` are module-internal helpers — not exported.)

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop . --command zinc test` → `1 test suite(s) passed`.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/LLM/Anthropic.hs test/Spec.hs
git commit -m "feat(chat): Anthropic chat wire — chatRequestJson + parseTurn"
```
End with the `Co-Authored-By` trailer.

---

### Task 6: `runChatAnthropic` interpreter + live smoke demo

**Files:** Modify `src/Crucible/LLM/Anthropic.hs` (export + interpreter); Modify `app/Main.hs`.

- [ ] **Step 1: Add the live chat interpreter**

In `src/Crucible/LLM/Anthropic.hs`:
(a) Add to the export list: `, runChatAnthropic`.
(b) Extend the `Crucible.Chat` import to also bring in the effect: `import Crucible.Chat (Block (..), Chat (..), ChatMsg (..), ToolUse (..), Turn (..))`.
(c) Add (e.g. after `runLLMCassette`):
```haskell
-- | Interpret 'Chat' against the live Anthropic Messages API with native
-- tool-calling. One shared TLS manager is created up front; each 'Converse'
-- POSTs the conversation + tool specs and parses the assistant's 'Turn'.
-- Failures throw 'AnthropicError'.
runChatAnthropic :: (IOE :> es) => AnthropicConfig -> Eff (Chat : es) a -> Eff es a
runChatAnthropic cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  interpret
    (\_ (Converse specs msgs) -> liftIO $ do
        body <- postMessages cfg mgr (chatRequestJson cfg specs msgs)
        either (\_ -> throwIO (AnthropicNoContent body)) pure (parseTurn body))
    action
```

- [ ] **Step 2: Build to verify the interpreter compiles**

Run: `nix develop . --command zinc build` → exit 0.

- [ ] **Step 3: Add a live tool-agent demo to the smoke exe**

In `app/Main.hs`, add imports:
```haskell
import Crucible.Chat (runToolAgent)
import Crucible.LLM.Anthropic (runChatAnthropic)
import Crucible.Tool (Tool (..))
import Crucible.Schema (Schema (SObj, SStr))
import Crucible.Json.Value (Value (JString))
```
(Some — e.g. `Crucible.LLM.Anthropic` — are already imported; merge, don't duplicate. `Data.Text as T` and `TIO` are already in scope.)
Inside the `Just key -> do` block, after the existing typed-function demo, add:
```haskell
      let weatherTool = Tool "get_weather" (SObj [("city", SStr)])
            (\_ -> pure (JString "It is 26C and sunny."))
      toolAns <- runEff (runChatAnthropic cfg (runToolAgent [weatherTool] "Use the tool to get the weather in Brisbane, then tell me."))
      case toolAns of
        Right a  -> TIO.putStrLn ("tool agent: " <> a)
        Left err -> TIO.putStrLn ("tool agent error: " <> T.pack (show err))
```

- [ ] **Step 4: Build + test**

Run: `nix develop . --command zinc build` → exit 0, `.zinc/build/crucible-anthropic` produced.
Run: `nix develop . --command zinc test` → `1 test suite(s) passed`.
(Do NOT run the exe live — it makes paid API calls; the build proves the path compiles/links.)

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/LLM/Anthropic.hs app/Main.hs
git commit -m "feat(chat): runChatAnthropic interpreter + live tool-agent demo"
```
End with the `Co-Authored-By` trailer.

---

## Self-Review

**Spec coverage:**
- Additive `Chat` (Decision 1) → Task 2 (effect/types) + Task 3 (`runToolAgent`); text path untouched (only `anthropicComplete` is refactored behaviour-preservingly in Task 4).
- Loop cap + error feedback (Decision 2) → Task 3 (`runToolAgent`: `defaultMaxIterations`, unknown-tool/`toolRun` result fed back).
- Total `Either ChatError Text` (Decision 3) → Task 3 signature.
- Interpreters: scripted (Task 2) + live `runChatAnthropic` (Task 6); cassettes deferred (not in any task) — matches Decision 4.
- `schemaToJson` → Task 1. `postMessages` shared core → Task 4. Chat wire (`chatRequestJson`/`parseTurn`) → Task 5.
- Tests: `schemaToJson` (Task 1); scripted `converse` (Task 2); `runToolAgent` happy/unknown/cap (Task 3); `parseTurn`/`chatRequestJson` (Task 5). Live demo builds (Task 6). The spec's "tool error" case is the same code path as the happy case (a result `Value` fed back) — covered, not separately tested, noted in Task 3.

**Placeholder scan:** none — full code/commands throughout.

**Type consistency:** `Turn`, `ToolUse`, `Block`, `ChatMsg`, `Chat`, `converse`, `runChatScripted`, `runToolAgent`, `ChatError(..)`, `defaultMaxIterations` defined in Tasks 2–3 are used consistently in Tasks 5–6. `chatRequestJson :: AnthropicConfig -> [(ToolName, Schema)] -> [ChatMsg] -> Value` and `parseTurn :: Text -> Either D.Error Turn` (Task 5) match their uses in `runChatAnthropic` (Task 6). `postMessages :: AnthropicConfig -> Manager -> Value -> IO Text` (Task 4) is used by both `anthropicComplete` (Task 4) and `runChatAnthropic` (Task 6). `schemaToJson` (Task 1) is used in `chatRequestJson` (Task 5). `toolRun`/`toolName`/`toolSchema` field names match `Crucible.Tool`.
