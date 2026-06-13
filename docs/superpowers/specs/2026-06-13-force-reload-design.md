# `metaeval load --force` reload fix — Design

**Status:** Approved (batch brainstorm 2026-06-13). · **Date:** 2026-06-13

**Goal:** `metaeval load --force` actually replaces a same-slug+version
labelled set, instead of being blocked by the synthetic run's `Restrict`
cascade.

## Root cause
`metaLoad` always seeds a synthetic `Run` under the version, and
`DatasetVersion→Run` is a `Restrict` cascade. So the old force path
(`delete v`) would abort, and `metaLoad` pre-empted that with a `HasRuns`
refusal — making `--force` inert for meta-eval (a same-version reload always
failed; you had to bump the version).

## Decisions (user-approved)
- Scoped fix (do NOT weaken the global `DatasetVersion→Run` Restrict — it
  protects real datasets).
- Add an `Output→CriterionLabel` **Cascade** rule (correct regardless: labels
  should die with their output).
- `metaLoad --force` deletes the version's runs first (cascading
  Run→Output→{Score, CriterionLabel}), then the version, then re-seeds.

## 1. Schema — cascade rule
The `Output` entity gains a cascade rule so deleting an Output removes its
labels (it already cascades to `Score`):
```haskell
instance Entity Output where
  ...
  cascadeRules = [ cascade (Proxy @Score) (Proxy @"output") Cascade
                 , cascade (Proxy @CriterionLabel) (Proxy @"output") Cascade ]
```
(`CriterionLabel` is defined later in the module — a forward reference, fine at
top level.)

## 2. `metaLoad` force path
Replace the `(v : _) | otherwise` branch (which returned `HasRuns`) with a
delete-then-reseed inside one transaction. manifest's recursive cascade
(manifest-va2) removes a Run's Outputs, their Scores, and now their
CriterionLabels:
```haskell
  | otherwise -> withTransaction $ do
      runs <- selectWhere [ #datasetVersion ==. v.id ] :: Db [Run]
      mapM_ delete runs   -- cascades Run -> Output -> {Score, CriterionLabel}
      flush               -- runs (and subtree) gone before deleting the version
      delete v            -- now no runs reference it (Restrict satisfied); cascades Examples
      flush               -- version gone before seedGraph's eager inserts
      Right <$> seedGraph d.id opts rows now nSkip
```
The `HasRuns` constructor (now unreachable in `metaLoad`) is removed from
`MetaLoadError` and `renderMetaLoadError`. `AlreadyExists` (refuse without
`--force`) is unchanged.

## 3. Testing
Update the existing `MetaEvalSpec` ingest scenario (which currently asserts
`--force → Left (HasRuns …)`): now `--force` must SUCCEED and REPLACE. After the
first successful `--skip-bad` load (2 examples, 3 labels) and the no-force
`AlreadyExists` refusal, a `--force` load asserts:
- it returns `Right` (a new `runId`, distinct from the original);
- labels are REPLACED not accumulated — total `CriterionLabel` count is 3
  (not 6);
- examples total 2 (not 4) — the old version's examples were cascaded away.

## 4. Out of scope
- Changing the global `DatasetVersion→Run` cascade.
- `--force` for the regular dataset `ingest` (it keeps its own `HasRuns` guard
  — real runs there are not disposable).
