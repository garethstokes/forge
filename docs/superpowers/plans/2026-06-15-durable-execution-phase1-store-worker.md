# Durable Execution — Phase 1: Durable Store + Worker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.
> **Spec:** `docs/superpowers/specs/2026-06-15-durable-execution-phase1-store-worker-design.md` (approved).

**Goal:** Persist a workflow journal in Postgres and run it under a worker that survives a kill and replay-to-resumes. Three layers: crucible IO journal sink → manifest durable store → `crucible-worker` loop.

**Architecture:** Reuse the shipped patterns — thick handle (`JournalStore`, like `MemoryStore`), HKD entities + `migrateUp` (`crucible-manifest`), the Ledger CAS-claim (now with a lease), the ephemeral-pg test rig, a new workspace member (like `crucible-manifest`). The pure Phase-0 `State Journal` path is untouched.

**Tech Stack:** GHC 9.12.2, effectful, `Crucible.Journal` (Phase 0), manifest rev `62f097c…`, ephemeral Postgres.
**Build/test:** `nix develop . --command timeout -s KILL 300 zinc build` / `... -s KILL 600 zinc test` (137 → retry once).

**Reference (READ):** `src/Crucible/Journal.hs` (Phase 0); `crucible-manifest/src/Crucible/Manifest/Ledger.hs` (Entity/migrate/CAS/execDb); `crucible-manifest/test/Spec.hs` + `Conformance.hs` (withEphemeralDb rig); the worker mirrors `crucible-manifest`'s package layout.

---

### Task 1: crucible — IO journal sink (`JournalStore`) + captured-at

**Files:** `src/Crucible/Journal.hs`, `test/Spec.hs`.

- [ ] **Step 1: add `jiCapturedAt` to `JournalIdentity`.** Add the field (ISO-8601 `Text`); update `identityCodec` (a `"capturedAt"` field) and bump nothing else. This breaks Phase-0 test constructions `JournalIdentity "wf" "" "v1"` → add a 4th arg `"2026-06-15T00:00:00Z"` at each call site in `test/Spec.hs` (grep `JournalIdentity ` to find ~10 sites). Mechanical.
```haskell
data JournalIdentity = JournalIdentity
  { jiWorkflowType :: Text, jiInput :: ByteString, jiAppVersion :: Text, jiCapturedAt :: Text }
  deriving (Eq, Show)
```

- [ ] **Step 2: add the `JournalStore` thick handle + IO primitives.** New section in `Crucible.Journal`; export `JournalStore (..)`, `recordTo`, `replayFrom`, `newInMemoryJournalStore`.
```haskell
import Effectful (IOE, liftIO)
import Data.IORef (IORef, newIORef, readIORef, modifyIORef')

-- thick handle: one IO action per journal op (à la MemoryStore). jsIntent records
-- an activity 'intent' (started) before its side effect, for exactly-once on resume.
data JournalStore = JournalStore
  { jsLoad   :: IO Journal
  , jsAppend :: CassetteKey -> Text -> ByteString -> IO ()   -- key, op, encoded result
  , jsIntent :: CassetteKey -> Text -> IO ()                 -- key, op
  }

-- run an op live and durably append its result.
recordTo :: (IOE :> es) => JournalStore -> CassetteKey -> Text -> (a -> ByteString) -> Eff es a -> Eff es a
recordTo s k op enc act = do
  a <- act
  liftIO (s.jsAppend k op (enc a))
  pure a

-- serve from a pre-loaded journal; on a miss apply the policy. The live
-- fallthrough is run in IO (and, for resume past-head, should itself recordTo).
replayFrom :: (IOE :> es) => Journal -> MissPolicy -> CassetteKey
           -> (ByteString -> Either Text a) -> Eff es a -> Eff es (ReplayOutcome a)
replayFrom j pol k dec live = case lookupEntry k j of
  Just e  -> case dec (eResult e) of
               Right a  -> pure (Replayed a)
               Left _   -> onMiss            -- decode failure handled like a miss per policy
  Nothing -> onMiss
  where onMiss = case pol of
          Fail        -> liftIO (throwIO (userError ("journal miss: " <> show k)))  -- or reuse JournalError via Error
          Signal      -> Diverged (Divergence k) <$> live
          Fallthrough -> Replayed <$> live

-- in-memory store over an IORef Journal (testable; the Phase-3 eval consumer uses it).
newInMemoryJournalStore :: Journal -> IO JournalStore
newInMemoryJournalStore j0 = do
  ref <- newIORef j0
  pure JournalStore
    { jsLoad   = readIORef ref
    , jsAppend = \k op bs -> modifyIORef' ref (insertEntry k bs)   -- op stored in Entry if Entry gains eOp; else ignore op here
    , jsIntent = \_ _ -> pure ()                                   -- in-memory: no separate intent rows
    }
```
NOTE: Phase-0 `Entry` is `{eSeq,eResult}` (no op). Either (a) add `eOp :: Text` to `Entry` (and to `insertEntry`/codec/tests — more churn) OR (b) keep `Entry` as-is and let the *store* track op separately (the Postgres `journal_entry` row has an `op` column; the in-memory store ignores `op`). **Choose (b)** to minimize Phase-0 churn: `jsAppend` takes `op` for the durable store's benefit; the in-memory store ignores it. Keep `replayFrom`/`recordTo` decoupled from op-in-Entry.
For `Fail`, prefer reusing the Phase-0 `Error JournalError` rather than `throwIO userError` — make `replayFrom`'s constraint `(IOE :> es, Error JournalError :> es)` and `throwError (MissError k)` (consistent with `replay`). Adjust the skeleton accordingly.

- [ ] **Step 3: tests** (in-memory store round-trip, in `test/Spec.hs`, IO checks via `runEff`):
```haskell
  , do st <- J.newInMemoryJournalStore (J.emptyJournal ident0)
       v  <- runEff (J.recordTo st (J.mkKey "double" ["3"]) "double" encInt (pure (6 :: Int)))
       j  <- J.jsLoad st
       check "journal store: recordTo persists + returns value"
         (6 :: Int, Just "6") (v, BC.unpack . J.eResult <$> J.lookupEntry (J.mkKey "double" ["3"]) j)
  , do st <- J.newInMemoryJournalStore
          (J.insertEntry (J.mkKey "double" ["3"]) (encInt 6) (J.emptyJournal ident0))
       j  <- J.jsLoad st
       out <- runEff (J.replayFrom j J.Fallthrough (J.mkKey "double" ["3"]) decInt (pure 0))
       check "journal store: replayFrom hit returns Replayed" (J.Replayed (6 :: Int)) out
```
(`ident0` = a `JournalIdentity` with the 4 fields, defined near the journal checks.)

- [ ] **Step 4: build + test** → ALL PASS. **Step 5: commit** (`feat(journal): IO JournalStore sink (recordTo/replayFrom) + captured-at` + trailer).

---

### Task 2: crucible-manifest — durable store (`journalStoreManifest`) + run queue

**Files:** `crucible-manifest/src/Crucible/Manifest/Journal.hs` (new), `crucible-manifest/test/Spec.hs`, maybe `crucible-manifest/zinc.toml` (no new dep expected).

- [ ] **Step 1: entities.** Three HKD entities (mirror `Manifest/Ledger.hs`): plain-column types, `deriving via (Table "…" …T)`. `ByteString` columns store via a base64/`bytea` codec — reuse the approach from `Crucible.Journal.b64Codec`/Memory's bytes handling, or store as `Text` (base64) columns to avoid a bytea `DbType` (simplest: keep all columns Text, base64 the bytes at the mapping boundary). Use `Pk Int` serials for ids; `ExecutionId = Int`.
```haskell
data ExecutionRowT f = ExecutionRow
  { exId :: Field f (Pk Int), exType :: Field f Text, exInput :: Field f Text  -- base64
  , exAppVersion :: Field f Text, exCapturedAt :: Field f Text, exStatus :: Field f Text } deriving Generic
data JournalEntryRowT f = JournalEntryRow
  { jeId :: Field f (Pk Int), jeExec :: Field f Int, jeSeq :: Field f Int
  , jeKey :: Field f Text     -- base64 cassette key
  , jeOp :: Field f Text, jeResult :: Field f Text  -- base64 result
  } deriving Generic
data RunQueueRowT f = RunQueueRow
  { rqExec :: Field f (Pk Int), rqState :: Field f Text
  , rqClaimant :: Field f (Maybe Text), rqLeaseUntil :: Field f (Maybe Text) } deriving Generic
-- + `type X = XT Identity` + `deriving via (Table "workflow_execution"/"journal_entry"/"run_queue" …) instance Entity X`
```
`migrateExecutions :: Pool -> IO ()` = `withSession pool (migrateUp [managed (Proxy @ExecutionRow), managed (Proxy @JournalEntryRow), managed (Proxy @RunQueueRow)])`.

- [ ] **Step 2: execution lifecycle + store handle.**
```haskell
-- create an execution (+ its ready run_queue row); returns the assigned id.
createExecution :: Pool -> JournalIdentity -> IO Int
-- the durable JournalStore for one execution: jsLoad selects journal_entry by exec ordered by seq
-- and rebuilds Journal (decode base64); jsAppend inserts a journal_entry (next seq); jsIntent inserts
-- an intent row (op + null result) — see exactly-once. Transactional append+queue-advance via withTransaction.
journalStoreManifest :: Pool -> Int -> IO JournalStore
```
Mapping: base64 the `CassetteKey`/`jiInput`/`eResult` bytes (`Data.ByteString.Base64`) to the Text columns; decode on load. `jsLoad` reconstructs `Journal jIdentity [(key,Entry seq result)]` from the execution row + ordered entry rows.

- [ ] **Step 3: claim-with-lease (reuse Ledger CAS).**
```haskell
-- claim a ready (or lease-expired) execution; returns its id if claimed.
claimExecution :: Pool -> Text -> Text -> IO (Maybe Int)   -- claimant, leaseUntil
claimExecution pool who lease = withSession pool $ do
  rows <- execDb "UPDATE run_queue SET state='claimed', claimant=$1, lease_until=$2 \
                 \WHERE state='ready' RETURNING exec /* limit 1 semantics */" [encode who, encode lease]
  ... pure (first id or Nothing)   -- adapt: claim one; lease-expiry reclaim = (state='claimed' AND lease_until < now) too
heartbeat :: Pool -> Int -> Text -> IO ()                 -- extend lease_until
completeExecution :: Pool -> Int -> IO ()                 -- status='completed', run_queue state='done'
listReadyExecutions :: Pool -> IO [Int]                   -- for polling/tests
```
(Reuse the exact `execDb`/`RETURNING`/non-empty pattern from `ledgerStoreManifest.doClaim`. For "lease expired" reclaim, the WHERE adds `OR (state='claimed' AND lease_until < $now)`; pass a comparison string. Keep Phase-1 simple: claim `state='ready'`; add the expired-lease clause and a `releaseExpired`/reclaim test.)

- [ ] **Step 4: ephemeral-pg tests** (extend `crucible-manifest/test/Spec.hs`): append→load round-trips ordered entries; `createExecution`→`claimExecution` returns id, second claim returns Nothing (CAS); heartbeat extends lease; an expired lease is reclaimable; `completeExecution` drops from ready. Assert observable values.

- [ ] **Step 5: build + test** → ALL PASS. **Step 6: commit** (`feat(crucible-manifest): durable journal store + run_queue (claim-with-lease)` + trailer).

---

### Task 3: crucible-worker — the engine + crash/resume test

**Files:** `crucible-worker/zinc.toml` (new member), `crucible-worker/src/Crucible/Worker.hs` (new), `crucible-worker/test/Spec.hs` (new); root `zinc.toml` (`members += "crucible-worker"`); `flake.nix` already has Postgres.

- [ ] **Step 1: package skeleton.** `crucible-worker/zinc.toml` mirrors `crucible-manifest/zinc.toml` (lib + ephemeral-pg test stanza with `-lpq`/`-threaded`; deps: base, text, bytestring, crucible, crucible-manifest, manifest, manifest-core, effectful, effectful-core, aeson; `crucible = {path=".."}`). Root `zinc.toml` `members = [".", "crucible-manifest", "crucible-worker"]`. Build a placeholder module first to prove resolution (it depends on crucible-manifest, a sibling member — confirm zinc resolves member→member path deps; if `crucible-manifest = {path="../crucible-manifest"}` is needed, add it).

- [ ] **Step 2: the worker.**
```haskell
-- a workflow definition the worker can run (Phase 1: one example type).
data WorkflowDef i o = WorkflowDef
  { wdType :: Text
  , wdProgram :: i -> Journal -> Eff '[Error JournalError, IOE] o   -- replay-to-resume program over a loaded journal
  }

-- claim one ready execution and run it to completion under replay-to-resume; returns
-- the execution id run, or Nothing if the queue was empty.
runOnce :: Pool -> Text -> WorkflowDef i o -> (Int -> IO i) -> IO (Maybe Int)
runOnce pool who def loadInput = do
  mid <- claimExecution pool who leaseStr
  case mid of
    Nothing  -> pure Nothing
    Just eid -> do
      store <- journalStoreManifest pool eid
      j     <- store.jsLoad
      i     <- loadInput eid
      _ <- runEff (runErrorNoCallStack (wdProgram def i j))   -- program uses replayFrom/recordTo against `store`
      completeExecution pool eid
      pure (Just eid)
```
The example program records two activities through `store` (recordTo) keyed by op; on replay it `replayFrom`s them (Fallthrough) and runs only the past-head tail live. (Pass `store` into the program via closure or an extra arg — simplest: `wdProgram :: i -> JournalStore -> Journal -> Eff ... o` so it can both replay the loaded `j` and record live via `store`.)

- [ ] **Step 3: crash/resume test (THE ACCEPTANCE)** in `crucible-worker/test/Spec.hs`, ephemeral pg:
  1. migrate; create an execution for a 3-activity workflow.
  2. **partial run:** run the program directly against the store but stop after activity 2 (simulate a crash by NOT calling `completeExecution` and dropping the runtime). Use a side-effect counter (an `IORef Int` incremented inside each activity's live action) to observe re-execution.
  3. **resume:** a fresh worker `claimExecution` (the row is still claimable — make the first run leave it `ready`/expired, or directly re-load) → `journalStoreManifest` → `jsLoad` (sees activities 1-2) → run the FULL program in replay-to-resume: assert activities 1-2 are **replayed** (the side-effect counter does NOT increment for them) and activity 3 runs live (counter increments once) → completes.
  4. assert: final output correct; counter shows exactly 1 (only activity 3 ran live on resume) + the 2 from the partial run = 3 total live executions across both runs, none re-run.
  Keep it a clear scripted scenario with the IORef counter as the "did the side effect re-run?" oracle.

- [ ] **Step 4: build + test** → ALL PASS (hermetic + all ephemeral-pg suites incl. the worker crash/resume). **Step 5: commit** (`feat(crucible-worker): claim/run/resume engine + crash-recovery test` + trailer).

---

## Self-Review
- **Spec coverage:** Task 1 = Layer A (IO JournalStore, recordTo/replayFrom, in-memory store, jiCapturedAt). Task 2 = Layer B (3 tables, journalStoreManifest, claim-with-lease, transactional append; intent rows DEFERRED — not built). Task 3 = Layer C (crucible-worker package, loop, crash/resume acceptance test).
- **Decisions honoured:** crucible-worker new member (Q5); IO sink + captured-at (bead). Pure Phase-0 path untouched. **Intent/result + activity-kind + idempotency keys (Q1) are DEFERRED to a follow-on slice — NOT built in Phase 1.** Phase 1 ships only *basic durable resume*: committed activities replay; the uncommitted tail is at-least-once on resume.
- **Risk handling:** Entry-op decision = (b) store-tracks-op (minimize Phase-0 churn); base64 Text columns (no bytea DbType); member→member path dep validated in Task 3 Step 1; simulated crash via IORef counter oracle.
- **Placeholder scan:** the skeletons mark where the implementer fills exact manifest API calls (claim SQL, withTransaction) — all reference shipped equivalents (`ledgerStoreManifest`), not invented APIs.
