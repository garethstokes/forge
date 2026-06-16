# Meta-eval report persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Persist each `CalibrationReport` as a `MetaEval` row; `metaeval report` saves + prints.

**Spec:** `docs/superpowers/specs/2026-06-13-metaeval-persistence-design.md`

**Repo facts (verified):**
- `src/Evals/Ids.hs`: list of `newtype …Id = …Id Int deriving stock (Eq, Ord, Show) deriving newtype DbType`; last is `CriterionLabelId`.
- `src/Evals/Schema.hs`: HKD `data XT f = X { field :: Field f T, … } deriving Generic` + `type X = XT Identity`, then `instance Entity X where tableMeta = genericTableMeta @XT "table"; indexes = [...]`. `RunId`/`GraderVersionId`/`Text`/`Int`/`Double`/`UTCTime`/`Aeson`/`Pk`/`Field`/`Identity`/`btree`/`genericTableMeta`/`Entity`/`Generic` in scope. `CriterionLabel` is the last entity (instance has `indexes = [ unique [#output, #criterion] ]`).
- `src/Evals/Migrate.hs`: `schema :: [ManagedTable]` ends `…, managed (Proxy @CriterionLabel) ]`.
- `src/Evals/MetaEval.hs`: `module Evals.MetaEval (MetaMode (..), metaReport)`; imports `qualified Crucible.Eval.Calibrate as Cal`, `Manifest`, `Manifest.Postgres (Pool)`, `Evals.Ids`, `Evals.Schema`, `Data.Text (Text)`. `metaReport :: Pool -> Int -> MetaMode -> RunId -> GraderVersionId -> IO (Either Text Cal.CalibrationReport)`. `Cal.CalibrationReport` fields via record-dot: `agreement :: Double`, `kappa :: Double`, `kappaCI :: (Double,Double)`, `failPrecision :: Double`, `failRecall :: Double`, `measured :: Int`, `judgeErrors :: [Text]`.
- `test/MetaEvalSpec.hs`: `seedRun :: Pool -> UTCTime -> IO (RunId, GraderVersionId, OutputId)` (seeds Dataset/Version/Example(c-good/c-bad rubric)/Target/TargetVersion/Run/Output/2 CriterionLabels); `storedSpec pool now` seeds a `Score` with `detail` `{criteria:[{criterion,met}]}` then `metaReport pool 0 Stored rid gvid`. Local `expect`. `main = withEphemeralDb $ \pool -> do { _ <- withSession pool migrateAll; ingestSpec pool; now <- getCurrentTime; storedSpec pool now; liveSpec pool now; putStrLn "manifest-evals MetaEvalSpec: ingest + stored + live OK" }`.
- `app/Main.hs` `metaeval report` arm: `withEnvPool $ \pool -> metaReport pool seed mode rid gvid >>= \case { Left e -> die (T.unpack e); Right r -> putStrLn (T.unpack (Cal.renderCalibration r)) }`. `modeName :: String` and `seed :: Int` and `rid :: RunId`, `gvid :: GraderVersionId` are in scope in that arm; `Cal` is imported; `T` = `Data.Text`.
- Build/test: `nix develop -c zinc build` / `nix develop -c zinc test 2>&1 | tail -8`.

---

### Task 1: `MetaEval` entity + `saveMetaEval` + engine test (TDD)

**Files:** `src/Evals/Ids.hs`, `src/Evals/Schema.hs`, `src/Evals/Migrate.hs`, `src/Evals/MetaEval.hs`, `test/MetaEvalSpec.hs`.

- [ ] **Step 1: the id.** In `src/Evals/Ids.hs`, after `CriterionLabelId`:
```haskell
newtype MetaEvalId = MetaEvalId Int deriving stock (Eq, Ord, Show) deriving newtype DbType
```

- [ ] **Step 2: the entity.** In `src/Evals/Schema.hs`, after the `CriterionLabel` type alias + instance, add:
```haskell
data MetaEvalT f = MetaEval
  { id            :: Field f (Pk MetaEvalId)
  , run           :: Field f RunId
  , graderVersion :: Field f GraderVersionId
  , mode          :: Field f Text          -- "live" | "stored"
  , seed          :: Field f Int
  , agreement     :: Field f Double
  , kappa         :: Field f Double
  , kappaLow      :: Field f Double
  , kappaHigh     :: Field f Double
  , failPrecision :: Field f Double
  , failRecall    :: Field f Double
  , measured      :: Field f Int
  , judgeErrors   :: Field f (Aeson Value)
  , computedAt    :: Field f UTCTime
  } deriving Generic
type MetaEval = MetaEvalT Identity

instance Entity MetaEval where
  tableMeta = genericTableMeta @MetaEvalT "meta_evals"
  indexes   = [ btree #run ]
```

- [ ] **Step 3: register migration.** In `src/Evals/Migrate.hs`, append `, managed (Proxy @MetaEval)` to the `schema` list.

- [ ] **Step 4: failing engine test.** In `test/MetaEvalSpec.hs`: add `import Data.Aeson (toJSON)` if absent (it imports `Data.Aeson (object, toJSON, (.=))` already — verify) and `import Evals.MetaEval (metaReport, MetaMode (..), saveMetaEval)` (add `saveMetaEval`). Add a `persistSpec` and wire it into `main` after `liveSpec`:
```haskell
persistSpec :: Pool -> UTCTime -> IO ()
persistSpec pool now = do
  (rid, gvid, oid) <- seedRun pool now
  _ <- withSession pool $ add (Score
        { id = ScoreId 0, output = oid, graderVersion = gvid
        , value = Just 0.5, passed = Nothing
        , detail = Just (Aeson (object
            [ "criteria" .= [ object ["criterion" .= ("c-good"::Text), "met" .= True]
                            , object ["criterion" .= ("c-bad"::Text),  "met" .= True] ] ]))
        , error = Nothing, createdAt = now } :: Score)
  rep <- metaReport pool 0 Stored rid gvid
  case rep of
    Left e  -> expect ("persist metaReport: " <> T.unpack e) False
    Right r -> do
      _ <- saveMetaEval pool rid gvid "stored" 0 r
      rows <- withSession pool (selectWhere [ #run ==. rid ]) :: IO [MetaEval]
      expect "persist: one row" (length rows == 1)
      case rows of
        [m] -> do
          expect "persist: agreement matches" (m.agreement == r.agreement)
          expect "persist: kappa matches"     (m.kappa == r.kappa)
          expect "persist: measured matches"  (m.measured == r.measured)
          expect "persist: mode/seed"         (m.mode == "stored" && m.seed == 0)
        _ -> expect "persist: exactly one" False
      _ <- saveMetaEval pool rid gvid "stored" 0 r
      rows2 <- withSession pool (selectWhere [ #run ==. rid ]) :: IO [MetaEval]
      expect "persist: append -> two rows" (length rows2 == 2)
```
Update `main`'s final putStrLn to `"manifest-evals MetaEvalSpec: ingest + stored + live + persist OK"` and add `persistSpec pool now` after `liveSpec pool now`. Run `nix develop -c zinc test 2>&1 | tail -6` — compile FAIL (`saveMetaEval`/`MetaEval` missing).

- [ ] **Step 5: implement `saveMetaEval`.** In `src/Evals/MetaEval.hs`: add `, saveMetaEval` to the export list; add imports `Data.Time (getCurrentTime)` and `Data.Aeson (toJSON)` (merge with existing aeson import — it imports `Data.Aeson (Value (..))`; add `toJSON`). Add:
```haskell
-- | Persist a calibration report as a 'MetaEval' row (append/history).
saveMetaEval :: Pool -> RunId -> GraderVersionId -> Text -> Int
             -> Cal.CalibrationReport -> IO MetaEval
saveMetaEval pool rid gvid modeT seed rep = do
  now <- getCurrentTime
  withSession pool $ add (MetaEval
    { id = MetaEvalId 0, run = rid, graderVersion = gvid, mode = modeT, seed = seed
    , agreement = rep.agreement, kappa = rep.kappa
    , kappaLow = fst rep.kappaCI, kappaHigh = snd rep.kappaCI
    , failPrecision = rep.failPrecision, failRecall = rep.failRecall
    , measured = rep.measured, judgeErrors = Aeson (toJSON rep.judgeErrors)
    , computedAt = now } :: MetaEval)
```
(`Aeson` is from `Manifest`, already imported. `MetaEval`/`MetaEvalId` come from `Evals.Schema`/`Evals.Ids`, already imported.) Run `nix develop -c zinc test 2>&1 | tail -8` — `persist OK` and all specs green. `nix develop -c zinc build 2>&1 | tail -3` — links.

- [ ] **Step 6: commit.** `git add src/Evals/Ids.hs src/Evals/Schema.hs src/Evals/Migrate.hs src/Evals/MetaEval.hs test/MetaEvalSpec.hs && git commit -m "$(printf 'feat(metaeval): MetaEval entity + saveMetaEval (persist calibration reports)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"`

---

### Task 2: CLI persists + push

**Files:** `app/Main.hs`, `README.md`.

- [ ] **Step 1: import.** In `app/Main.hs`, change `import Evals.MetaEval (metaReport, MetaMode (..))` → `import Evals.MetaEval (metaReport, MetaMode (..), saveMetaEval)`.
- [ ] **Step 2: persist in the report arm.** In the `metaeval report` arm, change the `Right r` branch from `Right r -> putStrLn (T.unpack (Cal.renderCalibration r))` to:
```haskell
      Right r -> do
        _ <- saveMetaEval pool rid gvid (T.pack modeName) seed r
        putStrLn (T.unpack (Cal.renderCalibration r))
```
(`rid`/`gvid`/`modeName`/`seed`/`pool` are all in scope in that arm.)
- [ ] **Step 3: build.** `nix develop -c zinc build 2>&1 | tail -3` — links. `nix develop -c zinc test 2>&1 | tail -6` — green.
- [ ] **Step 4: README.** Add a sentence to the meta-evaluation docs: each `metaeval report` run is persisted as a `MetaEval` row (agreement, κ + CI, fail precision/recall, measured, mode, seed, timestamp) — appended as history, queryable; the printed output is unchanged.
- [ ] **Step 5: commit + push.** `git add app/Main.hs README.md && git commit -m "$(printf 'feat(cli): metaeval report persists each MetaEval row\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')" && git push`

---

## Self-Review
- Spec §1 (MetaEval entity, btree #run, no unique, migrate) → Task 1; §2 (saveMetaEval mapping kappaCI→low/high, judgeErrors→jsonb) → Task 1; §3 (CLI persists + prints) → Task 2; §4 testing (persist + read-back field match + append→2 rows) → Task 1; §5 out-of-scope (no dashboard/DTO/history-command) absent.
- Type consistency: `MetaEvalId Int`; `MetaEval` fields match `saveMetaEval`'s `add`; `saveMetaEval :: Pool -> RunId -> GraderVersionId -> Text -> Int -> Cal.CalibrationReport -> IO MetaEval` used identically in the test and the CLI; `Cal.CalibrationReport` record-dot fields (`agreement`/`kappa`/`kappaCI`/`failPrecision`/`failRecall`/`measured`/`judgeErrors`) match the verified API.
