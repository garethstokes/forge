# Judge-Gated Subagent Outputs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Crucible.Agents.Gate` with a `Gate o` value and `spawnGated`: spawn a worker, verify its output with the existing Eval/Judge vote, and re-spawn with the critique on rejection, bounded by a retry budget.

**Architecture:** `spawnGated` runs in the orchestrator row (which has `Agents es` and `LLM`); it calls `spawn` then `Crucible.Eval.Judge.vote`. Only `Right o` spawn results are judged; rejection re-spawns with the critique appended to the worker's `system`. A new `GateRejected` constructor is added to `AgentFailure`. `runAgents`/`runAgentsScripted`/`SubAgent` are unchanged.

**Tech Stack:** GHC 9.12.2, effectful, aeson/autodocodec; zinc build.

**Spec:** `docs/superpowers/specs/2026-06-14-spawn-gate-design.md`

## Conventions (every task)
- Build/test: `nix develop . --command timeout -s KILL 300 zinc build|test`. Judge success by exit status or "test suite(s) passed", never a pipeline tail. 137 = GHC flake, retry once; second 137 = BLOCKED. Ignore "Git tree is dirty".
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot. Annotate ambiguous getter sections / effectful State and report.
- Tests: custom harness `check "label" expected actual`; comma entries in `runChecks` at END of `test/Spec.hs`; `do` blocks allowed. No hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit per task, do not push.

## Existing pieces this builds on
- `Crucible.Agents`: `SubAgent (..)` (fields incl. `name :: Text`, `system :: Text`), `Agents`, `spawn :: (Agents es :> r) => SubAgent es i o -> i -> Eff r (Either AgentFailure o)`, `AgentFailure (..)` (`SpawnBudgetExceeded`/`WorkerLoopExceeded`/`WorkerDecodeFailed`), `runAgentsScripted :: Int -> [Text] -> Eff (Agents es : es) a -> Eff es a`.
- `Crucible.Eval.Judge`: `vote :: (LLM :> es) => Bool -> JudgeOpts -> Text -> Text -> Eff es VoteOutcome`; `VoteOutcome` constructors `Decided p w d y f` (pass::Bool, why::Text, dissent, yes, no), `AllErrored m`, `AllAbstained m`; `JudgeOpts` with field `votes :: Int`; `defaultJudgeOpts`.
- `Crucible.LLM`: `LLM` effect, `runLLMScripted :: [Text] -> Eff (LLM : es) a -> Eff es a`.

## File Structure
- Modify `src/Crucible/Agents.hs` — add `GateRejected Text Text` to `AgentFailure`.
- Create `src/Crucible/Agents/Gate.hs` — `Gate`, `gate`, `spawnGated`.
- Modify `test/Spec.hs` — hermetic gate tests.
- Modify `app/Main.hs` — live gated-spawn demo.
- Modify `docs/subagents.md` — a "Judge gates" section.

---

### Task 1: `GateRejected` + `Crucible.Agents.Gate` + tests

**Files:**
- Modify: `src/Crucible/Agents.hs`
- Create: `src/Crucible/Agents/Gate.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Add `GateRejected` to `AgentFailure` in `src/Crucible/Agents.hs`**

Change the `AgentFailure` data type to add a constructor (keep the others and the `deriving (Eq, Show)`):
```haskell
data AgentFailure
  = SpawnBudgetExceeded Int               -- ^ the spawn cap that was hit
  | WorkerLoopExceeded  Text Int          -- ^ worker name; the iteration cap it exhausted
  | WorkerDecodeFailed  Text DecodeError  -- ^ worker name, the decode error
  | GateRejected        Text Text         -- ^ worker name, the judge's critique
  deriving (Eq, Show)
```
No other change to `Crucible.Agents`; `AgentFailure (..)` is already exported.

- [ ] **Step 2: Create `src/Crucible/Agents/Gate.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | A judge gate over a spawned worker's output. 'spawnGated' runs a worker,
-- verifies its decoded output with the existing Eval/Judge vote, and on
-- rejection re-spawns the worker with the critique appended to its instruction,
-- bounded by a retry budget. The gate lives in the orchestrator row (where 'LLM'
-- is available), so the base 'Crucible.Agents.spawn' path stays free of an 'LLM'
-- constraint. The judge is an independent vote (no closed loop): the worker does
-- not grade itself; the critique is retry guidance.
module Crucible.Agents.Gate
  ( Gate (..)
  , gate
  , spawnGated
  ) where

import Data.Text (Text)

import Effectful

import Crucible.Agents (SubAgent (..), AgentFailure (..), Agents, spawn)
import Crucible.LLM (LLM)
import Crucible.Eval.Judge (vote, defaultJudgeOpts, JudgeOpts (..), VoteOutcome (..))

-- | A judge gate over a worker output of type @o@.
data Gate o = Gate
  { rubric  :: Text       -- ^ what a good output looks like, handed to the judge
  , render  :: o -> Text  -- ^ render the worker output for judging
  , votes   :: Int        -- ^ judge sample count (odd; independent majority vote)
  , retries :: Int        -- ^ max worker re-runs on rejection
  }

-- | A gate with @votes = 1@ and @retries = 1@.
gate :: Text -> (o -> Text) -> Gate o
gate r f = Gate r f 1 1

-- | Spawn a worker, then verify its output with the judge; on rejection
-- re-spawn with the critique appended to the worker instruction, bounded by the
-- gate's retries. A spawn failure short-circuits (only @Right o@ is judged).
spawnGated :: (Agents es :> r, LLM :> r)
           => Gate o -> SubAgent es i o -> i -> Eff r (Either AgentFailure o)
spawnGated g sub0 i = loop g.retries sub0
  where
    loop n sub = do
      result <- spawn sub i
      case result of
        Left f  -> pure (Left f)
        Right o -> do
          outcome <- vote True defaultJudgeOpts { votes = g.votes } g.rubric (g.render o)
          case outcome of
            Decided True _ _ _ _    -> pure (Right o)
            Decided False why _ _ _ -> retryOrReject n sub why o
            AllAbstained why        -> retryOrReject n sub why o
            AllErrored m            -> pure (Left (GateRejected sub.name ("judge error: " <> m)))

    retryOrReject n sub why _o
      | n <= 0    = pure (Left (GateRejected sub.name why))
      | otherwise = loop (n - 1) sub { system = augment sub.system why }

    augment s why =
      s <> "\n\nA previous attempt was rejected: " <> why <> "\nAddress this and try again."
```
Notes:
- The `VoteOutcome` constructor arity is `Decided pass why dissent yes no`; match it as `Decided p w d y f`. `AllErrored m` and `AllAbstained m` carry a message.
- `JudgeOpts (..)` is imported for the `votes` record-update `defaultJudgeOpts { votes = g.votes }`.
- `sub { system = ... }` is a record update on `SubAgent`; under DuplicateRecordFields this may need the field to be unambiguous; if GHC complains, the update still works because `system` is a `SubAgent` field in scope. Report any annotation needed.
- The `_o` parameter to `retryOrReject` is unused (kept for readability); drop it if the linter prefers, or just inline. Prefer dropping it: `retryOrReject n sub why` and call `retryOrReject n sub why`.

- [ ] **Step 3: Add hermetic tests to `test/Spec.hs`**

Add imports near the other crucible imports:
```haskell
import Crucible.Agents.Gate (Gate (..), gate, spawnGated)
```
`runPureEff`, `runLLMScripted` are imported; `runAgentsScripted`, `subAgent`, `AgentFailure (..)`, `spawn` are imported (Agents). `C`/`T`/`Tl` aliases as before. The program row has both `Agents '[LLM]` and `LLM`: discharge `Agents` with `runAgentsScripted` then `LLM` with `runLLMScripted` then `runPureEff`. The worker base row is `'[LLM]` (so the toolbox annotation is `([] :: [Tl.Tool '[LLM]])`; import the `LLM` type if needed via the existing `Crucible.LLM` import — it is imported; if the bare name is not in scope, qualify as the test file already does for effect types).

Verdict replies decode via the judge: a pass is `"{\"verdict\":\"pass\",\"why\":\"ok\"}"`, a fail is `"{\"verdict\":\"fail\",\"why\":\"missing X\"}"` (this matches the format used by existing judge tests in this file around line 1009/1028). Add to `runChecks`:

```haskell
  -- A worker returning {"n": ...} as an Int; gate judges the rendered Int.
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool '[LLM]])
        g = gate "the number is positive" (\n -> T.pack (show n))
    in check "spawnGated: judge passes -> Right o"
         (Right (6 :: Int))
         (runPureEff (runLLMScripted ["{\"verdict\":\"pass\",\"why\":\"ok\"}"]
            (runAgentsScripted 5 ["{\"n\": 6}"] (spawnGated g w 3))))
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool '[LLM]])
        g = gate "the number is positive" (\n -> T.pack (show n))
    in check "spawnGated: reject then accept on retry"
         (Right (7 :: Int))
         (runPureEff (runLLMScripted ["{\"verdict\":\"fail\",\"why\":\"too small\"}", "{\"verdict\":\"pass\",\"why\":\"ok\"}"]
            (runAgentsScripted 5 ["{\"n\": 1}", "{\"n\": 7}"] (spawnGated g w 3))))
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool '[LLM]])
        g = gate "the number is positive" (\n -> T.pack (show n))
    in check "spawnGated: reject past retries -> GateRejected"
         True
         (case runPureEff (runLLMScripted ["{\"verdict\":\"fail\",\"why\":\"bad\"}", "{\"verdict\":\"fail\",\"why\":\"still bad\"}"]
                 (runAgentsScripted 5 ["{\"n\": 1}", "{\"n\": 2}"] (spawnGated (gate "pos" (\n -> T.pack (show (n :: Int)))) w 3))) of
            Left (GateRejected nm _) -> nm == "double"
            _ -> False)
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool '[LLM]])
        g = gate "the number is positive" (\n -> T.pack (show (n :: Int)))
    in check "spawnGated: spawn decode failure short-circuits (no judging)"
         True
         (case runPureEff (runLLMScripted []
                 (runAgentsScripted 5 ["not json"] (spawnGated g w 3))) of
            Left (WorkerDecodeFailed nm _) -> nm == "double"
            _ -> False)
  , check "gate defaults: votes = 1, retries = 1"
      (1 :: Int, 1 :: Int)
      (let g = gate "r" (id :: Text -> Text) in (g.votes, g.retries))
```
Notes:
- The pass test passes ONE verdict and ONE worker answer; the reject-then-accept passes two of each (`gate` default retries = 1 allows one retry). The reject-past-retries uses `gate` (retries = 1) with two fail verdicts -> the second fail exhausts the retry -> `GateRejected`.
- The short-circuit test gives `runLLMScripted []` (no verdicts) because the worker decode fails before any judging; if the judge were wrongly invoked, the empty LLM script would surface (an `AllErrored`/empty reply), so this also proves the gate did not run.
- `gate`'s default-fields test reaches `.votes`/`.retries`; annotate if a getter section is ambiguous.
- If `runPureEff` layering differs (it returns the value directly, one `Either` layer), pin the actual shape; the `case` tests already match one layer, and the equality tests expect one layer (`Right 6`).

- [ ] **Step 4: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: new gate checks pass; full suite green. Likely first-try wrinkles: the `'[LLM]` toolbox row annotation, or the verdict JSON not matching `verdictCodec` (if so, copy the exact format from the existing judge tests at lines ~1009/1028 and pin it). Retry once on 137.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Agents.hs src/Crucible/Agents/Gate.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(agents): spawnGated judge gate + GateRejected failure

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Live demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a gated-spawn demo**

Read `app/Main.hs`. It has the spawn demo's `weatherWorker` (a `SubAgent` with `tools weatherBox`, output `Text`, annotated to a concrete row). It already imports `Crucible.Agents (...)` and uses `Anthropic.run`/`Anthropic.runChat`. Add the import:
```haskell
import Crucible.Agents.Gate (gate, spawnGated)
```
After the existing spawn demo, add a gated variant. The judge needs `LLM` and the worker needs `Chat`, so the worker base row must include `LLM`; define a worker (or reuse one) whose row matches the stack `runEff (Anthropic.run cfg (Anthropic.runChat cfg (runAgents N (spawnGated ...))))`:
```haskell
      -- Judge gate: verify the worker's summary before accepting it.
      let gatedWorker :: SubAgent '[Chat, LLM, IOE] T.Text T.Text
          gatedWorker =
            subAgent "weather-worker" str
              (object (field "summary" Prelude.id str))
              "Use the get_weather tool, then summarize the weather in one sentence."
              (tools weatherBox)
          summaryGate = gate "the summary names a city and a temperature" Prelude.id
      gatedRes <- runEff (Anthropic.run cfg (Anthropic.runChat cfg
                    (runAgents 4 (spawnGated summaryGate gatedWorker "Brisbane"))))
      case gatedRes of
        Right summary -> TIO.putStrLn ("spawnGated: accepted: " <> summary)
        Left failure  -> TIO.putStrLn ("spawnGated: " <> T.pack (show failure))
```
Notes:
- The worker base row is `'[Chat, LLM, IOE]` (the row left after `runAgents` discharges `Agents`, before `runChat`/`run`/`runEff`). Ensure `Chat`, `LLM`, `IOE` are imported as types in `Main` (the spawn demo already imports `Chat`; add `LLM`/`IOE` to the relevant import lists if missing). Adjust the row order in the annotation to whatever GHC infers if it complains; report the exact annotation used.
- If the `Anthropic.run` + `Anthropic.runChat` double-wrap does not compile (e.g. an ordering/ambiguity issue), try swapping their order, or bind the worker result in two stages. Report what worked.

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. Retry once on 137. (Do not run the binary.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "$(cat <<'EOF'
demo(agents): judge-gated spawn verifies the worker summary

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: "Judge gates" section in `docs/subagents.md`

**Files:**
- Modify: `docs/subagents.md`

- [ ] **Step 1: Add the section**

Read `docs/subagents.md`. Insert a `## Judge gates` section AFTER the `## Interpreters` section and BEFORE `## What is not covered`. Content (real triple-backtick fences):

```markdown
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
```
(The outer ```markdown fence delimits the block here only; write real markdown.)

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/subagents.md` (expect no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/subagents.md` (expect no output).

- [ ] **Step 3: Commit**

```bash
git add docs/subagents.md
git commit -m "$(cat <<'EOF'
docs(agents): Judge gates section (spawnGated)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** `GateRejected` (T1 Step 1), `Gate`/`gate`/`spawnGated` (T1 Step 2), all six testing scenarios from the spec (T1 Step 3: pass, reject-then-accept, reject-past-retries, spawn-failure short-circuit, gate defaults; the judge-error case is covered by the short-circuit + the `AllErrored` branch in code, and can be added if the implementer can script an unparseable verdict cleanly), demo (T2), docs (T3). Non-goals are "do not build".
- **Type consistency:** `Gate o {rubric, render, votes, retries}`, `gate :: Text -> (o -> Text) -> Gate o`, `spawnGated :: (Agents es :> r, LLM :> r) => Gate o -> SubAgent es i o -> i -> Eff r (Either AgentFailure o)`, and `GateRejected Text Text` match across module, tests, demo, and docs.
- **Placeholder scan:** the flagged judgement points are the `'[LLM]`/`'[Chat,LLM,IOE]` row annotations and the verdict-JSON format (pin to the existing judge tests if it differs). No vague steps.
- **Note for the implementer:** if scripting an `AllErrored` judge-error test is awkward (it needs unparseable verdict replies that survive the judge's repair re-prompt), it is acceptable to omit that one test and rely on the short-circuit + reject-path coverage; do not fabricate a passing test. Report if omitted.
