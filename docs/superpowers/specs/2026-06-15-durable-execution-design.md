# Durable Execution Substrate Design Spec

**Date:** 2026-06-15
**Status:** Draft design — pending review
**Tracker:** `crucible-w0k` (epic). Phases: `crucible-9t3` (0), `crucible-03x` (1), `crucible-7mt` (2), `crucible-ymd` (3).
**Goal:** A durable execution substrate on crucible. A *workflow* is a
deterministic `Eff` program whose effectful operations are journaled; one
journal abstraction serves three execution modes — **live/record**,
**replay-to-resume** (crash recovery), and **replay-to-eval** (the eval
flywheel) — distinguished by two knobs: a per-effect replay *mode* and a
*miss policy*. Adds a worker/runtime, durable orchestration primitives
(timers, signals, child workflows, retries), and incremental durability of
in-flight progress, backed by manifest/Postgres.

**Scope:** new effect + interpreter machinery in crucible (`Crucible.Workflow`,
journaling combinators, journal codec/keying, `MissPolicy`); new durable store
in manifest (schema + migrations + queries for executions, journal entries,
run queue, signals); a new worker/runtime package; an app-owned domain
`Environment` effect pattern (Sparky); and manifest-evals as the eval-mode
consumer. Cross-cutting; delivered in phases (see "Phasing").

---

## Motivation

This design fell out of an eval-flywheel investigation, and the lineage matters
because it explains the shape.

We wanted four things for **manifest-evals**: grade a production turn, promote
interesting turns into an offline dataset, reduce a turn to its simplest
reproduction, and track a metric across offline runs and live prod. All four
require re-running a *captured* agent turn against *changed* code. An agent turn
is not data — it is **data plus an environment**: the turn only has meaning
relative to how its tools behaved. So a captured turn is an input plus a
recording of the I/O its tools produced, and re-running it means replaying that
recording into new code.

Designing that recording/replay seam, we arrived at: a domain effect whose
operations are journaled, with swappable interpreters — *live*, *record*, and
*replay* — where replay serves recorded results so the surrounding code re-runs
deterministically. At which point the shape was unmistakable: **this is the
replay core of a durable execution engine** (Temporal, Restate, DBOS, Cadence).
The cassette is an event history; the effect boundary is an activity; "route I/O
through the effect so it can be recorded" is the determinism sandbox; a replay
"miss" is a non-determinism / history-divergence error. The canonical way
durable execution is *implemented* is exactly effect-handlers swapped between
live and replay — which is crucible's native idiom.

Having recognised that, the decision is to build the **whole substrate**, not
just the eval-replay slice: worker/runtime, orchestration, and durability of
in-flight progress. The eval flywheel then becomes one *mode* of the same
machine — durable execution's replay path pointed at *changed* code instead of
*recovered* code.

The one inversion to keep in view throughout: durable execution replays to get
the **same** result (determinism is sacred; divergence is fatal). Eval replays
to get a **different** result (we changed the code on purpose; divergence is the
*signal* we measure). Same journal, same replay interpreter — the difference is
the miss policy and whether we continue past the journal's head.

---

## The core thesis: one journal, three modes

A workflow is an `Eff` program whose effectful operations are recorded to a
**journal** (the cassette / event history). The same journal + the same
journaling interpreter run in three modes, set by two knobs per run:

| Mode | Per-effect mode | Miss policy | Stop at head? | Purpose |
|------|-----------------|-------------|---------------|---------|
| **Live / record** | live (execute) + append | n/a | no — run to completion | production execution; the journal is written |
| **Replay-to-resume** | replay to head, then live | `Fail` (strict — divergence is a bug) | no — continue past head | crash recovery; rebuild in-flight state, continue |
| **Replay-to-eval** | per-effect: replay *or* live | `Signal` (divergence is the measurement) | yes — replay only | the eval flywheel; re-run changed code against the recording |

Two observations carry the whole design:

1. **Capture and durability are the same write.** A production workflow running
   in live/record mode *is* the capture path for evals. There is no separate
   "instrument for evals" step — the journal you persist for crash recovery is
   the journal you lift into a dataset.

2. **The replay mode is per-effect, not global.** In replay-to-eval for a
   *prompt* change, you want to re-run the **model live** (the prompt changed!)
   but **replay the tools** (their world is gone). In replay-to-resume you
   replay *everything*, model included. So each effect in the row gets its own
   mode at the call site — `LLM` live, `Environment` replay — which is the
   per-tool policy from the eval investigation, generalised to per-effect.

---

## Architecture & layering

The substrate splits cleanly across the existing repos. Each layer owns one
thing and knows nothing of the layers' domains.

```
 crucible        ── the SUBSTRATE (domain-agnostic, no storage):
                    • Crucible.Workflow effect: durable orchestration primitives
                      (durableSleep, awaitSignal, executeChild, now, newId, retry)
                    • the journaling combinator: turn ANY effect into a
                      recorded/replayed one, given a per-op codec
                    • Journal type + keying/normalization + MissPolicy
                    ✗ defines NO domain effect, owns NO storage, runs NO worker

 manifest        ── the durable STORE (Postgres: schema, migrations, queries):
                    • workflow_execution, journal_entry, run_queue, signal tables
                    • transactional append + queue transition (one txn)
                    • claim-with-lease (reuse the Ledger CAS-claim pattern)

 worker/runtime  ── the ENGINE (new package, e.g. crucible-worker):
                    • poll run_queue → claim (CAS+lease) → run program under the
                      journaling interpreter backed by manifest → heartbeat
                    • recover orphaned executions: replay-to-resume from journal
                    • fire due timers, deliver signals, spawn children

 app (Sparky)    ── the DOMAIN (per the decision: domain-specific, app-owned):
                    • its Environment effect + ops (LookupTwin, RunPowershell…)
                    • live / record / replay interpreters built FROM crucible prims
                    • per-op codecs (key + result (de)serialization)
                    • buildTurn :: RawContext -> Eff (Environment : LLM : …) Output

 manifest-evals  ── the EVAL-MODE consumer (domain-agnostic):
                    • stores a workflow_execution's journal as an Example (opaque)
                    • injects the app's { buildTurn, runEnvironmentReplaying }
                      (same DI move as the existing injected LlmRunner)
                    • runs replay-to-eval, grades (reference-free), tracks
```

The reusable artifact that crosses every layer is the **journal**. crucible owns
its *format*; the app owns *what goes in it* (domain ops + codecs); manifest
*persists* it; manifest-evals *shuttles it opaque* into the eval path. Nobody
but the app needs the domain types.

This mapping is not incidental — it is the existing repo division. manifest is
already "schema, migrations, queries over Postgres"; crucible is already
"effectful capabilities with swappable interpreters." Durable execution is the
two composed, which is why it fits.

---

## Component: the Journal

The journal is a **keyed** store of entries (not a positional log) plus
identity metadata:

```haskell
data Journal = Journal
  { jIdentity :: JournalIdentity          -- portability: who/what/when/version
  , jEntries  :: Map CassetteKey Entry     -- keyed by (opName, normalizedArgs)
  }

data JournalIdentity = JournalIdentity
  { jiWorkflowType :: Text
  , jiInput        :: ByteString           -- the raw input, re-runnable
  , jiAppVersion   :: Text                  -- git sha of the app at capture
  , jiCapturedAt   :: UTCTime
  }

data Entry = Entry
  { eSeq     :: Int                         -- order, for resume + audit
  , eResult  :: ByteString                  -- encoded op result
  , eMeta    :: EntryMeta                   -- attempt count, timing, effect name
  }

newtype CassetteKey = CassetteKey ByteString
```

Two decisions baked in here, both consequences of earlier reasoning:

- **Keyed, not positional.** Temporal-style histories key entries by sequence
  position, which is exactly why *workflow versioning* (changing code against an
  existing history) is the hardest, most-complained-about problem in durable
  execution. Our entire eval use case *is* "change the code against an existing
  history," so we cannot inherit that. Keying by domain-level
  `(opName, normalizedArgs)` lets entries be served out of order, makes a code
  change a *localized miss* rather than a cascading desync, and makes divergence
  observable per-op. Domain-level ops make these keys naturally stable.

- **Portable.** A Temporal/Restate history is bound to one workflow definition
  in one running engine — never meant to be lifted elsewhere. Ours must travel:
  prod worker → manifest/Postgres → manifest-evals (a different process, a later
  time, *changed* code). `JournalIdentity` carries everything needed to re-run
  the workflow from scratch, so the journal doubles as a **portable test
  fixture**. This portability is the property that lets one artifact serve both
  resume-in-place and eval-elsewhere.

### Keying & normalization (the real engineering work)

A `CassetteKey` is a hash of `(opName, normalizedArgs)`. *Normalization* strips
volatile fields — auth headers, request-ids, timestamps, nonces — so replays
don't spuriously miss. This is exactly VCR's "request matchers," and it is
per-op config supplied by the app (since the app owns the ops). crucible
provides the hashing + a normalization hook; the app decides what's volatile.
Budget for this — it is where replay systems live or die.

---

## Component: the journaling combinator (crucible)

crucible does **not** ship domain effects or a `Recordable` typeclass. It ships
a small set of primitives, and the app writes its interpreters by hand
(pattern-matching constructors, as Effectful interpreters do anyway). The
per-op codec lives inline in the app's interpreter:

```haskell
-- crucible provides:
data MissPolicy = Fail | Signal | Fallthrough | Fake

-- serve an op from the journal under a mode + policy; `live` is the
-- fallthrough action (used by Fallthrough, and by replay-to-resume past head).
replay :: (IOE :> es)
       => Journal -> MissPolicy -> CassetteKey
       -> (ByteString -> a)        -- decode
       -> Eff es a                 -- live fallthrough
       -> Eff es (a, Maybe Divergence)

-- run an op live and append its encoded result to the sink.
record :: (IOE :> es)
       => JournalSink -> CassetteKey -> (a -> ByteString)
       -> Eff es a -> Eff es a

key :: Text -> NormalizedArgs -> CassetteKey
```

The app's interpreter trio (≈10 lines each) is then:

```haskell
-- app (Sparky): the domain effect
data Environment :: Effect where
  LookupTwin    :: MachineId -> Environment m Twin
  RunPowershell :: Text      -> Environment m PSResult
type instance DispatchOf Environment = Dynamic

runEnvironmentLive       = interpret $ \_ -> \case
  LookupTwin mid  -> liftIO (realLookupTwin mid)
  RunPowershell c -> liftIO (realRunPowershell c)

runEnvironmentRecording sink = interpret $ \_ -> \case
  LookupTwin mid  -> record sink (key "LookupTwin" (norm mid)) encodeTwin (liftIO (realLookupTwin mid))
  RunPowershell c -> record sink (key "RunPowershell" (norm c)) encodePS  (liftIO (realRunPowershell c))

runEnvironmentReplaying j pol = interpret $ \_ -> \case
  LookupTwin mid  -> fst <$> replay j pol (key "LookupTwin" (norm mid)) decodeTwin (liftIO (realLookupTwin mid))
  RunPowershell c -> fst <$> replay j pol (key "RunPowershell" (norm c)) decodePS  (throwIO NotReplayable)
```

`run_powershell_cmd` shows the spectrum: inherently stateful, it has no live
fallthrough — its only valid environment is a frozen output cassette. The app
encodes that by throwing on a replay miss. A tool like `LookupTwin`, recorded at
a *domain* boundary, can fall through to live (re-record) or run new logic over
a replayed *inner* result (record one level deeper — at the API/DB call inside
the tool — so the tool's own logic re-runs). Depth of recording is a per-op app
decision; crucible is indifferent to it.

> **The model is a journaled activity too.** crucible's own `LLM` effect is
> wrapped by the same combinator. In replay-to-resume, model responses are
> replayed (determinism). In replay-to-eval of a *prompt* change, `LLM` runs in
> **live** mode while `Environment` runs in **replay** mode — the per-effect
> knob in action. This is the single most important consequence of "mode is
> per-effect."

---

## Component: the Workflow effect (crucible, orchestration)

Domain ops are *activities* (journaled via the combinator above). The
orchestration primitives that are **not** domain-specific live in a
crucible-owned effect — the determinism sandbox. A workflow obtains all
non-determinism through these, so it is fully replayable:

```haskell
data Workflow :: Effect where
  Activity     :: ActivityId -> IO a -> Workflow m a   -- a one-shot journaled effect
  DurableSleep :: Duration -> Workflow m ()            -- journaled timer
  AwaitSignal  :: SignalKey -> Workflow m ByteString   -- block on external append
  ExecuteChild :: ChildSpec -> Workflow m a            -- child workflow, journaled result
  Retry        :: RetryPolicy -> Workflow m a -> Workflow m a
  Now          :: Workflow m UTCTime                   -- journaled clock
  NewId        :: Workflow m UUID                       -- journaled randomness
type instance DispatchOf Workflow = Dynamic
```

Each primitive is journaled by the same machinery: a timer records "wake at T"
and the worker requeues the execution then; a signal is an external journal
append that unblocks `AwaitSignal`; a child enqueues a new execution whose
result is journaled into the parent; `Retry` journals attempt counts and
backoff. `Now`/`NewId` journal their values so replay reproduces them — the
classic determinism requirement.

---

## Component: the worker/runtime (new package)

A process (or N of them) that turns persisted executions into progress:

1. **Poll** `run_queue` for ready executions: freshly enqueued, timers that have
   fired, signals delivered, children completed.
2. **Claim** one via compare-and-set with a **lease** (visibility timeout). This
   is the Ledger design's CAS-claim pattern (`crucible-a6k`) — reuse it; a
   durable worker is a Ledger consumer with a journal attached.
3. **Run** the crucible program under the journaling interpreter, backed by
   manifest persistence. Each activity result is appended to `journal_entry`.
4. **Heartbeat** to extend the lease. If a worker dies, the lease expires and
   another worker reclaims the execution.
5. **Recover** on reclaim: run in **replay-to-resume** mode — replay the
   persisted journal to rebuild in-flight state, then continue live from the
   head. This is durability of in-flight progress: a crash loses at most the
   uncommitted tail, and the journal reconstructs everything up to it.

Multiple workers claim distinct executions (horizontal scale). This is the
"worker/runtime + durability" the user asked to add; orchestration primitives
(above) ride on the same loop.

---

## Component: durability & exactly-once (the crux)

The hard correctness question in any durable execution system: an activity has a
side effect *and* a journal write, and a crash can land between them.

- **Transactional journaling (our advantage).** Because the store is Postgres
  (manifest), the journal append and the `run_queue` state transition happen in
  **one transaction** — the DBOS model. Temporal separates its event store from
  workers and cannot do this; it pays for that with more machinery. Using
  manifest buys us transactional progress for free, and is a real reason to
  prefer Postgres-as-system-of-record over a dedicated engine at our scale.

- **The activity itself is not transactional with its journal** (the side effect
  hits an external world). The standard resolution, which we adopt:
  - **Intent-then-result.** Journal an *intent* row (`ActivityId`, started) in
    the workflow transaction, perform the effect, then journal the *result*.
  - **On resume:** if intent is present but result is absent, the activity *may*
    have run. Policy by activity kind: **idempotent** → re-run safely;
    **non-idempotent** → require an **idempotency key** derived from
    `ActivityId` so the downstream dedupes; **un-keyable** (e.g. a fire-and-pray
    side effect) → mark for human / accept at-least-once. crucible exposes the
    activity-kind annotation; the app declares it per op.

This intent/result + idempotency-key discipline is the genuine hard part and is
called out as an open question (below) for the phase that builds it.

---

## Eval mode: the flywheel as a consumer

With the substrate in place, the four eval concepts are thin consumers, not new
machinery:

- **Capture** — a prod workflow in live/record mode already writes the journal.
  Nothing extra.
- **Grade a prod turn** — run a reference-free grader (`pointed`/`checklist`)
  over a completed execution's output. No dataset membership required.
- **Promote to a dataset** — lift a `workflow_execution`'s journal into a
  manifest-evals `Example`: `raw_input` (= `jiInput`) + the journal blob
  (opaque) + `app_version`. New dataset version (manifest-evals already versions
  datasets and refuses `--force` against referenced versions).
- **Replay-to-eval** — manifest-evals runs the app's `buildTurn` on `raw_input`
  → a crucible program reflecting the engineer's *current* code → the journaling
  interpreter in replay mode with `MissPolicy = Signal`, per-effect modes set by
  what's under test (prompt change → `LLM` live, `Environment` replay; tool-logic
  change → that tool's `Environment` op replayed one level deeper so new logic
  runs). Divergence surfaces as first-class output, graded anyway.
- **Reduce to simplest repro** — delta-debugging (ddmin) over `jiInput` and
  journal entries: drop a chunk, re-replay, keep the removal if the grader still
  fails. Oracle = "fails ≥ k of N samples" (stochastic; budget N judge calls per
  step).
- **Track across datasets / runs / prod** — every run (prod and offline) is
  tagged `app_version × tool_policy`; `RunMetric` already carries overall +
  per-tag. The new axis is `app_version × tool_policy`; the dashboard's
  align-by-key `#/compare` gains those dimensions.

The provenance that makes "compare the broken prod turn to my fix" work is just
two journals with the same `jiInput` and different `app_version`, scored, deltaed.

---

## Key design decisions & tradeoffs

| Decision | Choice | Why / cost |
|---|---|---|
| Journal keying | **keyed (domain-level)**, not positional | tolerates code change → enables eval & painless versioning; cost: app must supply stable keys + normalization |
| Journal portability | **portable** (carries identity) | one artifact serves resume-in-place *and* eval-elsewhere; cost: identity metadata, stable keys |
| Divergence semantics | **per-mode** (`Fail` resume / `Signal` eval) | same machinery, one knob; nothing to special-case |
| Replay granularity | **per-effect mode** | lets prompt-change re-run the model while replaying tools; cost: consumer sets modes explicitly |
| System of record | **Postgres / manifest** (DBOS-style) | transactional journal+queue, fits the stack, library-not-service; cost: Postgres throughput ceiling vs a dedicated engine (fine at our scale) |
| Exactly-once | **intent/result + idempotency key** | standard, honest about the un-keyable tail; cost: per-op activity-kind annotation |
| Domain effects | **app-owned**, crucible owns only the combinator | crucible stays a substrate; manifest-evals stays domain-agnostic; cost: app writes interpreter trios |

### Lineage — what we borrow and reject

- **Borrow from DBOS:** Postgres as system of record, transactional journaling,
  library-not-service deployment.
- **Borrow from Temporal/Restate:** the determinism sandbox, the activity/journal
  model, the effect-handler implementation technique, matcher/normalization for
  keys.
- **Reject from Temporal:** positional event history (→ keyed), a separate
  service + worker-fleet ceremony (→ a library + a simple Postgres-backed
  worker), and the `patched()`/`GetVersion` versioning ceremony (→ keyed +
  portable journals handle code change natively).
- **Invert from all of them:** divergence is a *signal* in eval mode, not a
  fatal error. The hardest problem in their world (history divergence on code
  change) is our base case — and we picked the journal structure that makes it
  survivable.

---

## What each repo owns (summary)

- **crucible:** `Crucible.Workflow` effect; the journaling combinator
  (`replay`/`record`/`key`); `Journal`/`MissPolicy`/`Divergence` types;
  in-memory journal store for tests. No storage, no worker, no domain effects.
- **manifest:** Postgres schema + migrations + queries for `workflow_execution`,
  `journal_entry`, `run_queue`, `signal`; transactional append+transition;
  CAS-claim-with-lease.
- **worker/runtime (new):** the claim/run/heartbeat/recover loop; timer + signal
  + child dispatch.
- **app (Sparky):** the `Environment` domain effect, its interpreter trio, per-op
  codecs + normalization, activity-kind annotations, `buildTurn`.
- **manifest-evals:** journal-as-Example storage; injected app harness
  (`buildTurn` + replay interpreter); replay-to-eval; ddmin minimizer;
  reference-free grading; `app_version × tool_policy` tracking.

---

## Phasing (decomposition — this is too big for one plan)

Each phase is independently shippable and gets its own spec → plan → build.

- **Phase 0 — replay core (crucible).** `Journal` + keying + the journaling
  combinator + `MissPolicy`; in-memory store. End state: a program can be run
  live-recording into an in-memory journal and replayed against changed code,
  with divergence surfaced. This is the slice the eval investigation already
  validated; it unblocks an in-memory eval path immediately.
- **Phase 1 — durable store + worker (manifest + worker).** Postgres schema,
  `run_queue`, claim-with-lease, incremental persistence, crash → replay-to-
  resume. Single workflow type, no orchestration yet. End state: a workflow
  survives a worker kill and resumes.
- **Phase 2 — orchestration (crucible `Workflow`).** `durableSleep`,
  `awaitSignal`, `executeChild`, `retry`, journaled `now`/`newId`. End state:
  multi-step, timer-driven, signal-driven workflows.
- **Phase 3 — eval flywheel (manifest-evals).** Promotion, the replay-to-eval
  consumer, the ddmin minimizer, `app_version × tool_policy` tracking. Parts can
  start after Phase 0 against in-memory journals.

---

## Open questions

1. **Exactly-once for non-idempotent, un-keyable activities.** The intent/result
   + idempotency-key discipline covers most ops; the residual (fire-and-pray
   side effects) needs a policy — at-least-once + human flag, or refuse such ops
   in workflows. Decide in Phase 1.
2. **Codec/schema evolution.** Encoded activity results are stored under an
   `app_version`; replaying an old journal against new result types needs codec
   versioning or a tolerant decoder. Decide in Phase 0 (it shapes the format).
3. **`buildTurn` determinism.** The app's input→program mapping must itself be
   deterministic (or its non-determinism journaled), or replay-to-eval is
   unsound. Likely a constraint we document + lint rather than enforce in types.
4. **Journal granularity.** Do we journal *only* domain ops + `Workflow`
   primitives, or also intermediate crucible internals? Default: the effect-row
   boundary only (domain effects + `LLM` + `Workflow`), nothing below.
5. **Worker package home.** New top-level package in crucible vs. a manifest-side
   package vs. app-level. Leaning new package (`crucible-worker`) depending on
   both, mirroring manifest-evals' bridge position.

---

## Non-goals

- Not a hosted service or a worker-fleet control plane — a library + a
  Postgres-backed worker process.
- Not a general queue/job system — the unit is a *workflow execution* with a
  journal, not an opaque job.
- Not replacing manifest-evals' existing offline JSONL path — this adds a
  *captured-turn* source alongside it.
