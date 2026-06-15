# Durable Execution — ExecuteChild — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.
> **Spec:** `docs/superpowers/specs/2026-06-15-durable-execution-executechild-design.md`.

**Goal:** `ExecuteChild` — spawn a child workflow, suspend the parent, propagate the child's result back into the parent's journal, resume. Same-type children this cycle (multi-type registry deferred).

**Architecture:** Mirrors the AwaitSignal/DurableSleep suspend pattern + a child lifecycle: interpreter throws `Suspended (WaitChild k ctype cinput)`; worker creates a linked child execution + parks the parent; on child completion `completeExecutionWith` appends the child's output into the parent's journal under the await key + readies the parent.

**Build/test:** `nix develop . --command timeout -s KILL 300 zinc build` / `... -s KILL 600 zinc test` (137 → retry once).
**Reference (READ):** `src/Crucible/Workflow.hs` (Workflow GADT, WaitSpec, runWorkflow's AwaitSignal/DurableSleep branches, nextKey/liveRef); `crucible-manifest/src/Crucible/Manifest/Journal.hs` (ExecutionRowT, createExecution, completeExecution, suspendSignal/deliverSignal, b64/unb64, withTransaction, execDb); `crucible-worker/src/Crucible/Worker.hs` (runOnce's Suspended cases, RunResult, WorkflowDef, drainOnce).

---

### Task 1: crucible — `ExecuteChild` effect + interpreter

**Files:** `src/Crucible/Workflow.hs`, `test/Spec.hs`.

- [ ] **Step 1:** Add to the `Workflow` GADT `ExecuteChild :: Text -> ByteString -> Workflow m ByteString`; add `executeChild :: (Workflow :> es) => Text -> ByteString -> Eff es ByteString` (`= \t i -> send (ExecuteChild t i)`). Export both. Add `WaitSpec` ctor `WaitChild CassetteKey Text ByteString` (key, childType, childInput).
- [ ] **Step 2:** interpreter branch (mirror AwaitSignal):
```haskell
    ExecuteChild ctype cinput -> do
      k <- nextKey "child"
      live <- liftIO (readIORef liveRef)
      case lookupEntry k live of
        Just e  -> pure (eResult e)                       -- child result (raw bytes)
        Nothing -> throwError (Suspended (WaitChild k ctype cinput))
```
- [ ] **Step 3:** tests (in-memory): `executeChild "calc" "child"` on empty journal → `Left (Suspended (WaitChild (mkKey "child" ["0"]) "calc" "child"))`; with an entry under `mkKey "child" ["0"]` = `"child-result"` → returns `"child-result"`. (Same discharge as the AwaitSignal tests.)
- [ ] **Step 4:** build + test → ALL PASS. **Step 5:** commit (`feat(workflow): ExecuteChild effect + WaitChild` + trailer).

---

### Task 2: crucible-manifest — parent link + child lifecycle ops

**Files:** `crucible-manifest/src/Crucible/Manifest/Journal.hs`, `crucible-manifest/test/Spec.hs`.

- [ ] **Step 1: schema.** Add `exParentExec :: Field f (Maybe Int)` and `exParentKey :: Field f (Maybe Text)` to `ExecutionRowT` (columns `ex_parent_exec`, `ex_parent_key`). Update `createExecution`'s `ExecutionRow` construction to pass `Nothing Nothing`.
- [ ] **Step 2: ops** (export all):
```haskell
-- create a child execution linked to its parent; return the child exec id.
createChildExecution :: Pool -> JournalIdentity -> Int -> CassetteKey -> IO Int
createChildExecution pool ident parentEid (CassetteKey pkey) = withSession pool $ withTransaction $ do
  ex <- add (ExecutionRow 0 (jiWorkflowType ident) (b64 (jiInput ident)) (jiAppVersion ident) (jiCapturedAt ident) "running" (Just parentEid) (Just (b64 pkey)))
  let eid = exId ex
  _ <- add (RunQueueRow eid "ready" Nothing Nothing Nothing Nothing Nothing)   -- match RunQueueRow arity (wait fields Nothing)
  pure eid

-- park the parent waiting on a child.
suspendChild :: Pool -> Int -> CassetteKey -> IO ()
suspendChild pool eid (CassetteKey k) = withSession pool $ do
  _ <- execDb "UPDATE run_queue SET state='waiting', rq_wait_key=$1, rq_wait_kind='child', claimant=NULL WHERE rq_exec=$2" [encode (b64 k), encode eid]
  pure ()

-- read an execution's stored input bytes.
executionInput :: Pool -> Int -> IO ByteString
executionInput pool eid = withSession pool $ do
  exs <- selectWhere [#exId ==. eid] :: Db [ExecutionRow]
  pure (case exs of (e:_) -> unb64 (exInput e); [] -> "")

-- complete an execution with its output bytes; if it has a parent, append the output
-- into the parent's journal under the parent_key (op "child", status "result") + ready the parent.
completeExecutionWith :: Pool -> Int -> ByteString -> IO ()
completeExecutionWith pool eid out = withSession pool $ withTransaction $ do
  exs <- selectWhere [#exId ==. eid] :: Db [ExecutionRow]
  _ <- execDb "UPDATE workflow_execution SET ex_status='completed' WHERE ex_id=$1" [encode eid]
  _ <- execDb "UPDATE run_queue SET state='done' WHERE rq_exec=$1" [encode eid]
  case exs of
    (e:_) | Just pexec <- exParentExec e, Just pkeyB64 <- exParentKey e -> do
      pes <- selectWhere [#jeExec ==. pexec] :: Db [JournalEntryRow]
      _ <- add (JournalEntryRow 0 pexec (length pes) pkeyB64 "child" (b64 out) "result" "")
      _ <- execDb "UPDATE run_queue SET state='ready', rq_wait_key=NULL, rq_wait_kind=NULL WHERE rq_exec=$1" [encode pexec]
      pure ()
    _ -> pure ()
```
VERIFY the exact `ExecutionRow`/`RunQueueRow`/`JournalEntryRow` constructor arities against the current module (ExecutionRow now 8 fields with the 2 new ones; RunQueueRow 8 fields incl. rq_wait_name; JournalEntryRow 8 fields incl. status/kind) and the camelToSnake column names (`ex_parent_exec`, `ex_parent_key`, `ex_status`, `ex_id`). Keep the existing `completeExecution` for back-compat (or make it `completeExecutionWith pool eid ""`).
- [ ] **Step 3:** ephemeral-pg tests: `executionInput` round-trips; `createChildExecution` creates a ready child whose ExecutionRow has parent_exec/parent_key set; `completeExecutionWith` on a linked child appends the output to the parent's journal (jsLoad the parent → entry under the await key decodes to the output) + parent becomes ready; on an UNLINKED exec it just completes (no parent append). Assert.
- [ ] **Step 4:** build + test → ALL PASS. **Step 5:** commit (`feat(crucible-manifest): child execution link + completeExecutionWith propagation` + trailer).

---

### Task 3: crucible-worker — WaitChild handling + wdEncodeOutput + acceptance test

**Files:** `crucible-worker/src/Crucible/Worker.hs`, `crucible-worker/test/Spec.hs`.

- [ ] **Step 1:** `WorkflowDef` gains `wdEncodeOutput :: o -> ByteString`. Update existing `WorkflowDef` constructions in the worker tests to add it (for `ByteString` outputs, `id`; for typed, the appropriate encoder). `runOnce`'s success branch: replace `completeExecution pool eid` with `completeExecutionWith pool eid (wdEncodeOutput def o)`. Import `completeExecutionWith`, `createChildExecution`, `suspendChild` from `Crucible.Manifest.Journal`.
- [ ] **Step 2:** handle the child suspend in `runOnce`:
```haskell
        Left (Suspended (WaitChild k ctype cinput)) -> do
          let childIdent = JournalIdentity ctype cinput appVer capAt   -- appVer: read parent's or use env; capAt: env's weNow
          _ <- createChildExecution pool childIdent eid k
          suspendChild pool eid k
          pure (Just (SuspendedRun (WaitChild k ctype cinput)))
```
(Get `appVer`/`capAt`: simplest — `capAt <- weNow env`; `appVer` = a constant like "v1" or read the parent's via a helper. Keep it simple; document.)
- [ ] **Step 3:** acceptance test (ephemeral pg): a single `WorkflowDef ByteString ByteString` (`wdEncodeOutput = id`) whose program branches on input:
```haskell
prog inp _j store = case inp of
  "parent" -> do r <- executeChild "calc" "child"; pure ("got:" <> r)
  _        -> pure "child-result"
```
`loadInput eid = executionInput pool eid` (each exec runs with its own stored input). Drive:
  1. migrate; `eid <- createExecution pool (JournalIdentity "calc" "parent" "v1" t0)`.
  2. `runOnce` (parent) → `SuspendedRun (WaitChild _ "calc" "child")`; a child execution now exists and is ready (assert `listReadyExecutions` has a new id, not the parent); parent status running.
  3. `runOnce` (child) → `Completed "child-result"`; this propagates into the parent (parent becomes ready).
  4. `runOnce` (parent resume) → `Completed "got:child-result"`; parent status completed.
  (You can drive steps 2-4 with three `runOnce` calls or `drainOnce`; assert the final parent output is `"got:child-result"` and the parent completed.) `exitFailure` on failure.
- [ ] **Step 4:** build + test → ALL PASS (hermetic + manifest + worker incl. new ExecuteChild test + existing). **Step 5:** commit (`feat(crucible-worker): ExecuteChild — child spawn + result propagation + acceptance test` + trailer).

---

## Self-Review
- **Spec coverage:** Task 1 = ExecuteChild effect/interpreter + WaitChild. Task 2 = parent-link columns + createChildExecution/suspendChild/completeExecutionWith/executionInput (the propagation crux, transactional). Task 3 = worker WaitChild handling + wdEncodeOutput + the same-type parent→child acceptance test.
- **Type consistency:** `WaitChild CassetteKey Text ByteString` threaded interpreter→worker→store; `completeExecutionWith` propagates under the stored parent_key (same b64 round-trip as timer/signal); `wdEncodeOutput` supplies the child's output bytes.
- **Propagation atomicity:** child-complete + parent-append + parent-ready in one `withTransaction`.
- **Scope:** same-type children (program branches on input); multi-type registry deferred (noted). `loadInput = executionInput` so each exec runs its own input.
- **Back-compat:** existing `completeExecution` kept; `runOnce` moves to `completeExecutionWith`; existing WorkflowDefs gain `wdEncodeOutput` (mechanical).
- **Placeholder scan:** none; all ops mirror shipped createExecution/suspendSignal/deliverSignal.
