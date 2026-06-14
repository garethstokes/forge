# Nested Spawn Trees + Tree Budget Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-gt5` (follow-on to `crucible-pch`, Spawn; from `docs/superpowers/research/2026-06-11-multi-agent-harnesses.md` rec 5).
**Goal:** Let a spawned worker spawn its own sub-workers (an arbitrary-depth tree), with a single spawn budget shared across the whole tree, by evolving `Crucible.Agents` in place.

**Scope:** `src/Crucible/Agents.hs` (worker tool row + re-entrant interpreter); `test/Spec.hs` (toolbox-row annotations + nesting tests); `src/Crucible/Agents/Gate.hs` is unchanged but its tests' annotations update; `app/Main.hs` (a delegation demo); `docs/subagents.md` (rewrite the one-level framing). No change to `manifest-evals` (it does not use `Agents`).

## What problem this solves

Real decomposition is recursive: an orchestrator splits a task into parts, and a
part is often itself big enough to split again. The shipped `Agents` effect is
one level deep on purpose, so a worker that meets a sub-task it should delegate
has no way to do so; the orchestrator must anticipate every layer up front and
flatten the tree by hand, which defeats the point of handing a worker an
open-ended job. Worse, once you do fan out by hand across layers, nothing bounds
the total: a naive multi-level fan-out is exactly where the 15x token blow-ups
and runaway agent bills come from, because each layer multiplies the last. This
work fixes both. A worker can spawn sub-workers through an ordinary tool, so
decomposition happens where the work is understood rather than only at the root,
and a single budget threads through the entire tree, so the whole structure
(not each level in isolation) is capped and a runaway recursion stops at a
typed failure instead of an invoice. The typed result-only handoff and
context isolation from the foundation still hold at every level.

## Motivation

The foundation indexes `Agents es` by the worker base row and runs each worker
in `es` (which has no `Agents`), which is what makes workers leaf. Nesting needs
the worker's tool loop to run in a row that contains `Agents`, so a tool handler
can call `spawn`. The viable non-infinite encoding keeps `Agents` indexed by the
base row `es` and moves the worker tools into the row `Agents es : es`; the
interpreter becomes re-entrant, re-interpreting each worker's computation against
one shared budget. One level becomes the degenerate case of a worker whose tools
never spawn.

## Decisions taken during design

- **Evolve in place, not a parallel layer.** `SubAgent es i o` and the public
  signatures of `subAgent`/`spawn`/`runAgents`/`spawnGated` stay the same; only
  the `tools` field's row changes (`[Tool es]` -> `[Tool (Agents es : es)]`). The
  breakage is in-repo annotation churn; `manifest-evals` does not use `Agents`.
- **Delegation as a tool.** A worker is a `Chat` tool loop, so the only way it
  spawns is by calling a tool whose handler calls `spawn`. Nesting needs no new
  worker concept, just tools in a spawn-capable row.
- **One shared spawn budget for the whole tree.** A single `IORef` counter,
  decremented on every `spawn` anywhere in the tree (the root spawn included);
  exhaustion is `SpawnBudgetExceeded`, surfaced wherever the spawn was attempted.
  This caps the whole tree and is the runaway guard (it also bounds depth). Token
  budgets and an explicit depth cap are non-goals here.
- **Re-entrant interpreter.** `runAgents`'s handler recursively re-interprets a
  worker's computation (`go (runToolAgentN ...)`), so a `spawn` from a worker's
  tool is caught and serviced against the shared counter.
- **Scripted interpreter unchanged.** `runAgentsScripted` ignores tools (returns
  a canned final answer per spawn), so it still tests top-level orchestration;
  nesting is exercised with the live re-entrant interpreter over a scripted
  `Chat`.

## Design (`Crucible.Agents`, evolved)

```haskell
data SubAgent es i o = SubAgent
  { name     :: Text
  , input    :: JSONCodec i
  , output   :: JSONCodec o
  , system   :: Text
  , tools    :: [Tool (Agents es : es)]   -- CHANGED from [Tool es]
  , maxIters :: Int
  }

subAgent :: Text -> JSONCodec i -> JSONCodec o -> Text -> [Tool (Agents es : es)] -> SubAgent es i o

-- unchanged:
data Agents (es :: [Effect]) :: Effect where
  Spawn :: SubAgent es i o -> i -> Agents es m (Either AgentFailure o)
spawn     :: (Agents es :> r) => SubAgent es i o -> i -> Eff r (Either AgentFailure o)
runAgentsScripted :: Int -> [Text] -> Eff (Agents es : es) a -> Eff es a

-- re-entrant, shared tree budget:
runAgents :: forall es a. (Chat :> es, IOE :> es) => Int -> Eff (Agents es : es) a -> Eff es a
```

### `runAgents` (re-entrant)

```haskell
runAgents cap act = do
  ref <- liftIO (newIORef cap)
  let go :: forall x. Eff (Agents es : es) x -> Eff es x
      go = interpret $ \_ -> \case
        Spawn sub i -> do
          remaining <- liftIO (readIORef ref)
          if remaining <= 0
            then pure (Left (SpawnBudgetExceeded cap))
            else do
              liftIO (writeIORef ref (remaining - 1))
              res <- go (runToolAgentN sub.maxIters sub.tools (workerPrompt sub i))
              pure $ case res of
                Left (ToolLoopExceeded n) -> Left (WorkerLoopExceeded sub.name n)
                Right finalText           -> decodeFinal sub finalText
  go act
```

`go` is used at the top level (`go act`) and recursively on each worker
(`go (runToolAgentN ...)`); `runToolAgentN sub.maxIters sub.tools (...)` has type
`Eff (Agents es : es) (Either ChatError Text)` because `sub.tools :: [Tool (Agents es : es)]`
and `Chat :> es`. A `spawn` from inside one of those tools is an `Agents es`
operation in the worker row, caught by `go`'s `interpret` and serviced against
the shared `ref`. Needs `ScopedTypeVariables` (the `forall es a` on `runAgents`
binds `es` for `go`'s signature) and `RankNTypes` for the local `go`.

### Spike (de-risk first)

Because the re-entrant `go` plus the `tools :: [Tool (Agents es : es)]` GADT is
the one part not verifiable without compiling, the plan's first task compiles
this skeleton and proves a worker spawns a sub-worker hermetically before the
rest is built. If the encoding does not compile as written, the task reports the
exact error before proceeding.

### Gate (`Crucible.Agents/Gate.hs`)

Unchanged code: `spawnGated :: (Agents es :> r, LLM :> r) => Gate o -> SubAgent es i o -> i -> Eff r (...)` still type-checks (it does not touch `tools`). It now composes with nesting: a worker tool can call `spawnGated` when the worker row has `LLM`. Its tests' toolbox annotations update for the new row.

## Demo (`app/Main.hs`)

A coordinator worker that delegates a sub-task to a child worker through a tool.
Define a child `SubAgent` (for example the existing weather worker), and a
coordinator `SubAgent` whose toolbox contains one tool whose handler `spawn`s the
child and returns its result as text. Run
`runEff (Anthropic.runChat cfg (runAgents 6 (spawn coordinator input)))`, print
the coordinator's typed result. Shows a two-level tree, the delegate tool, and
the shared cap live.

## Manual (`docs/subagents.md`)

Rewrite the "one level" framing: workers can spawn sub-workers by carrying a tool
whose handler calls `spawn`; the spawn cap bounds the whole tree (root included),
so a runaway recursion stops at `SpawnBudgetExceeded`. Update the module summary,
the `spawn` note (no longer "cannot spawn"), and remove "nested trees with
tree-wide budgets" from "What is not covered". Keep the typed-handoff and
context-isolation points (they hold at every level). House style: no
emdashes/endashes, no hype words, no manifest mentions.

## Testing (hermetic)

The existing one-level tests keep passing after their toolbox-row annotations are
updated to `[Tool (Agents <row> : <row>)]`. New nesting tests use the live
re-entrant interpreter over a scripted `Chat` (`runEff (runChatScripted [...]
(runAgents cap (spawn root i)))`), with a worker whose toolbox has a delegate
tool that `spawn`s a child:

- **Nesting works:** a root worker whose scripted turn calls the delegate tool,
  whose handler spawns a child whose scripted turn returns a final answer; the
  root's final answer reflects the child's result. Decodes to the expected typed
  output.
- **Shared tree budget:** with `cap = 1`, the root spawn consumes the only slot;
  the delegate tool's `spawn` of the child returns `Left (SpawnBudgetExceeded 1)`,
  which the tool surfaces (the tree is capped as a whole, not per level).
- **One level still works:** a leaf worker (empty toolbox) under `runAgents` over
  a scripted `Chat` returns its decoded answer (regression of the foundation).

The `runAgentsScripted` tests are unchanged (it ignores tools); they continue to
cover top-level orchestration and the spawn cap.

Live: the delegation demo before merge (gated on the Anthropic key).

## Non-goals

- Token-based or per-depth budgets (the unit is total spawn count across the
  tree; tokens/depth are future).
- A distinct depth limit (the spawn cap bounds depth indirectly).
- Concurrent spawn of siblings (still synchronous; a separate interpreter, the
  `crucible-qyc` follow-on).
- A parallel non-breaking nesting type (we evolve `Agents` in place).
- Changing `runAgentsScripted` to simulate tool-driven nesting (nesting is tested
  with the live interpreter over a scripted `Chat`).
