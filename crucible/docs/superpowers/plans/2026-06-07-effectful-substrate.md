# Crucible: migrate the effect substrate from tagless-final to effectful

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Replace the hand-rolled tagless-final `MonadLLM`/`MonadTool` substrate with **effectful** effects (`LLM`, `Tools`) and interpreters, realizing the original design where the control loop's type — `(LLM :> es, Tools :> es) => …` — is the capability manifest. Keep all 82 tests green (run via interpreters). This is a coherent big-bang migration: the effect-using modules (`LLM`, `Tool`, `Agent`, `Eval`, `Example`) and `Spec.hs` change together.

**Foundation (done):** effectful builds in crucible (commit `5c203fc`): root forward-pins for `monad-control`/`strict-mutable-base`, deps on **both** `effectful` and `effectful-core`, jdf-fixed zinc deployed. The library can `import Effectful` (verified). Branch `adopt-effectful`.

**Tech Stack:** GHC 9.6.5 via `nix develop`; zinc. Deps: `base`, `text`, `mtl`(boot), `effectful`, `effectful-core`. Run zinc as `nix develop --command zinc <...>`.

**Beads:** track as crucible effectful-adoption (create/claim a bead).

## effectful API crib (get these right)

```haskell
{-# LANGUAGE GADTs, TypeFamilies, DataKinds, KindSignatures, FlexibleContexts, TypeOperators, LambdaCase #-}
import Effectful                       -- Eff, (:>), Effect, IOE, runEff, runPureEff, DispatchOf, Dispatch(Dynamic)
import Effectful.Dispatch.Dynamic      -- send, interpret, reinterpret
import Effectful.State.Static.Local (evalState, get, put)  -- for the scripted interpreter
```
- Define a dynamic effect: `data E :: Effect where Op :: ... -> E m r` + `type instance DispatchOf E = Dynamic`.
- Smart constructor: `op args = send (Op args)` with `(E :> es) => … -> Eff es r`.
- Handle: `interpret (\_ -> \case Op a -> …) :: Eff (E : es) a -> Eff es a` (handler returns `Eff es r`).
- Handle using a fresh local effect: `reinterpret (evalState s0) (\_ -> \case …) :: Eff (E : es) a -> Eff es a` (handler runs in `Eff (State s : es)`).
- Run pure stack: `runPureEff (runX … (runY … prog))`.

---

## Task 1: `Crucible.LLM` as an effect + scripted interpreter

**Files:** Rewrite `packages/crucible/src/Crucible/LLM.hs`; delete `packages/crucible/src/Crucible/LLM/Scripted.hs`.

```haskell
{-# LANGUAGE GADTs, TypeFamilies, DataKinds, KindSignatures, TypeOperators, FlexibleContexts, LambdaCase #-}
module Crucible.LLM
  ( Role(..), Message(..)
  , LLM(..), complete
  , runLLMScripted
  ) where

import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (send, reinterpret)
import Effectful.State.Static.Local (evalState, get, put)

data Role = System | User | Assistant | Tool deriving (Eq, Show)
data Message = Message { role :: Role, content :: Text } deriving (Eq, Show)

-- | The LLM capability as a dynamic effect. A function with @LLM :> es@ can
-- talk to the model and (absent other constraints) nothing else.
data LLM :: Effect where
  Complete :: [Message] -> LLM m Text
type instance DispatchOf LLM = Dynamic

complete :: (LLM :> es) => [Message] -> Eff es Text
complete msgs = send (Complete msgs)

-- | Interpret LLM by popping canned replies (tests). Uses a local State.
runLLMScripted :: [Text] -> Eff (LLM : es) a -> Eff es a
runLLMScripted replies = reinterpret (evalState replies) $ \_ -> \case
  Complete _ -> do
    rs <- get
    case rs of
      (x : xs) -> put xs >> pure x
      []       -> pure ""
```

- [ ] Rewrite `LLM.hs` as above; `rm packages/crucible/src/Crucible/LLM/Scripted.hs`.
- [ ] Run `nix develop --command zinc test` — expect FAILURES in dependents (Agent/Example/Eval/Spec) referencing the old `MonadLLM`/`ScriptedM`/`runScripted`. That's expected; fix in the next tasks. (You may need to migrate all tasks before the suite compiles — this is a big-bang migration; commit once at the end.)

---

## Task 2: `Crucible.Tool` as an effect + toolbox interpreter

**Files:** Rewrite the effect parts of `packages/crucible/src/Crucible/Tool.hs`.

Keep `ToolName`, `ToolCall(..)`, `toolCallCodec`, `anyValue`, `toolsHelp` unchanged. Replace `MonadTool`/`dispatchTools` and make `Tool` carry an `Eff es` runner:

```haskell
{-# LANGUAGE GADTs, TypeFamilies, DataKinds, KindSignatures, TypeOperators, FlexibleContexts, LambdaCase, OverloadedStrings #-}
-- exports: ToolName, ToolCall(..), toolCallCodec, anyValue, Tool(..), Tools(..), callTool, runTools, toolsHelp

import Effectful
import Effectful.Dispatch.Dynamic (send, interpret)

data Tool es = Tool
  { toolName   :: ToolName
  , toolSchema :: Schema
  , toolRun    :: Value -> Eff es Value }   -- runner in the ambient effect row

data Tools :: Effect where
  CallTool :: ToolName -> Value -> Tools m (Either Text Value)
type instance DispatchOf Tools = Dynamic

callTool :: (Tools :> es) => ToolName -> Value -> Eff es (Either Text Value)
callTool n v = send (CallTool n v)

-- | Interpret Tools against a toolbox; unknown tool -> Left.
runTools :: [Tool es] -> Eff (Tools : es) a -> Eff es a
runTools tools = interpret $ \_ -> \case
  CallTool name args -> case filter ((== name) . toolName) tools of
    (t : _) -> Right <$> toolRun t args
    []      -> pure (Left ("unknown tool: " <> name))
```

- [ ] Rewrite `Tool.hs` accordingly (keep the codec/help helpers). `toolsHelp :: [Tool es] -> Text` stays (ignores the runner).

---

## Task 3: `Crucible.Agent` — the effectful control loop

**Files:** Rewrite `packages/crucible/src/Crucible/Agent.hs`.

```haskell
{-# LANGUAGE DataKinds, TypeOperators, FlexibleContexts, OverloadedStrings #-}
module Crucible.Agent (AgentState(..), startAgent, runAgent) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import Crucible.LLM (LLM, complete, Message(..), Role(..))
import Crucible.Tool (Tools, callTool, ToolCall(..))
import Crucible.Schema (renderSchema)
import Crucible.Codec (Codec(..))
import Crucible.SAP (decodeLLM)
import Crucible.Decision (Decision, Step(..), reduce)
import Crucible.Json.Encode (encode)
import qualified Crucible.Json.Decode as D

newtype AgentState = AgentState { transcript :: [Message] } deriving (Eq, Show)

startAgent :: Codec (Decision tool answer) -> Text -> AgentState
startAgent codec question = AgentState
  [ Message System ("Respond ONLY with JSON matching this schema:\n" <> renderSchema (codecSchema codec))
  , Message User question ]

-- | The control loop. Its type IS the capability manifest.
runAgent :: (LLM :> es, Tools :> es)
         => Codec (Decision ToolCall answer) -> AgentState -> Eff es answer
runAgent codec = loop
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

append :: AgentState -> Message -> AgentState
append (AgentState ms) m = AgentState (ms ++ [m])
```

- [ ] Rewrite `Agent.hs`. Drop the old `runAgent`/`runAgentT` (tagless) forms.

---

## Task 4: `Crucible.Eval` — scoring/judge on the LLM effect

**Files:** Modify `packages/crucible/src/Crucible/Eval.hs`. Replace `MonadLLM m =>` with `(LLM :> es) =>` and `m` with `Eff es`:

```haskell
judge   :: (LLM :> es) => (a -> Text) -> Text -> a -> Eff es Score
scoreM  :: (Eq a, LLM :> es) => (a -> Text) -> Expectation a -> a -> Eff es Score
runEval :: (Eq a, LLM :> es) => (a -> Text) -> (i -> Eff es a) -> [Case i a] -> Eff es (Report i a)
```
Bodies are otherwise unchanged (`complete` keeps its name; `mapM`/`pure` work in `Eff es`). Update imports: `import Effectful`, `import Crucible.LLM (LLM, complete, Message(..), Role(..))`.

- [ ] Rewrite the three signatures + imports. Logic unchanged.

---

## Task 5: `Crucible.Example` — interpreter composition

**Files:** Rewrite `packages/crucible/src/Crucible/Example.hs`. No carrier monad; compose interpreters.

```haskell
{-# LANGUAGE DataKinds, TypeOperators, OverloadedStrings #-}
module Crucible.Example (demoAgent, demoTools) where

import Data.Text (Text)
import Effectful (Eff, runPureEff)
import Crucible.Json.Value (Value(..))
import qualified Crucible.Json.Decode as D
import Crucible.Schema (Schema(..))
import Crucible.Codec (Codec, object, field, str)
import Crucible.Decision (Decision, decisionCodec)
import Crucible.LLM (runLLMScripted, Message(..), Role(..))
import Crucible.Tool
import Crucible.Agent (AgentState(..), startAgent, runAgent)

-- pure tools (polymorphic in es; run via `pure`)
weatherTool :: Tool es
weatherTool = Tool "get_weather" (SObj [("city", SStr)]) $ \args ->
  pure $ case D.decodeValue (D.field "city" D.string) args of
           Right c -> JString ("sunny in " <> c)
           Left _  -> JString "unknown city"

addTool :: Tool es
addTool = Tool "add" (SObj [("a", SNum), ("b", SNum)]) $ \args ->
  pure $ case (,) <$> D.decodeValue (D.field "a" D.int) args
                  <*> D.decodeValue (D.field "b" D.int) args of
           Right (a, b) -> JNumber (fromIntegral (a + b))
           Left _       -> JString "bad args"

demoTools :: [Tool es]
demoTools = [weatherTool, addTool]

answerCodec :: Codec Text
answerCodec = object (field "answer" id str)

demoCodec :: Codec (Decision ToolCall Text)
demoCodec = decisionCodec toolCallCodec answerCodec

startDemo :: AgentState
startDemo = startAgent demoCodec "demo"   -- or keep the toolsHelp system message variant

-- | Run the example agent on canned replies. Discharge LLM (scripted) then Tools, then pure.
demoAgent :: [Text] -> Text
demoAgent replies =
  runPureEff
    . runTools demoTools
    . runLLMScripted replies
    $ runAgent demoCodec startDemo
```
> Interpreter order: `runLLMScripted` is applied to `runAgent` first (discharging `LLM`, leaving `Tools` in the row), then `runTools` (discharging `Tools`), then `runPureEff` on `Eff '[]`. If the rows don't line up, flip the two `run*` lines — the type errors will tell you. `demoTools :: [Tool es]` is polymorphic so it specialises to whatever row `runTools` discharges.

- [ ] Rewrite `Example.hs`. Keep `demoAgent :: [Text] -> Text` returning the final answer.

---

## Task 6: migrate `Spec.hs` + green the suite

**Files:** `packages/crucible/test/Spec.hs`.

The M7 scripted-loop checks and M10 eval checks used `runScripted`/`MonadLLM`. Rewrite them to run through the effectful interpreters:

```haskell
-- M7-era agent checks: replace runScripted+toolRunner with the effectful stack.
-- Use the Example demoAgent where possible, or inline:
--   runPureEff . runTools tools . runLLMScripted replies $ runAgent codec st
import Effectful (runPureEff)
import Crucible.LLM (runLLMScripted)
import Crucible.Tool (runTools)
import Crucible.Agent (runAgent, startAgent)

-- M10 eval checks: runEval now returns Eff es; run it with runLLMScripted:
--   runPureEff (runLLMScripted [] (runEval id sut cases))
--   runPureEff (runLLMScripted ["{\"vPass\":true,...}"] (runEval id (pure) cases))
```

- [ ] Update every check that used `runScripted`/`MonadLLM`/`runAgentT`/`ScriptedM` to the effectful interpreters. The agent + eval semantics are identical; only the run-wrapper changes. Pure SUTs in eval become `\i -> pure (f i) :: Eff es a`.
- [ ] `nix develop --command zinc test` → all checks green (`ALL PASS`).
- [ ] Add ONE new check exercising the capability manifest, e.g. that `demoAgent` still yields the right answer through the effectful stack:
```haskell
  , check "effectful agent: tool then answer"
      "sunny in Brisbane"
      (demoAgent [ "{\"tool\":\"get_weather\",\"args\":{\"city\":\"Brisbane\"}}"
                 , "{\"answer\":\"sunny in Brisbane\"}" ])
```
- [ ] Commit the whole migration:
```bash
git add -A && git commit -m "feat(effectful): migrate agent substrate from tagless-final to effectful effects"
```

---

## Self-Review

**Coverage:** LLM effect+scripted interp (T1); Tools effect+toolbox interp (T2); effectful control loop with the `(LLM :> es, Tools :> es)` manifest (T3); Eval on the LLM effect (T4); Example via interpreter composition (T5); Spec migrated, suite green (T6). The original capability-manifest design is realized.
**Big-bang note:** the suite won't compile mid-migration (effects + dependents change together); commit once at the end. Expect to iterate on effectful's `interpret`/`reinterpret`/handler types and the interpreter ordering in `Example`/`Spec` — the type errors are guiding.
**Watch-outs:** `LambdaCase` for the `\_ -> \case` handlers; `DataKinds`/`TypeOperators` everywhere effects/rows appear; `effectful-core` must stay in depends (reexport origin). Pure tools are `Tool es` (polymorphic, via `pure`). `runPureEff` requires the row fully discharged to `'[]` — no `IOE` (scripted is pure; the live Anthropic interpreter at M8 would use `runEff` + `IOE`).
**Deferred:** the live `runLLMAnthropic` (IOE + curl) is still M8; this migration keeps everything pure/scripted and green.
