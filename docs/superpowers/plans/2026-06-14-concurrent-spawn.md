# Concurrent Spawn Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run independent subagent spawns concurrently via a `spawnAll` combinator, with `runAgents`'s budget made an atomic compare-and-set so concurrency cannot over-spend. No change to the `Agents` effect.

**Architecture:** `runAgents`'s budget becomes `atomicModifyIORef'` (sequential behavior unchanged, concurrency-safe). `spawnAll = mapConcurrently (uncurry spawn)` from effectful's `Concurrent`. Siblings share no state; failures are `Left` values; the atomic budget is shared across the whole tree.

**Tech Stack:** GHC 9.12.2, effectful 2.6.1.0 (`Effectful.Concurrent`, `Effectful.Concurrent.Async` — both already available, no new dep), `atomicModifyIORef'`; zinc build.

**Spec:** `docs/superpowers/specs/2026-06-14-concurrent-spawn-design.md`

## Conventions (every task)
- Build/test: `nix develop . --command timeout -s KILL 300 zinc build|test`. Judge success by exit status or "test suite(s) passed", never a pipeline tail. 137 = GHC flake, retry once; second 137 = BLOCKED. Ignore "Git tree is dirty".
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot. Annotate ambiguous getters/State and report.
- Tests: custom harness `check "label" expected actual`; comma entries in `runChecks` at END of `test/Spec.hs`; `do` blocks (returning `IO Bool`) allowed. No hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit per task; do not push.

## Confirmed facts
- `effectful` 2.6.1.0 (already a dependency) exports `Effectful.Concurrent (Concurrent, runConcurrent)` and `Effectful.Concurrent.Async (mapConcurrently)`. No dependency change is expected. If the build cannot resolve these modules, report the exact error (do not invent a new dependency without confirming the build needs it).
- Current `runAgents` (in `src/Crucible/Agents.hs`) is re-entrant with a non-atomic `readIORef`/`writeIORef` budget. `runAgentsScripted` is unchanged by this work. `spawn`/`SubAgent`/`Spawn`/`subAgent`/`spawnGated` are unchanged.
- `atomicModifyIORef'` is already used in `Crucible.LLM.Fallback` and `Crucible.LLM.CallLog`.

## File Structure
- Modify `src/Crucible/Agents.hs` — atomic budget + `spawnAll` + imports/export (Task 1).
- Modify `test/Spec.hs` — concurrency tests (Task 1).
- Modify `app/Main.hs` — live concurrent fan-out demo (Task 2).
- Modify `docs/subagents.md` — "Concurrent spawn" section (Task 3).

---

### Task 1: Atomic budget + `spawnAll` + tests (the spike)

This is the risky task: it both makes the budget atomic and proves concurrent spawn works hermetically. If the concurrent-over-scripted test stack does not work, use the deterministic `claimSlot` fallback test and report which path held.

**Files:**
- Modify: `src/Crucible/Agents.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Imports + export `spawnAll`**

In `src/Crucible/Agents.hs`:
- Change the `Data.IORef` import to bring `atomicModifyIORef'` (drop `writeIORef`/`readIORef` if no longer used after Step 2):
```haskell
import Data.IORef (newIORef, atomicModifyIORef')
```
- Add the concurrency imports:
```haskell
import Effectful.Concurrent (Concurrent)
import Effectful.Concurrent.Async (mapConcurrently)
```
- Add `spawnAll` to the module export list (after `spawn`).

- [ ] **Step 2: Make the budget atomic in `runAgents`**

Add a helper above `runAgents`:
```haskell
-- | Atomically claim one unit of budget: True if a slot was taken (and the
-- counter decremented), False if the budget was already exhausted. Safe under
-- concurrent spawns (a compare-and-set), so the cap is never over-spent.
claimSlot :: IORef Int -> IO Bool
claimSlot ref = atomicModifyIORef' ref (\r -> if r <= 0 then (r, False) else (r - 1, True))
```
(Needs `IORef` in scope; add it to the `Data.IORef` import: `import Data.IORef (IORef, newIORef, atomicModifyIORef')`.)

Replace the `Spawn` handler's non-atomic check in `runAgents` (the `remaining <- liftIO (readIORef ref); if remaining <= 0 ... else do liftIO (writeIORef ref (remaining - 1)); ...` block) with:
```haskell
        Spawn sub i -> do
          claimed <- liftIO (claimSlot ref)
          if not claimed
            then pure (Left (SpawnBudgetExceeded cap))
            else do
              res <- go (runToolAgentN sub.maxIters sub.tools (workerPrompt sub i))
              pure $ case res of
                Left (ToolLoopExceeded n) -> Left (WorkerLoopExceeded sub.name n)
                Right finalText           -> decodeFinal sub finalText
```
Everything else in `runAgents` (the `ref <- liftIO (newIORef cap)`, the `go` signature, `go act`) is unchanged. `runAgentsScripted` is unchanged.

- [ ] **Step 3: Add `spawnAll`**

Add after `spawn`:
```haskell
-- | Spawn a batch of workers concurrently and collect their results in input
-- order. Built on effectful's 'Concurrent' ('mapConcurrently' over 'spawn'), so
-- the 'Agents' effect is unchanged. Siblings share no state; each returns its
-- own typed result. The spawn budget is shared atomically across the batch (and
-- the whole tree), so with a cap below the batch size exactly cap spawns
-- succeed and the rest return 'SpawnBudgetExceeded'. A worker failure is a
-- 'Left' (it does not cancel siblings); a worker that throws cancels the
-- siblings and rethrows (the 'async' semantics). Discharge 'Concurrent' with
-- 'Effectful.Concurrent.runConcurrent'.
spawnAll :: (Agents es :> r, Concurrent :> r)
         => [(SubAgent es i o, i)] -> Eff r [Either AgentFailure o]
spawnAll = mapConcurrently (uncurry spawn)
```

- [ ] **Step 4: Build the library**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile (confirms the `Effectful.Concurrent*` imports resolve and the atomic budget type-checks). If `mapConcurrently` or `Concurrent`/`runConcurrent` cannot be resolved, report the exact error before continuing (this is the dependency/import spike). Retry once on 137.

- [ ] **Step 5: Add concurrency tests to `test/Spec.hs`**

Add imports if missing: `Effectful.Concurrent (runConcurrent)`, `spawnAll` from `Crucible.Agents`. `runEff`, `runChatScripted`, `Turn (..)`, `subAgent`, `SubAgent (..)`, `AgentFailure (..)`, `Agents`, `C.str`, `Text` are present.

The stack is `runEff (runConcurrent (runChatScripted [canned] (runAgents cap (spawnAll pairs))))`. Forked workers each clone the scripted-Chat state at fork time, so an identical canned answer is deterministic per worker; the atomic budget gives a deterministic success/fail count. Add:

```haskell
  -- all succeed when the cap covers the batch (results in input order)
  , do let w :: SubAgent '[Chat.Chat, IOE] Text Text
           w = subAgent "w" C.str C.str "do it" []
           pairs = [(w, "a"), (w, "b"), (w, "c")]
       rs <- runEff (runConcurrent (runChatScripted [Turn "\"ok\"" [], Turn "\"ok\"" [], Turn "\"ok\"" []]
               (runAgents 5 (spawnAll pairs))))
       check "spawnAll: all succeed under the cap" [Right "ok", Right "ok", Right "ok"] rs
  -- the shared budget caps the batch: exactly cap successes, rest SpawnBudgetExceeded
  , do let w :: SubAgent '[Chat.Chat, IOE] Text Text
           w = subAgent "w" C.str C.str "do it" []
           pairs = [(w, "a"), (w, "b"), (w, "c")]
       rs <- runEff (runConcurrent (runChatScripted [Turn "\"ok\"" [], Turn "\"ok\"" [], Turn "\"ok\"" []]
               (runAgents 2 (spawnAll pairs))))
       let oks  = length [() | Right _ <- rs]
           caps = length [() | Left (SpawnBudgetExceeded _) <- rs]
       check "spawnAll: shared budget caps the batch (2 ok, 1 over budget)" (2 :: Int, 1 :: Int) (oks, caps)
```
Notes:
- The empty toolbox `[]` should infer from `w`'s type `SubAgent '[Chat.Chat, IOE] Text Text`; if GHC needs it, annotate `([] :: [Tl.Tool (Agents '[Chat.Chat, IOE] : '[Chat.Chat, IOE])])` (the nested-spawn worker tool row) and report.
- `runChatScripted` needs 3 canned turns for the all-succeed case (one per worker; each forked worker clones the script and pops its first turn). For the budget case 3 turns is also safe (the over-budget worker never converses, so a spare turn is harmless).
- The all-succeed test asserts the full ordered list (`mapConcurrently` preserves input order). The budget test asserts the deterministic COUNT (2 ok, 1 capped); which spawn is capped is not asserted.

- [ ] **Step 6: Build and run the full suite**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: both concurrency checks pass; the full existing suite still passes (the atomic budget preserves sequential behavior). 

IF the concurrent-over-scripted stack does NOT work (e.g. `runChatScripted`'s State does not survive `mapConcurrently`, or an interpreter-order type error you cannot resolve): replace the two tests above with a deterministic `claimSlot` test instead, and report that you took the fallback. To do that, export `claimSlot` from `Crucible.Agents` and add:
```haskell
  , do ref <- newIORef (2 :: Int)
       results <- mapM (const (claimSlot ref)) [1 :: Int ..5]
       check "claimSlot: exactly cap successes" (2 :: Int) (length (filter Prelude.id results))
```
(This proves the atomic budget logic deterministically; real parallelism is then shown only in the live demo. Prefer the concurrent tests; use this fallback only if the stack genuinely will not work, and say so in a comment.) Retry once on 137.

- [ ] **Step 7: Commit**

```bash
git add src/Crucible/Agents.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(agents): atomic spawn budget + spawnAll concurrent fan-out

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Live concurrent fan-out demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a concurrent spawn demo**

Read `app/Main.hs`. It has `weatherBox`/`tools weatherBox` and the nested-spawn demo using `runEff (Anthropic.runChat cfg (runAgents N (...)))`. Add imports: `import Crucible.Agents (spawnAll)` (append to the existing `Crucible.Agents` import) and `import qualified Effectful.Concurrent as Conc` (for `Conc.runConcurrent`). `object`/`field`/`str`/`tools`/`weatherBox` are in scope.

Insert after the nested-spawn demo, at 6-space indentation:
```haskell
      -- Concurrent spawn: fan out three weather workers at once under one
      -- shared budget; results come back in order.
      let cityWorker :: SubAgent '[Chat, IOE] T.Text T.Text
          cityWorker =
            subAgent "city-weather" str (object (field "summary" Prelude.id str))
              "Use the get_weather tool and summarize the weather in one sentence."
              (tools weatherBox)
          cityPairs = [(cityWorker, "Brisbane"), (cityWorker, "Sydney"), (cityWorker, "Perth")]
      concRes <- runEff (Conc.runConcurrent (Anthropic.runChat cfg
                   (runAgents 6 (spawnAll cityPairs))))
      mapM_ (\r -> TIO.putStrLn ("concurrent spawn: " <> either (T.pack . show) Prelude.id r)) concRes
```
Notes:
- The worker base row is `'[Chat, IOE]` (the row after `runAgents` discharges `Agents`, under `runChat`/`runEff`). `runConcurrent` provides `Concurrent`, which `spawnAll` needs in the spawn row (`Agents '[Chat,IOE] : '[Chat,IOE]`) — so `Concurrent` must be in `'[Chat, IOE]` too; that means the base row is actually `'[Chat, Concurrent, IOE]`-ish. Set the `cityWorker` annotation to EXACTLY the row GHC requires (it will tell you), and report it. The interpreter nesting is `runEff (Conc.runConcurrent (Anthropic.runChat cfg (runAgents 6 ...)))`; if GHC wants a different order, adjust and report.
- `runAgents 6` gives the three concurrent spawns ample budget.

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. If the worker row annotation fights inference, set it to GHC's expected row (likely including `Concurrent`) and report. Retry once on 137. (Do not run the binary.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "$(cat <<'EOF'
demo(agents): concurrent weather fan-out via spawnAll

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: "Concurrent spawn" section in `docs/subagents.md`

**Files:**
- Modify: `docs/subagents.md`

- [ ] **Step 1: Add the section and update "What is not covered"**

Read `docs/subagents.md`. Insert a `## Concurrent spawn` section after `## Judge gates` (or after the nesting content, before `## What is not covered`). Content (real triple-backtick fences):

```markdown
## Concurrent spawn

Independent subtasks can run at once instead of one after another.

```haskell
spawnAll :: (Agents es :> r, Concurrent :> r)
         => [(SubAgent es i o, i)] -> Eff r [Either AgentFailure o]
```

`spawnAll` runs a batch of spawns concurrently and returns their results in
input order. Discharge the `Concurrent` effect with
`Effectful.Concurrent.runConcurrent`. Each worker keeps its own isolated
transcript and returns its own typed result, so siblings share no state. The
spawn budget is shared atomically across the batch and the whole tree, so with a
cap below the batch size exactly that many spawns succeed and the rest return
`SpawnBudgetExceeded`. A worker failure is a `Left` value and does not cancel
its siblings; a worker that throws an exception cancels the siblings and
rethrows, the standard concurrent-task behaviour. For a batch with mixed input
or output types, use `Effectful.Concurrent.Async.mapConcurrently` over `spawn`
directly.
```
(The outer ```markdown fence delimits this block in the plan only; write real markdown.)

Then update `## What is not covered`: REMOVE the "concurrent spawn" item (it now exists). Reword the remaining sentence so it reads naturally (cross-sibling communication / blackboard / debate remain out of scope, as does streaming partial results, if listed; otherwise just remove the concurrent-spawn item).

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/subagents.md` (expect no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/subagents.md` (expect no output).

- [ ] **Step 3: Commit**

```bash
git add docs/subagents.md
git commit -m "$(cat <<'EOF'
docs(agents): Concurrent spawn section (spawnAll)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** atomic budget (T1 S2), `spawnAll` (T1 S3), concurrency tests with the `claimSlot` fallback = the spike (T1 S4-6), demo (T2), docs + remove not-covered item (T3). Non-goals (second interpreter, effect change, structured cancellation, streaming, cross-sibling comms, per-sibling budget) are "do not build".
- **Type consistency:** `claimSlot :: IORef Int -> IO Bool`, `spawnAll :: (Agents es :> r, Concurrent :> r) => [(SubAgent es i o, i)] -> Eff r [Either AgentFailure o]`. `runAgents`/`runAgentsScripted`/`spawn`/`SubAgent` signatures unchanged. Imports `Effectful.Concurrent (Concurrent, runConcurrent)`, `Effectful.Concurrent.Async (mapConcurrently)` confirmed present in effectful 2.6.1.0.
- **Placeholder scan:** no placeholder code. The flagged judgement points: the import/atomic spike (T1 S4), the concurrent-over-scripted stack with an explicit deterministic `claimSlot` fallback (T1 S6), and the demo worker-row annotation (likely needs `Concurrent` in the row; T2). All call out "report what worked".
- **Risk:** the concurrent-over-scripted test stack is the one uncertain piece; Task 1 has a deterministic fallback so the atomic budget is tested either way, and the live demo proves real parallelism.
