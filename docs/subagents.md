---
title: Subagents
nav_order: 12
---

# Subagents

A subagent is a worker an orchestrator can spawn for a subtask. It runs its own
tool loop over a fresh transcript the parent never sees, and hands back a typed
result. The typed handoff is the part a hand-rolled multi-agent setup usually
leaves as prose or loose JSON.

## Defining a worker

```haskell
data SubAgent es i o = SubAgent
  { name :: Text, input :: JSONCodec i, output :: JSONCodec o
  , system :: Text, tools :: [Tool es], maxIters :: Int }

subAgent :: Text -> JSONCodec i -> JSONCodec o -> Text -> [Tool es] -> SubAgent es i o
```

A `SubAgent` is a `Skill` whose body is a tool loop: an input codec, an output
codec, an instruction, its own toolbox, and a tool-loop cap. Each worker carries
its own toolbox, so a worker has only the authority it needs.

If a worker has tools, its `system` instruction must tell it to use them before
replying. The base prompt only asks the worker to finish with JSON; it does not
prompt tool use, so a worker told nothing about its tools may answer without
calling them.

## Spawning

```haskell
data AgentFailure
  = SpawnBudgetExceeded Int
  | WorkerLoopExceeded  Text Int
  | WorkerDecodeFailed  Text DecodeError

spawn :: (Agents es :> r) => SubAgent es i o -> i -> Eff r (Either AgentFailure o)
```

`spawn` runs the worker and decodes its final answer through the output codec.
The parent gets `Either AgentFailure o` and never sees the worker transcript. A
worker cannot spawn its own workers in this release: spawn is one level.

## Interpreters

```haskell
runAgents         :: (Chat :> es, IOE :> es) => Int -> Eff (Agents es : es) a -> Eff es a
runAgentsScripted :: Int -> [Text] -> Eff (Agents es : es) a -> Eff es a
```

`runAgents` is the live interpreter: it drives each worker's tool loop under the
ambient `Chat`, capped at the given number of spawns (exhaustion is
`SpawnBudgetExceeded`). `runAgentsScripted` is model-free: each spawn pops the
next canned final-answer text and decodes it, honoring the same cap, so you can
test an orchestrator's logic without a model.

```haskell
orchestrate :: (Agents es :> r) => Eff r (Either AgentFailure Summary)
orchestrate = spawn researchWorker "the question"

-- live:     runEff (Anthropic.runChat cfg (runAgents 4 orchestrate))
-- in tests: runPureEff (runAgentsScripted 4 ["{...}"] orchestrate)
```

## Judge gates

A spawned worker hands back a typed value, but typed is not the same as correct.
A gate verifies the worker's output with the judge before accepting it.

```haskell
data Gate o = Gate { rubric :: Text, render :: o -> Text, votes :: Int, retries :: Int }

gate :: Text -> (o -> Text) -> Gate o   -- votes = 1, retries = 1

spawnGated :: (Agents es :> r, LLM :> r)
           => Gate o -> SubAgent es i o -> i -> Eff r (Either AgentFailure o)
```

`spawnGated` spawns the worker, renders its output, and judges it against the
rubric with an independent vote. On a pass it returns the output. On a rejection
it re-spawns the worker with the critique appended to its instruction, up to
`retries` times, then returns `GateRejected`. Only a successful spawn is judged:
a worker that fails to produce a value short-circuits with its own
`AgentFailure`.

```haskell
g = gate "the summary names a city and a temperature" id
spawnGated g weatherWorker "Brisbane"
```

The judge is a separate call, not the worker grading itself, so this is not a
closed loop; the critique is retry guidance. Gating is opt-in per spawn: the
base `spawn` is ungated. For a pure check with no judge call, use a `refine` on
the worker's output codec instead.

## What is not covered

Workers are leaf (no nested trees) and spawn is synchronous. A work-ledger
effect, nested trees with tree-wide budgets, and concurrent spawn are planned as
separate work.
