# Spawn Effect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A typed orchestrator-worker primitive: `Crucible.Agents` with a `SubAgent` value and an `Agents` effect whose `Spawn` runs an isolated worker tool loop and hands back a codec-typed result, with a spawn cap.

**Architecture:** `Agents` is a dynamic effect indexed by the worker base row (`Agents es`), keeping spawn one level and the encoding non-recursive. The live interpreter `runAgents` uses `interpret` plus an `IORef` budget (row unchanged, so a worker's `[Tool es]` matches `runToolAgentN`), needing `IOE`. The scripted interpreter `runAgentsScripted` uses `reinterpret (evalState ...)`, runs no tools, and stays pure. Shared pure helpers `workerPrompt` and `decodeFinal` keep the two interpreters from drifting.

**Tech Stack:** GHC 9.12.2, effectful (dynamic effects), aeson/autodocodec; zinc build (`nix develop . --command timeout -s KILL 300 zinc build|test`).

**Spec:** `docs/superpowers/specs/2026-06-14-spawn-effect-design.md`

## Conventions (every task)
- Build: `nix develop . --command timeout -s KILL 300 zinc build`. Test: `nix develop . --command timeout -s KILL 300 zinc test`. Judge success by exit status or the "test suite(s) passed" line, never a pipeline tail. Exit 137 = GHC iserv flake: retry once; second 137 = BLOCKED. Ignore "Git tree is dirty".
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot, `(.field)` access; under DuplicateRecordFields a `(.field)` getter section may need an inline type annotation (annotate and report). Effectful dynamic dispatch often needs `get @T` / `put`-with-annotation; annotate State types.
- Tests: custom harness `test/Harness.hs` `check :: (Eq a, Show a) => String -> a -> a -> IO Bool`, called `check "label" expected actual`; entries comma-separated in the `runChecks` list at the END of `test/Spec.hs`; each entry is `IO Bool` (a `do` block is allowed). No hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit at the end of each task; do not push.
- Modules are auto-discovered; a new module needs no zinc.toml change.

## Existing pieces this builds on (already in the repo)
- `Crucible.Chat`: `runToolAgentN :: (Chat :> es) => Int -> [Tool es] -> Text -> Eff es (Either ChatError Text)`, `ChatError (..)` with `ToolLoopExceeded Int`, `defaultMaxIterations :: Int`, the `Chat` effect.
- `Crucible.Tool`: `Tool es` (GADT with `name`/`schema`/`input`/`output`/`run`).
- `Crucible.Codec`: `JSONCodec`, `schemaText :: JSONCodec a -> Text`, `encodeText :: JSONCodec a -> a -> Text`.
- `Crucible.Decode`: `decodeLLM :: JSONCodec a -> Text -> Either DecodeError a`, `DecodeError (..)` with fields `message :: Text`, `raw :: Text`.
- effectful: `interpret`, `reinterpret`, `send` from `Effectful.Dispatch.Dynamic`; `evalState`, `get`, `put` from `Effectful.State.Static.Local`; `Effectful (Eff, IOE, liftIO, (:>), type (:))`.

## File Structure
- Create `src/Crucible/Agents.hs` — the whole module (types, effect, helpers, both interpreters).
- Modify `test/Spec.hs` — scripted tests (Task 1), live-interpreter-via-scripted-Chat test (Task 2).
- Modify `app/Main.hs` — live demo (Task 3).
- Create `docs/subagents.md` — manual page (Task 4).

---

### Task 1: Core module + scripted interpreter + hermetic tests

**Files:**
- Create: `src/Crucible/Agents.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Create `src/Crucible/Agents.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Typed orchestrator-worker spawn. A 'SubAgent' is a worker: a 'Skill' whose
-- body is a tool loop. The 'Agents' effect's 'spawn' runs the worker as a fresh
-- transcript (the parent never sees it) and decodes its final answer through the
-- worker's output codec, the typed handoff no surveyed harness has. This release
-- is one level (workers are leaf, cannot spawn) and synchronous, with a built-in
-- spawn cap. 'runAgents' is the live interpreter; 'runAgentsScripted' is a
-- model-free interpreter for testing parent logic.
module Crucible.Agents
  ( SubAgent (..)
  , subAgent
  , AgentFailure (..)
  , Agents (..)
  , spawn
  , workerPrompt
  , runAgents
  , runAgentsScripted
  ) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (evalState, get, put)

import Crucible.Chat (Chat, ChatError (..), runToolAgentN, defaultMaxIterations)
import Crucible.Codec (JSONCodec, schemaText, encodeText)
import Crucible.Decode (DecodeError (..), decodeLLM)
import Crucible.Tool (Tool)

-- | A spawnable worker. @es@ is the base effect row the worker runs in (it has
-- 'Chat' and whatever its tools need, not 'Agents', which keeps spawn one level).
data SubAgent es i o = SubAgent
  { name     :: Text
  , input    :: JSONCodec i
  , output   :: JSONCodec o
  , system   :: Text
  , tools    :: [Tool es]
  , maxIters :: Int
  }

-- | Build a SubAgent with @maxIters@ defaulted to 'defaultMaxIterations'.
subAgent :: Text -> JSONCodec i -> JSONCodec o -> Text -> [Tool es] -> SubAgent es i o
subAgent n inC outC sys ts = SubAgent n inC outC sys ts defaultMaxIterations

-- | A spawn failure.
data AgentFailure
  = SpawnBudgetExceeded Int               -- ^ the spawn cap that was hit
  | WorkerLoopExceeded  Text Int          -- ^ worker name, its iteration cap
  | WorkerDecodeFailed  Text DecodeError  -- ^ worker name, the decode error
  deriving (Eq, Show)

-- | Orchestrator-worker spawn, indexed by the worker base row @es@.
data Agents (es :: [Effect]) :: Effect where
  Spawn :: SubAgent es i o -> i -> Agents es m (Either AgentFailure o)
type instance DispatchOf (Agents es) = Dynamic

spawn :: (Agents es :> es) => SubAgent es i o -> i -> Eff es (Either AgentFailure o)
spawn sub i = send (Spawn sub i)

-- | The worker prompt: the worker instruction, the output-schema contract, and
-- the rendered input. ('runToolAgent' has no system slot, so the instruction is
-- folded in here.) Pure, so it is unit-tested.
workerPrompt :: SubAgent es i o -> i -> Text
workerPrompt sub i = T.concat
  [ sub.system, "\n\n"
  , "Respond ONLY with JSON matching this schema:\n", schemaText sub.output, "\n\n"
  , "<input>\n", encodeText sub.input i, "\n</input>\n\n"
  , "When you are done, reply with JSON only; your reply is parsed by a machine."
  ]

-- | Decode a worker's final answer text into the typed result.
decodeFinal :: SubAgent es i o -> Text -> Either AgentFailure o
decodeFinal sub t = case decodeLLM sub.output t of
  Left e  -> Left (WorkerDecodeFailed sub.name e)
  Right o -> Right o

-- | Live interpreter: each spawn runs the worker tool loop as a fresh
-- transcript under the ambient 'Chat', honoring a spawn-count cap. Needs 'IOE'
-- (the budget is an 'IORef'; live spawn is IO-backed).
runAgents :: (Chat :> es, IOE :> es) => Int -> Eff (Agents es : es) a -> Eff es a
runAgents cap act = do
  ref <- liftIO (newIORef cap)
  interpret
    (\_ -> \case
        Spawn sub i -> do
          remaining <- liftIO (readIORef ref)
          if remaining <= 0
            then pure (Left (SpawnBudgetExceeded cap))
            else do
              liftIO (writeIORef ref (remaining - 1))
              res <- runToolAgentN sub.maxIters sub.tools (workerPrompt sub i)
              pure $ case res of
                Left (ToolLoopExceeded n) -> Left (WorkerLoopExceeded sub.name n)
                Right finalText           -> decodeFinal sub finalText)
    act

-- | Model-free interpreter: each spawn pops the next canned final-answer text
-- and decodes it through that spawn's output codec, honoring the same cap. Runs
-- no tools, so it is pure ('runPureEff'-compatible).
runAgentsScripted :: Int -> [Text] -> Eff (Agents es : es) a -> Eff es a
runAgentsScripted cap script =
  reinterpret (evalState (cap, script)) $ \_ -> \case
    Spawn sub _i -> do
      (remaining, answers) <- get @(Int, [Text])
      if remaining <= 0
        then pure (Left (SpawnBudgetExceeded cap))
        else case answers of
          (t : ts) -> put (remaining - 1, ts) >> pure (decodeFinal sub t)
          []       -> put (remaining - 1, [] :: [Text])
                        >> pure (Left (WorkerDecodeFailed sub.name (DecodeError "no scripted answer" "")))
```
Notes for the implementer:
- The `Agents (es :: [Effect]) :: Effect` GADT is indexed by the base row; `type instance DispatchOf (Agents es) = Dynamic` is a parameterized family instance (needs `TypeFamilies`). `spawn`'s `(Agents es :> es)` is a normal membership constraint (no infinite type: in the interpreters the handled row is `Agents es : es`, where the element `Agents es` references the tail `es`, not the whole row).
- In `runAgents`, `interpret` keeps the row at `es`, so `runToolAgentN sub.maxIters sub.tools ... :: Eff es (...)` matches `sub.tools :: [Tool es]` and `Chat :> es`. The existential `o` from `Spawn :: SubAgent es i o -> ...` is handled because both branches produce `Either AgentFailure o` (`SpawnBudgetExceeded`/`WorkerLoopExceeded` are `Left`, `decodeFinal sub` returns `Either AgentFailure o`).
- In `runAgentsScripted`, the State tuple type annotation `get @(Int, [Text])` is required under dynamic dispatch.
- If any `(.field)` getter section is ambiguous, annotate and report it.

- [ ] **Step 2: Add scripted tests to `test/Spec.hs`**

Add imports near the other crucible imports:
```haskell
import Crucible.Agents (SubAgent (..), subAgent, AgentFailure (..), spawn, workerPrompt, runAgentsScripted)
```
`runPureEff` is already imported from `Effectful`; `C` is `Crucible.Codec` (with `C.str`, `C.int`, `C.object`, `C.field`); `T` is `Data.Text`. Define a tiny typed output for the handoff tests using the codec facade. Add to `runChecks` (comma-prefixed entries). The base row for hermetic tests is `'[]`, and the toolbox is empty (scripted ignores tools), so SubAgents are `SubAgent '[] i o`:

```haskell
  -- A worker that returns a typed Int wrapped in {"n": ...}.
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool '[]])
    in check "spawn: canned answer decodes to typed output"
         (Right (Right (6 :: Int)))
         (runPureEff (runAgentsScripted 5 ["{\"n\": 6}"] (spawn w 3)))
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool '[]])
    in check "spawn: undecodable answer -> WorkerDecodeFailed"
         True
         (case runPureEff (runAgentsScripted 5 ["not json"] (spawn w 3)) of
            Right (Left (WorkerDecodeFailed n _)) -> n == "double"
            _ -> False)
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool '[]])
    in check "spawn: budget cap exceeded on the second spawn"
         (Right (Right (1 :: Int), Left (SpawnBudgetExceeded 1)))
         (runPureEff (runAgentsScripted 1 ["{\"n\": 1}", "{\"n\": 2}"]
            (do a <- spawn w 0; b <- spawn w 0; pure (a, b))))
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool '[]])
    in check "spawn: exhausted script -> WorkerDecodeFailed"
         True
         (case runPureEff (runAgentsScripted 5 [] (spawn w 0)) of
            Right (Left (WorkerDecodeFailed _ e)) -> e.message == "no scripted answer"
            _ -> False)
  , check "workerPrompt contains system, schema, and input"
      True
      (let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool '[]])
           p = workerPrompt w 7
       in T.isInfixOf "double the input" p && T.isInfixOf "<input>\n7" p && T.isInfixOf "\"n\"" p)
  , check "AgentFailure Eq/Show round value"
      (SpawnBudgetExceeded 3) (SpawnBudgetExceeded 3)
```
Notes:
- `Tl` is the existing qualified import of `Crucible.Tool` in Spec.hs (verify the alias; the file imports `import qualified Crucible.Tool as Tl`). The empty toolbox needs the type annotation `([] :: [Tl.Tool '[]])` so the base row resolves to `'[]`.
- `runPureEff (runAgentsScripted ...)` returns the program's result; for the single-spawn tests the program is `spawn w x :: Eff (Agents '[] : '[]) (Either AgentFailure Int)`, so the outer value is `Either AgentFailure Int` and `runPureEff` yields it directly. The expected `(Right (Right 6))` reflects `runPureEff` returning the pure value `Right 6`... CHECK: `runPureEff :: Eff '[] a -> a` returns `a` directly (NOT wrapped in Either). So the expected for the first test is just `Right (6 :: Int)`, NOT `Right (Right 6)`. CORRECT the expected values to a single layer: `(Right (6 :: Int))`, and the budget test expected is `(Right (1 :: Int), Left (SpawnBudgetExceeded 1))`. (The `case ... of` tests already pattern-match the single layer.) Use the single-layer form; if the compiler reports a type mismatch, the harness error will show the actual shape, pin it.
- `C.object (C.field "n" Prelude.id C.int)` builds `JSONCodec Int` encoding/decoding `{"n": <int>}`. Confirm `C.object`/`C.field` are exported (they are, used elsewhere in Spec.hs and Main.hs).

- [ ] **Step 3: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the new scripted checks pass; full suite green. The single-vs-double `Either` layering is the most likely first-try error: `runPureEff` returns the value directly, so a single-spawn program yields `Either AgentFailure o` (one layer). Fix expecteds to one layer if needed. Retry once on 137.

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/Agents.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(agents): SubAgent + Agents effect + scripted spawn interpreter

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Live interpreter test (via scripted Chat)

The `runAgents` live interpreter is already written in Task 1. This task adds a hermetic test that exercises it without a model, by running it over a scripted `Chat` under `runEff` (which supplies `IOE`).

**Files:**
- Test: `test/Spec.hs`

- [ ] **Step 1: Add the import and test**

`runEff` is imported from `Effectful`; `runChatScripted` and `Turn (..)` are imported from `Crucible.Chat` (the file already imports them for the tool-agent tests). Add `runAgents` to the existing `Crucible.Agents` import line (append `, runAgents`). Add to `runChecks`:

```haskell
  -- runAgents over a scripted Chat: the worker's tool loop gets the canned
  -- Turn as its final answer (no tool calls), which decodes to the typed output.
  , do let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool '[]])
       r <- runEff (runChatScripted [Turn "{\"n\": 42}" []] (runAgents 5 (spawn w 21)))
       check "runAgents (scripted Chat): worker answer decodes to typed output" (Right (42 :: Int)) r
```
Notes:
- Here the base row `es` under `runChatScripted` (within `runEff`) provides `Chat` and `IOE`, satisfying `runAgents :: (Chat :> es, IOE :> es) => ...`. The empty toolbox `([] :: [Tl.Tool '[]])` may need its base row to match the run row; if GHC complains the toolbox row does not match, change the annotation to let it be inferred (write `[]` without annotation and let unification pick the run row) OR annotate to the inferred row. Prefer dropping the annotation here and letting it infer, since `spawn`/`runAgents` pin the row. If inference is ambiguous, report the exact error.
- `runChatScripted [Turn "{...}" []]` returns that Turn as the worker's first assistant turn; with no `toolUses` the tool loop ends and returns `Right "{...}"`, which `decodeFinal` decodes.
- `r :: Either AgentFailure Int` (one layer; `runEff` returns the value).

- [ ] **Step 2: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the new check passes; full suite green. If the empty-toolbox row annotation fights inference, drop it (Step 1 note). Retry once on 137.

- [ ] **Step 3: Commit**

```bash
git add test/Spec.hs
git commit -m "$(cat <<'EOF'
test(agents): runAgents over scripted Chat (hermetic live-path test)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Live demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a spawn demo to the Anthropic-key-gated block**

Read `app/Main.hs`. It already has `weatherBox`/`WeatherTools` and uses `runToolAgent` with `tools weatherBox`; `Anthropic.runChat`, `cfg`, `runEff`, `TIO`, `T`, `skill`, `str`, `object`, `field`, `int` are in scope. Add imports near the other crucible imports:
```haskell
import Crucible.Agents (subAgent, spawn, AgentFailure (..), runAgents)
```
Insert this demo inside the `Just key -> do` block, after an existing demo near the end (for example after the latency demo), at 6-space indentation:
```haskell
      -- Spawn: an orchestrator spawns one worker subagent (with a tool) and
      -- gets back a typed result over an isolated transcript.
      let weatherWorker =
            subAgent "weather-worker" str
              (object (field "summary" Prelude.id str))
              "Use the get_weather tool, then summarize the weather in one sentence."
              (tools weatherBox)
      spawnRes <- runEff (Anthropic.runChat cfg
                    (runAgents 4 (spawn weatherWorker "Brisbane")))
      case spawnRes of
        Right summary -> TIO.putStrLn ("spawn: worker returned: " <> summary)
        Left failure  -> TIO.putStrLn ("spawn: worker failed: " <> T.pack (show failure))
```
Notes:
- `weatherWorker :: SubAgent es T.Text T.Text` where `es` is the run row under `Anthropic.runChat` (which has `Chat`) and `runEff` (which has `IOE`). `tools weatherBox` produces `[Tool es]` for that row (the generic-tools machinery is row-polymorphic). The output codec `object (field "summary" Prelude.id str)` decodes `{"summary": "..."}` to `Text`.
- If the worker output type is ambiguous, annotate `weatherWorker :: SubAgent _ T.Text T.Text` is not valid; instead let it infer from `spawn weatherWorker "Brisbane"` usage, or add a top-level-style annotation only if the compiler requires. Prefer letting inference work; report any ambiguity.

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. Retry once on 137. (Do not run the binary; it needs a key.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "$(cat <<'EOF'
demo(agents): orchestrator spawns a typed worker subagent

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Manual page `docs/subagents.md`

**Files:**
- Create: `docs/subagents.md`

- [ ] **Step 1: Write the page**

Check used nav orders: `grep -rn "nav_order:" docs/*.md`. Use `12` if free (memory is 10, multimodal 11); if taken, use the next free integer. Create `docs/subagents.md` matching the voice of `docs/memory.md` (matter-of-fact, short sentences). Content (use REAL triple-backtick fences):

```markdown
---
title: Subagents
nav_order: 12
---

# Subagents

A subagent is a worker an orchestrator can spawn for a subtask. It runs its own
tool loop over a fresh transcript the parent never sees, and hands back a typed
result. The typed handoff is the part a hand-rolled multi-agent setup usually
leaves as prose or loose JSON.

## Defining a worker

```haskell
data SubAgent es i o = SubAgent
  { name :: Text, input :: JSONCodec i, output :: JSONCodec o
  , system :: Text, tools :: [Tool es], maxIters :: Int }

subAgent :: Text -> JSONCodec i -> JSONCodec o -> Text -> [Tool es] -> SubAgent es i o
```

A `SubAgent` is a `Skill` whose body is a tool loop: an input codec, an output
codec, an instruction, its own toolbox, and a tool-loop cap. Each worker carries
its own toolbox, so a worker has only the authority it needs.

## Spawning

```haskell
data AgentFailure
  = SpawnBudgetExceeded Int
  | WorkerLoopExceeded  Text Int
  | WorkerDecodeFailed  Text DecodeError

spawn :: (Agents es :> es) => SubAgent es i o -> i -> Eff es (Either AgentFailure o)
```

`spawn` runs the worker and decodes its final answer through the output codec.
The parent gets `Either AgentFailure o` and never sees the worker transcript. A
worker cannot spawn its own workers in this release: spawn is one level.

## Interpreters

```haskell
runAgents         :: (Chat :> es, IOE :> es) => Int -> Eff (Agents es : es) a -> Eff es a
runAgentsScripted :: Int -> [Text] -> Eff (Agents es : es) a -> Eff es a
```

`runAgents` is the live interpreter: it drives each worker's tool loop under the
ambient `Chat`, capped at the given number of spawns (exhaustion is
`SpawnBudgetExceeded`). `runAgentsScripted` is model-free: each spawn pops the
next canned final-answer text and decodes it, honoring the same cap, so you can
test an orchestrator's logic without a model.

```haskell
orchestrate :: (Agents es :> es) => Eff es (Either AgentFailure Summary)
orchestrate = spawn researchWorker "the question"

-- live:    runEff (Anthropic.runChat cfg (runAgents 4 orchestrate))
-- in tests: runPureEff (runAgentsScripted 4 ["{...}"] orchestrate)
```

## What is not covered

Workers are leaf (no nested trees) and spawn is synchronous. Judge-gated worker
outputs, a work-ledger effect, nested trees with tree-wide budgets, and
concurrent spawn are planned as separate work.
```
(The outer ```markdown fence delimits the block in this plan only; write real markdown.)

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/subagents.md` (expect no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/subagents.md` (expect no output).
Confirm the chosen `nav_order` does not collide.

- [ ] **Step 3: Commit**

```bash
git add docs/subagents.md
git commit -m "$(cat <<'EOF'
docs(agents): subagents manual page

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** `SubAgent`/`subAgent` (T1), `Agents`/`spawn`/`AgentFailure` (T1), `workerPrompt` + `decodeFinal` shared helpers (T1), `runAgentsScripted` (T1), `runAgents` live (written T1, tested T2), demo (T3), `docs/subagents.md` (T4). Non-goals are "do not build". All spec Design/Testing items map to a task.
- **Type consistency:** `SubAgent es i o` fields and `subAgent`/`spawn`/`runAgents`/`runAgentsScripted` signatures match the spec exactly. `AgentFailure` constructors (`SpawnBudgetExceeded Int`, `WorkerLoopExceeded Text Int`, `WorkerDecodeFailed Text DecodeError`) are identical across module, tests, and demo. `workerPrompt :: SubAgent es i o -> i -> Text`.
- **Placeholder scan:** the only flagged judgement points are (a) the `Either` layering of `runPureEff` results (single layer; corrected in T1 Step 2 notes) and (b) the empty-toolbox row annotation in T2 (drop it to let inference resolve). Both are called out with the fix.
- **Encoding risk:** Task 1's scripted interpreter exercises the `Agents es` base-row encoding end to end under `runPureEff`; if Task 1 compiles and its tests pass, the encoding is validated before the live interpreter is tested in Task 2.
