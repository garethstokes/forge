# Meta-eval κ Calibration Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface persisted `MetaEval` calibration reports (agreement, Cohen's κ + CI, fail precision/recall) on the Miso dashboard — a run-detail section with a κ-over-time sparkline plus a cross-run `#/calibration` view.

**Architecture:** No schema change — read existing append-history `MetaEval` rows. New pure helpers (`Evals.Calibration`) own the trust threshold + Landis–Koch band. New DTOs in `evals-api` carry server-computed `trusted`/`band`. The server adds a `calibration` field to `RunDetailDto` and a `GET /api/calibration` route. The wasm UI gains a `CalibrationR` route, a reusable calibration card, and a sparkline.

**Tech Stack:** Haskell (GHC 9.12 native / 9.14 wasm), manifest ORM, Miso 1.11 wasm, warp, hspec, zinc build.

**Spec:** `docs/superpowers/specs/2026-06-14-metaeval-calibration-surface-design.md`

**Build/verify commands:**
- Native lib + tests: `zinc test spec` (runs `test/Spec.hs`). To run only fast specs during iteration the suite is monolithic — `zinc test spec` is the command.
- Native build only: `zinc build`
- Wasm UI: `scripts/build-ui.sh`
- Restart server after a wire change: kill the running `evals-dashboard` then re-run it (see Task 12).

**Key existing patterns to mirror (read these before coding):**
- Grader identity resolution: `groupedMetricDtos`/`buildOne` in `src/Evals/Dashboard.hs:207-230` (`get @GraderVersion`, `get @Grader`, `.name`/`.version`/`.kind`).
- Id → Int: pattern-match the newtype, e.g. `let RunId rid = r.id` (`src/Evals/Dashboard.hs:184`).
- Grouping: `Map.fromListWith (++)` (`src/Evals/Dashboard.hs:211`).
- κ bar can reuse `widthStyle`/`pct`/`fmtD`/`ciCol` (`evals-ui/src/Evals/Ui/View.hs:466-491`).

---

## File Structure

- **Create** `src/Evals/Calibration.hs` — pure trust/band helpers (server-only, unit-tested).
- **Create** `test/CalibrationSpec.hs` — unit tests for the helpers; wired into `test/Spec.hs`.
- **Modify** `evals-api/src/Evals/Api.hs` — add `MetaEvalDto`, `TrendPointDto`, `CalibrationSeriesDto`; add `calibration` field to `RunDetailDto`; extend the export list.
- **Modify** `src/Evals/Dashboard.hs` — `metaEvalDto`/`trendPoint`/series builders; fill `RunDetailDto.calibration`; add `["api","calibration"]` route + `calibrationHandler`.
- **Modify** `evals-ui/src/Evals/Ui/Model.hs` — `CalibrationR` route, `_calibrationM`, `GotCalibration`, `calibrationHash`, `parseHash`/`relevantTo`.
- **Modify** `evals-ui/src/Main.hs` — `SetRoute`/`fetchRoute`/`GotCalibration`/`DoRefetch` arms.
- **Modify** `evals-ui/src/Evals/Ui/View.hs` — calibration card + sparkline, run-detail section, cross-run `calibrationView`, nav link, `viewModel` arm.
- **Modify** `static/style.css` — calibration classes.
- **Modify** `scripts/seed-demo.sh` — `meta_evals` INSERTs + setval.
- **Modify** `test/ApiSpec.hs` — seed `MetaEval` rows; assert run-detail `calibration` and `GET /api/calibration`.

---

### Task 1: Calibration pure helpers

**Files:**
- Create: `src/Evals/Calibration.hs`
- Create: `test/CalibrationSpec.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: Write the failing test**

Create `test/CalibrationSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module CalibrationSpec (main) where

import Test.Hspec
import Evals.Calibration (kappaTrustThreshold, bandOf, trustedBy)

main :: IO ()
main = hspec $ do
  describe "kappaTrustThreshold" $
    it "is 0.6" $ kappaTrustThreshold `shouldBe` 0.6

  describe "bandOf (Landis-Koch)" $ do
    it "labels below 0.2 slight"        $ bandOf 0.1  `shouldBe` "slight"
    it "labels 0.2 fair (lower edge)"   $ bandOf 0.2  `shouldBe` "fair"
    it "labels 0.4 moderate"            $ bandOf 0.4  `shouldBe` "moderate"
    it "labels 0.6 substantial"         $ bandOf 0.6  `shouldBe` "substantial"
    it "labels 0.8 almost perfect"      $ bandOf 0.8  `shouldBe` "almost perfect"
    it "labels 0.95 almost perfect"     $ bandOf 0.95 `shouldBe` "almost perfect"

  describe "trustedBy (kappa CI lower bound vs threshold)" $ do
    it "trusts when lower bound >= 0.6" $ trustedBy 0.64 `shouldBe` True
    it "trusts at exactly 0.6"          $ trustedBy 0.6  `shouldBe` True
    it "distrusts below 0.6"            $ trustedBy 0.38 `shouldBe` False
```

- [ ] **Step 2: Wire the spec into the suite**

Edit `test/Spec.hs` to import and run it. New contents:

```haskell
module Main where
import qualified ApiSpec
import qualified CalibrationSpec
import qualified ExecuteSpec
import qualified GradeSpec
import qualified IngestSpec
import qualified MetaEvalSpec
import qualified SchemaSpec
main :: IO ()
-- ApiSpec first: fastest feedback (DTO round-trips fail before any DB spins up).
main = CalibrationSpec.main >> ApiSpec.main >> SchemaSpec.main >> ExecuteSpec.main >> GradeSpec.main >> IngestSpec.main >> MetaEvalSpec.main
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `zinc test spec`
Expected: compile error — `Could not find module 'Evals.Calibration'`.

- [ ] **Step 4: Write the implementation**

Create `src/Evals/Calibration.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Pure calibration verdict helpers. The κ trust threshold and the
-- Landis–Koch qualitative band live here so they have exactly one home,
-- shared by the dashboard server (which bakes the results into the wire DTOs)
-- and the test suite. The headline verdict is driven by the κ 95%-CI lower
-- bound vs 'kappaTrustThreshold' — sample-size aware, unlike the band.
module Evals.Calibration
  ( kappaTrustThreshold
  , bandOf
  , trustedBy
  ) where

import Data.Text (Text)

-- | A grader is "trustworthy" when the 95% CI lower bound of its Cohen's κ
-- clears this bar (the conventional "substantial" floor). A single constant so
-- it is easy to find and tune.
kappaTrustThreshold :: Double
kappaTrustThreshold = 0.6

-- | True when the κ CI lower bound clears the trust threshold.
trustedBy :: Double -> Bool
trustedBy kappaLow = kappaLow >= kappaTrustThreshold

-- | Landis–Koch qualitative label for a κ value. Demoted to a teaching aid in
-- the UI (the cut-points are admittedly arbitrary); never the verdict.
bandOf :: Double -> Text
bandOf k
  | k < 0.2   = "slight"
  | k < 0.4   = "fair"
  | k < 0.6   = "moderate"
  | k < 0.8   = "substantial"
  | otherwise = "almost perfect"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `zinc test spec`
Expected: PASS — the 12 CalibrationSpec assertions pass (other specs unchanged).

- [ ] **Step 6: Commit**

```bash
git add src/Evals/Calibration.hs test/CalibrationSpec.hs test/Spec.hs
git commit -m "feat: pure calibration trust-threshold + Landis-Koch band helpers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Calibration DTOs in evals-api

**Files:**
- Modify: `evals-api/src/Evals/Api.hs`
- Modify: `src/Evals/Dashboard.hs:268` (keep it compiling — add `calibration = []`)
- Modify: `test/ApiSpec.hs` (DTO round-trip)

- [ ] **Step 1: Write the failing test**

In `test/ApiSpec.hs`, find the existing DTO round-trip section (the early `it`s that `decode . encode` DTOs before the DB specs). Add a round-trip assertion. First add a sample value near the other sample DTOs; then assert. Insert this `it` inside the existing `describe "DTO JSON round-trips"` block (or the equivalent pure block at the top of `ApiSpec.main`):

```haskell
    it "MetaEvalDto / CalibrationSeriesDto round-trip" $ do
      let me = MetaEvalDto
            { graderName = "rubric", graderVersion = 1, graderKind = "pointed"
            , mode = "stored", agreement = 0.88, kappa = 0.78
            , kappaLow = 0.66, kappaHigh = 0.9, failPrecision = 0.8, failRecall = 0.75
            , measured = 40, judgeErrors = 0, computedAt = "2026-06-14T00:00:00Z"
            , trusted = True, band = "substantial" }
          series = CalibrationSeriesDto
            { graderName = "rubric", graderVersion = 1, graderKind = "pointed"
            , mode = "stored", latest = me
            , trend = [ TrendPointDto { runId = 1, kappa = 0.7, kappaLow = 0.55
                                      , kappaHigh = 0.85, computedAt = "2026-06-13T00:00:00Z"
                                      , isCurrent = False } ] }
      decode (encode series) `shouldBe` Just series
```

(If the top pure block uses a different style, match it — the point is `decode (encode x) == Just x`. `decode`/`encode` from `Data.Aeson` are already imported in ApiSpec.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `zinc test spec`
Expected: compile error — `MetaEvalDto`/`CalibrationSeriesDto`/`TrendPointDto` not in scope.

- [ ] **Step 3: Add the DTOs**

In `evals-api/src/Evals/Api.hs`, extend the export list (add to the existing export group):

```haskell
  , MetaEvalDto (..), CalibrationSeriesDto (..), TrendPointDto (..)
```

Add the data declarations (place them just after `GradeDto`/`ExampleDetailDto`, before `ApiError`):

```haskell
-- | One persisted calibration report, denormalised with grader identity and
-- the server-computed verdict ('trusted' = κ CI lower bound ≥ threshold) and
-- 'band' (Landis–Koch). 'judgeErrors' is a count (the stored array's length).
data MetaEvalDto = MetaEvalDto
  { graderName    :: Text
  , graderVersion :: Int
  , graderKind    :: Text
  , mode          :: Text
  , agreement     :: Double
  , kappa         :: Double
  , kappaLow      :: Double
  , kappaHigh     :: Double
  , failPrecision :: Double
  , failRecall    :: Double
  , measured      :: Int
  , judgeErrors   :: Int
  , computedAt    :: Text
  , trusted       :: Bool
  , band          :: Text
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | One point on a grader version's κ-over-time trend. 'isCurrent' marks the
-- run being viewed (run-detail only; always False in the cross-run view).
data TrendPointDto = TrendPointDto
  { runId      :: Int
  , kappa      :: Double
  , kappaLow   :: Double
  , kappaHigh  :: Double
  , computedAt :: Text
  , isCurrent  :: Bool
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | A grader version's calibration history under one mode: the latest report
-- plus the κ trend (chronological, oldest → newest).
data CalibrationSeriesDto = CalibrationSeriesDto
  { graderName    :: Text
  , graderVersion :: Int
  , graderKind    :: Text
  , mode          :: Text
  , latest        :: MetaEvalDto
  , trend         :: [TrendPointDto]
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

Add the `calibration` field to `RunDetailDto`:

```haskell
data RunDetailDto = RunDetailDto
  { run         :: RunSummaryDto
  , outputs     :: [OutputRowDto]
  , calibration :: [CalibrationSeriesDto]
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

- [ ] **Step 4: Keep the server compiling**

In `src/Evals/Dashboard.hs`, the only `RunDetailDto` construction is at line ~268. Add the new field:

```haskell
        pure (Just RunDetailDto { run = summary, outputs = sortedRows, calibration = [] })
```

(Task 3 replaces `[]` with the real builder.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `zinc test spec`
Expected: PASS — round-trip succeeds; server still builds.

- [ ] **Step 6: Commit**

```bash
git add evals-api/src/Evals/Api.hs src/Evals/Dashboard.hs test/ApiSpec.hs
git commit -m "feat: MetaEval/CalibrationSeries/TrendPoint wire DTOs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Server — run-detail calibration builder

**Files:**
- Modify: `src/Evals/Dashboard.hs`
- Modify: `test/ApiSpec.hs`

- [ ] **Step 1: Write the failing test**

In `test/ApiSpec.hs`, the run-detail seed block (`serverSpec`, around line 357-375) already creates `gv` (exactness/exact, version 1) and `pgv` (rubric/pointed, version 1) and run `r`. Seed two `MetaEval` rows for `gv` against `r` (an older one and a newer one, so "latest" is well-defined). Add after the run-metrics inserts in that `withSession` block:

```haskell
    _ <- add (MetaEval { id = MetaEvalId 0, run = r.id, graderVersion = gv.id
                       , mode = "stored", seed = 1, agreement = 0.8, kappa = 0.6
                       , kappaLow = 0.5, kappaHigh = 0.7, failPrecision = 0.7, failRecall = 0.6
                       , measured = 4, judgeErrors = Aeson (toJSON ([] :: [Text]))
                       , computedAt = addUTCTime (-3600) now } :: MetaEval)
    _ <- add (MetaEval { id = MetaEvalId 0, run = r.id, graderVersion = gv.id
                       , mode = "stored", seed = 1, agreement = 0.9, kappa = 0.78
                       , kappaLow = 0.66, kappaHigh = 0.9, failPrecision = 0.8, failRecall = 0.75
                       , measured = 4, judgeErrors = Aeson (toJSON ([] :: [Text]))
                       , computedAt = now } :: MetaEval)
```

Ensure imports exist in ApiSpec: `addUTCTime` from `Data.Time` (`import Data.Time (addUTCTime, ...)`), and `toJSON` from `Data.Aeson`. `Aeson`/`MetaEval`/`MetaEvalId` come from the already-imported `Manifest`/`Evals.Schema`/`Evals.Ids`.

Then, in the run-detail assertions (after `r3 <- getReq ("/api/runs/" <> show runIdInt)` decodes a `RunDetailDto` — find the existing decode, call it `detail`), add:

```haskell
    -- calibration: one series for (exactness v1, stored), latest = the newer row
    let cal = (decodeBody r3 :: RunDetailDto).calibration
    length cal `shouldBe` 1
    let s = head cal
    s.graderName `shouldBe` "exactness"
    s.mode `shouldBe` "stored"
    s.latest.kappa `shouldBe` 0.78
    s.latest.trusted `shouldBe` True
    s.latest.band `shouldBe` "substantial"
    -- trend is chronological and both points mark the current run
    map (.kappa) s.trend `shouldBe` [0.6, 0.78]
    all (.isCurrent) s.trend `shouldBe` True
```

(Use whatever the existing decode helper is named — ApiSpec already decodes `r3` into a `RunDetailDto`; reuse that binding rather than decoding twice. If it currently only checks `.outputs`, bind `detail <- ...` once and read both `detail.outputs` and `detail.calibration`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `zinc test spec`
Expected: FAIL — `calibration` is `[]` (length 0 ≠ 1).

- [ ] **Step 3: Implement the builder**

In `src/Evals/Dashboard.hs`:

Add imports (merge into existing import lines):
- `import Data.List (maximumBy, ...)` — add `maximumBy` to the existing `Data.List` import (already has `minimumBy, nub, sortBy, sortOn`).
- `import Data.Time (UTCTime, defaultTimeLocale, formatTime)`
- `import Evals.Calibration (bandOf, trustedBy)`

Add these helpers (place after `groupedMetricDtos`/`rubricCriteriaFor`, before the `/api/runs/:id` section):

```haskell
-- ---------------------------------------------------------------------------
-- Calibration (meta-eval) surfacing

-- | Resolve a MetaEval row into its wire DTO: grader identity, judge-error
-- count, and the server-computed trust verdict + Landis–Koch band.
metaEvalDto :: MetaEval -> Db MetaEvalDto
metaEvalDto me = do
  mgv <- get @GraderVersion (Key me.graderVersion)
  mg  <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv
  pure MetaEvalDto
    { graderName    = maybe "?" (.name) mg
    , graderVersion = maybe 0 (.version) mgv
    , graderKind    = maybe "?" (.kind) mg
    , mode          = me.mode
    , agreement     = me.agreement
    , kappa         = me.kappa
    , kappaLow      = me.kappaLow
    , kappaHigh     = me.kappaHigh
    , failPrecision = me.failPrecision
    , failRecall    = me.failRecall
    , measured      = me.measured
    , judgeErrors   = judgeErrorCount me.judgeErrors
    , computedAt    = isoTime me.computedAt
    , trusted       = trustedBy me.kappaLow
    , band          = bandOf me.kappa
    }

-- | A trend point. 'isCurrent' is True when this report belongs to the run
-- being viewed (Nothing → cross-run view, never current).
trendPoint :: Maybe RunId -> MetaEval -> TrendPointDto
trendPoint mrid me =
  let RunId rid = me.run
  in TrendPointDto
       { runId      = rid
       , kappa      = me.kappa
       , kappaLow   = me.kappaLow
       , kappaHigh  = me.kappaHigh
       , computedAt = isoTime me.computedAt
       , isCurrent  = maybe False (== me.run) mrid
       }

judgeErrorCount :: Aeson Value -> Int
judgeErrorCount (Aeson v) = case v of
  Aeson.Array a -> length a
  _             -> 0

isoTime :: UTCTime -> T.Text
isoTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | Build one CalibrationSeriesDto from a chosen "latest" row and a chronological
-- history (already filtered to one (graderVersion, mode) group).
buildSeries :: Maybe RunId -> MetaEval -> [MetaEval] -> Db CalibrationSeriesDto
buildSeries mrid latestRow history = do
  latestDto <- metaEvalDto latestRow
  pure CalibrationSeriesDto
    { graderName    = latestDto.graderName
    , graderVersion = latestDto.graderVersion
    , graderKind    = latestDto.graderKind
    , mode          = latestDto.mode
    , latest        = latestDto
    , trend         = map (trendPoint mrid) (sortOn (.computedAt) history)
    }

-- | Calibration series for a single run: latest report per (graderVersion,
-- mode) seen on THIS run, each with that grader version's κ trend across ALL
-- runs (so the sparkline shows whether this run's κ is typical).
runCalibration :: RunId -> Db [CalibrationSeriesDto]
runCalibration rid = do
  thisRun <- selectWhere [ #run ==. rid ] :: Db [MetaEval]
  let byGroup = Map.fromListWith (++) [ ((me.graderVersion, me.mode), [me]) | me <- thisRun ]
  mapM buildGroup (Map.toList byGroup)
  where
    buildGroup ((gvId, md), rows) = do
      let latestRow = maximumBy (comparing (.computedAt)) rows
      allForGv <- selectWhere [ #graderVersion ==. gvId ] :: Db [MetaEval]
      let history = [ h | h <- allForGv, h.mode == md ]
      buildSeries (Just rid) latestRow history
```

Then wire it into `runDetailHandler` — replace the `calibration = []` placeholder. The `buildOne`/construction lives in the `withSession` `Db` block; add a fetch before the `pure`:

```haskell
        cal <- runCalibration rid
        pure (Just RunDetailDto { run = summary, outputs = sortedRows, calibration = cal })
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zinc test spec`
Expected: PASS — run-detail returns one series, latest κ 0.78, trusted, band "substantial", trend `[0.6,0.78]` all current.

- [ ] **Step 5: Commit**

```bash
git add src/Evals/Dashboard.hs test/ApiSpec.hs
git commit -m "feat: run-detail calibration series with cross-run kappa trend

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Server — GET /api/calibration

**Files:**
- Modify: `src/Evals/Dashboard.hs`
- Modify: `test/ApiSpec.hs`

- [ ] **Step 1: Write the failing test**

In `test/ApiSpec.hs` `serverSpec`, after the run-detail assertions, add:

```haskell
    -- cross-run calibration
    rCal <- getReq "/api/calibration"
    statusOf rCal `shouldBe` 200
    let series = decodeBody rCal :: [CalibrationSeriesDto]
    -- one series for the seeded (exactness v1, stored) group
    map (\s -> (s.graderName, s.mode)) series `shouldBe` [("exactness", "stored")]
    let s0 = head series
    s0.latest.kappa `shouldBe` 0.78
    map (.kappa) s0.trend `shouldBe` [0.6, 0.78]
    all (not . (.isCurrent)) s0.trend `shouldBe` True
```

(Use the same `getReq`/`statusOf`/`decodeBody` helpers the surrounding assertions use — match their exact names.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `zinc test spec`
Expected: FAIL — `/api/calibration` returns 404 (route absent).

- [ ] **Step 3: Implement the route + handler**

In `src/Evals/Dashboard.hs`, add the route in the `pathInfo` case (next to `["api","compare"]`, line ~54):

```haskell
    ["api", "calibration"] -> apiWith (calibrationHandler pool respond)
```

Add the handler (after `runDetailHandler`/`exampleDetailHandler` block, before the `notFound` helpers):

```haskell
-- | GET /api/calibration — every (graderVersion, mode) group that has any
-- MetaEval row: the overall latest report + the full κ trend (no current marker).
calibrationHandler :: Pool -> (Response -> IO a) -> IO a
calibrationHandler pool respond = do
  series <- withSession pool $ do
    allMetas <- selectWhere ([] :: [Cond MetaEval])
    let byGroup = Map.fromListWith (++) [ ((me.graderVersion, me.mode), [me]) | me <- allMetas ]
        build ((_gv, _md), rows) =
          buildSeries Nothing (maximumBy (comparing (.computedAt)) rows) rows
    mapM build (Map.toList byGroup)
  let sorted = sortBy (comparing (\s -> (s.graderName, s.graderVersion, s.mode))) series
  respond (json status200 sorted)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zinc test spec`
Expected: PASS — `/api/calibration` returns one series, latest κ 0.78, trend `[0.6,0.78]`, none current.

- [ ] **Step 5: Commit**

```bash
git add src/Evals/Dashboard.hs test/ApiSpec.hs
git commit -m "feat: GET /api/calibration cross-run grader-calibration endpoint

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: UI Model — CalibrationR route + remote field

**Files:**
- Modify: `evals-ui/src/Evals/Ui/Model.hs`

This is a wasm module — verify by building (`scripts/build-ui.sh`), no unit test.

- [ ] **Step 1: Add the route constructor**

In the `Route` data type (line ~53), add `CalibrationR`:

```haskell
data Route
  = RunsR
  | RunR Int
  | CompareR Int Int
  | ExampleR Int T.Text
  | CalibrationR
  deriving (Show, Eq)
```

- [ ] **Step 2: Add the remote field, lens, action**

In `Model` add (after `_exampleM`):

```haskell
  , _calibrationM :: RemoteData [CalibrationSeriesDto]
```

Update `emptyModel` to add the new `NotAsked` in the matching position:

```haskell
emptyModel = Model RunsR NotAsked NotAsked NotAsked NotAsked NotAsked [] [] LiveReconnecting False False
```

(Count the fields: `_runsM _detailM _compareM _exampleM _calibrationM` → five `NotAsked` before `_selectedM`'s `[]`.)

Add the lens next to `exampleM` (mirror its definition exactly, swapping the field):

```haskell
calibrationM :: Lens Model (RemoteData [CalibrationSeriesDto])
calibrationM = lens _calibrationM (\m v -> m { _calibrationM = v })
```

Add the lens to the module export list (next to the other `...M` lens exports).

Add the action (after `GotExample`):

```haskell
  | GotCalibration (Either MisoString [CalibrationSeriesDto])
```

- [ ] **Step 3: Add hash + parse + relevance**

Add `calibrationHash` near `runHash`/`compareHash`/`exampleHash` and export it:

```haskell
calibrationHash :: MisoString
calibrationHash = "#/calibration"
```

In `parseHash`, add a case for the `["calibration"]` segment list (match the existing structure — it splits the hash on `/`). Add alongside the other matches:

```haskell
    ["calibration"] -> CalibrationR
```

In `relevantTo`, make `CalibrationR` relevant to the `meta_evals` table so SSE refetches it:

```haskell
relevantTo CalibrationR table = table == "meta_evals"
```

(Add this equation next to the existing `relevantTo` equations; keep the catch-all last.)

- [ ] **Step 4: Verify the build**

Run: `scripts/build-ui.sh`
Expected: builds clean (Main.hs may warn about a missing `GotCalibration`/`CalibrationR` case — fixed in Task 6; if it errors on non-exhaustive `update`/`fetchRoute`, that is expected until Task 6).

(If the build fails only because `Main.hs` doesn't yet handle the new constructors, proceed to Task 6 and build them together; do not commit a broken build. Otherwise commit:)

- [ ] **Step 5: Commit**

```bash
git add evals-ui/src/Evals/Ui/Model.hs
git commit -m "feat(ui): CalibrationR route + calibration remote field

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: UI Main — wire fetch + update for CalibrationR

**Files:**
- Modify: `evals-ui/src/Main.hs`

- [ ] **Step 1: Handle the new route in SetRoute**

In `updateModel`, the `SetRoute` arm resets the per-route remote to `Loading` then fires `fetchRoute`. Add `CalibrationR` so it sets `calibrationM .~ Loading` (mirror how `RunR`/`ExampleR` reset their field). Find the `SetRoute` case and add the `CalibrationR` branch alongside the others.

- [ ] **Step 2: Handle GotCalibration**

Add an update arm mirroring `GotRuns` (no stale guard needed — there's only one calibration resource):

```haskell
    GotCalibration r -> m & calibrationM .~ either Failed Got r <# pure NoOp
```

(Match the exact shape used by `GotRuns` in this file — if it uses `noEff`/`<#`/effectful style, copy that style. The point: set `calibrationM` to `Failed`/`Got`.)

- [ ] **Step 3: Handle fetchRoute**

In `fetchRoute`, add the `CalibrationR` mapping to fetch `"/api/calibration"` and dispatch `GotCalibration`:

```haskell
    CalibrationR -> fetchJson "/api/calibration" GotCalibration
```

(Match the exact `fetchJson` signature/argument order used by the existing `RunsR`/`RunR` arms.)

- [ ] **Step 4: Handle DoRefetch**

If `DoRefetch` switches on the current route to re-issue the fetch, add `CalibrationR` there too (re-fetch `/api/calibration`). If `DoRefetch` simply calls `fetchRoute (_routeM m)`, no change is needed — verify which pattern is used and act accordingly.

- [ ] **Step 5: Verify the build**

Run: `scripts/build-ui.sh`
Expected: builds clean, no non-exhaustive-pattern warnings for Route.

- [ ] **Step 6: Commit**

```bash
git add evals-ui/src/Main.hs evals-ui/src/Evals/Ui/Model.hs
git commit -m "feat(ui): fetch + update wiring for the calibration route

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: UI View — calibration card + sparkline + run-detail section

**Files:**
- Modify: `evals-ui/src/Evals/Ui/View.hs`

- [ ] **Step 1: Add the card + sparkline renderers**

Add these functions (place near `breakdownChart`). The κ bar reuses `pct`/`fmtD`. The sparkline is an inline SVG via `Miso.Svg`.

Add imports at the top of `View.hs`:

```haskell
import qualified Miso.Svg.Element as S
import qualified Miso.Svg.Property as SP
```

Card renderer:

```haskell
-- | One grader version's calibration: headline κ bar + verdict, sparkline,
-- and the secondary precision/recall/agreement line. Reused by the run-detail
-- section and the cross-run view.
calibCard :: CalibrationSeriesDto -> View Model Action
calibCard s =
  div_ [ P.class_ "calib-card" ]
    [ div_ [ P.class_ "calib-head" ]
        [ span_ [ P.class_ "gname" ] [ text (ms s.graderName <> " v" <> msShow s.graderVersion) ]
        , span_ [ P.class_ ("kind " <> ms s.graderKind) ] [ text (ms s.graderKind) ]
        , span_ [ P.class_ "mode" ] [ text (ms s.mode) ]
        ]
    , kappaBar s.latest
    , calibSpark s.trend
    , div_ [ P.class_ "calib-sub" ]
        [ text ("fail precision " <> fmtD s.latest.failPrecision
                <> " · fail recall " <> fmtD s.latest.failRecall
                <> " · agreement " <> pct s.latest.agreement
                <> " · n=" <> msShow s.latest.measured
                <> (if s.latest.judgeErrors > 0
                      then " · " <> msShow s.latest.judgeErrors <> " judge errors" else ""))
        ]
    , div_ [ P.class_ "calib-band" ]
        [ text ("κ " <> fmtD s.latest.kappa <> " — \8220" <> ms s.latest.band <> "\8221 on the Landis\8211Koch scale") ]
    ]

-- | κ value + 95% CI on a 0–1 track with a trust-threshold tick at 0.6 and a
-- verdict driven by the CI lower bound.
kappaBar :: MetaEvalDto -> View Model Action
kappaBar me =
  div_ [ P.class_ "calib-bar" ]
    [ div_ [ P.class_ "calib-track" ]
        [ span_ [ P.class_ "calib-ci", styleInline_ (ciStyle me.kappaLow me.kappaHigh) ] []
        , span_ [ P.class_ "calib-mark", styleInline_ ("left:" <> pct me.kappa) ] []
        , span_ [ P.class_ "calib-threshold", styleInline_ ("left:" <> pct 0.6) ] []
        ]
    , span_ [ P.class_ ("calib-verdict " <> if me.trusted then "trusted" else "untrusted") ]
        [ text ("κ " <> fmtD me.kappa
                <> " (95% CI " <> fmtD me.kappaLow <> "\8211" <> fmtD me.kappaHigh <> ") — "
                <> (if me.trusted then "trustworthy" else "below trust threshold")) ]
    ]

-- | Inline-SVG sparkline of κ over runs; current/latest point highlighted, a
-- faint line at the 0.6 threshold. Empty trend → nothing.
calibSpark :: [TrendPointDto] -> View Model Action
calibSpark [] = text ""
calibSpark pts =
  S.svg_ [ SP.viewBox_ "0 0 100 30", P.class_ "calib-spark" ]
    ( S.line_ [ SP.x1_ "0", SP.y1_ (ms (yOf 0.6)), SP.x2_ "100", SP.y2_ (ms (yOf 0.6)), P.class_ "thr" ] []
    : S.polyline_ [ SP.points_ (ms polyPts), P.class_ "line" ] []
    : [ S.circle_ [ SP.cx_ (ms (xOf i)), SP.cy_ (ms (yOf p.kappa))
                  , SP.r_ (if p.isCurrent then "2.5" else "1.5")
                  , P.class_ (if p.isCurrent then "pt cur" else "pt") ] []
      | (i, p) <- zip [0 :: Int ..] pts ] )
  where
    n      = length pts
    xOf i  = if n <= 1 then 50 else fromIntegral i / fromIntegral (n - 1) * 100 :: Double
    yOf k  = 30 - max 0 (min 1 k) * 30 :: Double   -- κ 0 at bottom, 1 at top
    polyPts = T.intercalate " " [ showD (xOf i) <> "," <> showD (yOf p.kappa) | (i, p) <- zip [0 ..] pts ]
    showD d = T.pack (showFFloat (Just 1) d "")

-- | Inline @left:..%;width:..%@ for the CI band span (clamped to [0,1]).
ciStyle :: Double -> Double -> MisoString
ciStyle lo hi =
  let l = max 0 (min 1 lo); h = max 0 (min 1 hi)
  in "left:" <> pct l <> ";width:" <> pct (max 0 (h - l))
```

Note: `S.line_`/`S.polyline_`/`S.circle_`/`S.svg_` and `SP.*` come from `Miso.Svg.Element`/`Miso.Svg.Property`. If a specific attribute name differs in this Miso version (e.g. `points_` lives in `Miso.Svg.Property`), the implementer should check `/home/gareth/.zinc/store/checkout/miso/src/Miso/Svg/Property.hs` and adjust. `P.class_` works on SVG nodes.

- [ ] **Step 2: Add the run-detail section + wire into detailView**

Add:

```haskell
-- | Run-detail calibration block — omitted entirely when the run has no
-- meta-evals (the common case for older runs).
calibrationSection :: [CalibrationSeriesDto] -> View Model Action
calibrationSection [] = text ""
calibrationSection ss =
  div_ [ P.class_ "calib" ]
    ( h3_ [] [ text "grader calibration" ] : map calibCard ss )
```

Wire it into `detailView` (line ~150) — add after `outputsTable`:

```haskell
detailView m _ =
  remoteView (_detailM m) $ \d ->
    div_
      [ P.class_ "detail" ]
      [ backLink
      , runHeader (_expandedM m) d.run
      , outputsTable d.run.runId (_expandedM m) d.run.metrics d.outputs
      , calibrationSection d.calibration
      ]
```

- [ ] **Step 3: Verify the build**

Run: `scripts/build-ui.sh`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add evals-ui/src/Evals/Ui/View.hs
git commit -m "feat(ui): calibration card, kappa bar, sparkline, run-detail section

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: UI View — cross-run calibration view + nav

**Files:**
- Modify: `evals-ui/src/Evals/Ui/View.hs`

- [ ] **Step 1: Add the cross-run view**

```haskell
-- | The #/calibration page: a teaching legend then one card per grader series.
calibrationView :: Model -> View Model Action
calibrationView m =
  remoteView (_calibrationM m) $ \ss ->
    div_ [ P.class_ "calib calib-page" ]
      [ backLink
      , h2_ [] [ text "grader calibration" ]
      , div_ [ P.class_ "calib-legend" ]
          [ text ("κ (Cohen's kappa) measures judge\8211human agreement beyond chance. "
                  <> "The bar shows κ with its 95% CI; the tick at 0.6 is the trust threshold "
                  <> "\8212 a grader is \8220trustworthy\8221 when the CI lower bound clears it. "
                  <> "fail precision/recall describe how well it catches real failures.") ]
      , if null ss
          then p_ [ P.class_ "empty" ] [ text "no calibration runs yet." ]
          else div_ [] (map calibCard ss)
      ]
```

- [ ] **Step 2: Dispatch it in viewModel**

In `viewModel`'s `body` case (line ~42), add:

```haskell
      CalibrationR -> calibrationView m
```

- [ ] **Step 3: Add a nav link**

The runs view header/toolbar is where the runs list renders nav. Add a link to `calibrationHash` in the runs view (find `runsView` and add, near the top, a small nav line):

```haskell
      , a_ [ P.class_ "nav-link", P.href_ calibrationHash ] [ text "grader calibration →" ]
```

(Place it where it reads naturally — e.g. under the runs `h2_`. Mirror the existing link styling; `calibrationHash` is exported from `Evals.Ui.Model`.)

- [ ] **Step 4: Verify the build**

Run: `scripts/build-ui.sh`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add evals-ui/src/Evals/Ui/View.hs
git commit -m "feat(ui): cross-run #/calibration view + nav link

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Styles

**Files:**
- Modify: `static/style.css`

- [ ] **Step 1: Add calibration styles**

Append to `static/style.css` (uses the existing `--line`/`--muted`/`--accent`/`--muted-bg` vars; mirrors the `.run-header`/`.card` white-card idiom):

```css
/* ---- grader calibration ---- */
.calib { margin-top: 1.5rem; }
.calib > h3 { margin: 0 0 .75rem; font-size: 1rem; }
.calib-page { max-width: 820px; }
.calib-legend {
  background: var(--muted-bg); border: 1px solid var(--line); border-radius: 8px;
  padding: .75rem .9rem; color: var(--muted); font-size: .85rem; line-height: 1.5;
  margin-bottom: 1rem;
}
.calib-card {
  background: #fff; border: 1px solid var(--line); border-radius: 8px;
  padding: .9rem 1rem; margin-bottom: .9rem;
}
.calib-head { display: flex; align-items: center; gap: .5rem; margin-bottom: .6rem; }
.calib-head .gname { font-weight: 600; }
.calib-head .kind, .calib-head .mode {
  font-size: .7rem; text-transform: uppercase; letter-spacing: .03em;
  padding: .1rem .4rem; border-radius: 4px; background: var(--muted-bg); color: var(--muted);
}
.calib-bar { display: flex; align-items: center; gap: .75rem; margin-bottom: .5rem; }
.calib-track {
  position: relative; flex: 0 0 200px; height: 10px; border-radius: 5px;
  background: var(--muted-bg);
}
.calib-ci { position: absolute; top: 0; height: 100%; background: rgba(36,86,200,.25); border-radius: 5px; }
.calib-mark { position: absolute; top: -2px; width: 2px; height: 14px; background: var(--accent); }
.calib-threshold { position: absolute; top: -3px; width: 0; height: 16px; border-left: 1px dashed var(--muted); }
.calib-verdict { font-size: .85rem; }
.calib-verdict.trusted { color: #1a7f4b; }
.calib-verdict.untrusted { color: #b4541a; }
.calib-spark { width: 120px; height: 36px; display: block; margin: .25rem 0 .5rem; overflow: visible; }
.calib-spark .line { fill: none; stroke: var(--accent); stroke-width: 1; }
.calib-spark .thr { stroke: var(--muted); stroke-width: .5; stroke-dasharray: 2 2; }
.calib-spark .pt { fill: var(--accent); }
.calib-spark .pt.cur { fill: #1a7f4b; }
.calib-sub { font-size: .8rem; color: var(--muted); }
.calib-band { font-size: .8rem; color: var(--muted); margin-top: .2rem; }
.nav-link { color: var(--accent); text-decoration: none; font-size: .9rem; }
.nav-link:hover { text-decoration: underline; }
```

- [ ] **Step 2: Verify (static asset — no build)**

The CSS is served by the dashboard directly; no compile step. Re-running the dashboard (Task 12) picks it up.

- [ ] **Step 3: Commit**

```bash
git add static/style.css
git commit -m "style: grader calibration card, kappa bar, sparkline

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Demo seed — meta_evals rows

**Files:**
- Modify: `scripts/seed-demo.sh`

- [ ] **Step 1: Add meta_evals INSERTs**

In `scripts/seed-demo.sh`, after the `run_metrics` INSERT block (before the `setval` line), add. Grader version 1 = exactness/exact; grader version 2 = rubric/pointed (per the existing seed). Give exactness a comfortably-trustworthy, rising trend; give rubric a borderline-untrustworthy one. Two runs exist (1, 2).

```sql
-- meta-eval calibration history (append-only). exactness climbs and clears the
-- 0.6 trust threshold; rubric sits borderline below it. Two computedAt points
-- per grader make the sparkline meaningful.
INSERT INTO meta_evals
  (id, run, grader_version, mode, seed, agreement, kappa, kappa_low, kappa_high,
   fail_precision, fail_recall, measured, judge_errors, computed_at) VALUES
  -- exactness (gv 1): trustworthy, rising
  (1, 1, 1, 'stored', 1, 0.86, 0.70, 0.58, 0.82, 0.83, 0.80, 4, '[]', now() - interval '25 hours'),
  (2, 2, 1, 'stored', 1, 0.92, 0.80, 0.66, 0.92, 0.88, 0.85, 4, '[]', now() - interval '1 hour'),
  -- rubric (gv 2): borderline, below threshold
  (3, 1, 2, 'stored', 1, 0.74, 0.52, 0.34, 0.70, 0.66, 0.60, 4, '["capital-au"]', now() - interval '25 hours'),
  (4, 2, 2, 'stored', 1, 0.78, 0.55, 0.38, 0.72, 0.70, 0.64, 4, '[]', now() - interval '1 hour');
```

- [ ] **Step 2: Keep the sequence ahead**

In the existing `SELECT setval(...)` block, add the meta_evals sequence:

```sql
       setval('meta_evals_id_seq', 10);
```

(Append it inside the existing `setval(...)` SELECT — match the existing comma/format. Confirm the sequence name with `\d meta_evals` if unsure; manifest's `genericTableMeta "meta_evals"` yields `meta_evals_id_seq`.)

- [ ] **Step 3: Re-seed and eyeball**

Run: `scripts/seed-demo.sh` (against the demo DB the script targets).
Expected: no SQL error; `meta_evals` has 4 rows.

- [ ] **Step 4: Commit**

```bash
git add scripts/seed-demo.sh
git commit -m "chore: seed meta_evals calibration history for the demo

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: Full test run

**Files:** none (verification)

- [ ] **Step 1: Run the whole suite**

Run: `zinc test spec`
Expected: PASS — CalibrationSpec + ApiSpec calibration assertions + all pre-existing specs green.

- [ ] **Step 2: Native build**

Run: `zinc build`
Expected: clean.

---

### Task 12: Rebuild wasm + restart server

**Files:** none (deploy/verify)

> **Gotcha:** a wire-shape change needs BOTH the wasm rebuilt AND the running `evals-dashboard` process restarted — the on-disk binary and the in-memory one are independent.

- [ ] **Step 1: Build the UI**

Run: `scripts/build-ui.sh`
Expected: wasm reactor + static artifacts staged, no errors.

- [ ] **Step 2: Re-seed the demo DB** (if not already done in Task 10)

Run: `scripts/seed-demo.sh`

- [ ] **Step 3: Restart the dashboard**

Kill the running `evals-dashboard`, then start it again on the demo DB (port 8787, as before). The controller handles process management — see prior session pattern (`scripts/start-server.sh` or the direct `evals-dashboard` invocation used for the demo).

- [ ] **Step 4: Manual smoke (controller, not subagent)**

Load `#/runs/1` — a "grader calibration" section appears with two cards (exactness trusted/green, rubric below-threshold/amber), each with a sparkline. Load `#/calibration` — the legend + both series. Confirm no console decode errors.

---

## Self-Review

**Spec coverage:**
- Headline κ + CI bar + threshold marker + verdict → Task 7 `kappaBar`. ✓
- Verdict from CI-lower-bound vs threshold → Task 1 `trustedBy`, surfaced in Task 7. ✓
- κ-over-time sparkline, current point marked → Task 7 `calibSpark`, `isCurrent` from Task 3. ✓
- fail precision/recall + agreement + n → Task 7 `calibCard` sub-line. ✓
- Landis–Koch demoted to sub-label → Task 1 `bandOf`, Task 7 `.calib-band`. ✓
- `MetaEvalDto`/`CalibrationSeriesDto`/`TrendPointDto`, `RunDetailDto.calibration` → Task 2. ✓
- Server run-detail (latest-per-(gv,mode), trend across runs) → Task 3. ✓
- `GET /api/calibration` → Task 4. ✓
- UI route/model/fetch/view/nav → Tasks 5–8. ✓
- Styles → Task 9. ✓
- Demo seed enrichment (one trustworthy, one borderline, visible trend) → Task 10. ✓
- Tests (band/trust units, run-detail calibration, cross-run endpoint) → Tasks 1, 3, 4. ✓
- Rebuild wasm + restart → Task 12. ✓

**Type consistency:** `kappaTrustThreshold`/`bandOf`/`trustedBy` defined Task 1, used Task 3 & 7. DTO field names (`kappaLow`/`kappaHigh`/`failPrecision`/`failRecall`/`judgeErrors`/`computedAt`/`trusted`/`band`/`isCurrent`/`latest`/`trend`) defined Task 2, consumed identically in Tasks 3/4/7/8. `runCalibration`/`buildSeries`/`metaEvalDto`/`trendPoint`/`calibrationHandler` names consistent across Tasks 3–4. `calibrationM`/`GotCalibration`/`CalibrationR`/`calibrationHash` consistent across Tasks 5–8.

**Placeholder scan:** none — `calibration = []` in Task 2 is an explicit interim that Task 3 replaces (called out in both).

**Known risk:** Miso SVG attribute names (Task 7) may differ slightly in this Miso checkout; the task points the implementer at `Miso/Svg/Property.hs` to confirm. The spec permits a div-based fallback if SVG proves troublesome, but SVG is preferred.
