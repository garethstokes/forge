# Crucible.Journal — the durable execution replay core (Phase 0)

A `Journal` is a keyed, portable recording of an effectful program's operations.
It is the in-memory core of crucible's durable execution substrate (see
`docs/superpowers/specs/2026-06-15-durable-execution-design.md`); later phases
back it with Postgres + a worker and build orchestration on top.

## Model

- `mkKey op parts` — a `CassetteKey` from an operation name and already-
  normalized argument parts. The app strips volatile fields before keying.
- `record key encode action` — run `action` live and append its encoded result.
  This is the production / capture path.
- `replay policy key decode live` — serve a recorded result. On a miss the
  `MissPolicy` decides: `Fail` aborts (crash-recovery strictness), `Signal`
  runs `live` and flags a `Divergence` (eval: a miss is the measurement),
  `Fallthrough` runs `live` silently.

Keys are content-addressed, so changed code replaying an old journal hits the
ops it shares and diverges on the rest — divergence is a first-class
`ReplayOutcome`, not a desync.

## Example

```haskell
-- record (live): run the real op, journal its result
(_, j) <- pure $ runPureEff $ runState (emptyJournal ident) $
  record (mkKey "lookupTwin" [machineIdBytes]) encodeTwin (lookupTwinLive mid)

-- replay (eval): re-run changed code against the recording
runPureEff $ runErrorNoCallStack $ runState j $
  replay Signal (mkKey "lookupTwin" [machineIdBytes]) decodeTwin (lookupTwinLive mid)
```

`record`/`replay` run over `State Journal`, so they are `runPureEff`-testable.
Persisting the journal uses `journalCodec` (a stable, base64-framed JSON form).
