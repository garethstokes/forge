# Durable Execution — Intent/Result Exactly-Once — Design

**Date:** 2026-06-15
**Status:** Committed spec
**Bead:** `crucible-8bt` (epic `crucible-w0k`). Depends on Phase 1 (`crucible-03x`, shipped).
**Design basis:** the main design doc's Q1 / "Exactly-once" section + the Phase-1 spec "Future work".

## The problem this solves

Phase 1 gives *basic durable resume*: committed activities replay (no re-run), but
an activity whose **side effect completed yet whose result was not journaled before
a crash** is re-run on resume — at-least-once for that uncommitted tail. This
closes that window for the cases that can be closed, honestly:

- **idempotent** activities → re-running is safe (no change needed);
- **keyable** non-idempotent activities → run with a **deterministic idempotency
  key** derived from the activity's content key, so a re-run sends the *same* key
  and the downstream **dedupes** → exactly-once;
- **un-keyable** fire-and-pray side effects → cannot be made exactly-once; we make
  the crashed-mid-flight case **observable** (an *intent* row with no result) so it
  can be flagged, and accept at-least-once (no fabricated guarantee).

## Design

### Activity-kind annotation

```haskell
data ActivityKind = Idempotent | Keyable | Unkeyable deriving (Eq, Show)
newtype IdemKey = IdemKey ByteString deriving (Eq, Show)   -- deterministic, = the content key bytes
```

### Intent-then-result + idempotency key

`recordTo` (the current write path: run-then-append) is supplemented by a
kind-aware variant that records an **intent** before the side effect and gives the
action a deterministic idempotency key:

```haskell
recordActivity :: (IOE :> es)
  => JournalStore -> ActivityKind -> CassetteKey -> Text
  -> (a -> ByteString)            -- encode result
  -> (IdemKey -> Eff es a)        -- the side effect, given a stable idempotency key
  -> Eff es a
recordActivity s kind k op enc act = do
  liftIO (jsIntent s k op kind)          -- 1. intent row (key, op, kind; no result yet)
  a <- act (idemKeyOf k)                 -- 2. the side effect, with a stable idem key
  liftIO (jsAppend s k op (enc a))       -- 3. result row
  pure a
  where idemKeyOf (CassetteKey b) = IdemKey b
```

- The **idempotency key is deterministic** (the content key's bytes), so a re-run
  after a crash sends the identical key and a deduping downstream returns the
  prior result — exactly-once for keyable activities **without** needing the
  intent row to drive a re-run decision. (`recordTo` stays for activities that
  don't need a key; `recordActivity` is the exactly-once-aware path.)
- The **intent row** records that the activity *started* (with its kind). It is
  the mechanism that makes the crashed-mid-flight case observable.

### Re-adding `jsIntent` + intent representation

`JournalStore` regains `jsIntent :: CassetteKey -> Text -> ActivityKind -> IO ()`.
Intents and results are distinguished by a status:

- **manifest store**: `journal_entry` gains a `je_status` column (`"intent" |
  "result"`) and a `je_kind` column (the activity kind, for intents). `jsIntent`
  inserts a `status="intent"` row (empty result); `jsAppend` inserts a
  `status="result"` row. `jsLoad` builds the `Journal` from **result** rows only
  (so replay is unchanged). A new `pendingIntents :: Pool -> Int -> IO [(CassetteKey,
  ActivityKind)]` returns keys that have an intent but no result — the
  crashed-mid-flight set.
- **in-memory store**: a second `IORef` of `[(CassetteKey, ActivityKind)]` for
  intents; `jsIntent` appends; results don't remove them (pendingIntents = intents
  whose key is absent from the journal's result entries). Keeps the path testable
  without Postgres.

### Resume-side handling (worker)

On reclaim, before/while running, the worker can call `pendingIntents` to find
activities that may have run but didn't journal a result:

- **Unkeyable** pending intents → log/flag (at-least-once; surfaced, not hidden).
  (A real "human flag" sink is out of scope; we expose the list + a worker log.)
- **Idempotent / Keyable** → no special action: replay-to-resume re-runs them
  (idempotent: safe; keyable: the deterministic idem key dedupes).

So the behavioural change 8bt delivers is: **keyable activities are exactly-once**
(deterministic idem key), and **crashed-mid-flight activities are observable**
(intent rows + `pendingIntents`), with unkeyable honestly flagged.

## Scope

**IN:** `ActivityKind`/`IdemKey`; `jsIntent` re-added (in-memory + manifest, with
`je_status`/`je_kind` columns); `recordActivity` (intent → side-effect-with-idem-key
→ result); `pendingIntents`; a worker hook that surfaces unkeyable pending intents;
tests (intent recorded before result; idem key stable across re-runs; pendingIntents
detects intent-without-result; a keyable activity re-run sends the same idem key).

**OUT:** a real human-flag/alert sink (just expose the list + log); changing the
existing `recordTo` callers (they keep at-least-once unless migrated to
`recordActivity`); durable-backoff retry.

## Testing
- in-memory: `recordActivity` records an intent then a result (assert order/rows);
  the action receives a stable `IdemKey` equal across two runs of the same key;
  `pendingIntents` returns a key after `jsIntent` with no `jsAppend`, and empties
  after the result.
- ephemeral pg (crucible-manifest): `je_status`/`je_kind` columns; `jsLoad` ignores
  intent rows (replay sees only results); `pendingIntents` after a simulated crash
  (intent written, no result) returns the key+kind; a completed activity is absent.
- worker (crucible-worker): a workflow whose activity crashes after the side effect
  (intent written, result not) → on resume, `pendingIntents` surfaces it; a keyable
  re-run uses the same idem key (assert via a recorded idem key from the action).

## Risks
- **Distinguishing intent from a legitimately-empty result** — solved by the
  explicit `je_status` column (not by "empty result"), so a unit-result activity
  (e.g. a fired timer) is not mistaken for an intent.
- **Existing `recordTo` callers unchanged** — they remain at-least-once; only
  `recordActivity` is exactly-once-aware. Documented; migration is opt-in.
- **idem-key = content-key bytes** — fine since content keys are already stable and
  normalized by the app; a hashed form is a later optimization.
