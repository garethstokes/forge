# Crucible M9: MonadTool + tool registry + example agent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** A tool registry and the `MonadTool` capability, the loop dispatching tools by name, and a complete runnable example agent (registers a couple of tools, runs on canned replies, produces a final answer). Demonstrates the dual capability manifest `(MonadLLM m, MonadTool m) =>`. Zero non-boot deps.

**Architecture:** `Crucible.Tool` (generic `ToolCall {name,args}` + codec, `Tool m` record, `MonadTool`, `dispatchTools`, `toolsHelp`); extend `Crucible.Agent` with `runAgentT` (loop on `MonadTool`); `Crucible.Example` (a `DemoM` carrier that satisfies both capabilities, two pure tools, a `demoAgent`). Adds `SAny` to `Schema` for arbitrary args. See spec §8. (effectful's row-typed manifest parked: zinc-4d8; here the manifest is the typeclass constraint set.)

**Tech Stack:** GHC 9.6.5 via `nix develop`; zinc. `base`, `text`, `mtl` (all boot). Run zinc as `nix develop --command zinc <...>`.

**Already built & green (M0–M7, 73 checks):** JSON; `Schema (Schema(..), renderSchema)`; `Codec` (`Codec(..)`, `object`/`field`, `str`/`int`, `Variant`/`oneOfC`); `Codec.Generic`; `SAP (decodeLLM)`; `Decision (Decision(..), decisionCodec, Step(..), reduce)`; `LLM (MonadLLM(..), Message(..), Role(..))`; `LLM.Scripted (ScriptedM, runScripted)`; `Agent (AgentState(..), startAgent, runAgent, append?)`. NOTE: `Crucible.Agent` currently does NOT export `append` — this plan adds `runAgentT` inside `Crucible.Agent` so it can reuse the private `append`. `Crucible.Json.Decode` exports `decodeValue`, `field`, `string`, `int`, `message`. `Crucible.Json.Encode` exports `encode`. Member `zinc.toml` lib/test depends include `base text mtl crucible`.

**Beads:** M9 = `crucible-car`. Claim at start; close at end.

---

## Task 1: `SAny` schema + `Crucible.Tool`

**Files:** Modify `packages/crucible/src/Crucible/Schema.hs`; create `packages/crucible/src/Crucible/Tool.hs`; modify `packages/crucible/test/Spec.hs`.

First: `bd update crucible-car --claim`.

- [ ] **Step 1: Add `SAny` to Schema**

In `Crucible/Schema.hs` add the constructor `| SAny` to `data Schema` and the renderer case `renderSchema SAny = "any"`.

- [ ] **Step 2: Failing tests for the tool layer**

In `Spec.hs` add `import Crucible.Tool` and:
```haskell
  , check "toolCallCodec decodes name+args"
      (Right (ToolCall "get_weather" (JObject [("city", JString "Hobart")])))
      (D.decodeValue (codecDecode toolCallCodec)
        (JObject [("tool", JString "get_weather"), ("args", JObject [("city", JString "Hobart")])]))
  , check "toolsHelp lists tools"
      "- echo(args: {\"msg\": string})"
      (toolsHelp [Tool "echo" (SObj [("msg", SStr)]) (\_ -> Just JNull)])
```
(For the second check, `Tool` runs in `m = Maybe` just to have a concrete `Monad`; `toolsHelp` ignores the runner.) Run `nix develop --command zinc test` → FAIL.

- [ ] **Step 3: Implement `Crucible.Tool`**

`packages/crucible/src/Crucible/Tool.hs`:
```haskell
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Tool
  ( ToolName, ToolCall(..), toolCallCodec, anyValue
  , Tool(..), MonadTool(..), dispatchTools, toolsHelp
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Crucible.Schema (Schema(..), renderSchema)
import Crucible.Json.Value (Value(..))
import qualified Crucible.Json.Decode as D
import Crucible.Codec (Codec(..), object, field, str)

type ToolName = Text

-- | A tool invocation as the model emits it: a name and raw args.
data ToolCall = ToolCall { tcName :: ToolName, tcArgs :: Value }
  deriving (Eq, Show)

-- | Identity codec over an arbitrary JSON value (args are tool-specific).
anyValue :: Codec Value
anyValue = Codec SAny D.value id

toolCallCodec :: Codec ToolCall
toolCallCodec = object (ToolCall <$> field "tool" tcName str <*> field "args" tcArgs anyValue)

-- | A named tool: an args schema (shown in the prompt) and a runner in @m@.
-- The runner's monad constraint is the tool's capability (pure tools are
-- @Monad m => Tool m@; an IO tool would be @MonadIO m => Tool m@).
data Tool m = Tool
  { toolName   :: ToolName
  , toolSchema :: Schema
  , toolRun    :: Value -> m Value }

-- | The tool-dispatch capability.
class Monad m => MonadTool m where
  callTool :: ToolName -> Value -> m (Either Text Value)

-- | Dispatch a call against a toolbox by name.
dispatchTools :: Monad m => [Tool m] -> ToolName -> Value -> m (Either Text Value)
dispatchTools ts name args =
  case [t | t <- ts, toolName t == name] of
    (t : _) -> Right <$> toolRun t args
    []      -> pure (Left ("unknown tool: " <> name))

-- | A prose listing of the toolbox for the system prompt.
toolsHelp :: [Tool m] -> Text
toolsHelp ts = T.intercalate "\n"
  [ "- " <> toolName t <> "(args: " <> renderSchema (toolSchema t) <> ")" | t <- ts ]
```

- [ ] **Step 4: Run** → PASS. `nix develop --command zinc test`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(m9): SAny schema + Crucible.Tool (ToolCall, Tool, MonadTool, dispatch)"
```

---

## Task 2: `runAgentT` — the loop dispatching via `MonadTool`

**Files:** Modify `packages/crucible/src/Crucible/Agent.hs`.

- [ ] **Step 1: Extend `Crucible.Agent`**

Add `runAgentT` to the export list and implement it (reusing the private `append`):
```haskell
-- new imports at the top of Crucible/Agent.hs:
import Crucible.Tool (ToolCall(..), MonadTool(..))
import Crucible.Json.Encode (encode)

-- | Like 'runAgent' but tool dispatch comes from the 'MonadTool' capability
-- (name-based registry) rather than a supplied runner. Its type
-- @(MonadLLM m, MonadTool m) =>@ is the capability manifest.
runAgentT :: (MonadLLM m, MonadTool m)
          => Codec (Decision ToolCall answer) -> AgentState -> m answer
runAgentT codec = loop
  where
    loop st = do
      raw <- complete (transcript st)
      let st1 = append st (Message Assistant raw)
      case decodeLLM codec raw of
        Left err -> loop (append st1
          (Message User ("Your reply did not parse: " <> T.pack (D.message err)
                         <> ". Respond with valid JSON only.")))
        Right dec -> case reduce dec of
          Halt ans                -> pure ans
          Continue (ToolCall n a) -> do
            res <- callTool n a
            loop (append st1 (Message Tool (either ("error: " <>) encode res)))
```
Add `runAgentT` to the module's export list: `( AgentState(..), startAgent, runAgent, runAgentT )`.

> No new test here — `runAgentT` is exercised end-to-end by the example in Task 3. (This task only compiles; the green bar is unchanged.)

- [ ] **Step 2: Run** → still PASS (compiles; existing checks unaffected). `nix develop --command zinc test`.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(m9): runAgentT — control loop dispatching via MonadTool"
```

---

## Task 3: `Crucible.Example` — a runnable end-to-end agent

**Files:** Create `packages/crucible/src/Crucible/Example.hs`; modify `Spec.hs`.

- [ ] **Step 1: Failing tests — the example agent**

In `Spec.hs` add `import Crucible.Example (demoAgent)`:
```haskell
  , check "example agent: tool (get_weather) then answer"
      "sunny in Brisbane"
      (demoAgent [ "{\"tool\":\"get_weather\",\"args\":{\"city\":\"Brisbane\"}}"
                 , "{\"answer\":\"sunny in Brisbane\"}" ])
  , check "example agent: add tool then answer"
      "the sum is 7"
      (demoAgent [ "{\"tool\":\"add\",\"args\":{\"a\":3,\"b\":4}}"
                 , "{\"answer\":\"the sum is 7\"}" ])
  , check "example agent: direct answer (no tool)"
      "hello there"
      (demoAgent [ "{\"answer\":\"hello there\"}" ])
```
Run → FAIL (module not found).

- [ ] **Step 2: Implement `Crucible.Example`**

`packages/crucible/src/Crucible/Example.hs`:
```haskell
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Example (demoAgent, demoTools) where

import Data.Text (Text)
import Control.Monad.State (State, evalState, state)
import Crucible.Json.Value (Value(..))
import qualified Crucible.Json.Decode as D
import Crucible.Schema (Schema(..))
import Crucible.Codec (Codec, object, field, str)
import Crucible.Decision (Decision, decisionCodec)
import Crucible.LLM (MonadLLM(..), Message(..), Role(..))
import Crucible.Tool
import Crucible.Agent (AgentState(..), runAgentT)

-- | A carrier that satisfies BOTH capabilities: scripted model replies (State)
-- and the fixed demo toolbox. Its instances are the manifest made concrete.
newtype DemoM a = DemoM (State [Text] a)
  deriving (Functor, Applicative, Monad)

instance MonadLLM DemoM where
  complete _ = DemoM (state (\rs -> case rs of (x : xs) -> (x, xs); [] -> ("", [])))

instance MonadTool DemoM where
  callTool = dispatchTools demoTools

runDemo :: [Text] -> DemoM a -> a
runDemo replies (DemoM m) = evalState m replies

-- pure tools: polymorphic in m (no special capability), specialised to DemoM below.
weatherTool :: Monad m => Tool m
weatherTool = Tool "get_weather" (SObj [("city", SStr)]) $ \args ->
  pure $ case D.decodeValue (D.field "city" D.string) args of
           Right c -> JString ("sunny in " <> c)
           Left _  -> JString "unknown city"

addTool :: Monad m => Tool m
addTool = Tool "add" (SObj [("a", SNum), ("b", SNum)]) $ \args ->
  pure $ case (,) <$> D.decodeValue (D.field "a" D.int) args
                  <*> D.decodeValue (D.field "b" D.int) args of
           Right (a, b) -> JNumber (fromIntegral (a + b))
           Left _       -> JString "bad args"

demoTools :: [Tool DemoM]
demoTools = [weatherTool, addTool]

-- final-answer codec: {"answer": <text>} -> Text
answerCodec :: Codec Text
answerCodec = object (field "answer" id str)

demoCodec :: Codec (Decision ToolCall Text)
demoCodec = decisionCodec toolCallCodec answerCodec

startDemo :: AgentState
startDemo = AgentState
  [ Message System ("You can call these tools:\n" <> toolsHelp demoTools
      <> "\nRespond with JSON: either {\"tool\":<name>,\"args\":{...}} or {\"answer\":<text>}.")
  , Message User "demo" ]

-- | Run the example agent against canned model replies; returns the final answer.
demoAgent :: [Text] -> Text
demoAgent replies = runDemo replies (runAgentT demoCodec startDemo)
```

- [ ] **Step 3: Run** → PASS. `nix develop --command zinc test`. (Each test traverses: decode a `{"tool":...}` reply → `callTool` via `MonadTool DemoM` → dispatch to the registered tool → next reply `{"answer":...}` → `Done` → final text.)

- [ ] **Step 4: Commit + close M9**

```bash
git add -A && git commit -m "feat(m9): Crucible.Example — end-to-end tool-using agent (scripted)"
```
Run: `bd close crucible-car --reason="MonadTool + Tool registry + dispatchTools; runAgentT dispatches by name; DemoM carrier satisfies (MonadLLM,MonadTool); example agent runs get_weather/add tools to a final answer on scripted replies; tests green"`

---

## Self-Review

**Spec coverage (§8):** `MonadTool` + `Tool` registry + `dispatchTools` (Task 1); `runAgentT` capability-manifest loop (Task 2); end-to-end example agent with two tools + a carrier satisfying both capabilities (Task 3). ✓
**Placeholder scan:** none. The `toolsHelp` test uses `m = Maybe` purely to supply a concrete `Monad` — intentional, not a stub.
**Type consistency:** `ToolCall(tcName,tcArgs)`, `toolCallCodec`, `Tool(toolName,toolSchema,toolRun)`, `MonadTool(callTool)`, `dispatchTools`, `toolsHelp`, `runAgentT :: (MonadLLM m, MonadTool m) => Codec (Decision ToolCall answer) -> AgentState -> m answer`. `Crucible.Agent` gains `runAgentT` in its export list and imports `Crucible.Tool`/`Crucible.Json.Encode` (no cycle: `Crucible.Tool` does not import `Crucible.Agent`). `SAny` added to `Schema` + `renderSchema`. `answerCodec = object (field "answer" id str) :: Codec Text`.
**Caveats (not failures):** Example tools are pure (`Monad m => Tool m`), so the capability manifest is shown by the agent's `(MonadLLM m, MonadTool m)` constraint rather than an IO tool; an effectful tool (`MonadIO m => Tool m`) would force `MonadIO` into the carrier's type — noted, not built. The tool-args schema in the prompt is the generic `SAny` plus the `toolsHelp` listing (per-tool union schema with a literal name discriminant is deferred). Still no max-iteration cap (M8/real-interpreter concern).