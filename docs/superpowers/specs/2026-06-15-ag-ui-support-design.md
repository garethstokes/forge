---
type: design
status: draft
updated: 2026-06-15
---

# AG-UI Support in Crucible — Design

**Date:** 2026-06-15
**Scope:** Full AG-UI surface — outbound event stream, inbound `RunAgentInput`,
and shared state with JSON-Patch deltas.
**Approach:** A (approved) — an AG-UI-shaped `Events` effect in crucible-core, with
all protocol/transport/HTTP in a `crucible-ag-ui` satellite.

---

## 1. What AG-UI is (verified 2026-06-15)

AG-UI (Agent User Interaction Protocol, CopilotKit) standardizes how an agent run
streams to a frontend. Verified against `docs.ag-ui.com`:

- **Core abstraction:** `run(RunAgentInput) → Observable<BaseEvent>`. `RunAgentInput`
  (threadId, runId, messages, state, tools, context) arrives via **HTTP POST**;
  typed events stream back.
- **`BaseEvent` envelope:** every event has `type`, optional `timestamp`, optional
  `rawEvent`.
- **Event categories:** Lifecycle (`RUN_STARTED/FINISHED/ERROR`,
  `STEP_STARTED/FINISHED`), Text (`TEXT_MESSAGE_START/CONTENT/END`, `…CHUNK`),
  Tool (`TOOL_CALL_START/ARGS/END/RESULT`, `…CHUNK`), State (`STATE_SNAPSHOT`,
  `STATE_DELTA`, `MESSAGES_SNAPSHOT`), Reasoning (`REASONING_*`), Activity, and
  Special (`RAW`, `CUSTOM`).
- **State:** `STATE_SNAPSHOT` is the full object (sent initially/infrequently);
  **`STATE_DELTA` is JSON Patch (RFC 6902)**, applied sequentially.
- **Transport-agnostic:** SSE is the debuggable default; binary/WebSocket/webhooks
  also valid. This design ships SSE first.

The key observation driving Approach A: **crucible already produces every one of
these events semantically** — `runToolAgent`/`runAgent` is the run; `Chat.ToolUse`
is a tool call; `Emit` deltas are text content; `AgentState.transcript` is the
messages snapshot; `Partial` yields progressively-complete values for state. What
is missing is a typed envelope, emit points, a wire encoder, a transport, and the
inbound decode.

---

## 2. Architecture

```
Frontend (CopilotKit HttpAgent)
   │  HTTP POST RunAgentInput
   ▼
HOST server handler  (the app's own warp / servant / wai / snap route — NOT ours)
   │  hands us the request body + a chunk sink, plugs our streaming body into its response
   ▼
crucible-ag-ui  (satellite: a library, no server)
   ├─ decode RunAgentInput → AgentState (transcript) + tool set + seed coState
   ├─ run the crucible loop  (Events + Chat + Tools interpreters)
   │      └─ loop emits RunEvent at lifecycle / text / tool / state / reasoning seams
   └─ Events interpreter: RunEvent → AG-UI JSON (BaseEvent) → SSE frame → host chunk sink
        ▲
crucible-core
   ├─ Crucible.RunEvent : the Events effect + RunEvent type + pure interpreters
   ├─ loop emit points in runToolAgent / runAgent
   └─ Crucible.JsonPatch : pure RFC 6902 differ (diff / applyPatch)
```

**crucible-ag-ui ships no HTTP server.** It provides a framework-agnostic
streaming-body adapter that the host plugs into its own handler. Dependency
direction matches `crucible-manifest`: core stays dependency-light; the protocol
and the adapter live in the opt-in satellite — with **no warp/servant dependency**.

---

## 3. `Crucible.RunEvent` (core) — the typed event effect

A typed sibling of `Emit`. Models the **semantic** events crucible produces; the
wire-only `*CHUNK` / `RAW` variants are encoder concerns, not core constructors.

```haskell
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
  | StateSnapshot Value                  -- full app state
  | StateDelta [PatchOp]                 -- RFC 6902
  | MessagesSnapshot [Message]
  | CustomEvent Text Value

data Events :: Effect where
  EmitEvent :: RunEvent -> Events m ()
type instance DispatchOf Events = Dynamic

event :: (Events :> es) => RunEvent -> Eff es ()
event = send . EmitEvent
```

**Interpreters** (mirroring `Emit`):

- `runEventsList :: Eff (Events : es) a -> Eff es (a, [RunEvent])` — collect, for tests.
- `runEventsIO :: IOE :> es => (RunEvent -> IO ()) -> Eff (Events : es) a -> Eff es a` — encode + sink, live.
- `ignoreEvents :: Eff (Events : es) a -> Eff es a` — discard.

Pure event core, thin IO interpreter — the `Emit` / `Anthropic.Stream` discipline.

### Relationship to `Emit` (decided)

`Emit Text` **stays as a separate sibling effect** — it is widely used and
text-only consumers should not pay for the richer type. A one-line bridge forwards
text events to `Emit`:

```haskell
-- forward TextDelta payloads to an Emit sink, ignore the rest
runEventsAsEmit :: (Emit :> es) => Eff (Events : es) a -> Eff es a
```

The two are not folded together.

---

## 4. Loop wiring (core)

`runToolAgent` / `runAgent` gain `Events :> es` and emit at the seams:

| Seam | Event(s) |
|------|----------|
| loop entry | `RunStarted threadId runId` |
| each iteration | `StepStarted` … `StepFinished` |
| assistant text block | `TextStart` / `TextDelta`* / `TextEnd` |
| each `ToolUse` in the `Turn` | `ToolStart` / `ToolArgs`* / `ToolEnd` |
| after tool dispatch | `ToolResult toolCallId content` |
| thinking block | `ReasonStart` / `ReasonDelta`* / `ReasonEnd` |
| loop exit (`Done`) | `MessagesSnapshot transcript` + `RunFinished` |
| `ChatError` | `RunErrored message code` |

Additive: a program that doesn't care discharges `Events` with `ignoreEvents`,
consistent with "the loop's type IS its capability manifest" (`Agent.hs`).

**Fidelity scales with the Chat interpreter.** Token-level `TextDelta` / `ToolArgs`
deltas (`*` above) come from the streaming interpreter (`streamChat` in
`Anthropic.Stream`). With a non-streaming `Chat` interpreter the loop still emits
**valid** AG-UI — `TextStart` + one full `TextDelta` + `TextEnd` (coarser
granularity). Both conform; fidelity is a function of the chosen interpreter, not
the protocol layer.

---

## 5. `crucible-ag-ui` satellite — wire, encode, handler adapter (no server)

The satellite is a **library**, not a server. The host app owns the route, the
HTTP method, auth, and the response object; crucible-ag-ui supplies the four
pieces it plugs in:

- **`RunAgentInput` decode** — `decodeRunInput :: ByteString -> Either Text
  RunAgentInput` (messages, tools, state, threadId, runId, context). The host reads
  its own request body and hands us the bytes.
- **Codec** `agUiEventJson :: RunEvent -> Value` (via `Crucible.Codec`) — produces
  the `BaseEvent` envelope (`type`, `timestamp`, `rawEvent`) plus per-event fields,
  mapping neutral constructors to wire names (`TextDelta` →
  `{"type":"TEXT_MESSAGE_CONTENT","messageId":…,"delta":…}`).
- **SSE encoder** — each event → a `data: <json>\n\n` `Builder`. The inverse of
  `Anthropic.Stream.splitFrames`; trivial.
- **Streaming-body adapter** — the seam that runs inside the host's handler:

  ```haskell
  -- Structurally identical to WAI's StreamingBody = (Builder -> IO ()) -> IO () -> IO (),
  -- but defined here so the satellite needs NO wai/warp/servant dependency.
  type SseBody = (Builder -> IO ())   -- write a chunk
              -> IO ()                -- flush
              -> IO ()

  -- Decode → run the loop → encode each emitted RunEvent to an SSE frame and write it.
  -- The host builds the run from the input (which tools, which LLM interpreter, state seed).
  agUiSseBody :: RunAgentInput
              -> (RunAgentInput -> Eff '[Events, IOE] ())  -- the host-provided run
              -> SseBody
  ```

  The host wires it in with one line, e.g. WAI:
  `responseStream status200 sseHeaders (agUiSseBody input run)` — or the equivalent
  in servant (`StreamGet`/`SourceIO`), snap, yesod, or a raw socket. Because
  `SseBody` is structurally WAI's `StreamingBody`, the WAI case needs no shim while
  the satellite still has no wai dependency.

- Only dep beyond core: `bytestring` (`Builder`), already used by core. **No
  warp/servant/wai.**

---

## 6. Shared state + JSON-Patch (the novel chunk)

State is app-defined JSON co-owned by agent and UI.

- The run carries a typed app state `s` with a `JSONCodec s` (crucible-style typed),
  reduced to a `Value` (`coState`) for snapshot/delta.
- `StateSnapshot` is emitted at run start and on demand.
- **`Crucible.JsonPatch` (core, pure):**
  ```haskell
  data PatchOp = Add Pointer Value | Remove Pointer | Replace Pointer Value
               | Move Pointer Pointer | Copy Pointer Pointer | Test Pointer Value
  diff       :: Value -> Value -> [PatchOp]      -- structural diff → RFC 6902
  applyPatch :: [PatchOp] -> Value -> Either Text Value
  ```
  After each mutation, `diff prev next` produces the ops for a `StateDelta`. This is
  the one genuinely new algorithm; property law: `applyPatch (diff a b) a == Right b`.
- **`Partial` tie-in:** successive progressively-complete values from
  `Crucible.Partial` → `diff` → `StateDelta` gives **generative-UI streaming for
  free** (stream a structured object to the UI as it forms).

### Who writes state (decided): model-tool **and** app

Both write paths are supported, and both go through one helper so the differ always
observes before/after:

```haskell
-- compute the delta from the current coState, emit StateDelta, advance coState
patchState :: (Events :> es) => Value -> Eff es ()   -- new full state → emits diff
```

1. **Model-written** — an optional built-in `set_state` (and/or `patch_state`) tool
   is registered in the tool set; when the model calls it, the handler routes
   through `patchState`, so a model-driven state change emits a `StateDelta` like any
   other.
2. **App-written** — the app calls `patchState` directly between steps.

`coState` is carried in the loop context alongside the transcript so both paths see
the same current value.

---

## 7. Error handling

- **`ChatError`** (loop) → `RunErrored {message, code}` event, then a graceful SSE
  close (clients expect `RUN_ERROR` followed by stream end).
- **Malformed `RunAgentInput`** → HTTP 400 before any run starts (no event stream).
- **Client disconnect** → the loop `Eff` is cancelled by the warp handler; events are
  whole frames, so there is no torn write to recover.
- **Tool errors** → surfaced as `ToolResult` with error content (AG-UI has no
  separate tool-error event); the loop continues or halts per existing semantics.
- **Mid-stream provider failure** → `RunErrored`, then end the stream.

---

## 8. Testing

- **Core sequence:** `runEventsList` + `runChatScripted` → assert the exact event
  sequence for a tool-using turn (golden): `RunStarted, StepStarted, TextStart,
  TextDelta…, TextEnd, ToolStart, ToolArgs…, ToolEnd, ToolResult, StepFinished, …,
  MessagesSnapshot, RunFinished`.
- **`JsonPatch`:** property `applyPatch (diff a b) a == Right b` over arbitrary JSON;
  golden diffs for representative cases.
- **Codec:** golden `RunEvent → AG-UI JSON` against fixtures captured from the spec.
- **Satellite integration (no server needed):** drive `agUiSseBody` directly with a
  decoded `RunAgentInput` and an in-memory chunk sink (a `Builder` collector), then
  parse the captured SSE back with `splitFrames` and assert the event sequence.
  Optionally validate event JSON against AG-UI's published schema, or run an
  end-to-end check by mounting `agUiSseBody` in a throwaway WAI app and driving it
  with a CopilotKit `HttpAgent`.

---

## 9. Components & build order

| # | Component | Package | New deps |
|---|-----------|---------|----------|
| 1 | `Crucible.RunEvent` (effect + type + interpreters) + loop emit points | core | none |
| 2 | `Crucible.JsonPatch` (diff / applyPatch) | core | none |
| 3 | AG-UI JSON codec (`agUiEventJson`) | crucible-ag-ui | none beyond codec |
| 4 | SSE encoder | crucible-ag-ui | none |
| 5 | `RunAgentInput` decode + streaming-body adapter (`agUiSseBody`) | crucible-ag-ui | none (bytestring `Builder`; structurally WAI-compatible) |
| 6 | shared state (`patchState`, `set_state` tool, snapshot/delta) | core + satellite | none |
| 7 | reasoning events + `Partial`/generative-UI | core + satellite | none |

**Build order:** 1 → 2 → 3 → 4 → 5 → 6 → 7. Each is independently shippable; an
outbound-only AG-UI agent works at the end of step 5, and full state/generative-UI
lands at 6–7.

---

## 10. Open questions

- **Thread continuity (resumed threads):** AG-UI's default is **client-carries-
  state** — the frontend replays `messages` + `state` in every `RunAgentInput`, so a
  same-`threadId` follow-up POST reconstructs the `AgentState` purely from decode,
  with no server-side store. v1 relies on this; nothing to build. *If* a future use
  case needs server-authoritative history (client not trusted to carry state), that
  is a crucible store keyed by `threadId` (Memory / `crucible-manifest`), composing
  with the persistence work — not a new subsystem.
- **Binary transport:** SSE only for v1; the `RunEvent → Value` seam keeps a binary
  encoder as a later drop-in.
- **Auth / routing / method:** owned entirely by the host handler — the satellite
  ships no server, so there is nothing to authenticate here (consistent with AG-UI's
  optional Secure Proxy).
