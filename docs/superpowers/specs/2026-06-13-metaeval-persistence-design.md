# Meta-eval report persistence — Design

**Status:** Approved (batch brainstorm 2026-06-13). · **Date:** 2026-06-13

**Goal:** Persist each `CalibrationReport` from `metaeval report` as a `MetaEval`
result row, so calibration measurements are stored/queryable. Backend only — no
dashboard surface this slice.

## Decisions (user-approved)
- A `MetaEval` result entity.
- Append/history (re-running keeps prior measurements; `computedAt` distinguishes).
- `metaeval report` persists AND prints (as now). No dashboard.

## Facts (verified)
crucible `Cal.CalibrationReport` exposes (record-dot): `agreement :: Double`,
`kappa :: Double`, `kappaCI :: (Double, Double)`, `failPrecision :: Double`,
`failRecall :: Double`, `measured :: Int`, `judgeErrors :: [Text]` (plus
`contested`/`abstained`/`exampleCount`, which are always empty/0 for the
`reportFromVerdicts` path → not persisted). `Evals.MetaEval.metaReport :: Pool
-> Int -> MetaMode -> RunId -> GraderVersionId -> IO (Either Text
Cal.CalibrationReport)`. The CLI `metaeval report` arm has `modeName :: String`
("live"/"stored") and `seed :: Int` in scope and currently does
`metaReport … >>= \case Left e -> die …; Right r -> putStrLn (renderCalibration r)`.

## 1. Schema — `MetaEval`
New entity:
```haskell
data MetaEvalT f = MetaEval
  { id            :: Field f (Pk MetaEvalId)
  , run           :: Field f RunId
  , graderVersion :: Field f GraderVersionId
  , mode          :: Field f Text          -- "live" | "stored"
  , seed          :: Field f Int
  , agreement     :: Field f Double
  , kappa         :: Field f Double
  , kappaLow      :: Field f Double         -- kappaCI lower
  , kappaHigh     :: Field f Double         -- kappaCI upper
  , failPrecision :: Field f Double
  , failRecall    :: Field f Double
  , measured      :: Field f Int
  , judgeErrors   :: Field f (Aeson Value)  -- the [Text] case keys, as jsonb
  , computedAt    :: Field f UTCTime
  } deriving Generic
```
`indexes = [ btree #run ]` (history lookups by run; no unique — append). New
`MetaEvalId` in `Evals.Ids`. No `notifyChanges`. Registered in `Evals.Migrate`.

## 2. `saveMetaEval`
In `Evals.MetaEval`:
```haskell
saveMetaEval :: Pool -> RunId -> GraderVersionId -> Text -> Int
             -> Cal.CalibrationReport -> IO MetaEval
```
Opens a session, stamps `computedAt = now`, maps the report's fields
(`kappaCI` → `kappaLow`/`kappaHigh`; `judgeErrors :: [Text]` →
`Aeson (toJSON …)`), `add`s and returns the row. Pure mapping otherwise.

## 3. CLI
`metaeval report`'s `Right r` branch becomes: `saveMetaEval pool rid gvid
(T.pack modeName) seed r` (discard the result), then the existing
`putStrLn (renderCalibration r)`. No flag — persistence is the slice's purpose
and is cheap.

## 4. Testing
- **Engine** (ephemeral PG): seed a labelled run + a stored `Score.detail`
  (reuse the existing `MetaEvalSpec` `seedRun`); compute `rep` via `metaReport
  pool 0 Stored …`; `saveMetaEval`; `selectWhere [#run ==. rid] :: [MetaEval]`
  → assert exactly one row whose `agreement`/`kappa`/`measured`/`mode`/`seed`
  match the report; a second `saveMetaEval` appends (two rows — history).
- `SchemaSpec` migrate/round-trip continues to pass with the new table.

## 5. Out of scope
- Dashboard surface (grader κ over time / DTO / API / UI).
- Persisting `contested`/`abstained`/`exampleCount` (always empty here).
- A `metaeval history` query command.
