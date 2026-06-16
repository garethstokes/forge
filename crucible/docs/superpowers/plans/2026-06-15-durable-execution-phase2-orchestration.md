# Durable Execution — Phase 2 (2a + DurableSleep) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.
> **Spec:** `docs/superpowers/specs/2026-06-15-durable-execution-phase2-orchestration-design.md` (approved; scope = 2a + DurableSleep).

**Goal:** A `Crucible.Workflow` effect with journaled-determinism prims (`Now`/`NewId` + a `retryN` combinator) AND the suspend/resume model + `DurableSleep` (durable timers). `AwaitSignal`/`ExecuteChild` are deferred to 2b.

**Architecture:** The `Workflow` interpreter journals each primitive via the Phase 0/1 machinery, keyed by a per-execution **call index** (a `State Int`). `Now`/`NewId` record a value (from an injectable source) and replay it. `DurableSleep` suspends: if its call-index entry is absent it registers a timer wait and `throwError (Suspended …)`; the worker catches that, sets the execution `waiting`; `fireDueTimers` appends the entry + requeues; resume replays to the suspend point and continues. Builds on Phase 1's store + worker.

**Tech Stack:** GHC 9.12.2, effectful (`State.Static.Local`, `Error.Static`), `Crucible.Journal` (Phase 0/1), `Crucible.Manifest.Journal` (Phase 1), ephemeral Postgres.
**Build/test:** `nix develop . --command timeout -s KILL 300 zinc build` / `... -s KILL 600 zinc test` (137 → retry once).

**Reference (READ):** `src/Crucible/Journal.hs` (record/replay/recordTo/replayFrom, mkKey, MissPolicy, ReplayOutcome, JournalError); `crucible-manifest/src/Crucible/Manifest/Journal.hs` (the store + run_queue + claim/complete); `crucible-worker/src/Crucible/Worker.hs` (runOnce); the effect style of `src/Crucible/Ledger.hs` / `src/Crucible/Memory.hs` (GADT effect + `interpret`).

---

### Task 1: crucible — `Crucible.Workflow` effect + journaled-determinism interpreter

**Files:** Create `src/Crucible/Workflow.hs`; `test/Spec.hs`.

- [ ] **Step 1: the effect + supporting types.** New module `Crucible.Workflow`. Export `Workflow (..)`, `now`, `newId`, `durableSleep`, `retryN`, `WaitSpec (..)`, `Suspended (..)`, `WorkflowEnv (..)`, `runWorkflow`.
```haskell
data Workflow :: Effect where
  Now          :: Workflow m Text       -- journaled clock value (ISO-8601 text; keep it Text to avoid a time dep in the effect)
  NewId        :: Workflow m Text       -- journaled unique id
  DurableSleep :: Int -> Workflow m ()  -- seconds; journaled timer (suspends)
type instance DispatchOf Workflow = Dynamic

now :: (Workflow :> es) => Eff es Text
now = send Now
newId :: (Workflow :> es) => Eff es Text
newId = send NewId
durableSleep :: (Workflow :> es) => Int -> Eff es ()
durableSleep = send . DurableSleep

-- what an execution is waiting on (this cycle: only a timer).
data WaitSpec = WaitTimer Text   -- wake-at, ISO-8601
  deriving (Eq, Show)
newtype Suspended = Suspended WaitSpec
  deriving (Eq, Show)

-- injectable non-determinism sources (real IO clock/id in prod; fixed in tests).
data WorkflowEnv = WorkflowEnv
  { weNow   :: IO Text   -- current time as ISO-8601
  , weNewId :: IO Text   -- a fresh unique id
  }
```

- [ ] **Step 2: the interpreter (journaled, call-indexed, suspend-aware).** It threads a call-index `State Int`, reads/writes the journal via a `JournalStore` (Phase 1), and uses `Error Suspended` + `Error JournalError`. `Now`/`NewId` record-or-replay a value; `DurableSleep` replays its entry or suspends.
```haskell
runWorkflow
  :: (IOE :> es, Error Suspended :> es, Error JournalError :> es)
  => WorkflowEnv -> JournalStore -> Journal -> Eff (Workflow : State Int : es) a -> Eff es a
runWorkflow env store j = reinterpret (evalState (0 :: Int)) $ \_ -> \case
  Now -> journaledValue "now" (liftIO env.weNow)
  NewId -> journaledValue "newId" (liftIO env.weNewId)
  DurableSleep secs -> do
    k <- nextKey "sleep"
    case lookupEntry k j of
      Just _  -> pure ()                                   -- timer fired (resumed) → continue
      Nothing -> do                                        -- first encounter → register + suspend
        t <- liftIO env.weNow
        throwError (Suspended (WaitTimer (addSeconds secs t)))
  where
    -- next call-index key for an op name
    nextKey op = do n <- get; put (n + 1); pure (mkKey op [BC.pack (show n)])
    -- replay a recorded value, or run the source + record it.
    journaledValue op mk = do
      k <- nextKey op
      case lookupEntry k j of
        Just e  -> pure (TE.decodeUtf8 (eResult e))        -- recorded value (Text payload)
        Nothing -> do v <- mk; liftIO (store `jsAppend'` (k, op, TE.encodeUtf8 v)); pure v
    -- (jsAppend' = uncurry the JournalStore field; use plain accessors — Crucible.Journal has no OverloadedRecordDot)
```
NOTES for the implementer:
- `addSeconds :: Int -> Text -> Text` — parse the ISO-8601 string, add seconds, re-format. Use `Data.Time` (`parseTimeM`/`formatTime`/`addUTCTime`) — add `time` to crucible's lib deps if not present (it likely is via transitive; verify in `zinc.toml`). Keep it simple and total (a parse failure → just return the input or `t`); document.
- `lookupEntry` reads the *loaded* `Journal j` (a worker loads once per claim). `Now`/`NewId` ALSO need to see values recorded earlier *in the same run* — since they `jsAppend` to the store but `j` is the snapshot loaded at start, a SECOND `Now` in the same first run would not see the first via `j`. For correctness within a single pass, also thread the new entries: simplest is to re-`jsLoad` is too heavy; instead keep an in-run `IORef Journal` seeded from `j` and updated on each append, and `lookupEntry` against THAT. Implement `runWorkflow` to maintain a live `IORef Journal` (seed = j; on append, `insertEntry` into it AND `jsAppend` to the store), and look up against the live ref. This makes both within-run and across-replay lookups correct. (Adjust the skeleton: replace the pure `j` lookups with `readIORef liveRef`.)
- `retryN` is a plain combinator (not an effect ctor):
```haskell
-- run an action up to n times until it returns Right; returns the last result.
retryN :: Monad m => Int -> m (Either e a) -> m (Either e a)
retryN n act = go (max 1 n)
  where go 1 = act
        go k = act >>= either (const (go (k - 1))) (pure . Right)
```
(No journal coupling: a journaled inner activity hits its recorded success on replay, so retry only re-runs live. Document this.)

- [ ] **Step 3: in-memory tests** (`test/Spec.hs`, via `runEff` + the in-memory `JournalStore` + `runErrorNoCallStack` for both error effects). Use a FIXED `WorkflowEnv` (e.g. `weNow = pure "2026-06-15T00:00:00Z"`, an id counter via an IORef) so values are deterministic. Checks:
  - `Now` records then replays the SAME value across two runs against the same journal (journaled determinism): run a program `now` against an empty in-memory store (records "…00Z"); then run `now` again against the now-populated journal → returns the same recorded value even if `weNow` changed.
  - `NewId` similar (second program run replays the first id).
  - two `Now`s in one run get distinct call-index keys and both are recorded.
  - `retryN 3 (…)` returns `Right` after a failing-then-succeeding action; returns the last `Left` if all fail.
  - `DurableSleep` on first encounter (empty journal) throws `Suspended (WaitTimer …)` (assert `Left (Suspended …)`); with a `sleep`-keyed entry present, returns `()` and continues.

- [ ] **Step 4: build + test → ALL PASS. Step 5: commit** (`feat(workflow): Crucible.Workflow effect — journaled now/newId/durableSleep + suspend` + trailer).

---

### Task 2: crucible-manifest — run_queue wait fields + timer driver

**Files:** `crucible-manifest/src/Crucible/Manifest/Journal.hs`, `crucible-manifest/test/Spec.hs`.

- [ ] **Step 1: extend `RunQueueRow` with wait fields.** Add nullable columns: `rqWaitKey :: Field f (Maybe Text)` (base64 cassette key), `rqWaitKind :: Field f (Maybe Text)`, `rqWakeAt :: Field f (Maybe Text)`. (Existing rows/migrations: `migrateJournal` will create the new columns on a fresh ephemeral db; no data migration needed.) Update `createExecution`'s `RunQueueRow` construction to pass `Nothing` for the three new fields.

- [ ] **Step 2: suspend + timer-driver store ops.** Add and export:
```haskell
-- park an execution as waiting-on-timer: state='waiting', store the wait key + wake_at.
suspendTimer :: Pool -> Int -> CassetteKey -> Text -> IO ()   -- exec, sleep key, wakeAt
suspendTimer pool eid (CassetteKey k) wakeAt = withSession pool $
  -- UPDATE run_queue SET state='waiting', rq_wait_key=$, rq_wait_kind='timer', rq_wake_at=$, claimant=NULL WHERE rq_exec=$
  ...

-- fire all due timers: for each waiting timer with wake_at <= now, append the sleep entry
-- under its wait key and set the execution ready (clearing the wait). Returns the fired exec ids.
fireDueTimers :: Pool -> Text -> IO [Int]   -- now
fireDueTimers pool nowT = withSession pool $ withTransaction $ do
  due <- selectWhere [#rqState ==. "waiting"] :: Db [RunQueueRow]   -- then filter wake_at <= now in Haskell (lexical ISO compare)
  forM (filter (\r -> maybe False (<= nowT) (rqWakeAt r) && rqWaitKind r == Just "timer") due) $ \r -> do
    let eid = rqExec r
        key = maybe "" id (rqWaitKey r)   -- base64'd sleep key
    es <- selectWhere [#jeExec ==. eid] :: Db [JournalEntryRow]
    _  <- add (JournalEntryRow 0 eid (length es) key "sleep" (b64 ""))   -- unit result for the timer
    _  <- /* UPDATE run_queue SET state='ready', rq_wait_key=NULL, rq_wait_kind=NULL, rq_wake_at=NULL WHERE rq_exec=eid */
    pure eid
```
(Use `execDb` UPDATEs where the Assign/`=.` API is awkward, as Ledger/Phase-1 did. Column names = camelToSnake: `rq_wait_key`, `rq_wait_kind`, `rq_wake_at`, `rq_state`, `rq_exec`. The sleep entry's key must be the SAME base64 key the Workflow interpreter used — note: the interpreter built `mkKey "sleep" [show n]`; suspendTimer stores `b64` of that key's bytes; `fireDueTimers` writes a journal_entry with `jeKey = that same b64`. So on resume, `jsLoad` rebuilds the entry under the right `CassetteKey` and `lookupEntry (mkKey "sleep" [show n])` hits. VERIFY this key round-trips: suspendTimer receives the `CassetteKey` from the worker (the interpreter's thrown wait must carry the key — see Task 3) and b64s its bytes.)

CORRECTION on the wait key plumbing: `Suspended (WaitTimer wakeAt)` as defined in Task 1 does NOT carry the cassette key. The worker needs the key to store in run_queue so `fireDueTimers` can append under it. So **extend `WaitTimer` to carry the key**: `WaitTimer CassetteKey Text` (key + wakeAt). Update Task 1's `DurableSleep` to `throwError (Suspended (WaitTimer k (addSeconds secs t)))` where `k` is the sleep call-index key. (Adjust Task 1 accordingly — the key is already computed there as `k`.)

- [ ] **Step 3: ephemeral-pg tests** (extend `crucible-manifest/test/Spec.hs`): migrate; create exec; `suspendTimer` it (assert run_queue state='waiting', wake_at set, not in `listReadyExecutions`); `fireDueTimers` with `now < wakeAt` fires nothing (still waiting); `fireDueTimers` with `now >= wakeAt` returns the exec id, the exec is ready again, and a `sleep` journal_entry now exists under the stored key (load the journal, assert an entry with op "sleep").

- [ ] **Step 4: build + test → ALL PASS. Step 5: commit** (`feat(crucible-manifest): run_queue wait fields + fireDueTimers (durable timers)` + trailer).

---

### Task 3: crucible-worker — suspend-aware runOnce + DurableSleep crash/resume test

**Files:** `crucible-worker/src/Crucible/Worker.hs`, `crucible-worker/test/Spec.hs`.

- [ ] **Step 1: suspend-aware `runOnce`.** Add `Error Suspended` to the run stack. After running the program: on `Left (Suspended (WaitTimer key wakeAt))` → `suspendTimer pool eid key wakeAt` (park it; NOT completed). On the inner `Left JournalError` → leave claimed (Phase-1 behaviour). On `Right` → `completeExecution`. The `WorkflowDef`'s program now runs under `runWorkflow env store j` (the Workflow interpreter) in addition to the journal errors. Thread a `WorkflowEnv` into `runOnce` (real clock/id in prod; fixed in test). Return type: extend to surface suspension distinctly, e.g. `data RunResult o = Completed o | SuspendedRun WaitSpec | Errored JournalError`; `runOnce :: … -> IO (Maybe RunResult ...)`. Update the Phase-1 tests' call sites (they expect `Completed`/`Just (Right _)` → adapt to the new constructor).
  - Concretely the run is `runEff (runErrorNoCallStack @Suspended (runErrorNoCallStack @JournalError (runWorkflow env store j (wdProgram def i j store))))` (confirm nesting/order so you can distinguish the two Lefts; adjust `wdProgram`'s type to include the `Workflow` effect in its row).
  - `wdProgram :: i -> Journal -> JournalStore -> Eff '[Workflow, State Int, Error JournalError, Error Suspended, IOE] o` (or whatever order `runWorkflow` + the two `runError`s + `runEff` discharge cleanly — get it compiling, keep the program able to call `now`/`durableSleep` AND `recordTo`/`replayFrom`).

- [ ] **Step 2: the DurableSleep suspend/resume test (THE ACCEPTANCE)** in `crucible-worker/test/Spec.hs`, ephemeral pg. Use a fixed `WorkflowEnv` (`weNow = pure "2026-06-15T00:00:00Z"` for run 1; you may vary it). An `IORef Int` activity counter as the "did it run live?" oracle. Workflow program: `do { t <- now; durableSleep 10; <activity that bumps counter via recordTo>; pure () }`.
  1. migrate (`migrateJournal`); `createExecution`.
  2. **first `runOnce`:** records `now`, hits `durableSleep` (no entry) → throws `Suspended (WaitTimer key "…10s later")` → worker parks it. Assert: result is `SuspendedRun`; `executionStatus` is still `running` (NOT completed); run_queue state `waiting`; the activity counter is still 0 (the post-sleep activity did NOT run).
  3. `fireDueTimers pool "2026-06-15T01:00:00Z"` (well past wake) → returns the exec id; it's ready again.
  4. **second `runOnce`:** replays `now` (hit — same value), `durableSleep` (now hits the fired sleep entry → returns ()), runs the activity live (counter → 1), completes. Assert: result `Completed`; counter == 1; `executionStatus` completed; the `now` value equals run-1's recorded value (journaled determinism across the suspend).
  `exitFailure` on any failed check.

- [ ] **Step 3: build + test → ALL PASS** (hermetic + manifest + worker incl. the new suspend/resume timer test + the existing Phase-1 tests adapted). **Step 4: commit** (`feat(crucible-worker): suspend-aware runOnce + DurableSleep timer resume test` + trailer).

---

## Self-Review
- **Spec coverage (2a + DurableSleep):** Task 1 = the Workflow effect + Now/NewId/retryN (journaled determinism, call-indexed) + the suspend throw for DurableSleep. Task 2 = the durable-timer store surface (run_queue wait fields + suspendTimer/fireDueTimers). Task 3 = suspend-aware worker + the timer suspend/resume acceptance test. AwaitSignal/ExecuteChild correctly deferred to 2b.
- **Type consistency:** `WaitTimer CassetteKey Text` (carries the key — corrected in Task 2), `Suspended`, `WorkflowEnv`, `runWorkflow`, `RunResult`; the sleep call-index key is built identically in the interpreter and round-tripped through suspendTimer→fireDueTimers→journal.
- **Key correctness:** the single most important invariant — the `("sleep", n)` CassetteKey the interpreter looks up on resume is the SAME key fireDueTimers appended. Called out in Task 2 with a verify.
- **Risk:** within-run lookups need a live `IORef Journal` (not the start snapshot) — flagged in Task 1. The Phase-1 worker tests need their call sites updated for the new `RunResult` return — flagged in Task 3.
- **Placeholder scan:** skeletons reference shipped equivalents (execDb UPDATEs as in Ledger/Phase 1), not invented APIs.
