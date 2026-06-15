# Durable Execution — ExecuteChild — Design

**Date:** 2026-06-15
**Status:** Committed spec
**Bead:** `crucible-1pv` (split from `crucible-5gr`). Depends on Phase 2a/2b (suspend model + signals, shipped).

## The problem this solves

The last orchestration primitive: a workflow spawns a **child workflow** and
suspends until the child completes, then receives the child's result. This
completes the `Crucible.Workflow` primitive set (now/newId/durableSleep/awaitSignal
+ executeChild). It is the most complex primitive: a child is a separate durable
execution whose completion must **propagate its result back into the parent's
journal** and wake the parent.

## ExecuteChild on the suspend model

```haskell
ExecuteChild :: Text -> ByteString -> Workflow m ByteString  -- child type, child input -> child result
executeChild :: (Workflow :> es) => Text -> ByteString -> Eff es ByteString
```

- **WaitSpec** gains `WaitChild CassetteKey Text ByteString` (the call-index key +
  child workflow type + child input).
- **Interpreter** (`runWorkflow`): `ExecuteChild ctype cinput` at call-index `n` → if
  the journal has the `("child", n)` key, return the recorded child result; else
  `throwError (Suspended (WaitChild k ctype cinput))`.
- **Worker** on `Suspended (WaitChild k ctype cinput)`:
  1. `createChildExecution` — a new `workflow_execution` (type=ctype, input=cinput)
     + ready `run_queue` row, **linked to the parent** via new columns
     `parent_exec`/`parent_key` (= the parent's exec id + the await key `k`).
  2. `suspendChild pool parentEid k` — parent `run_queue` `state='waiting'`,
     `wait_kind='child'`, `wait_key=k`. Not completed.
- **Child completion** (the propagation, the crux): when the worker completes any
  execution, it uses `completeExecutionWith pool eid outputBytes` which:
  1. marks the child `completed`;
  2. if the child has a `parent_exec`, **appends** the child's `outputBytes` into the
     **parent's** journal under `parent_key` (op `"child"`, status `"result"`) and
     sets the parent `run_queue.state='ready'`. (Transactional.)
- **Parent resume**: the next `runOnce` claims the parent, replays to the
  `executeChild` call, which now finds its `("child", n)` entry → returns the child
  result → continues.

### Output bytes — `wdEncodeOutput`

`completeExecutionWith` needs the child's output as bytes. `WorkflowDef` gains
`wdEncodeOutput :: o -> ByteString`; `runOnce` on `Completed o` calls
`completeExecutionWith pool eid (wdEncodeOutput def o)` (replacing the bare
`completeExecution`). For a `ByteString`-output workflow, `wdEncodeOutput = id`.

### Scope: same-type children (this cycle)

To keep the worker single-`WorkflowDef` (no existential/registry machinery), the
demonstrated pattern is **same-type** parent/child: one `WorkflowDef` whose program
branches on its input (e.g. input `"parent"` calls `executeChild "calc" "child"`;
input `"child"` returns a result). This is a real pattern (recursive / fan-out
workflows) and exercises the full mechanism. The worker's `loadInput` reads each
execution's stored input (`executionInput`), so parent and child both get their
own input. A **multi-type registry** (dispatch different `WorkflowDef`s by
`workflow_type`) is a natural follow-on, noted, not built here.

## Store surface (crucible-manifest)

- `workflow_execution` gains `parent_exec :: Maybe Int`, `parent_key :: Maybe Text`
  (b64 await key). `createExecution` sets both `Nothing`.
- `createChildExecution :: Pool -> JournalIdentity -> Int -> CassetteKey -> IO Int`
  (child ident, parent exec, parent await key) → child exec id, with the link set +
  a ready run_queue row.
- `suspendChild :: Pool -> Int -> CassetteKey -> IO ()` (parent waiting on child).
- `completeExecutionWith :: Pool -> Int -> ByteString -> IO ()` — replaces/augments
  `completeExecution`: mark completed; if linked, append output to parent under
  parent_key (op "child", status "result") + ready the parent, in one transaction.
- `executionInput :: Pool -> Int -> IO ByteString` — read an execution's stored
  input bytes (so the worker can load a child's input).

## Testing
- crucible (in-memory): `executeChild "t" "in"` miss → `Suspended (WaitChild k "t"
  "in")`; with the `("child",n)` entry present → returns the recorded result.
- crucible-manifest (ephemeral pg): `createChildExecution` sets the parent link +
  a ready row; `completeExecutionWith` on a linked child appends the output to the
  parent's journal under the await key + readies the parent; on an unlinked exec it
  just completes. `executionInput` round-trips.
- crucible-worker (ephemeral pg, the acceptance): a same-type workflow where input
  `"parent"` does `r <- executeChild "calc" "child"; pure ("got:" <> r)` and input
  `"child"` returns `"child-result"`. Drive: create parent (input "parent");
  `runOnce` → parent suspends (`SuspendedRun (WaitChild …)`), a child execution
  exists (ready); `runOnce` → runs the child → `Completed "child-result"`, which
  propagates into the parent + readies it; `runOnce` → parent resumes, `executeChild`
  returns "child-result", `Completed "got:child-result"`. Assert the final parent
  output + that both ran. (`drainOnce`/`pollRounds` can drive the three steps.)

## Risks
- **Output propagation ordering** — `completeExecutionWith` does child-complete +
  parent-append + parent-ready in one transaction (no window where the child is
  done but the parent never wakes).
- **Same-type-only scope** — a multi-type registry is deferred; the mechanism is
  type-agnostic (the child's `workflow_type` is stored), so the registry is purely
  a worker-dispatch addition later. Noted.
- **`completeExecution` callers** — `runOnce`'s success branch moves to
  `completeExecutionWith` (with `wdEncodeOutput`); the bare `completeExecution`
  stays for any non-output caller/back-compat. Existing worker tests gain a
  `wdEncodeOutput` field on their `WorkflowDef`s (mechanical).
