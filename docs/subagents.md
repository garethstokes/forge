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

## What is not covered

Workers are leaf (no nested trees) and spawn is synchronous. Judge-gated worker
outputs, a work-ledger effect, nested trees with tree-wide budgets, and
concurrent spawn are planned as separate work.
