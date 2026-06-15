# Durable Execution — AwaitSignal + Real Env + Poll Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.
> **Spec:** `docs/superpowers/specs/2026-06-15-durable-execution-awaitsignal-design.md` (ExecuteChild is out of scope → its own bead).

**Goal:** `AwaitSignal` on the 2a suspend model + a production `WorkflowEnv` + a poll loop.

**Architecture:** `AwaitSignal` mirrors `DurableSleep`: miss → `throwError (Suspended (WaitSignal k name))`; worker parks `waiting`; `deliverSignal` appends the payload entry + readies; resume returns it. Reuses the 2a wait machinery + adds `rq_wait_name`. `realWorkflowEnv` + `drainOnce`/`pollRounds` are the operational bits.

**Build/test:** `nix develop . --command timeout -s KILL 300 zinc build` / `... -s KILL 600 zinc test` (137 → retry once).
**Reference (READ):** `src/Crucible/Workflow.hs` (Workflow GADT, WaitSpec, runWorkflow's DurableSleep branch, WorkflowEnv, addSeconds, the call-index `nextKey`); `crucible-manifest/src/Crucible/Manifest/Journal.hs` (RunQueueRow wait fields, suspendTimer, fireDueTimers, claimExecution, jsAppend); `crucible-worker/src/Crucible/Worker.hs` (runOnce's Suspended handling, RunResult, unkeyablePending).

---

### Task 1: crucible — `AwaitSignal` + `realWorkflowEnv`

**Files:** `src/Crucible/Workflow.hs`, `test/Spec.hs`.

- [ ] **Step 1: effect + WaitSpec.** Add to the `Workflow` GADT `AwaitSignal :: Text -> Workflow m ByteString`; add `awaitSignal :: (Workflow :> es) => Text -> Eff es ByteString` (`= send . AwaitSignal`). Export both. Add a `WaitSpec` ctor: `WaitSignal CassetteKey Text` (key, signal name). Export (already `WaitSpec (..)`).

- [ ] **Step 2: interpreter branch** in `runWorkflow` (mirror `DurableSleep`):
```haskell
    AwaitSignal name -> do
      k <- nextKey "signal"
      live <- liftIO (readIORef liveRef)
      case lookupEntry k live of
        Just e  -> pure (eResult e)                     -- delivered payload (ByteString)
        Nothing -> throwError (Suspended (WaitSignal k name))
```
(`eResult` is the raw ByteString — AwaitSignal returns bytes, no decode. Use plain accessors.)

- [ ] **Step 3: `realWorkflowEnv :: IO WorkflowEnv`.** `weNow` = `getCurrentTime` formatted `"%Y-%m-%dT%H:%M:%SZ"` (via `Data.Time.Format`, same format `addSeconds` parses). `weNewId` = a unique id, e.g. `formatTime` with `%Y%m%d%H%M%S%q` (picoseconds) of `getCurrentTime`, or that plus an `IORef` counter — uniqueness only. Export `realWorkflowEnv`.

- [ ] **Step 4: tests** (`test/Spec.hs`, in-memory): `awaitSignal "go"` on an empty in-memory store → `Left (Suspended (W.WaitSignal <key> "go"))` (key = `mkKey "signal" ["0"]`); seed the store with an entry under `mkKey "signal" ["0"]` = `"payload"` → `awaitSignal "go"` returns `"payload"`. (Run under `runEff` + the two `runErrorNoCallStack`s, as the DurableSleep tests do.)

- [ ] **Step 5: build + test → ALL PASS. Step 6: commit** (`feat(workflow): AwaitSignal + realWorkflowEnv` + trailer).

---

### Task 2: crucible-manifest — `rq_wait_name` + `suspendSignal`/`deliverSignal`

**Files:** `crucible-manifest/src/Crucible/Manifest/Journal.hs`, `crucible-manifest/test/Spec.hs`.

- [ ] **Step 1: schema.** Add `rqWaitName :: Field f (Maybe Text)` to `RunQueueRowT` (column `rq_wait_name`). Update `createExecution`'s `RunQueueRow` (add `Nothing`) and any other `RunQueueRow` construction. (`suspendTimer` sets `rq_wait_name=NULL`.)

- [ ] **Step 2: ops** (mirror suspendTimer/fireDueTimers):
```haskell
-- park waiting-on-signal: state='waiting', wait_kind='signal', wait_key=k, wait_name=name.
suspendSignal :: Pool -> Int -> CassetteKey -> Text -> IO ()
suspendSignal pool eid (CassetteKey k) name = withSession pool $ do
  _ <- execDb "UPDATE run_queue SET state='waiting', rq_wait_key=$1, rq_wait_kind='signal', rq_wait_name=$2, claimant=NULL WHERE rq_exec=$3"
              [encode (b64 k), encode name, encode eid]
  pure ()

-- deliver a signal: if the exec is waiting on this name, append the payload under its wait key + ready it.
-- returns True if delivered.
deliverSignal :: Pool -> Int -> Text -> ByteString -> IO Bool
deliverSignal pool eid name payload = withSession pool $ withTransaction $ do
  rows <- selectWhere [#rqExec ==. eid] :: Db [RunQueueRow]
  case [ r | r <- rows, rqState r == "waiting", rqWaitKind r == Just "signal", rqWaitName r == Just name ] of
    (r:_) -> do
      es <- selectWhere [#jeExec ==. eid] :: Db [JournalEntryRow]
      let keyB64 = maybe "" id (rqWaitKey r)
      _ <- add (JournalEntryRow 0 eid (length es) keyB64 "signal" (b64 payload) "result" "")
      _ <- execDb "UPDATE run_queue SET state='ready', rq_wait_key=NULL, rq_wait_kind=NULL, rq_wait_name=NULL WHERE rq_exec=$1" [encode eid]
      pure True
    [] -> pure False
```
Export `suspendSignal`, `deliverSignal`. Column names via camelToSnake: `rq_wait_name`. (Note the `JournalEntryRow` now has the `je_status`/`je_kind` fields from 8bt — set `"result" ""`.)

- [ ] **Step 3: ephemeral-pg tests** (extend `crucible-manifest/test/Spec.hs`): create exec; `suspendSignal pool eid (CassetteKey "sk") "go"` → waiting, not ready; `deliverSignal pool eid "nope" "x"` → False, still waiting; `deliverSignal pool eid "go" "payload"` → True, ready, and `jsLoad` shows an entry under `CassetteKey "sk"` whose result decodes to "payload".

- [ ] **Step 4: build + test → ALL PASS. Step 5: commit** (`feat(crucible-manifest): rq_wait_name + suspendSignal/deliverSignal` + trailer).

---

### Task 3: crucible-worker — suspend-signal handling + poll loop + tests

**Files:** `crucible-worker/src/Crucible/Worker.hs`, `crucible-worker/test/Spec.hs`.

- [ ] **Step 1: handle the signal suspend in `runOnce`.** Add a case alongside the timer one: on `Left (Suspended (WaitSignal k name))` → `suspendSignal pool eid k name >> pure (Just (SuspendedRun (WaitSignal k name)))`. (Import `suspendSignal` from `Crucible.Manifest.Journal`, `WaitSpec(..)` already imported.)

- [ ] **Step 2: poll loop + observability.**
```haskell
-- run every currently-ready execution to completion/suspension (once through the queue).
drainOnce :: Pool -> Text -> WorkflowEnv -> WorkflowDef i o -> (Int -> IO i) -> IO [RunResult o]
drainOnce pool who env def loadInput = go []
  where go acc = do
          m <- runOnce pool who leaseFor env def loadInput   -- reuse runOnce's lease string scheme
          case m of Nothing -> pure (reverse acc); Just r -> go (r : acc)

-- fire due timers (at `now`) then drain; repeat up to n rounds. Test-friendly driver.
pollRounds :: Pool -> Text -> WorkflowEnv -> Int -> WorkflowDef i o -> (Int -> IO i) -> IO ()
```
(Use the same lease-string construction `runOnce` already uses, or pass a lease. Keep `pollRounds` simple: `replicateM_ n (do { t <- weNow env; _ <- fireDueTimers pool t; _ <- drainOnce …; pure () })`.) On each drain, optionally log `unkeyablePending` for processed execs (the 8bt observability hook) — at minimum expose it; a log line is enough. Export `drainOnce`, `pollRounds`.

- [ ] **Step 3: tests** (ephemeral pg):
  - **signal suspend/resume:** workflow `do { p <- awaitSignal "go"; recordTo store (mkKey "act" []) "act" id (liftIO (modifyIORef' ran (const True)) >> pure p) }`. First `runOnce` → `SuspendedRun (WaitSignal _ "go")`, status running, `ran`=False. `deliverSignal pool eid "go" "hi"` → True. Second `runOnce` → `Completed "hi"` (the awaited payload flowed through), `ran`=True, status completed.
  - **poll loop:** a `durableSleep`-then-activity workflow; `pollRounds pool who env 3 def loadInput` with an env whose `weNow` is well past the wake → the loop fires the timer and drains to completion automatically (assert status completed + activity ran once).
  `exitFailure` on failure.

- [ ] **Step 4: build + test → ALL PASS. Step 5: commit** (`feat(crucible-worker): AwaitSignal suspend + drainOnce/pollRounds poll loop` + trailer).

---

## Self-Review
- **Spec coverage:** Task 1 = AwaitSignal effect/interpreter + realWorkflowEnv. Task 2 = rq_wait_name + suspendSignal/deliverSignal. Task 3 = worker signal-suspend handling + drainOnce/pollRounds + tests. ExecuteChild correctly deferred to a new bead.
- **Type consistency:** `WaitSignal CassetteKey Text` threaded interpreter→worker→store; `deliverSignal` appends under the stored wait key (same b64 round-trip as fireDueTimers); `je_status`/`je_kind` (from 8bt) set on the signal entry.
- **Key round-trip:** the `("signal", n)` key the interpreter looks up == the key suspendSignal stores == the key deliverSignal appends under (same invariant as the timer path).
- **Reuse:** AwaitSignal is the DurableSleep pattern + payload + external delivery; low risk.
- **Placeholder scan:** none; all ops mirror shipped suspendTimer/fireDueTimers.
