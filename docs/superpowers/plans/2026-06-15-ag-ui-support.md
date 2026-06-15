# AG-UI Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make crucible agent runs speak the full AG-UI protocol — outbound typed
event stream, inbound `RunAgentInput`, and shared state with JSON-Patch deltas —
via a core `Events` effect and a server-less `crucible-ag-ui` satellite.

**Architecture:** Approach A from the design. A typed `Events` effect (sibling of
`Emit`) carries an AG-UI-shaped `RunEvent` sum; the agent loops emit events at each
seam; a pure `Crucible.JsonPatch` differ produces RFC 6902 state deltas. All
protocol/transport lives in a `crucible-ag-ui` satellite that ships **no HTTP
server** — only `agUiSseBody`, a streaming-body adapter structurally identical to
WAI's `StreamingBody` but with no wai dependency.

**Tech Stack:** Haskell, `effectful`, `Crucible.Codec` (autodocodec), `aeson`
`Value`, `bytestring` `Builder`. Tests: the in-repo `Harness` (`check` /
`runChecks`) in `test/Spec.hs`, run with `zinc test`. Build with `zinc build .`.

**Spec:** `docs/superpowers/specs/2026-06-15-ag-ui-support-design.md`

---

## File Structure

**crucible-core (existing package):**
- Create `src/Crucible/RunEvent.hs` — the `Events` effect, `RunEvent` type,
  `MessageId`, interpreters (`runEventsList`, `runEventsIO`, `ignoreEvents`,
  `runEventsAsEmit`).
- Create `src/Crucible/JsonPatch.hs` — `Pointer`, `PatchOp`, `diff`, `applyPatch`.
- Modify `src/Crucible/Chat.hs` — `runToolAgent`/`runToolAgentN` gain `Events :> es`
  and emit at seams; add a `patchState` helper.
- Modify `crucible.cabal`/`zinc.toml` `library` stanza — expose the two new modules.
- Modify `test/Spec.hs` — add checks for every task.

**crucible-ag-ui (new satellite package):**
- Create `ag-ui/zinc.toml` (or cabal) — package depending on `crucible`,
  `bytestring`, `aeson`.
- Create `ag-ui/src/Crucible/AgUi/Wire.hs` — `agUiEventJson`, `RunAgentInput`,
  `decodeRunInput`.
- Create `ag-ui/src/Crucible/AgUi/Sse.hs` — `sseFrame`, `agUiSseBody`, `SseBody`.
- Create `ag-ui/test/Spec.hs` — satellite tests.

Build order = the seven tasks below; each is independently shippable.

---

## Phase 1 — Core event substrate

### Task 1: `Crucible.RunEvent` — the `Events` effect and `RunEvent` type

**Files:**
- Create: `src/Crucible/RunEvent.hs`
- Modify: `zinc.toml` (add `Crucible.RunEvent` to library exposed modules if listed; the repo auto-discovers `src/**`, so only add if an explicit module list exists)
- Test: `test/Spec.hs`

- [ ] **Step 1: Write the failing test**

Add to the check list in `test/Spec.hs` `main` (and the import
`import Crucible.RunEvent (RunEvent(..), Events, event, runEventsList, ignoreEvents, MessageId(..))`):

```haskell
  -- AG-UI #1: Events effect collects in order
  , check "runevent: runEventsList collects in order"
      (((), [RunStarted "t1" "r1", TextDelta (MessageId "m1") "hi", RunFinished "r1"])
        :: ((), [RunEvent]))
      (runPureEff (runEventsList
        (event (RunStarted "t1" "r1") >> event (TextDelta (MessageId "m1") "hi") >> event (RunFinished "r1"))))
  , check "runevent: ignoreEvents discards, preserves result"
      (7 :: Int)
      (runPureEff (ignoreEvents (event (RunFinished "r") >> pure (7 :: Int))))
```

- [ ] **Step 2: Run to verify it fails**

Run: `zinc build . 2>&1 | head` — Expected: compile error, `Crucible.RunEvent` not found.

- [ ] **Step 3: Write `src/Crucible/RunEvent.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | A typed run-event channel: a sibling of 'Crucible.Emit.Emit' that carries
-- structured 'RunEvent's (AG-UI-shaped) instead of raw text. The agent loops
-- 'event' at each seam; interpreters choose how to consume them (collect, encode
-- to a sink, or discard) — the streamer never knows. Wire encoding and transport
-- live in the @crucible-ag-ui@ satellite, not here.
module Crucible.RunEvent
  ( MessageId (..)
  , RunEvent (..)
  , Events (..)
  , event
  , runEventsList
  , runEventsIO
  , ignoreEvents
  , runEventsAsEmit
  ) where

import Data.Aeson (Value)
import Data.Text (Text)

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (modify, runState)

import Crucible.LLM (Message, Role)
import Crucible.Chat (ToolUseId)
import Crucible.Emit (Emit, emit)
import Crucible.JsonPatch (PatchOp)

newtype MessageId = MessageId Text deriving (Eq, Ord, Show)

-- | The semantic events a crucible run produces. Wire-only convenience variants
-- (@*_CHUNK@, @RAW@) are encoder concerns and are not modelled here.
data RunEvent
  = RunStarted Text Text                 -- threadId, runId
  | RunFinished Text                     -- runId
  | RunErrored Text (Maybe Text)         -- message, code
  | StepStarted Text | StepFinished Text -- stepName
  | TextStart MessageId Role | TextDelta MessageId Text | TextEnd MessageId
  | ToolStart ToolUseId Text             -- toolCallId, toolName
  | ToolArgs ToolUseId Text              -- args delta
  | ToolEnd ToolUseId
  | ToolResult ToolUseId Text            -- result content
  | ReasonStart MessageId | ReasonDelta MessageId Text | ReasonEnd MessageId
  | StateSnapshot Value
  | StateDelta [PatchOp]
  | MessagesSnapshot [Message]
  | CustomEvent Text Value
  deriving (Eq, Show)

data Events :: Effect where
  EmitEvent :: RunEvent -> Events m ()
type instance DispatchOf Events = Dynamic

event :: (Events :> es) => RunEvent -> Eff es ()
event = send . EmitEvent

-- | Collect events in arrival order alongside the result (tests).
runEventsList :: Eff (Events : es) a -> Eff es (a, [RunEvent])
runEventsList action = do
  (a, xs) <- reinterpret (runState []) (\_ -> \case EmitEvent e -> modify (e :)) action
  pure (a, reverse xs)

-- | Run each event through an IO sink (the live encoder calls this).
runEventsIO :: (IOE :> es) => (RunEvent -> IO ()) -> Eff (Events : es) a -> Eff es a
runEventsIO sink = interpret $ \_ -> \case EmitEvent e -> liftIO (sink e)

-- | Discard all events (result still fully assembled).
ignoreEvents :: Eff (Events : es) a -> Eff es a
ignoreEvents = interpret $ \_ -> \case EmitEvent _ -> pure ()

-- | Forward 'TextDelta' payloads to an 'Emit' sink; drop the rest. The decided
-- bridge so text-only consumers can keep using 'Emit'.
runEventsAsEmit :: (Emit :> es) => Eff (Events : es) a -> Eff es a
runEventsAsEmit = interpret $ \_ -> \case
  EmitEvent (TextDelta _ t) -> emit t
  EmitEvent _               -> pure ()
```

Note: `Crucible.JsonPatch` (Task 2) is imported here. Implement Task 2 first, or
add a temporary `type PatchOp = ()` and replace it in Task 2. **Do Task 2 first**
to avoid the stub — reorder if executing strictly.

- [ ] **Step 4: Run to verify it passes**

Run: `zinc test 2>&1 | grep -E "runevent|FAIL|ALL PASS"` — Expected: both `runevent:` lines `ok`.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/RunEvent.hs test/Spec.hs
git commit -m "feat(ag-ui): Crucible.RunEvent — typed Events effect + RunEvent"
```

---

### Task 2: `Crucible.JsonPatch` — RFC 6902 differ

**Files:**
- Create: `src/Crucible/JsonPatch.hs`
- Test: `test/Spec.hs`

Implement **before** Task 1's compile (RunEvent imports `PatchOp`).

- [ ] **Step 1: Write the failing tests** (add imports
  `import Crucible.JsonPatch (Pointer(..), PatchOp(..), diff, applyPatch)`):

```haskell
  -- AG-UI #2: JsonPatch round-trip law
  , check "jsonpatch: replace scalar"
      [Replace (Pointer ["a"]) (A.Number 2)]
      (diff (object ["a" .= (1 :: Int)]) (object ["a" .= (2 :: Int)]))
  , check "jsonpatch: add and remove keys"
      [Remove (Pointer ["b"]), Add (Pointer ["c"]) (A.Number 3)]
      (diff (object ["b" .= (1 :: Int)]) (object ["c" .= (3 :: Int)]))
  , check "jsonpatch: apply(diff a b) a == Right b"
      (Right (object ["a" .= (2 :: Int), "c" .= (3 :: Int)]))
      (let a = object ["a" .= (1 :: Int), "b" .= (9 :: Int)]
           b = object ["a" .= (2 :: Int), "c" .= (3 :: Int)]
       in applyPatch (diff a b) a)
```

- [ ] **Step 2: Run to verify it fails**

Run: `zinc build . 2>&1 | head` — Expected: `Crucible.JsonPatch` not found.

- [ ] **Step 3: Write `src/Crucible/JsonPatch.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | A minimal RFC 6902 JSON Patch differ over aeson 'Value's, for AG-UI
-- 'Crucible.RunEvent.StateDelta'. v1 emits only Add/Remove/Replace; arrays that
-- differ are replaced wholesale (no LCS array diff). Law: for all a b,
-- @applyPatch (diff a b) a == Right b@.
module Crucible.JsonPatch
  ( Pointer (..)
  , PatchOp (..)
  , diff
  , applyPatch
  ) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as K
import Data.Text (Text)

-- | A JSON Pointer (RFC 6901) as decoded path segments (no escaping here;
-- the wire codec handles ~0/~1 when rendering to a string).
newtype Pointer = Pointer [Text] deriving (Eq, Show)

data PatchOp = Add Pointer Value | Remove Pointer | Replace Pointer Value
  deriving (Eq, Show)

snoc :: Pointer -> Text -> Pointer
snoc (Pointer ps) p = Pointer (ps ++ [p])

diff :: Value -> Value -> [PatchOp]
diff = go (Pointer [])
  where
    go p a b
      | a == b = []
      | otherwise = case (a, b) of
          (Object oa, Object ob) ->
            let removed = [ Remove (snoc p (K.toText k))
                          | k <- KM.keys oa, not (KM.member k ob) ]
                added   = [ Add (snoc p (K.toText k)) v
                          | (k, v) <- KM.toList ob, not (KM.member k oa) ]
                changed = concat [ go (snoc p (K.toText k)) va vb
                                 | (k, va) <- KM.toList oa
                                 , Just vb <- [KM.lookup k ob] ]
            in removed ++ added ++ changed
          _ -> [Replace p b]

applyPatch :: [PatchOp] -> Value -> Either Text Value
applyPatch ops v0 = foldl step (Right v0) ops
  where
    step (Left e) _ = Left e
    step (Right v) op = case op of
      Add (Pointer ps) x     -> setAt ps (const (Right x)) v
      Replace (Pointer ps) x -> setAt ps (const (Right x)) v
      Remove (Pointer ps)    -> removeAt ps v

    setAt [] f cur = f cur
    setAt (k : rest) f (Object o) =
      let key = K.fromText k
          child = KM.lookupDefault Null key o
      in (\nv -> Object (KM.insert key nv o)) <$> setAt rest f child
    setAt _ _ _ = Left "setAt: path runs through a non-object"

    removeAt [k] (Object o) = Right (Object (KM.delete (K.fromText k) o))
    removeAt (k : rest) (Object o) =
      let key = K.fromText k
      in case KM.lookup key o of
           Just child -> (\nv -> Object (KM.insert key nv o)) <$> removeAt rest child
           Nothing    -> Right (Object o)
    removeAt _ _ = Left "removeAt: path runs through a non-object"
```

- [ ] **Step 4: Run to verify it passes**

Run: `zinc test 2>&1 | grep -E "jsonpatch|FAIL|ALL PASS"` — Expected: three `jsonpatch:` lines `ok`.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/JsonPatch.hs test/Spec.hs
git commit -m "feat(ag-ui): Crucible.JsonPatch — RFC 6902 differ (add/remove/replace)"
```

---

### Task 3: Loop emit points + `patchState`

**Files:**
- Modify: `src/Crucible/Chat.hs` (the `runToolAgent`/`runToolAgentN` loop)
- Test: `test/Spec.hs`

- [ ] **Step 1: Write the failing test**

Add a scripted-Chat run that asserts the emitted event sequence. Mirror the
existing `runChatScripted` usage. Add to `main`:

```haskell
  -- AG-UI #3: the loop emits the expected event sequence for a text-only turn
  , check "runevent: loop emits RunStarted/Step/Text/RunFinished for a final answer"
      [ RunStarted "t" "r", StepStarted "1"
      , TextStart (MessageId "a0") Assistant, TextDelta (MessageId "a0") "done", TextEnd (MessageId "a0")
      , StepFinished "1", MessagesSnapshot [], RunFinished "r" ]   -- MessagesSnapshot content asserted loosely below
      (eventsOf (runChatToolAgentEmitting "t" "r" ["done"] "hello"))
```

Add a test helper near the other agent helpers (around `test/Spec.hs:171`):

```haskell
-- AG-UI loop event helper: run the tool-agent over scripted Chat turns, collecting events.
runChatToolAgentEmitting :: Text -> Text -> [Text] -> Text -> [RunEvent]
runChatToolAgentEmitting tid rid replies q =
  snd $ runPureEff $ runEventsList $ runChatScripted (map (\t -> Turn [TextBlock t] []) replies)
      $ runToolAgent tid rid [] (startChat q)   -- exact arg shape per Chat's API after this task

eventsOf :: [RunEvent] -> [RunEvent]
eventsOf = id
```

(The exact `runToolAgent` signature after instrumentation is defined in Step 3;
adjust the helper to match. `TextBlock`/`startChat` are existing `Chat` names —
confirm against `src/Crucible/Chat.hs` and substitute the real constructors.)

- [ ] **Step 2: Run to verify it fails**

Run: `zinc build . 2>&1 | head` — Expected: type error — `runToolAgent` lacks the
`Events` constraint / `threadId`/`runId` params.

- [ ] **Step 3: Instrument the loop**

In `src/Crucible/Chat.hs`, give `runToolAgent` the `Events :> es` capability and
thread `threadId`/`runId`. Emit at the seams (read the current loop body first;
this shows the additions, not a rewrite):

```haskell
-- signature gains Events and the two ids:
runToolAgent
  :: (Chat :> es, Tools :> es, Events :> es)
  => Text            -- threadId
  -> Text            -- runId
  -> [ToolSpec]      -- (existing tool specs arg, name per current API)
  -> ChatState       -- (existing seed)
  -> Eff es Turn
runToolAgent threadId runId specs st0 = do
  event (RunStarted threadId runId)
  r <- loop (1 :: Int) st0
  event (MessagesSnapshot (transcriptOf st0))   -- final transcript accessor per current API
  event (RunFinished runId)
  pure r
  where
    loop n st = do
      event (StepStarted (T.pack (show n)))
      turn <- converse st          -- existing call
      mapM_ emitTextBlock (textBlocks turn)
      mapM_ emitToolUse  (toolUses turn)
      -- ... existing dispatch of tool_use → results, append, recurse/stop ...
      event (StepFinished (T.pack (show n)))
      -- existing continue/halt decision; on halt return turn
      ...
    emitTextBlock (mid, t) = do
      event (TextStart (MessageId mid) Assistant)
      event (TextDelta (MessageId mid) t)
      event (TextEnd (MessageId mid))
    emitToolUse tu = do
      event (ToolStart tu.toolUseId tu.name)
      event (ToolArgs tu.toolUseId (encodeArgs tu.input))
      event (ToolEnd tu.toolUseId)
    -- after a tool result block is produced:
    -- event (ToolResult tuId resultText)
```

On a `ChatError`, emit `RunErrored msg code` before rethrowing/returning. Keep all
existing behaviour; the only changes are the constraint, the two id params, and the
`event` calls. Update `runToolAgentN` the same way (or have it delegate).

Also add the state helper used in Phase 2:

```haskell
-- | Replace co-state and emit the RFC 6902 delta from prev → next.
patchState :: (Events :> es) => Value -> Value -> Eff es Value
patchState prev next = do
  event (StateDelta (diff prev next))   -- diff from Crucible.JsonPatch
  pure next
```

- [ ] **Step 4: Update all existing `runToolAgent` call sites**

Run: `zinc build . 2>&1 | grep -i "runToolAgent"` to find callers (e.g.
`src/Crucible/Example.hs`, `app/`, `test/Spec.hs`). Pass `""`/`""` threadId/runId
and wrap with `ignoreEvents` where events aren't wanted. Expected after fixes: clean build.

- [ ] **Step 5: Run to verify it passes**

Run: `zinc test 2>&1 | grep -E "runevent: loop|FAIL|ALL PASS"` — Expected: the loop
event-sequence check is `ok` and `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add src/Crucible/Chat.hs src/Crucible/Example.hs app test/Spec.hs
git commit -m "feat(ag-ui): emit RunEvents from the tool-agent loop + patchState helper"
```

---

## Phase 2 — `crucible-ag-ui` satellite

### Task 4: Scaffold the satellite package

**Files:**
- Create: `ag-ui/zinc.toml`, `ag-ui/src/Crucible/AgUi/.gitkeep`, `ag-ui/test/Spec.hs` (empty harness)

- [ ] **Step 1: Create `ag-ui/zinc.toml`** mirroring the root layout, package name
  `crucible-ag-ui`, depending on `crucible`, `base`, `text`, `bytestring`, `aeson`.
  (Copy the `[build.test.spec]` stanza from the root `zinc.toml`; point `source-dirs`
  at `ag-ui/test`.)

- [ ] **Step 2: Create a trivial `ag-ui/test/Spec.hs`** that imports `Harness`
  (re-use the root `Harness.hs` via `source-dirs`) and runs an empty `runChecks []`
  so `zinc test` in the satellite is green.

- [ ] **Step 3: Verify it builds**

Run: `zinc build ag-ui 2>&1 | tail` — Expected: success.

- [ ] **Step 4: Commit**

```bash
git add ag-ui/zinc.toml ag-ui/src ag-ui/test
git commit -m "chore(ag-ui): scaffold crucible-ag-ui satellite package"
```

---

### Task 5: AG-UI wire codec (`agUiEventJson`) + `RunAgentInput` decode

**Files:**
- Create: `ag-ui/src/Crucible/AgUi/Wire.hs`
- Test: `ag-ui/test/Spec.hs`

- [ ] **Step 1: Write the failing tests**

```haskell
  , check "agui-wire: TextDelta encodes to TEXT_MESSAGE_CONTENT"
      (object [ "type" .= A.String "TEXT_MESSAGE_CONTENT"
              , "messageId" .= A.String "m1", "delta" .= A.String "hi" ])
      (agUiEventJson (TextDelta (MessageId "m1") "hi"))
  , check "agui-wire: decodeRunInput pulls runId/threadId/messages"
      (Right ("t1", "r1", 1 :: Int))
      (fmap (\i -> (i.threadId, i.runId, length i.messages))
            (decodeRunInput "{\"threadId\":\"t1\",\"runId\":\"r1\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"tools\":[],\"state\":{}}"))
```

- [ ] **Step 2: Run to verify it fails**

Run: `zinc build ag-ui 2>&1 | head` — Expected: `Crucible.AgUi.Wire` not found.

- [ ] **Step 3: Write `ag-ui/src/Crucible/AgUi/Wire.hs`**

Provide `agUiEventJson :: RunEvent -> Value` with one branch per constructor
mapping to the AG-UI wire `type` + fields (the full mapping table below), a
`RunAgentInput` record, and `decodeRunInput :: ByteString -> Either Text
RunAgentInput`. Wire `type` names: `RUN_STARTED`, `RUN_FINISHED`, `RUN_ERROR`,
`STEP_STARTED`, `STEP_FINISHED`, `TEXT_MESSAGE_START`, `TEXT_MESSAGE_CONTENT`,
`TEXT_MESSAGE_END`, `TOOL_CALL_START`, `TOOL_CALL_ARGS`, `TOOL_CALL_END`,
`TOOL_CALL_RESULT`, `REASONING_START`/`REASONING_MESSAGE_CONTENT`/`REASONING_END`,
`STATE_SNAPSHOT`, `STATE_DELTA`, `MESSAGES_SNAPSHOT`, `CUSTOM`. `StateDelta`
renders each `PatchOp` as `{op,path,value}` with the JSON Pointer string built
from the segments (escape `~`→`~0`, `/`→`~1`). Field names per the spec
(`messageId`, `delta`, `toolCallId`, `toolCallName`, `snapshot`, `delta`,
`messages`).

```haskell
-- shape (abbreviated — include every constructor):
agUiEventJson :: RunEvent -> Value
agUiEventJson = \case
  RunStarted tid rid -> ev "RUN_STARTED" ["threadId" .= tid, "runId" .= rid]
  RunFinished rid    -> ev "RUN_FINISHED" ["runId" .= rid]
  RunErrored m c     -> ev "RUN_ERROR" (["message" .= m] ++ maybe [] (\x -> ["code" .= x]) c)
  TextStart (MessageId m) role -> ev "TEXT_MESSAGE_START" ["messageId" .= m, "role" .= roleText role]
  TextDelta (MessageId m) d    -> ev "TEXT_MESSAGE_CONTENT" ["messageId" .= m, "delta" .= d]
  TextEnd (MessageId m)        -> ev "TEXT_MESSAGE_END" ["messageId" .= m]
  -- ... every other constructor ...
  where ev t fields = object (("type" .= A.String t) : fields)
```

- [ ] **Step 4: Run to verify it passes**

Run: `zinc test ag-ui 2>&1 | grep -E "agui-wire|FAIL|ALL PASS"` — Expected: both `ok`.

- [ ] **Step 5: Commit**

```bash
git add ag-ui/src/Crucible/AgUi/Wire.hs ag-ui/test/Spec.hs
git commit -m "feat(ag-ui): AG-UI event JSON codec + RunAgentInput decode"
```

---

### Task 6: SSE encoder + `agUiSseBody` streaming adapter

**Files:**
- Create: `ag-ui/src/Crucible/AgUi/Sse.hs`
- Test: `ag-ui/test/Spec.hs`

- [ ] **Step 1: Write the failing test** (drive the body with an in-memory sink,
  parse back with `splitFrames`):

```haskell
  , check "agui-sse: agUiSseBody writes parseable SSE frames"
      (BC.pack "{\"type\":\"RUN_STARTED\"")   -- prefix check on the first frame
      (let run _input = event (RunStarted "t" "r")    -- minimal run emitting one event
       in BC.take 17 (collectSse (agUiSseBody dummyInput run)))
```

with helpers in the test module:

```haskell
collectSse :: ((Builder -> IO ()) -> IO () -> IO ()) -> BC.ByteString
collectSse body = unsafePerformIO $ do
  ref <- newIORef mempty
  body (\b -> modifyIORef' ref (<> b)) (pure ())
  LBS.toStrict . BB.toLazyByteString <$> readIORef ref   -- then strip "data: " for the prefix check
```

- [ ] **Step 2: Run to verify it fails**

Run: `zinc build ag-ui 2>&1 | head` — Expected: `Crucible.AgUi.Sse` not found.

- [ ] **Step 3: Write `ag-ui/src/Crucible/AgUi/Sse.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Crucible.AgUi.Sse (SseBody, sseFrame, agUiSseBody) where

import Data.Aeson (Value, encode)
import qualified Data.ByteString.Builder as BB
import Effectful (Eff, IOE, runEff)
import Crucible.RunEvent (RunEvent, Events, runEventsIO)
import Crucible.AgUi.Wire (RunAgentInput, agUiEventJson)

-- | Structurally WAI's StreamingBody: (write, flush). Defined here so the
-- satellite has no wai/warp/servant dependency.
type SseBody = (BB.Builder -> IO ()) -> IO () -> IO ()

-- | Encode one AG-UI event JSON 'Value' as an SSE frame.
sseFrame :: Value -> BB.Builder
sseFrame v = "data: " <> BB.lazyByteString (encode v) <> "\n\n"

-- | Decode-side is the host's; this takes the already-decoded input and the
-- host-provided run (an Eff emitting Events), and produces the streaming body.
agUiSseBody :: RunAgentInput -> (RunAgentInput -> Eff '[Events, IOE] ()) -> SseBody
agUiSseBody input run write flush =
  runEff $ runEventsIO (\e -> write (sseFrame (agUiEventJson e)) >> liftIO flush) (run input)
```

(Adjust the `Eff '[Events, IOE] ()` row to whatever interpreter stack the host's
run actually needs — Chat/Tools/LLM interpreters are discharged by the host before
handing the `Eff Events` action in; document this in the module haddock.)

- [ ] **Step 4: Run to verify it passes**

Run: `zinc test ag-ui 2>&1 | grep -E "agui-sse|FAIL|ALL PASS"` — Expected: `ok`.

- [ ] **Step 5: Commit**

```bash
git add ag-ui/src/Crucible/AgUi/Sse.hs ag-ui/test/Spec.hs
git commit -m "feat(ag-ui): SSE encoder + agUiSseBody streaming-body adapter (no server)"
```

---

## Phase 3 — state, reasoning, generative UI

### Task 7: Shared state (`set_state` tool + snapshot) and reasoning/generative-UI wiring

**Files:**
- Modify: `src/Crucible/Chat.hs` (emit `StateSnapshot` at run start; register optional `set_state` tool)
- Modify: `src/Crucible/RunEvent.hs`/loop — emit `Reason*` from thinking blocks; route `Partial` values through `patchState` for generative UI
- Test: `test/Spec.hs`, `ag-ui/test/Spec.hs`

- [ ] **Step 1: Write the failing tests**

```haskell
  -- core: a state mutation emits a StateDelta with the right op
  , check "agui-state: patchState emits replace delta"
      [StateDelta [Replace (Pointer ["n"]) (A.Number 2)]]
      (snd (runPureEff (runEventsList
        (patchState (object ["n" .= (1 :: Int)]) (object ["n" .= (2 :: Int)]) >> pure ()))))
  -- core: run start emits a StateSnapshot of the seed state
  , check "agui-state: run emits StateSnapshot at start"
      (object ["k" .= A.String "v"])
      (head [ s | StateSnapshot s <- runChatToolAgentEmittingWithState (object ["k" .= A.String "v"]) ["done"] "hi" ])
```

- [ ] **Step 2: Run to verify it fails**

Run: `zinc build . 2>&1 | head` — Expected: missing `runChatToolAgentEmittingWithState` / no `StateSnapshot` emit / no `set_state`.

- [ ] **Step 3: Implement**

- In the loop (Task 3's `runToolAgent`), accept a seed `coState :: Value` and emit
  `event (StateSnapshot coState)` right after `RunStarted`.
- Add an optional built-in tool to the satellite/host tool set:

```haskell
-- set_state: the model proposes a new full state; handler routes through patchState.
setStateTool :: IORef Value -> Tool es     -- (Tool type per Crucible.Tool)
setStateTool ref = rawTool "set_state" setStateSchema $ \args -> do
  prev <- liftIO (readIORef ref)
  _ <- patchState prev args              -- emits StateDelta
  liftIO (writeIORef ref args)
  pure (String "ok")
```

  (Both write paths from the design: the model via `set_state`, the app via a
  direct `patchState` call between steps.)
- Reasoning: where the streaming Chat interpreter surfaces thinking deltas
  (`Anthropic.Stream` thinking blocks), emit `ReasonStart`/`ReasonDelta`/`ReasonEnd`
  analogously to text blocks.
- Generative UI: document that streaming a structured object via `Crucible.Partial`
  + `diff` + `patchState` yields `StateDelta`s — add a satellite example test that
  feeds two successive partial `Value`s and asserts the emitted deltas.

- [ ] **Step 4: Run to verify it passes**

Run: `zinc test 2>&1 | grep -E "agui-state|FAIL|ALL PASS"` then
`zinc test ag-ui 2>&1 | grep -E "agui|ALL PASS"` — Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Chat.hs src/Crucible/RunEvent.hs ag-ui/src ag-ui/test test/Spec.hs
git commit -m "feat(ag-ui): shared state (StateSnapshot + set_state) + reasoning/generative-UI"
```

---

## Self-Review

**Spec coverage:** §3 RunEvent → Task 1; §6 JsonPatch → Task 2; §4 loop emit points
→ Task 3; satellite scaffold → Task 4; §5 codec + RunAgentInput → Task 5; §5 SSE +
`agUiSseBody` → Task 6; §6 state + §1 reasoning/generative-UI → Task 7. All seven
design components covered.

**Known soft spots to resolve during execution (read the real source first):**
- The exact current `runToolAgent` signature, `Chat` block/turn constructors
  (`TextBlock`/`startChat`/`transcriptOf`), and the `Tool` smart-constructor names
  are placeholders matched to the design; substitute the real names from
  `src/Crucible/Chat.hs` and `src/Crucible/Tool.hs` in Tasks 3, 5, 7.
- Task 6's `Eff '[Events, IOE]` row is illustrative; the host discharges
  Chat/Tools/LLM before handing the `Eff Events` action to `agUiSseBody`.
- `unsafePerformIO` in the Task 6 test is acceptable for a synchronous in-memory
  sink; if the harness prefers `IO`-returning checks, lift the check to `IO`.

**Type consistency:** `MessageId`/`Pointer`/`PatchOp`/`RunEvent` constructors are
used identically across Tasks 1–7. `patchState :: Value -> Value -> Eff es Value`
defined in Task 3, used in Tasks 5/7.
