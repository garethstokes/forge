# Judge-Gated Subagent Outputs Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-d57` (follow-on to `crucible-pch`, Spawn; from `docs/superpowers/research/2026-06-11-multi-agent-harnesses.md` rec 3).
**Goal:** Verify a subagent's output with the existing Eval/Judge machinery before accepting it, with bounded worker retry on rejection.

**Scope:** new `src/Crucible/Agents/Gate.hs`; `src/Crucible/Agents.hs` (add the `GateRejected` constructor to `AgentFailure`); `test/Spec.hs`; `app/Main.hs`; `docs/subagents.md` (a "Judge gates" section). No change to `runAgents`, `runAgentsScripted`, or `SubAgent`.

## Motivation

A spawned worker hands back a typed value, but typed does not mean correct: MAST
finds 21.3% of multi-agent failures are missing verification. crucible already
has independent LLM-as-judge voting (`Crucible.Eval.Judge.vote`). A gate runs
that judge over a worker's decoded output and, on rejection, re-runs the worker
with the critique, bounded by a retry budget. The gate lives at the
orchestration level (a `spawnGated` call), not on `SubAgent` or inside
`runAgents`, so the base spawn path stays free of an `LLM` constraint and gating
is opt-in per call.

## Decisions taken during design

- **Orchestration-level, not a SubAgent field.** `spawnGated` is a function in
  the orchestrator row, where `LLM` is available for the judge; `runAgents`,
  `runAgentsScripted`, and `SubAgent` are untouched. The research's illustrative
  `gated :: SubAgent -> SubAgent` is expressed as a spawn-time combinator
  instead, which avoids forcing `LLM :> es` onto every (gated or not) spawn.
- **Only results are judged.** A spawn failure (`WorkerLoopExceeded`,
  `WorkerDecodeFailed`, `SpawnBudgetExceeded`) short-circuits and is returned
  unchanged; the gate judges only an actual `Right o`.
- **Retry feeds the critique back to the worker.** On rejection, the worker is
  re-spawned with the judge's critique appended to its `system` instruction
  (a pure transformation of the `SubAgent`), bounded by the gate's `retries`,
  mirroring `Skill`'s decode-retry shape.
- **No closed loop.** The judge is a separate `vote` call (an independent
  n-sample majority), not the worker grading itself; the critique is retry
  guidance, not a self-grade. This honors the reasoning-trap rule.
- **Judge malfunction does not re-run the worker.** `AllErrored` (the judge
  itself failed) returns `GateRejected` immediately; re-running the worker
  cannot fix a broken judge. `Decided False` and `AllAbstained` consume a retry.

## Design (`Crucible.Agents.Gate`)

```haskell
-- Added to AgentFailure in Crucible.Agents (re-exported):
--   | GateRejected Text Text   -- ^ worker name, the judge's critique

-- | A judge gate over a worker's output.
data Gate o = Gate
  { rubric  :: Text       -- ^ what a good output looks like, handed to the judge
  , render  :: o -> Text  -- ^ render the worker output for judging
  , votes   :: Int        -- ^ judge sample count (odd; independent majority vote)
  , retries :: Int        -- ^ max worker re-runs on rejection
  }

-- | A gate with @votes = 1@ and @retries = 1@.
gate :: Text -> (o -> Text) -> Gate o

-- | Spawn a worker, then verify its output with the judge; on rejection
-- re-spawn with the critique, bounded by the gate's retries.
spawnGated :: (Agents es :> r, LLM :> r)
           => Gate o -> SubAgent es i o -> i -> Eff r (Either AgentFailure o)
```

### `spawnGated` semantics

A loop carrying the remaining retry count and the (possibly critique-augmented)
subagent:

1. `r <- spawn sub i`. If `r` is `Left f`, return `Left f` (spawn failures are
   not judged).
2. `Right o`: judge with
   `vote True defaultJudgeOpts { votes = g.votes } g.rubric (g.render o)`,
   yielding a `VoteOutcome`.
3. Dispatch the outcome:
   - `Decided True _ _ _ _` -> `Right o`.
   - `Decided False why _ _ _` or `AllAbstained why` -> if retries remain,
     re-spawn with `sub { system = augment sub.system why }` and
     `retries - 1`; else `Left (GateRejected sub.name why)`.
   - `AllErrored m` -> `Left (GateRejected sub.name ("judge error: " <> m))`
     (no worker retry).

`augment s why = s <> "\n\nA previous attempt was rejected: " <> why <> "\nAddress this and try again."`

The judge runs in the orchestrator row `r` (which has `LLM`); the worker runs
through `spawn` (the `Agents` effect). The two are independent calls.

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block, reuse the weather-worker `SubAgent` from the
spawn demo. Define `gate "the summary names a city and a temperature" Prelude.id`
(the worker output is `Text`), then
`runEff (Anthropic.run cfg (Anthropic.runChat cfg (runAgents 4 (spawnGated g weatherWorker "Brisbane"))))`
and print the accepted summary or the `GateRejected` critique. (The judge needs
`LLM` via `Anthropic.run`; the worker needs `Chat` via `Anthropic.runChat`; both
discharge under `runEff`.) Note: confirm the live effect-stack ordering compiles;
if `Anthropic.run` and `Anthropic.runChat` cannot both wrap the same program in
`Main`, fall back to a single-skill judge already wired (the plan resolves the
exact stacking).

## Manual (`docs/subagents.md`)

A "Judge gates" section: the `Gate o` value and `gate`; `spawnGated` (judge the
worker output, re-spawn with critique on rejection, bounded retries); that only
`Right o` results are judged; that the judge is an independent vote (no closed
loop); the `GateRejected` failure; and that gating is opt-in per spawn (the base
`spawn` is ungated). House style: no emdashes/endashes, no hype words, no
manifest mentions.

## Testing (hermetic)

Compose `runAgentsScripted` (canned worker answers) with `runLLMScripted`
(canned judge verdict replies, JSON decoded by `verdictCodec`). The program row
has both `Agents es` and `LLM`.

- **Pass first try:** one worker answer, one `pass` verdict -> `Right o`, and the
  second worker answer (if any) is not consumed.
- **Reject then accept:** a `fail` verdict, a second worker answer, a `pass`
  verdict -> `Right o` after one retry (gate `retries = 1`).
- **Reject past retries:** `retries = 1`, two `fail` verdicts -> `Left (GateRejected name why)`.
- **Spawn failure short-circuits:** the worker answer fails the output codec ->
  `Left (WorkerDecodeFailed ...)`, and no judge verdict is consumed.
- **Judge error:** a judge reply that does not parse as a verdict (an
  `AllErrored` vote) -> `Left (GateRejected name "judge error: ...")` with no
  second worker spawn consumed.
- **`gate` defaults:** `(gate r f).votes == 1` and `.retries == 1`.

Live: the demo gated spawn before merge (gated on the Anthropic key).

## Non-goals

- Cross-model judge panels for gates (single-row n-sample `vote` here;
  `Crucible.Eval.Judge.votePanel` is a future extension).
- Gating spawn failures (only `Right o` is judged).
- Pure-predicate gates (use the codec `refine` on the worker output codec).
- A gate stored on `SubAgent` or honored by `runAgents` (the gate is a
  spawn-time combinator).
- Per-criterion checklist gates (the gate is a single rubric vote; a checklist
  variant could follow).
