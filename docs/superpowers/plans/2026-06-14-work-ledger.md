# Work-Ledger Effect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Crucible.Ledger`: a small work-ledger effect (`record`/`claim`/`complete`/`listReady`) with an in-memory test interpreter and a JSONL file interpreter, mirroring `Crucible.Memory`.

**Architecture:** An event-sourced effect. `Record`/`Claim`/`Complete` append `LedgerEvent`s; `ListReady` folds the log to current `WorkItem`s. `runLedgerState` keeps the log in `State` (returns the final ledger for tests); `runLedgerFile` keeps it in a JSONL file (appended on write, folded on read), so it outlives sessions. `claim` is a compare-and-set: it appends a `Claimed` event only when the item folds to `Ready`.

**Tech Stack:** GHC 9.12.2, effectful (dynamic effects + Static.Local State), autodocodec via the `Crucible.Codec` facade; zinc build.

**Spec:** `docs/superpowers/specs/2026-06-14-work-ledger-design.md`

## Conventions (every task)
- Build/test: `nix develop . --command timeout -s KILL 300 zinc build|test`. Judge success by exit status or "test suite(s) passed", never a pipeline tail. 137 = GHC flake, retry once; second 137 = BLOCKED. Ignore "Git tree is dirty".
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot, `(.field)` access. Effectful dynamic dispatch needs State type annotations like `get @[LedgerEvent]`. Annotate ambiguous getter sections and report.
- Tests: custom harness `check "label" expected actual`; comma entries in `runChecks` at END of `test/Spec.hs`; `do` blocks allowed. No hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit per task; do not push.
- Modules auto-discovered; a new module needs no zinc.toml change.

## Reference: this module mirrors `Crucible.Memory`
Read `src/Crucible/Memory.hs` for the exact patterns being mirrored: the event type + fold-on-read, `readLog`/`appendEntry` (tolerant of blank/garbled lines via `try`), the `runMemoryFile` interpreter (`interpret` + `liftIO`), the `runMemoryPure` interpreter (`reinterpret (runState [...])`), and the tagged `entryCodec` (a `RawEntry` record with `bimapCodec`). `Crucible.Codec` exports `JSONCodec, object, field, optField, enum, str, int, list', bimapCodec, dimapCodec, encodeText`; `Crucible.Decode` exports `decodeLLM`.

## File Structure
- Create `src/Crucible/Ledger.hs` — types, effect, smart ctors, fold, codecs, both interpreters.
- Modify `test/Spec.hs` — in-memory + codec tests (Task 1), file tests (Task 2).
- Modify `app/Main.hs` — demo (Task 3).
- Create `docs/ledger.md` — manual (Task 4).

---

### Task 1: `Crucible.Ledger` types, effect, codecs, `runLedgerState` + tests

**Files:**
- Create: `src/Crucible/Ledger.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Create `src/Crucible/Ledger.hs`**

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
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | A small work ledger in the house style: an append-only log of work items
-- with a compare-and-set claim, so independent workers (or sessions) can pull
-- one item each without colliding. Structurally a sibling of 'Crucible.Memory':
-- events appended on write, folded on read. 'runLedgerState' is the in-memory
-- test interpreter; 'runLedgerFile' is a git-diffable JSONL store that outlives
-- a session. 'claim' succeeds only when the item is still 'Ready'.
module Crucible.Ledger
  ( WorkId (..)
  , WorkState (..)
  , WorkItem (..)
  , Ledger (..)
  , record, claim, complete, listReady
  , runLedgerState
  , runLedgerFile
  , workStateCodec
  , workItemCodec
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (runState, get, put)

import Crucible.Codec (JSONCodec, object, field, optField, enum, str, int, bimapCodec, dimapCodec, encodeText)
import Crucible.Decode (decodeLLM)

newtype WorkId = WorkId Int deriving (Eq, Show)

widInt :: WorkId -> Int
widInt (WorkId i) = i

data WorkState = Ready | Claimed | Done
  deriving (Eq, Show)

data WorkItem = WorkItem
  { wid      :: WorkId
  , payload  :: Text
  , state    :: WorkState
  , claimant :: Maybe Text
  }
  deriving (Eq, Show)

data Ledger :: Effect where
  Record    :: Text -> Ledger m WorkId
  Claim     :: WorkId -> Text -> Ledger m Bool
  Complete  :: WorkId -> Ledger m ()
  ListReady :: Ledger m [WorkItem]
type instance DispatchOf Ledger = Dynamic

record :: (Ledger :> es) => Text -> Eff es WorkId
record = send . Record

claim :: (Ledger :> es) => WorkId -> Text -> Eff es Bool
claim w who = send (Claim w who)

complete :: (Ledger :> es) => WorkId -> Eff es ()
complete = send . Complete

listReady :: (Ledger :> es) => Eff es [WorkItem]
listReady = send ListReady

-- The internal event log.
data LedgerEvent
  = Recorded  WorkId Text
  | Claimed   WorkId Text
  | Completed WorkId
  deriving (Eq, Show)

-- | Fold the event log into the current work items, in record order.
foldItems :: [LedgerEvent] -> [WorkItem]
foldItems evs = map build recorded
  where
    recorded = [(i, p) | Recorded i p <- evs]
    build (i, p) = foldl step (WorkItem i p Ready Nothing) evs
      where
        step it = \case
          Claimed j who | widInt j == widInt i -> it { state = Claimed, claimant = Just who }
          Completed j   | widInt j == widInt i -> it { state = Done }
          _ -> it

-- | The Ready items, in record order.
readyOf :: [LedgerEvent] -> [WorkItem]
readyOf = filter (\it -> it.state == Ready) . foldItems

-- | The current state of one id, if it exists.
stateOf :: WorkId -> [LedgerEvent] -> Maybe WorkState
stateOf w evs = case [it | it <- foldItems evs, widInt it.wid == widInt w] of
  (it : _) -> Just it.state
  []       -> Nothing

-- | In-memory interpreter (tests). Returns the result and the final ledger
-- (every item, record order, any state) for assertions.
runLedgerState :: Eff (Ledger : es) a -> Eff es (a, [WorkItem])
runLedgerState action = do
  (a, evs) <- reinterpret (runState ([] :: [LedgerEvent])) (\_ -> \case
    Record p -> do
      evs <- get @[LedgerEvent]
      let n = length [() | Recorded _ _ <- evs]
      put (evs ++ [Recorded (WorkId n) p])
      pure (WorkId n)
    Claim w who -> do
      evs <- get @[LedgerEvent]
      case stateOf w evs of
        Just Ready -> put (evs ++ [Claimed w who]) >> pure True
        _          -> pure False
    Complete w -> do
      evs <- get @[LedgerEvent]
      put (evs ++ [Completed w])
    ListReady -> readyOf <$> get @[LedgerEvent]) action
  pure (a, foldItems evs)

-- Codecs.

workIdCodec :: JSONCodec WorkId
workIdCodec = dimapCodec WorkId widInt int

workStateCodec :: JSONCodec WorkState
workStateCodec = enum [("ready", Ready), ("claimed", Claimed), ("done", Done)]

workItemCodec :: JSONCodec WorkItem
workItemCodec = object (WorkItem
  <$> field "id"       (.wid)      workIdCodec
  <*> field "payload"  (.payload)  str
  <*> field "state"    (.state)    workStateCodec
  <*> optField "claimant" (.claimant) str)

data RawEvent = RawEvent { event :: Text, rid :: Maybe WorkId, payload :: Maybe Text, by :: Maybe Text }

eventCodec :: JSONCodec LedgerEvent
eventCodec = bimapCodec toE fromE
  (object (RawEvent <$> field "event" (.event) str
                    <*> optField "id"      (.rid)     workIdCodec
                    <*> optField "payload" (.payload) str
                    <*> optField "by"      (.by)      str))
  where
    toE r = case r.event of
      "recorded"  -> maybe (Left "recorded event needs id and payload") Right
                       (Recorded <$> r.rid <*> r.payload)
      "claimed"   -> maybe (Left "claimed event needs id and by") Right
                       (Claimed <$> r.rid <*> r.by)
      "completed" -> maybe (Left "completed event needs an id") (Right . Completed) r.rid
      other       -> Left ("unknown event: " <> T.unpack other)
    fromE (Recorded i p)  = RawEvent "recorded" (Just i) (Just p) Nothing
    fromE (Claimed i who) = RawEvent "claimed" (Just i) Nothing (Just who)
    fromE (Completed i)   = RawEvent "completed" (Just i) Nothing Nothing

-- | Read the event log, tolerant of blank/garbled lines (skipped).
readLog :: FilePath -> IO [LedgerEvent]
readLog path = do
  r <- try (TIO.readFile path) :: IO (Either IOException Text)
  let contents = either (const "") Prelude.id r
  pure [e | ln <- T.lines contents, not (T.null (T.strip ln))
          , Right e <- [decodeLLM eventCodec ln]]

appendEvent :: FilePath -> LedgerEvent -> IO ()
appendEvent path e = TIO.appendFile path (encodeText eventCodec e <> "\n")

-- | A JSONL log at the path: Record/Claim/Complete append one line; ListReady
-- reads and folds. id = count of prior Recorded events. git-diffable, outlives
-- sessions. Single-writer: each Record/Claim does a read-then-append, which is
-- not atomic, so concurrent calls from separate threads or processes can assign
-- duplicate ids or let two claims of one item both observe Ready.
runLedgerFile :: (IOE :> es) => FilePath -> Eff (Ledger : es) a -> Eff es a
runLedgerFile path = interpret $ \_ -> \case
  Record p -> liftIO $ do
    evs <- readLog path
    let n = length [() | Recorded _ _ <- evs]
    appendEvent path (Recorded (WorkId n) p)
    pure (WorkId n)
  Claim w who -> liftIO $ do
    evs <- readLog path
    case stateOf w evs of
      Just Ready -> appendEvent path (Claimed w who) >> pure True
      _          -> pure False
  Complete w -> liftIO (appendEvent path (Completed w))
  ListReady  -> liftIO (readyOf <$> readLog path)
```
Notes:
- `foldItems`/`readyOf`/`stateOf` are shared by both interpreters, so they cannot drift.
- The `step it = \case ...` uses `LambdaCase` (pragma present). Compare ids by `widInt` to avoid relying on `Eq WorkId` inside the guard (either works; `widInt` is explicit).
- State annotations `get @[LedgerEvent]` are required under dynamic dispatch.
- `workStateCodec` is exported for callers serializing a `WorkItem`; the file format uses `eventCodec` (internal), not `workItemCodec`.

- [ ] **Step 2: Add `runLedgerState` + codec tests to `test/Spec.hs`**

Add the import near the other crucible imports:
```haskell
import Crucible.Ledger (WorkId (..), WorkState (..), WorkItem (..), record, claim, complete, listReady, runLedgerState, runLedgerFile, workItemCodec)
```
`runPureEff` is imported; `C` = `Crucible.Codec` (for `C.encodeText`); `decodeLLM` is in `Crucible.Decode` (verify it is imported in Spec.hs; add it to the existing `Crucible.Decode` import if not). `runLedgerState prog` returns `(progResult, finalItems)` and `runPureEff` returns that pair directly. Add to `runChecks`:

```haskell
  , check "ledger: record yields sequential ids"
      ([WorkId 0, WorkId 1])
      (fst (runPureEff (runLedgerState (do a <- record "A"; b <- record "B"; pure [a, b]))))
  , check "ledger: both recorded items are Ready in record order"
      [WorkId 0, WorkId 1]
      (map (.wid) (snd (runPureEff (runLedgerState (do _ <- record "A"; _ <- record "B"; listReady)))))
  , check "ledger: claim a Ready item succeeds and sets claimant"
      (True, Just "worker-1", Claimed)
      (let (ok, final) = runPureEff (runLedgerState (do
                 w <- record "A"
                 ok <- claim w "worker-1"
                 pure ok))
           it = head (filter (\i -> i.wid == WorkId 0) final)
       in (ok, it.claimant, it.state))
  , check "ledger: a second claim of the same item fails"
      (True, False)
      (fst (runPureEff (runLedgerState (do
                 w <- record "A"
                 a <- claim w "worker-1"
                 b <- claim w "worker-2"
                 pure (a, b)))))
  , check "ledger: claiming an unknown id fails"
      False
      (fst (runPureEff (runLedgerState (claim (WorkId 99) "x"))))
  , check "ledger: claimed item drops from listReady"
      []
      (map (.wid) (fst (runPureEff (runLedgerState (do w <- record "A"; _ <- claim w "w1"; listReady)))))
  , check "ledger: complete marks Done and drops from listReady"
      (Done, ([] :: [WorkId]))
      (let (readyIds, final) = runPureEff (runLedgerState (do
                 w <- record "A"
                 complete w
                 rs <- listReady
                 pure (map (.wid) rs)))
           it = head final
       in (it.state, readyIds))
  , check "ledger: workItemCodec round-trips a Ready item"
      (Right (WorkItem (WorkId 3) "do it" Ready Nothing))
      (decodeLLM workItemCodec (C.encodeText workItemCodec (WorkItem (WorkId 3) "do it" Ready Nothing)))
```
Notes:
- `(.wid)`/`(.state)`/`(.claimant)` getter sections may need annotation under DuplicateRecordFields; annotate (e.g. `((.wid) :: WorkItem -> WorkId)`) and report if so.
- `decodeLLM` is from `Crucible.Decode` (already imported in Spec.hs as `decodeLLM`); `C.encodeText` from the Codec facade. If `decodeLLM` is not in scope, add it to the existing `Crucible.Decode` import.

- [ ] **Step 3: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the new ledger checks pass; full suite green. If a `(.field)` section is ambiguous, annotate. If `runPureEff` layering surprises you, remember `runLedgerState` returns `(result, [WorkItem])` and `runPureEff` returns that pair directly. Retry once on 137.

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/Ledger.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(ledger): work-ledger effect + in-memory interpreter

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: file interpreter tests (`runLedgerFile`, outlives sessions)

`runLedgerFile` is already written in Task 1. This task adds the file-backed tests.

**Files:**
- Test: `test/Spec.hs`

- [ ] **Step 1: Add file tests to `test/Spec.hs`**

`openTempFile`/`hClose` (from `System.IO`) and `removeFile` (from `System.Directory`) are already imported for the Memory file tests; `runEff` from `Effectful`. `runLedgerFile` was imported in Task 1. Each `check` entry can be a `do` block returning `IO Bool`. Add:

```haskell
  , do (path, h) <- openTempFile "/tmp" "crucible-ledger-test.jsonl"
       hClose h
       -- session 1: record two items
       _ <- runEff (runLedgerFile path (do _ <- record "A"; _ <- record "B"; pure ()))
       -- session 2 (separate interpreter call, same path): both survive
       ready <- runEff (runLedgerFile path listReady)
       removeFile path
       check "ledger file: recorded items outlive the session" [WorkId 0, WorkId 1] (map (.wid) ready)
  , do (path, h) <- openTempFile "/tmp" "crucible-ledger-claim.jsonl"
       hClose h
       ok <- runEff (runLedgerFile path (do w <- record "A"; claim w "worker-1"))
       -- a later session sees the claim: the item is gone from listReady
       ready <- runEff (runLedgerFile path listReady)
       removeFile path
       check "ledger file: a claim is visible in a later session" (True, ([] :: [WorkId]))
         (ok, map (.wid) ready)
```
Notes:
- The two `runEff (runLedgerFile path ...)` calls model two sessions over one file; the second reads back state the first wrote (the outlives-sessions property).
- If `(.wid)` is ambiguous, annotate.

- [ ] **Step 2: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the two file checks pass; full suite green. Retry once on 137.

- [ ] **Step 3: Commit**

```bash
git add test/Spec.hs
git commit -m "$(cat <<'EOF'
test(ledger): file interpreter outlives sessions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a ledger demo**

Read `app/Main.hs`. Add the import:
```haskell
import Crucible.Ledger (record, claim, complete, listReady, runLedgerFile)
```
Inside the `Just key -> do` block, after an existing demo (e.g. after the spawn/gate demos), add (it needs no API key, but lives here for consistency):
```haskell
      -- Work ledger: record two items, claim and complete one, list the rest.
      let ledgerPath = "/tmp/crucible-ledger-demo.jsonl"
      TIO.writeFile ledgerPath ""  -- fresh ledger
      ledgerRemaining <- runEff (runLedgerFile ledgerPath (do
        a <- record "summarize the inbox"
        _ <- record "draft the reply"
        ok <- claim a "worker-1"
        if ok then complete a else pure ()
        rs <- listReady
        pure (map (\it -> it.payload) rs)))
      TIO.putStrLn ("ledger: remaining ready = " <> T.pack (show ledgerRemaining))
```
Notes:
- `it.payload` getter may need annotation `((.payload) :: WorkItem -> T.Text)`; if so import `WorkItem` and annotate. Try the bare form first.
- `runEff`, `TIO`, `T` are in scope. Expected printed output is `ledger: remaining ready = ["draft the reply"]`.

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. Retry once on 137. (Do not run the binary here.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "$(cat <<'EOF'
demo(ledger): record/claim/complete/listReady over a file ledger

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Manual page `docs/ledger.md`

**Files:**
- Create: `docs/ledger.md`

- [ ] **Step 1: Write the page**

Check nav orders: `grep -rn "nav_order:" docs/*.md`. Use `13` if free; otherwise the next free integer. Match the voice of `docs/memory.md` (matter-of-fact, short sentences). Content (use REAL triple-backtick fences):

```markdown
---
title: Work ledger
nav_order: 13
---

# Work ledger

When more than one agent, or more than one session, works toward a shared goal,
they need one place that answers what is left to do and who is doing it. The
work ledger is that place: an append-only record of work items with a
compare-and-set claim, so each item goes to exactly one worker and progress
survives across sessions.

## The model

```haskell
newtype WorkId = WorkId Int
data WorkState = Ready | Claimed | Done
data WorkItem = WorkItem { wid :: WorkId, payload :: Text, state :: WorkState, claimant :: Maybe Text }
```

An item is `Ready` when it has been recorded and is neither claimed nor
completed. The `payload` is text; structured work data is encoded through a codec
to text, as with a memory's content.

## The effect

```haskell
record    :: (Ledger :> es) => Text -> Eff es WorkId
claim     :: (Ledger :> es) => WorkId -> Text -> Eff es Bool
complete  :: (Ledger :> es) => WorkId -> Eff es ()
listReady :: (Ledger :> es) => Eff es [WorkItem]
```

`record` adds a `Ready` item. `claim wid who` is a compare-and-set: it succeeds
(returns `True`) only when the item is still `Ready`, so two workers cannot take
the same item; an already-claimed, completed, or unknown id returns `False`.
`complete` marks an item `Done`. `listReady` returns the `Ready` items in record
order.

## Interpreters

```haskell
runLedgerState :: Eff (Ledger : es) a -> Eff es (a, [WorkItem])
runLedgerFile  :: (IOE :> es) => FilePath -> Eff (Ledger : es) a -> Eff es a
```

`runLedgerState` keeps the ledger in memory and returns the final items
alongside the result, for tests. `runLedgerFile` keeps a git-diffable JSONL
event log at a path: each operation appends a line, and reads fold the log. It
outlives a session, so a later run on the same path sees earlier work.

Single-writer: the file interpreter reads then appends, which is not atomic
across processes, so true concurrent claim needs a real backend. That is an
interpreter concern; a backend-specific interpreter (for example one backed by
an issue tracker) belongs in an application, not in the library.

The ledger is independent of subagents: any caller can record and claim work,
not just a `spawn` orchestrator.
```
(The outer ```markdown fence delimits this block in the plan only; write real markdown.)

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/ledger.md` (expect no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/ledger.md` (expect no output).
Confirm the `nav_order` does not collide.

- [ ] **Step 3: Commit**

```bash
git add docs/ledger.md
git commit -m "$(cat <<'EOF'
docs(ledger): work-ledger manual page

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** `WorkId`/`WorkState`/`WorkItem` (T1), `Ledger` + four ops (T1), `runLedgerState` (T1) and `runLedgerFile` (T1 code, T2 tests), event codec + `workItemCodec`/`workStateCodec` (T1), demo (T3), `docs/ledger.md` (T4). All spec Design/Testing items map to a task. Non-goals are "do not build".
- **Type consistency:** `WorkItem {wid, payload, state, claimant}`, `record :: Text -> Eff es WorkId`, `claim :: WorkId -> Text -> Eff es Bool`, `complete :: WorkId -> Eff es ()`, `listReady :: Eff es [WorkItem]`, `runLedgerState :: Eff (Ledger : es) a -> Eff es (a, [WorkItem])`, `runLedgerFile :: (IOE :> es) => FilePath -> ...` are identical across module, tests, demo, docs. `LedgerEvent` (`Recorded`/`Claimed`/`Completed`) and `foldItems`/`readyOf`/`stateOf` are internal and consistent.
- **Placeholder scan:** no broken or placeholder code blocks; every test/code step shows complete code. The only flagged judgement points are `(.field)` getter annotations and the `decodeLLM` import check. No vague steps.
