# Eval Orchestrator — Run Execution (sub-project C) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-10

**Goal:** Execute an eval run: load a queued `Run`, call the model for each of its
examples (through `crucible`), and persist one `Output` row per example, updating the run
status. The execution engine; **scoring is deferred** to a later sub-project.

---

## 0. Context

Sub-project A (the data model) is built (`examples/manifest-evals/`). C produces the
`Output` rows that a later scoring sub-project will grade. The model-calling substrate is
**crucible** (the sibling project): a typed LLM-agent layer on `effectful` that already
provides model calls with retries/backoff/timeout, plus deterministic test handlers. C is
the **orchestration + persistence bridge** between crucible (model calls) and Manifest
(the run/output schema). No HTTP, retry, or provider code of our own.

Earlier decisions: execution is an **in-process async** engine (the CLI triggers it now;
B's web layer hosts the same `executeRun` later). The model handler is crucible's. Prompt
assembly is **system-prompt + input-as-messages**. **Scoring (graders/scores) is entirely
out of scope here** — C writes outputs only.

---

## 1. Crucible integration

The eval package gains a dependency on `crucible` (git-pinned sibling repo). The relevant
crucible API:

- `Crucible.LLM`: `data Message = Message { role :: Role, content :: Text }`,
  `Role = System | User | Assistant | Tool`,
  `complete :: (LLM :> es) => [Message] -> Eff es Text`,
  `runLLMScripted :: [Text] -> Eff (LLM : es) a -> Eff es a` (the deterministic test handler).
- `Crucible.LLM.Anthropic`: the live handler (`runLLMAnthropic` / a usage-returning variant),
  `AnthropicConfig { acApiKey, acModel, acMaxTokens, acTimeoutSecs, acMaxRetries,
  acBaseDelayMicros, acStreamIdleSecs }`, `defaultAnthropicConfig :: Text -> AnthropicConfig`,
  and `runLLMCassette` (record/replay).
- `Crucible.Usage`: `Usage`, `usTotalTokens`.
- `runEff` from `Effectful`.

Retries, backoff, timeouts, and streaming are crucible's concern, configured per run from
the `TargetVersion`.

## 2. The LLM backend, injected (`LlmRunner`)

The model backend is injected so `executeRun` is testable with no network. A backend turns
a target version + messages into a result:

```haskell
data ExecError = LlmError Text | InputDecodeError Text deriving (Show)

type LlmRunner = TargetVersion -> [Message] -> IO (Either ExecError (Text, Usage))

-- Live: builds an AnthropicConfig from the target's model/params, runs crucible, catches errors.
liveAnthropicRunner :: Text {- ANTHROPIC_API_KEY -} -> LlmRunner
-- liveAnthropicRunner key tv msgs =
--   try (runEff . <usage-handler> (cfgFrom key tv) $ complete msgs) >>= \case
--     Right (t, u) -> pure (Right (t, u)); Left e -> pure (Left (LlmError (T.pack (show e))))

-- Test: ignores the target, replies from a scripted list (cycling), no network.
scriptedRunner :: [Text] -> LlmRunner
-- scriptedRunner replies _ msgs = Right . (, mempty) <$> (runEff . runLLMScripted replies $ complete msgs)
```

`cfgFrom key tv` maps `tv.model` → `acModel`, and the known fields of `tv.params` (jsonb:
`max_tokens`, `temperature`, `timeout`, `retries`) → the matching `AnthropicConfig` fields,
falling back to `defaultAnthropicConfig`.

## 3. Prompt assembly (`TargetVersion` + `Example` → `[Message]`)

```haskell
assembleMessages :: TargetVersion -> Example -> Either ExecError [Message]
assembleMessages tv ex = (Message System tv.prompt :) <$> decodeInput ex.input

-- Example.input is `Aeson Value`:
--   a JSON string         -> [Message User <that string>]
--   {"messages":[{role,content}...]} -> those messages (role parsed: system/user/assistant)
--   anything else         -> Left (InputDecodeError ...)
decodeInput :: Value -> Either ExecError [Message]
```

The target's `prompt` is the system message verbatim; the example carries the
conversation. Multi-turn is supported via the `{"messages":[…]}` form.

## 4. The executor

```haskell
data RunOutcome = RunOutcome { roTotal :: Int, roSucceeded :: Int, roErrored :: Int, roSkipped :: Int }

executeRun :: Pool -> Int {- concurrency -} -> LlmRunner -> RunId -> IO RunOutcome
```

Flow:

1. `withSession pool`: load the `Run`; its `TargetVersion`; its `DatasetVersion`'s
   `Example`s; and the set of `Example` ids that ALREADY have an `Output` for this run
   (for resume). If the run or target can't be loaded, set `status = failed` and return.
   Set `status = running`, `startedAt = now`.
2. For each `Example` NOT already done (bounded-concurrent at the given limit, via
   `Control.Concurrent.Async` + a `QSem`): assemble messages; if assembly fails, that is a
   per-example error; otherwise time the `LlmRunner` call. Then `withSession pool` write one
   `Output`:
   - success `(text, usage)` → `Output { run, example, text = Just text,
     tokens = Just (Aeson (toJSON usage)), latencyMs = Just ms, error = Nothing,
     response = Nothing }`
   - `Left err` → `Output { …, text = Nothing, error = Just (render err), latencyMs = Just ms }`
   (`response` (raw jsonb) is left `Nothing`: crucible's `complete` returns `Text`, not the
   raw provider envelope.)
3. `withSession pool`: set `status = succeeded`, `finishedAt = now`. Tally the outcome.

**Failure is per-example.** A model error or input-decode error is recorded on that
`Output` and the run continues; the run finishes `succeeded`. The run only goes `failed`
for a setup failure (run/target not loadable). **Resume:** examples with an existing
`Output` for the run are skipped, so a re-run after a crash continues and never duplicates
outputs.

The two effect worlds meet at IO: Manifest `Db` via `withSession pool`; crucible `Eff` via
`runEff . <handler> $ complete msgs` inside the `LlmRunner`. No shared monad.

## 5. Trigger — CLI

A new exe target in the eval package, `manifest-evals`, with subcommands:

- `manifest-evals migrate` — stand up / reconcile the schema (`migrateUp schema`).
- `manifest-evals run <runId>` — build the `Pool` + the live `LlmRunner` (API key from
  `ANTHROPIC_API_KEY`, concurrency from `--concurrency`/env), call `executeRun`, print the
  `RunOutcome`.

Config (Postgres URL via `MANIFEST_DATABASE_URL`, API key, concurrency) comes from
env/flags. B's web layer will later call `executeRun` directly with its own pool.

## 6. Dependency (the gating risk)

The eval package would depend on **both** `manifest` (workspace-local) **and** `crucible`
(git-pinned). Both pull `autodocodec`/`aeson`; crucible also pulls `effectful` and
`http-client-tls`. Their closures must resolve to one consistent version set under zinc's
single lock.

**The plan must verify `zinc add crucible` (or the equivalent git-pin) resolves and the
eval package builds against both `manifest` and `crucible` FIRST**, before any executor
code — the established gating pattern. If the closures conflict (e.g. divergent
`autodocodec` revs), reconcile the pins or reassess before proceeding.

## 7. Scope & testing

**In scope:** §2 the injected `LlmRunner` (live + scripted), §3 prompt assembly, §4
`executeRun` (load → assemble → call → write `Output` → status, bounded-async, per-example
error, resume), §5 the CLI exe.

**Testing** (deterministic, no network, via `scriptedRunner` + `Manifest.Testing.withEphemeralDb`):

- a run over N examples executes: N `Output` rows written, each with the scripted `text`;
  the run transitions `queued → running → succeeded`;
- a scripted error (or an undecodable input) for one example records `Output.error` and
  the run still finishes `succeeded` with the other outputs present;
- multi-turn input (`{"messages":[…]}`) assembles correctly (assert the messages the runner
  received, via a recording test runner that captures its `[Message]` argument);
- resume: pre-insert an `Output` for one example, run, assert that example is skipped (not
  duplicated) and the rest are produced;
- the system prompt is prepended (the recording runner sees `Message System target.prompt`
  first).

**Out of scope:** ALL scoring (graders / `Score` / score-derived `RunMetric`) — the next
sub-project; the web UI (B); live progress push (D); streaming; raw-response capture; full
crash-recovery of interrupted `running` runs (only the output-skip resume); the background
poller / claim-locking (the engine is built; B or a later worker drives it).
