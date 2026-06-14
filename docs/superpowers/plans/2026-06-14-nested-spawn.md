# Nested Spawn Trees Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a spawned worker spawn sub-workers (an arbitrary-depth tree) with one spawn budget shared across the whole tree, by evolving `Crucible.Agents` in place.

**Architecture:** The worker tool row changes from `[Tool es]` to `[Tool (Agents es : es)]`, so a worker's tool handler can call `spawn`. `runAgents` becomes re-entrant: its handler recursively re-interprets each worker's computation against one shared `IORef` budget, so a `spawn` from any tool anywhere in the tree decrements the same counter. Public signatures of `subAgent`/`spawn`/`runAgents`/`spawnGated` are unchanged; only the `tools` field/arg row changes. `runAgentsScripted` is unchanged.

**Tech Stack:** GHC 9.12.2, effectful (dynamic effects, recursive `interpret`, `ScopedTypeVariables`/`RankNTypes`); zinc build.

**Spec:** `docs/superpowers/specs/2026-06-14-nested-spawn-design.md`

## Conventions (every task)
- Build/test: `nix develop . --command timeout -s KILL 300 zinc build|test`. Judge success by exit status or "test suite(s) passed", never a pipeline tail. 137 = GHC flake, retry once; second 137 = BLOCKED. Ignore "Git tree is dirty".
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot. Annotate ambiguous getters/State and report.
- Tests: custom harness `check "label" expected actual`; comma entries in `runChecks` at END of `test/Spec.hs`; `do` blocks allowed. No hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit per task; do not push.

## File Structure
- Modify `src/Crucible/Agents.hs` — `tools` row, `subAgent` sig, re-entrant `runAgents` (Task 1).
- Modify `test/Spec.hs` — update toolbox-row annotations (Task 1); add nesting tests (Task 2).
- Modify `app/Main.hs` — delegation demo (Task 3).
- Modify `docs/subagents.md` — rewrite the one-level framing (Task 4).

---

### Task 1: Evolve `Crucible.Agents` (the spike) and keep the suite green

This is the encoding spike: change the worker tool row + make `runAgents` re-entrant, then fix the in-repo annotations so everything still compiles and the existing tests still pass. If the encoding does not compile as written, STOP and report the exact error (do not work around it by abandoning nesting).

**Files:**
- Modify: `src/Crucible/Agents.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: Add `RankNTypes` and change the `tools` field + `subAgent` signature**

In `src/Crucible/Agents.hs`, add `{-# LANGUAGE RankNTypes #-}` to the pragma block (the others, incl. `ScopedTypeVariables`/`DataKinds`/`TypeOperators`/`TypeFamilies`, are already present).

Change the `tools` field of `SubAgent` (currently `tools :: [Tool es]`) to:
```haskell
  , tools    :: [Tool (Agents es : es)]
```
Change `subAgent`'s signature accordingly:
```haskell
subAgent :: Text -> JSONCodec i -> JSONCodec o -> Text -> [Tool (Agents es : es)] -> SubAgent es i o
```
(The body `subAgent n inC outC sys ts = SubAgent n inC outC sys ts defaultMaxIterations` is unchanged.)

Update the `SubAgent` haddock: `es` is the base row; the worker's tools run in `Agents es : es`, so a tool handler may call `spawn` (this is how a worker spawns sub-workers).

- [ ] **Step 2: Make `runAgents` re-entrant with a shared tree budget**

Replace the existing `runAgents` (the whole definition) with:
```haskell
-- | Live interpreter for a spawn tree. One shared spawn budget is threaded
-- across the whole tree (each spawn anywhere decrements it; exhaustion is
-- 'SpawnBudgetExceeded'). Each worker runs in the full row 'Agents es : es', so
-- a worker tool can 'spawn' sub-workers; the handler re-interprets that worker
-- computation ('go'), servicing nested spawns against the same budget. Needs
-- 'IOE' (the budget is an 'IORef'; live spawn is IO-backed).
runAgents :: forall es a. (Chat :> es, IOE :> es) => Int -> Eff (Agents es : es) a -> Eff es a
runAgents cap act = do
  ref <- liftIO (newIORef cap)
  let go :: forall x. Eff (Agents es : es) x -> Eff es x
      go = interpret $ \_ -> \case
        Spawn sub i -> do
          remaining <- liftIO (readIORef ref)
          if remaining <= 0
            then pure (Left (SpawnBudgetExceeded cap))
            else do
              liftIO (writeIORef ref (remaining - 1))
              res <- go (runToolAgentN sub.maxIters sub.tools (workerPrompt sub i))
              pure $ case res of
                Left (ToolLoopExceeded n) -> Left (WorkerLoopExceeded sub.name n)
                Right finalText           -> decodeFinal sub finalText
  go act
```
Notes:
- The `forall es a.` on `runAgents` and `forall x.` on `go` need `ScopedTypeVariables` + `RankNTypes`. `go` is recursive (its handler calls `go`).
- `runToolAgentN sub.maxIters sub.tools (workerPrompt sub i) :: Eff (Agents es : es) (Either ChatError Text)` because `sub.tools :: [Tool (Agents es : es)]` and `Chat :> es` gives `Chat :> (Agents es : es)`. `go` re-interprets that computation's `Agents es` layer, handling any nested `spawn`.
- If GHC cannot infer the handler's effect for `interpret`, annotate `interpret @(Agents es)` or give the handler an explicit type; report what was needed.
- `runAgentsScripted` is UNCHANGED.

- [ ] **Step 3: Fix the broken `SubAgent` toolbox annotations in `test/Spec.hs`**

The `tools`-row change breaks every explicit empty-toolbox annotation on a `SubAgent` (the ones passed to `subAgent`). First add `Agents` (the effect type) to the Agents import on line 80:
```haskell
import Crucible.Agents (SubAgent (..), subAgent, AgentFailure (..), Agents, spawn, workerPrompt, runAgents, runAgentsScripted)
```
Then update each `subAgent ... ([] :: [Tl.Tool <ROW>])` annotation by wrapping the row as `Agents <ROW> : <ROW>`. The affected lines (verify by recompiling; line numbers approximate) and their new annotations:
- The foundation agents tests (currently `([] :: [Tl.Tool '[]])`): change to `([] :: [Tl.Tool (Agents '[] : '[])])`. (Around lines 2200, 2204, 2210, 2215, 2223, 2231.)
- The live `runAgents` over scripted Chat test (currently `([] :: [Tl.Tool '[Chat.Chat, IOE]])`, ~line 2236): change to `([] :: [Tl.Tool (Agents '[Chat.Chat, IOE] : '[Chat.Chat, IOE])])`.
- The gate tests (currently `([] :: [Tl.Tool '[LLM]])`, ~lines 2239, 2245, 2251, 2259, 2267, 2275): change to `([] :: [Tl.Tool (Agents '[LLM] : '[LLM])])`.

Do NOT change the annotations at lines ~417-432 and ~988-1006: those are `Tl.Tool '[]` for the `Chat.runToolAgent` tests (not `Agents`/`SubAgent`), and they are unaffected.

After editing, search for any remaining `Tl.Tool '[` inside a `subAgent`/`SubAgent` context and confirm each was wrapped. The simplest verification is to compile: the type error points at each unwrapped annotation.

- [ ] **Step 4: Build and run the full suite**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: everything compiles (the spike succeeded) and the FULL existing suite passes unchanged (no behavior changed, only the tool row and the interpreter internals). If `runAgents`'s re-entrant `go` does not type-check, report the exact GHC error verbatim. Retry once on 137.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Agents.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(agents): re-entrant spawn interpreter + spawn-capable worker tools

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Nesting + tree-budget tests

**Files:**
- Modify: `test/Spec.hs`

Nesting is exercised with the live re-entrant `runAgents` over a scripted `Chat`: a root worker carries a "delegate" tool whose handler `spawn`s a child. The child's spawn result is captured in an `IORef` the test inspects (the scripted Chat's canned root output cannot reflect the tool result, so observe the nested spawn directly).

- [ ] **Step 1: Add imports if missing**

Check the import block. You will need: `toolWith` from `Crucible.Tool` (it is imported qualified as `Tl`, so use `Tl.toolWith`); `ToolUse (..)` from `Crucible.Chat` (already imported there with `Turn`/`runChatScripted`); aeson's `String` value constructor (the file already uses `String` / `object` / `.=` in the tool-agent tests, e.g. line ~438; reuse that import); `newIORef`/`readIORef`/`writeIORef` from `Data.IORef` (add `import Data.IORef (newIORef, readIORef, writeIORef)` if not present); `liftIO` from `Effectful` (add to the `Effectful (...)` import if not present); `runEff` (present). `C.str` is the Text codec.

- [ ] **Step 2: Add the nesting plumbing test**

A root spawns a child via a delegate tool; capture the child's result in an `IORef`:
```haskell
  , do ref <- newIORef (Nothing :: Maybe (Either AgentFailure Text))
       let child :: SubAgent '[Chat.Chat, IOE] Text Text
           child = subAgent "child" C.str C.str "child instruction" []
           delegate = Tl.toolWith "delegate" C.str C.str (\q -> do
                        r <- spawn child q
                        liftIO (writeIORef ref (Just r))
                        pure (either (const "failed") Prelude.id r))
           root :: SubAgent '[Chat.Chat, IOE] Text Text
           root = subAgent "root" C.str C.str "root instruction" [delegate]
       _ <- runEff (runChatScripted
              [ Turn "" [ToolUse "u1" "delegate" (String "sub-task")]
              , Turn "\"child-done\"" []
              , Turn "\"root-done\"" [] ]
              (runAgents 5 (spawn root "start")))
       childResult <- readIORef ref
       check "nesting: a worker tool spawns a child that returns its typed result"
         (Just (Right "child-done")) childResult
```
Notes:
- `child`/`root` are `SubAgent '[Chat.Chat, IOE]` (the worker base row under `runEff (runChatScripted (runAgents ...))` is `'[Chat.Chat, IOE]`). The empty child toolbox `[] :: [Tl.Tool (Agents '[Chat.Chat, IOE] : '[Chat.Chat, IOE])]` may need annotation; if GHC infers it from `child`'s type, leave it bare, else annotate. `delegate :: Tl.Tool (Agents '[Chat.Chat, IOE] : '[Chat.Chat, IOE])` (its handler uses `spawn` + `liftIO`, both available in that row).
- Scripted Turn order: root's first converse returns the `delegate` tool_use (Turn 1); the delegate handler spawns the child, whose first converse returns its final JSON `"child-done"` (Turn 2); the child loop ends; the delegate returns; root's next converse returns its final JSON `"root-done"` (Turn 3).
- `ToolUse "u1" "delegate" (String "sub-task")`: the delegate tool's input codec is `C.str`, so its args are a JSON string. If the args format must differ for `str` decode, adjust to what `Tl.invoke`/the tool decoder expects and report.
- The assertion is on `childResult` (the IORef), which directly proves the child spawned and returned `"child-done"`.

- [ ] **Step 3: Add the shared-tree-budget test**

With `cap = 1`, the root spawn uses the only slot, so the child spawn fails:
```haskell
  , do ref <- newIORef (Nothing :: Maybe (Either AgentFailure Text))
       let child :: SubAgent '[Chat.Chat, IOE] Text Text
           child = subAgent "child" C.str C.str "child instruction" []
           delegate = Tl.toolWith "delegate" C.str C.str (\q -> do
                        r <- spawn child q
                        liftIO (writeIORef ref (Just r))
                        pure (either (const "failed") Prelude.id r))
           root :: SubAgent '[Chat.Chat, IOE] Text Text
           root = subAgent "root" C.str C.str "root instruction" [delegate]
       _ <- runEff (runChatScripted
              [ Turn "" [ToolUse "u1" "delegate" (String "sub-task")]
              , Turn "\"root-done\"" [] ]
              (runAgents 1 (spawn root "start")))
       childResult <- readIORef ref
       check "nesting: the spawn budget is shared across the tree"
         True
         (case childResult of Just (Left (SpawnBudgetExceeded 1)) -> True; _ -> False)
```
Notes:
- `cap = 1`: the root spawn decrements to 0; the delegate's child `spawn` sees 0 and returns `Left (SpawnBudgetExceeded 1)`. The child loop never runs, so only two scripted Turns are needed (root tool_use, root final).

- [ ] **Step 4: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: both nesting checks pass; full suite green. If the scripted Turn sequence or the tool-args format is off, the first failing assertion shows the actual `childResult`; adjust the Turns/args and pin. Retry once on 137.

- [ ] **Step 5: Commit**

```bash
git add test/Spec.hs
git commit -m "$(cat <<'EOF'
test(agents): nested spawn via a delegate tool + shared tree budget

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Delegation demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a two-level delegation demo**

Read `app/Main.hs`. The existing spawn/gate demos define `weatherWorker`/`gatedWorker` (`SubAgent '[Chat, ...]`) with `tools weatherBox`. `Tl`/`toolWith` may not be imported in Main; use `Crucible.Tool` helpers. Add imports as needed: `import Crucible.Tool (toolWith)` and ensure `str` is imported (it is). Add a demo where a coordinator worker delegates to a child via a tool:

```haskell
      -- Nested spawn: a coordinator worker delegates a sub-task to a child
      -- worker through a tool, all under one shared spawn budget.
      let weatherChild :: SubAgent '[Chat, LLM, IOE] T.Text T.Text
          weatherChild =
            subAgent "weather-child" str (object (field "summary" Prelude.id str))
              "Use the get_weather tool and summarize the weather in one sentence."
              (tools weatherBox)
          delegateWeather =
            toolWith "delegate_weather" str str (\city -> do
              r <- spawn weatherChild city
              pure (either (\f -> "delegation failed: " <> T.pack (show f)) Prelude.id r))
          coordinator :: SubAgent '[Chat, LLM, IOE] T.Text T.Text
          coordinator =
            subAgent "coordinator" str (object (field "report" Prelude.id str))
              "Delegate the weather lookup to the delegate_weather tool, then report it."
              [delegateWeather]
      nestedRes <- runEff (Anthropic.runChat cfg (runAgents 6 (spawn coordinator "Brisbane")))
      case nestedRes of
        Right report -> TIO.putStrLn ("nested spawn: " <> report)
        Left failure -> TIO.putStrLn ("nested spawn: " <> T.pack (show failure))
```
Notes:
- The worker base row here is `'[Chat, LLM, IOE]` (the row after `runAgents` discharges `Agents`, under `runChat`/`runEff`; `LLM` appears if another part of the block needs it, otherwise use `'[Chat, IOE]` and match what compiles). If GHC reports a different required row for `weatherChild`/`coordinator`, set the annotation to exactly what it expects and report it.
- `delegateWeather :: Tool (Agents '[Chat,...] : '[Chat,...])`; its handler calls `spawn` (available because the worker tool row contains `Agents`) and runs in IO.
- `runAgents 6` gives the tree 6 spawns (root coordinator + child, well within budget).

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. If the row annotation fights inference, set it to GHC's expected row and report. Retry once on 137. (Do not run the binary.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "$(cat <<'EOF'
demo(agents): coordinator delegates to a child worker (nested spawn)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Update `docs/subagents.md`

**Files:**
- Modify: `docs/subagents.md`

- [ ] **Step 1: Rewrite the one-level framing**

Read `docs/subagents.md`. Make these edits (house style: no emdashes/endashes, no hype words, no manifest mentions):
- The intro / `## Spawning` section currently says a worker "cannot spawn its own workers in this release: spawn is one level." Replace that sentence with: a worker spawns sub-workers by carrying a tool whose handler calls `spawn`, so decomposition can recurse; the spawn cap bounds the whole tree (the root spawn included), and a runaway recursion stops at `SpawnBudgetExceeded`.
- In `## Defining a worker`, note that a worker's tools run in a row that can `spawn`, so a tool can delegate a sub-task to a child worker.
- In `## Interpreters`, note that `runAgents`'s cap is the budget for the entire tree.
- In `## What is not covered`, REMOVE "nested trees with tree-wide budgets" from the list (it now exists). Leave the work-ledger (now shipped too, so also remove it if listed) and concurrent-spawn items per their actual status: remove items that now exist (nested trees; the work ledger if mentioned), keep "concurrent spawn". (Check the actual current text and only remove what is now shipped.)

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/subagents.md` (expect no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/subagents.md` (expect no output).

- [ ] **Step 3: Commit**

```bash
git add docs/subagents.md
git commit -m "$(cat <<'EOF'
docs(agents): nested spawn trees + tree budget

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** worker tool row + `subAgent` sig (T1 S1), re-entrant `runAgents` + shared budget (T1 S2), annotation churn to keep green = the spike (T1 S3-4), nesting + tree-budget tests (T2), demo (T3), docs (T4). Non-goals (tokens/depth budget, concurrency, parallel type) are "do not build".
- **Type consistency:** `tools :: [Tool (Agents es : es)]`, `subAgent :: ... -> [Tool (Agents es : es)] -> SubAgent es i o`, `runAgents :: forall es a. (Chat :> es, IOE :> es) => Int -> Eff (Agents es : es) a -> Eff es a` are consistent across module, tests, demo. `spawn`/`spawnGated`/`runAgentsScripted` unchanged.
- **Placeholder scan:** no placeholder code. The judgement points are flagged precisely: the spike compile-or-report gate (T1 S2/S4), the exact annotation rewrites (T1 S3, with the do-not-touch list), the scripted Turn sequence + tool-args format (T2, with "pin actual" guidance), and the demo row annotation (T3). No vague steps.
- **Risk:** the re-entrant `go` is the one unproven piece; Task 1 is structured so a compile failure there is reported before Tasks 2-4. The nesting tests (T2) prove the behavior hermetically.
