# Spawn Effect Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-pch` (from `docs/superpowers/research/2026-06-11-multi-agent-harnesses.md`, recommendations 1, 2, 5).
**Goal:** A typed orchestrator-worker primitive: a `SubAgent` value and an `Agents` effect whose `Spawn` runs a worker as an isolated tool loop and hands back a codec-typed result, with a spawn cap.

**Scope:** new `src/Crucible/Agents.hs`; `test/Spec.hs`; `app/Main.hs`; new `docs/subagents.md`. No change to `Crucible.Chat`, `Crucible.Tool`, or `Crucible.Agent`.

## Motivation

crucible is a single-agent substrate: `runToolAgent` drives a Chat-effect tool
loop, `Tools`/`Tool` give codec-typed dispatch, `Skill` gives codec-typed
one-shot calls. The surviving design from the multi-agent field
(orchestrator-worker, isolated child context, typed result-only handoff) is a
small extension of these pieces. A subagent is a `Skill` whose body is a tool
loop; spawning it runs a fresh transcript the parent never sees and decodes the
final answer through an output codec. The typed handoff is the part no surveyed
harness has: handoffs elsewhere are JSON or prose by convention. This cycle
ships the foundation plus a spawn cap; judge gates, a work ledger, nested
trees, and concurrency are explicit follow-ons.

## Decisions taken during design

- **One level (leaf workers).** The orchestrator spawns workers; a worker runs
  a tool loop and returns but cannot itself spawn. This keeps the effect
  encoding non-recursive (the `Agents` effect is indexed by the base row the
  workers run in, which has no `Agents`) and matches Anthropic's research
  system and Claude Code Task (no recursive spawn by default). Nested trees and
  tree-wide budgets are a later cycle.
- **Synchronous spawn.** Sequential spawn captures the context-isolation win
  with none of the parallel-sibling coordination cost (Anthropic shipped
  synchronous; Cognition's failure mode is uncoordinated parallel siblings).
  Concurrent spawn can arrive later as a different interpreter without changing
  the effect.
- **Spawn cap built in.** Like `runToolAgent` shipping with an iteration cap,
  the local interpreter ships with a spawn-count cap; exhaustion is a typed
  failure (`SpawnBudgetExceeded`), not unbounded recursion.
- **Typed result-only handoff.** The worker's final text is decoded through the
  subagent's output codec; the parent receives `Either AgentFailure o` and
  never sees the worker's transcript.
- **Least authority per worker.** Each `SubAgent` carries its own toolbox, so
  interpreters do not share one broad toolbox across every spawn.
- **Scripted interpreter takes canned final-answer text.** A spawn's `o` varies
  per call, so the scripted interpreter pops canned `Text` (the worker's final
  answer) and decodes it through that spawn's output codec, mirroring
  `runLLMScripted [Text]`. This keeps it homogeneous, model-free, and
  `runPureEff`-compatible, and it exercises the real decode path.

## Design (`Crucible.Agents`)

```haskell
-- | A spawnable worker: a Skill whose body is a tool loop. 'es' is the base
-- effect row the worker runs in (it has Chat and whatever its tools need, but
-- not Agents, which is what keeps spawn one level).
data SubAgent es i o = SubAgent
  { name     :: Text          -- ^ for failures and introspection
  , input    :: JSONCodec i   -- ^ renders the handoff input into the worker prompt
  , output   :: JSONCodec o   -- ^ decodes the worker's final answer (the typed handoff)
  , system   :: Text          -- ^ the worker's instruction
  , tools    :: [Tool es]     -- ^ the worker's own toolbox (least authority)
  , maxIters :: Int           -- ^ the worker's tool-loop cap
  }

-- | Build a SubAgent; maxIters defaults to 'Crucible.Chat.defaultMaxIterations'.
subAgent :: Text -> JSONCodec i -> JSONCodec o -> Text -> [Tool es] -> SubAgent es i o

-- | A spawn failure.
data AgentFailure
  = SpawnBudgetExceeded Int               -- ^ the spawn cap that was hit
  | WorkerLoopExceeded  Text Int          -- ^ worker name, its iteration cap
  | WorkerDecodeFailed  Text DecodeError  -- ^ worker name, the decode error
  deriving (Eq, Show)

-- | Orchestrator-worker spawn, indexed by the worker base row 'es'.
data Agents (es :: [Effect]) :: Effect where
  Spawn :: SubAgent es i o -> i -> Agents es m (Either AgentFailure o)
type instance DispatchOf (Agents es) = Dynamic

spawn :: (Agents es :> es) => SubAgent es i o -> i -> Eff es (Either AgentFailure o)
spawn sub i = send (Spawn sub i)

-- | Synchronous local interpreter with a spawn-count cap.
runAgents :: (Chat :> es) => Int -> Eff (Agents es : es) a -> Eff es a

-- | Model-free interpreter: each spawn pops the next canned final-answer text
-- and decodes it through that spawn's output codec, honoring the same cap.
runAgentsScripted :: Int -> [Text] -> Eff (Agents es : es) a -> Eff es a
```

### Effect-row encoding

`Agents` is indexed by the worker base row `es`: in `runAgents`, the handled row
is `Agents es : es`, and the effect element `Agents es` references `es` (the
tail), not the full row, so there is no infinite type. The orchestrator's type
is `(Chat :> es) => Eff (Agents es' : es') a` with `es'` the base; its
`spawn` calls use `SubAgent es'` whose `[Tool es']` handlers use only base-row
effects (Chat, IOE, etc.), which is the normal row-polymorphic way tools are
written. Workers cannot spawn because `es'` has no `Agents`.

### `runAgents` semantics (per `Spawn sub i`)

1. If the remaining spawn budget is `<= 0`, return `Left (SpawnBudgetExceeded cap)`.
2. Decrement the budget (a shared count in the interpreter's State, threaded
   across the whole orchestrator run).
3. Assemble the worker prompt: `sub.system`, then the output-schema contract
   (the same "Respond ONLY with JSON matching this schema" text `Skill.call`
   uses), then `\n\n<input>\n` + the input rendered via `sub.input` + `\n</input>\n\n`,
   then a trailing "finish with JSON only" reminder. (`runToolAgent` has no
   system slot, so the instruction is folded into the prompt; no `Chat` change.)
4. Run `Chat.runToolAgentN sub.maxIters sub.tools prompt :: Eff es (Either ChatError Text)`
   as a fresh transcript under the ambient `Chat`. The parent never sees it.
5. On `Left (ToolLoopExceeded n)` return `Left (WorkerLoopExceeded sub.name n)`.
6. On `Right finalText`, decode via `sub.output`: `Left err` ->
   `Left (WorkerDecodeFailed sub.name err)`; `Right o` -> `Right o`.

### `runAgentsScripted` semantics (per `Spawn sub i`)

Same budget check and decode path as `runAgents`, but step 4 is replaced by
popping the next canned `Text` from the script (the worker's final answer); an
exhausted script yields `Left (WorkerDecodeFailed sub.name (DecodeError "no scripted answer" ""))`.
No `Chat` is required, so the interpreter runs under `runPureEff`.

The budget-and-decode logic (steps 1, 2, 5, 6 plus the decode) is a shared pure
helper both interpreters call, so they cannot drift.

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block: define a worker `SubAgent` with the existing
weather tool and a typed output record, then an orchestrator that `spawn`s it
once for a subtask, run under
`runEff (Anthropic.runChat cfg (runAgents cap orchestrator))`. Print the typed
result or the `AgentFailure`. Shows context-isolated, typed, capped spawn live.

## Manual (`docs/subagents.md`, new page, nav_order 12)

The `SubAgent` value and `subAgent`; the `Agents`/`spawn`/`AgentFailure` API;
the typed result-only handoff (the parent never sees the worker transcript) as
the boundary no surveyed harness has; the two interpreters (live synchronous
`runAgents` vs model-free `runAgentsScripted` for tests); the spawn cap and its
typed failure; least authority (each worker carries its own toolbox); and the
one-level note (workers are leaf in this release). House style: no emdashes or
endashes, no hype words, no manifest mentions.

## Testing (hermetic, via `runAgentsScripted`)

- A one-spawn orchestrator with a canned answer decodes it to the typed `o`
  (typed handoff works end to end).
- A canned answer that fails the output codec returns
  `Left (WorkerDecodeFailed name err)`.
- Sequencing: spawn worker A, branch on its `Right`/`Left`, then spawn worker B;
  asserts the parent can react to a typed result and spawn again.
- Budget: cap 1 with two spawns returns `Left (SpawnBudgetExceeded 1)` on the
  second spawn; the first still succeeds.
- An exhausted script yields `Left (WorkerDecodeFailed ...)`.
- `subAgent` builds the expected value (name/system/maxIters defaulted).
- `AgentFailure` derives `Eq`/`Show` (constructed values compare).
- The worker-prompt assembly helper is pure and contains the system
  instruction, the `<input>` JSON, and the schema contract.

Live: the demo spawn before merge (gated on the Anthropic key).

## Non-goals (this cycle)

- Nested spawn / true trees and tree-wide token budgets (workers are leaf here).
- Judge-gated worker outputs (the `gated` combinator) and the work-ledger effect
  (each its own later cycle).
- Concurrent or async spawn (synchronous only; a different interpreter later).
- A system-turn change to `runToolAgent` (the worker instruction is folded into
  the prompt instead).
- Process management, role catalogs, group chat / blackboard / debate, channel
  gateways, human-approval UI (the research's explicit non-goals).
