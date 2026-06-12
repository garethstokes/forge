# CallLog Per-Call Introspection Design Spec

**Date:** 2026-06-12
**Status:** Approved design, pending implementation
**Tracker:** `crucible-c11`.
**Research basis:** `docs/superpowers/research/2026-06-11-baml-review.md` item 4 (collector parity); split out of the provider-fallback cycle (`crucible-3sj`), whose docs defer "which member answered" observability here.
**Scope:** new `src/Crucible/LLM/CallLog.hs`; `src/Crucible/LLM/Provider.hs` (model field); `src/Crucible/LLM/Anthropic.hs` and `src/Crucible/LLM/OpenAI.hs` (constructors fill model); `test/Spec.hs`; `app/Main.hs`; `docs/live-interpreter.md`.

## Motivation

A fallback chain makes decisions the caller cannot see: which members were
tried, which failed and why, which answered, and how long each attempt
took. Usage accumulation (the cheap default) says nothing about the walk.
CallLog records one entry per member attempt so the chain becomes
reconstructable after the fact.

## Decisions taken during design

- Hook point: a pure Provider decorator (`logging`), not logged Fallback
  variants (grammar doubling) and not an effect-level wrapper (cannot see
  provider name, member attempts, or failed-call durations).
- Entry fields: lean plus model: provider, model, duration (ms), outcome.
  TTFT deferred (streaming stays uninstrumented; non-streaming TTFT equals
  duration). Attempt position and which-member-answered are derivable from
  entry order and outcome, not first-class fields.
- Collection: an opaque IORef handle with `new`/`drain`, mirroring how
  round-robin already uses an IORef at the interpreter edge. `drain` reads
  AND clears.
- `Provider` gains `model :: Text` (the provider knows its model; the
  constructors fill it from config). Breaking for direct construction;
  every construction site lives in this repo.

## Design

### 1. `Provider` extension (`Crucible.LLM.Provider`)

```haskell
data Provider = Provider
  { name     :: Text
  , model    :: Text
  , complete :: [Message] -> IO (Text, Usage)
  , converse :: [(ToolName, Value)] -> [Chat.Message] -> IO (Turn, Usage)
  }
```

`Anthropic.provider` and `OpenAI.provider` set `model = cfg.model`. The
fake-provider test fixtures and the docs snippet gain the field; nothing
outside this repo constructs `Provider`.

### 2. `Crucible.LLM.CallLog` (new module, used qualified)

```haskell
-- | One member attempt: who was asked, how long it took, and how it
-- ended. Entries accumulate in chronological order, so a fallback walk
-- reads as: zero or more Left entries, then the Right entry that
-- answered (or all Left when the chain exhausted).
data CallEntry = CallEntry
  { provider   :: Text
  , model      :: Text
  , durationMs :: Int
  , outcome    :: Either Text Usage  -- rendered error | the call's usage
  }
  deriving (Eq, Show)

-- | An opaque accumulating handle.
newtype CallLog = CallLog (IORef [CallEntry])

new :: IO CallLog

-- | Wrap a provider so every complete/converse call is timed and
-- recorded. Success records Right usage and returns the result; failure
-- records Left (rendered error) and RETHROWS, so fallback semantics
-- (advance on synchronous failure, rethrow async) are untouched.
logging :: CallLog -> Provider -> Provider

-- | Read the entries in chronological order and clear the handle, so
-- phases of a longer program can collect their own windows.
drain :: CallLog -> IO [CallEntry]
```

Timing via `GHC.Clock.getMonotonicTimeNSec`, reported in whole
milliseconds. The decorator preserves `name` and `model` unchanged and
wraps both per-call functions with the same time/try/record/rethrow
shape (`try @SomeException`; record even async exceptions, then rethrow;
the fallback walk decides what advances).

Single-provider logging needs no new machinery:
`Fallback.run [CallLog.logging lg p]`.

## Demo (`app/Main.hs`)

Decorate the existing junk-key fallback chain: create a handle before the
chain, `map (CallLog.logging lg)` over the two members, and after the
`fallback: ...` line drain and print one line per entry, e.g.
`calllog: anthropic <model> error in NNNms` /
`calllog: openai <model> ok in NNNms`. Zero extra API calls; it
instruments the calls the demo already makes and proves both the failed
401 attempt and the answering member appear, in order.

## Manual (`docs/live-interpreter.md`)

- The `Provider` record snippet in "Fallback and round-robin" gains the
  `model` field.
- A new `### Observing the chain` subsection in that section:
  `CallLog.new`/`logging`/`drain` with a short example; the `CallEntry`
  fields; failed member attempts are logged too, in tried order, so the
  walk is reconstructable (the `Right` entry is the member that
  answered); drain reads and clears; single-provider use via a singleton
  chain. House style: no emdashes, no hype, no manifest mentions.

## Testing (hermetic; fake providers, no LLM scripting)

The `goodProvider`/`badProvider` fixtures gain the model argument (pin
`"fake-model"`). Checks:

- Success path: one good member under `Fallback.run` with logging gives
  one entry with the right provider/model, `outcome = Right (Usage 1 2)`,
  `durationMs >= 0`; the program result equals the undecorated run
  (transparency).
- Fallback walk visibility: bad-then-good chain gives exactly two entries
  in tried order, first `Left` containing the error text, second `Right`;
  the chain still answers from the second member.
- Drain semantics: a second drain with no calls between returns `[]`;
  entries made after a drain appear in the next one.
- Chat path: one `converse`-side success check.
- Round-robin composition: decorated members under `roundRobin` log in
  rotation order across consecutive calls.
- Constructors carry models: `Anthropic.provider`/`OpenAI.provider`
  produce `p.model` matching their config defaults.
- Existing fallback checks migrate mechanically (fixture arity).
- Live: the demo calllog lines before merge.

## Non-goals

- TTFT: a streaming-only metric and streaming stays uninstrumented; for
  non-streaming calls it equals duration.
- Attempt number / selected flag as first-class fields: derivable from
  entry order and outcome; adding them stores no new information.
- Log persistence or export formats: the list is the API; serialization
  belongs to the consumer.
- Logging for non-Provider interpreters (`Anthropic.run` and friends):
  Provider chains are the observability surface; instrumenting every
  interpreter family doubles the grammar for paths with nothing to
  observe but a single call.
- Automatic logging inside `Fallback`: decoration stays explicit so
  undecorated chains pay zero overhead and the decorator stays a plain
  function on `Provider`.
