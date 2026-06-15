# Durable Execution — Intent/Result Exactly-Once — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.
> **Spec:** `docs/superpowers/specs/2026-06-15-durable-execution-exactly-once-design.md`.

**Goal:** Intent-then-result + deterministic idempotency keys + crashed-mid-flight observability: keyable activities become exactly-once; un-keyable are flagged honestly.

**Architecture:** Re-add `jsIntent` to `JournalStore`; add `recordActivity` (intent → side-effect-with-idem-key → result) + `ActivityKind`/`IdemKey` in `Crucible.Journal`. The manifest store gains `je_status`/`je_kind` columns + `pendingIntents`; `jsLoad` still builds from result rows only. The worker surfaces unkeyable pending intents.

**Build/test:** `nix develop . --command timeout -s KILL 300 zinc build` / `... -s KILL 600 zinc test` (137 → retry once).
**Reference (READ):** `src/Crucible/Journal.hs` (JournalStore/recordTo/newInMemoryJournalStore/jsLoad), `crucible-manifest/src/Crucible/Manifest/Journal.hs` (JournalEntryRow, jsAppend, jsLoad, b64), `crucible-worker/src/Crucible/Worker.hs` (runOnce).

---

### Task 1: crucible — `ActivityKind`/`IdemKey`, `jsIntent`, `recordActivity`

**Files:** `src/Crucible/Journal.hs`, `test/Spec.hs`.

- [ ] **Step 1: types + handle field.** Export `ActivityKind (..)`, `IdemKey (..)`, `recordActivity`; add `jsIntent` back to `JournalStore`.
```haskell
data ActivityKind = Idempotent | Keyable | Unkeyable deriving (Eq, Show)
newtype IdemKey = IdemKey ByteString deriving (Eq, Show)

data JournalStore = JournalStore
  { jsLoad   :: IO Journal
  , jsAppend :: CassetteKey -> Text -> ByteString -> IO ()
  , jsIntent :: CassetteKey -> Text -> ActivityKind -> IO ()   -- re-added: key, op, kind
  }

recordActivity :: (IOE :> es)
  => JournalStore -> ActivityKind -> CassetteKey -> Text
  -> (a -> ByteString) -> (IdemKey -> Eff es a) -> Eff es a
recordActivity s kind k op enc act = do
  liftIO (jsIntent s k op kind)
  a <- act (idemKeyOf k)
  liftIO (jsAppend s k op (enc a))
  pure a
  where idemKeyOf (CassetteKey b) = IdemKey b
```
Update `newInMemoryJournalStore` to track intents in a second `IORef [(CassetteKey, ActivityKind)]`, and add an accessor for tests (e.g. return the store plus an `IO [(CassetteKey, ActivityKind)]` pending-intents query, OR expose `newInMemoryJournalStore' :: Journal -> IO (JournalStore, IO [(CassetteKey, ActivityKind)])`). Keep `newInMemoryJournalStore :: Journal -> IO JournalStore` working (it can ignore intents); add `newInMemoryJournalStore'` for the intent-aware tests. (`recordTo` is unchanged; it doesn't call jsIntent.)

- [ ] **Step 2: tests** (`test/Spec.hs`, in-memory):
  - `recordActivity` with `newInMemoryJournalStore'`: run an action that records the `IdemKey` it receives (into an outer IORef); assert the result is journaled AND the captured `IdemKey == IdemKey <keybytes>`; run a SECOND time (fresh store, same key) → captured idem key is identical (deterministic).
  - pending intents: after `recordActivity` where the action throws/short-circuits BEFORE `jsAppend` (simulate via an action that records intent then we DON'T complete — easier: call `jsIntent` directly then query pending → returns the key+kind; then `jsAppend` the result → pending no longer includes it). Assert `pendingIntents` reflects intent-without-result.

- [ ] **Step 3: build + test → ALL PASS. Step 4: commit** (`feat(journal): ActivityKind/IdemKey + recordActivity (intent/result) + jsIntent` + trailer).

---

### Task 2: crucible-manifest — `je_status`/`je_kind` columns + `pendingIntents`

**Files:** `crucible-manifest/src/Crucible/Manifest/Journal.hs`, `crucible-manifest/test/Spec.hs`.

- [ ] **Step 1: schema.** Add `jeStatus :: Field f Text` and `jeKind :: Field f Text` to `JournalEntryRowT` (column names `je_status`, `je_kind`). Update existing `jsAppend` inserts to set `jeStatus="result"`, `jeKind=""` (or "result"). `migrateJournal` creates the columns on a fresh db.

- [ ] **Step 2: wire `jsIntent` + `pendingIntents` into `journalStoreManifest`.**
```haskell
-- jsIntent: insert a status="intent" row carrying the kind, empty result.
, jsIntent = \(CassetteKey k) op kind -> withSession pool $ do
    es <- selectWhere [#jeExec ==. eid] :: Db [JournalEntryRow]
    _  <- add (JournalEntryRow 0 eid (length es) (b64 k) op (b64 "") "intent" (kindText kind))
    pure ()
```
`jsLoad` must build the `Journal` from `jeStatus == "result"` rows ONLY (filter intents). Add and export:
```haskell
-- keys with an intent row but no result row, for the same execution.
pendingIntents :: Pool -> Int -> IO [(CassetteKey, ActivityKind)]
pendingIntents pool eid = withSession pool $ do
  rs <- selectWhere [#jeExec ==. eid] :: Db [JournalEntryRow]
  let results = [ jeKey r | r <- rs, jeStatus r == "result" ]
      intents = [ (CassetteKey (unb64 (jeKey r)), kindOf (jeKind r)) | r <- rs, jeStatus r == "intent", jeKey r `notElem` results ]
  pure intents
```
Add `kindText :: ActivityKind -> Text` / `kindOf :: Text -> ActivityKind` (import `ActivityKind(..)`/`IdemKey` from `Crucible.Journal`). Keep `fireDueTimers`'s sleep-entry insert setting `jeStatus="result"`, `jeKind=""` (timers are results).

- [ ] **Step 3: ephemeral-pg tests** (extend `crucible-manifest/test/Spec.hs`): migrate; create exec; `jsIntent` a key (kind Keyable) → `pendingIntents` returns `[(key, Keyable)]`, and `jsLoad` does NOT include it (no result); then `jsAppend` the result → `pendingIntents` empty, `jsLoad` includes it. Assert.

- [ ] **Step 4: build + test → ALL PASS. Step 5: commit** (`feat(crucible-manifest): journal_entry status/kind + pendingIntents` + trailer).

---

### Task 3: crucible-worker — surface unkeyable pending intents + test

**Files:** `crucible-worker/src/Crucible/Worker.hs`, `crucible-worker/test/Spec.hs`.

- [ ] **Step 1: surface pending intents.** Add a helper the worker exposes (and optionally call it in `runOnce` on reclaim to log/collect): `unkeyablePending :: Pool -> Int -> IO [CassetteKey]` = `pendingIntents` filtered to `Unkeyable`. Export it. (A real alert sink is out of scope; exposing the list is the deliverable.) Optionally have `runOnce` collect pending intents and include them in a richer result or just leave the helper for callers/tests — keep `runOnce`'s signature stable; add the helper.

- [ ] **Step 2: test (ephemeral pg)** in `crucible-worker/test/Spec.hs`: build a workflow whose activity uses `recordActivity store Keyable (mkKey "charge" []) "charge" encInt (\idem -> liftIO (writeIORef capturedIdem (Just idem)) >> modifyIORef' counter (+1) >> pure 1)`. Simulate a crash AFTER the side effect but BEFORE the result: easiest faithful simulation — run the program directly against the store but `jsIntent` the activity + run the side effect WITHOUT `jsAppend` (i.e. call the activity's pieces manually, or run `recordActivity` in a variant that throws between act and append). Simplest: call `jsIntent store key Keyable` + run the side effect (counter++), do NOT `jsAppend`. Then assert `pendingIntents pool eid == [(key, Keyable)]` and `unkeyablePending == []` (it's keyable, not unkeyable). Then run the activity again via `recordActivity` → asserts the captured `IdemKey` is the SAME both times (deterministic dedupe key) and now the result is journaled (pending empties). Also a separate `Unkeyable` intent → `unkeyablePending` returns it.
  (Keep the scenario a clear scripted sequence; the point is to prove: intent observability + stable idem key + unkeyable flagging. Use the existing harness.)

- [ ] **Step 3: build + test → ALL PASS** (hermetic + manifest + worker). **Step 4: commit** (`feat(crucible-worker): surface unkeyable pending intents + exactly-once test` + trailer).

---

## Self-Review
- **Spec coverage:** Task 1 = ActivityKind/IdemKey/jsIntent/recordActivity + in-memory intent tracking. Task 2 = manifest je_status/je_kind + pendingIntents + jsLoad-results-only. Task 3 = worker unkeyable-pending surface + the exactly-once/observability test.
- **Type consistency:** `JournalStore` regains `jsIntent :: CassetteKey -> Text -> ActivityKind -> IO ()`; `recordActivity`/`IdemKey`/`pendingIntents`/`unkeyablePending` consistent; `je_status`/`je_kind` columns threaded through jsAppend/jsIntent/jsLoad/fireDueTimers.
- **Key invariant:** intent vs result distinguished by `je_status` (NOT empty-result), so unit-result activities aren't misread as intents — called out.
- **Non-breaking:** `recordTo` and existing callers unchanged (still at-least-once); `recordActivity` is the opt-in exactly-once path. `newInMemoryJournalStore` keeps working; `newInMemoryJournalStore'` adds intent-awareness for tests.
- **Placeholder scan:** none; schema/column adds mirror the shipped Phase-1/2 patterns.
