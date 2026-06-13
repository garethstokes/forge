# Tag Dimensional Metrics (HealthBench slice 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `RunMetric` gains a `tag` dimension; `recompute` emits, per grader version, an overall metric plus per-theme (example-level) and per-axis/cluster (pointed criterion-level, re-scored from stored verdicts) breakdowns, every mean clipped to [0,1]. The dashboard keeps showing the overall metric only.

**Architecture:** A pure aggregator (`dimensionalMetrics`, `axisScoresFromDetail`, `exampleThemes`, `clip01`) added to `Evals.Grade`, tested in isolation. `recompute`'s per-gv query widens to join `Example` and project `(value, passed, detail, meta)`, feeds the aggregator, and writes one `RunMetric` per emitted `DimMetric`. The dashboard's metric query filters to overall rows app-side.

**Tech Stack:** the existing lib closure (`aeson`, `containers`, `manifest`); ephemeral Postgres via `Manifest.Testing.withEphemeralDb`; the in-repo Harness.

**Spec:** `docs/superpowers/specs/2026-06-13-tag-metrics-design.md`

**Repo facts (verified):** `RunMetricT {id, run, graderVersion, mean :: Double, passRate :: Maybe Double, count :: Int, computedAt}` — no `tag`, no extra index; the Entity instance is standalone (`notifyChanges = True`). `recompute` (in `Evals.Grade`'s `scoreRun` where-clause) currently: per gv, `runQuery` joins `Score → Output` (`o ?. #id .== s ?. #output`, `o ?. #run .== val runId .&& s ?. #graderVersion .== val gv.id`), projects `(s ?. #value, s ?. #passed)`, computes unclipped mean + passRate-over-`Just` + count, `deleteWhere [#run, #graderVersion]`, adds one RunMetric. The pointed `Score.detail` shape: `{achieved, possible, criteria: [{criterion, points, tags :: [Text], met :: Bool, explanation}]}`. Multi-column projections nest as pairs: `(a, (b, (c, d)))`. The `Example` join idiom: `innerJoin @Example (\e -> e ?. #id .== o ?. #example)` (see SchemaSpec scenario D). `Score.detail`/`Example.meta` are `Field f (Maybe (Aeson Value))` → projected as `Maybe (Aeson Value)`, unwrap with `fmap (\(Aeson x) -> x)`. `Grade.hs` already imports `Data.List (find, nub)`, `qualified Data.Map.Strict as Map`, `Data.Aeson.Types as AT`, `Data.Aeson (Value (..), object, (.=))`. The dashboard's metric query is `selectWhere [#run ==. r.id] :: Db [RunMetric]` (`Dashboard.hs:171`, in `runSummary`). `MANIFEST` `==.` against `Nothing` does NOT reliably emit SQL `IS NULL` — filter overall rows app-side, not in the query.

## File structure

- Modify `src/Evals/Schema.hs` — `RunMetricT` gains `tag`.
- Modify `src/Evals/Grade.hs` — the pure aggregator (Task 1) + the `recompute` rewrite (Task 2).
- Modify `src/Evals/Dashboard.hs` — filter `runSummary`'s metrics to overall (Task 3).
- Modify `test/GradeSpec.hs` — pure aggregator tests (Task 1) + the dimensional engine scenario (Task 2); patch RunMetric literals.
- Modify `test/SchemaSpec.hs`, `test/ApiSpec.hs` — patch RunMetric literals + the dashboard overall-only assertion (Task 3).
- Modify `README.md` — note the breakdowns (Task 3).

---

### Task 1: schema column + the pure aggregator (TDD)

**Files:** Modify `src/Evals/Schema.hs`, `src/Evals/Grade.hs`, `test/GradeSpec.hs`; patch RunMetric literals across `test/{SchemaSpec,ApiSpec}.hs`.

- [ ] **Step 1: the column.** In `src/Evals/Schema.hs`, add `tag` to `RunMetricT` as the LAST field (mirrors how `ALTER TABLE ADD COLUMN` appends, so a fresh-migrated and an in-place-migrated DB agree on nothing-but-name anyway):

```haskell
data RunMetricT f = RunMetric
  { id            :: Field f (Pk RunMetricId)
  , run           :: Field f RunId
  , graderVersion :: Field f GraderVersionId
  , mean          :: Field f Double
  , passRate      :: Field f (Maybe Double)
  , count         :: Field f Int
  , computedAt    :: Field f UTCTime
  , tag           :: Field f (Maybe Text)   -- Nothing = overall; Just t = a per-tag breakdown
  } deriving Generic
```

- [ ] **Step 2: make existing RunMetric constructions compile.** Grep `grep -rn 'RunMetric {' src/ test/`. Add `tag = Nothing` to EVERY `RunMetric {...}` literal: the existing `recompute` add in `src/Evals/Grade.hs` (still old code — Task 2 rewrites it), and every test seed (e.g. `test/ApiSpec.hs`'s dashboard seed, any `test/SchemaSpec.hs` seed). Build to confirm: `nix develop -c zinc build 2>&1 | tail -3` — links.

- [ ] **Step 3: failing pure tests.** In `test/GradeSpec.hs` add a `dimSpec` (called from `main` after `pointedPureSpec`):

```haskell
dimSpec :: IO ()
dimSpec = do
  expect "clip01 below" (clip01 (-0.5) == 0)
  expect "clip01 above" (clip01 1.5 == 1)
  expect "clip01 in-range" (clip01 0.4 == 0.4)
  -- axisScoresFromDetail: A(4,acc,met) B(6,comp,unmet) -> acc 1.0, comp 0.0
  let detail = object
        [ "achieved" .= (4 :: Double), "possible" .= (10 :: Double)
        , "criteria" .=
          [ object ["criterion" .= ("A"::Text), "points" .= (4::Double)
                   , "tags" .= (["axis:accuracy"]::[Text]), "met" .= True, "explanation" .= (""::Text)]
          , object ["criterion" .= ("B"::Text), "points" .= (6::Double)
                   , "tags" .= (["axis:completeness"]::[Text]), "met" .= False, "explanation" .= (""::Text)]
          ] ]
  expect "axisScores per-tag"
    (sortOn fst (axisScoresFromDetail detail) == [("axis:accuracy", 1.0), ("axis:completeness", 0.0)])
  -- a criterion with no positive points contributes no tag (HealthBench None-skip)
  let negOnly = object ["criteria" .=
        [ object ["criterion" .= ("X"::Text), "points" .= ((-3)::Double)
                 , "tags" .= (["axis:safety"]::[Text]), "met" .= True, "explanation" .= (""::Text)] ]]
  expect "axisScores skips no-positive tag" (axisScoresFromDetail negOnly == [])
  -- a multi-tag criterion contributes to each tag
  let multi = object ["criteria" .=
        [ object ["criterion" .= ("M"::Text), "points" .= (5::Double)
                 , "tags" .= (["axis:accuracy","cluster:c1"]::[Text]), "met" .= True, "explanation" .= (""::Text)] ]]
  expect "axisScores multi-tag"
    (sortOn fst (axisScoresFromDetail multi) == [("axis:accuracy", 1.0), ("cluster:c1", 1.0)])
  expect "axisScores malformed -> []" (axisScoresFromDetail (object ["rationale" .= ("x"::Text)]) == [])
  -- exampleThemes
  expect "exampleThemes present"
    (exampleThemes (object ["example_tags" .= (["theme:x","theme:y"]::[Text])]) == ["theme:x","theme:y"])
  expect "exampleThemes absent -> []" (exampleThemes (object ["other" .= (1::Int)]) == [])
  -- dimensionalMetrics over two rows
  let row1 = (Just 0.4, Nothing, Just detail, Just (object ["example_tags" .= (["theme:x"]::[Text])]))
      row2 = (Just 0.8, Nothing, Just multi,  Just (object ["example_tags" .= (["theme:x"]::[Text])]))
      ms = dimensionalMetrics [row1, row2]
      byTag = sortOn (\m -> m.tag) ms
  expect "dim overall mean = clip01 avg(0.4,0.8) = 0.6"
    (case [ m | m <- ms, m.tag == Nothing ] of [m] -> abs (m.mean - 0.6) < 1e-9 && m.count == 2 && m.passRate == Nothing; _ -> False)
  expect "dim theme:x mean = avg(0.4,0.8) = 0.6, count 2"
    (case [ m | m <- ms, m.tag == Just "theme:x" ] of [m] -> abs (m.mean - 0.6) < 1e-9 && m.count == 2; _ -> False)
  expect "dim axis:accuracy mean = avg(1.0,1.0) = 1.0, count 2"
    (case [ m | m <- ms, m.tag == Just "axis:accuracy" ] of [m] -> abs (m.mean - 1.0) < 1e-9 && m.count == 2; _ -> False)
  expect "dim axis:completeness only from row1, count 1, mean 0.0"
    (case [ m | m <- ms, m.tag == Just "axis:completeness" ] of [m] -> m.mean == 0.0 && m.count == 1; _ -> False)
  -- a negative overall row clips the overall mean to 0
  let neg = (Just (-0.5), Nothing, Nothing, Nothing)
  expect "dim overall clips negative to 0"
    (case [ m | m <- dimensionalMetrics [neg], m.tag == Nothing ] of [m] -> m.mean == 0 && m.count == 1; _ -> False)
  byTag `seq` pure ()
```

(`sortOn` from `Data.List` — add to GradeSpec's imports if absent. `clip01`/`axisScoresFromDetail`/`exampleThemes`/`dimensionalMetrics`/`DimMetric (..)` come from `Evals.Grade` — import them.) Run `nix develop -c zinc test 2>&1 | tail -4` — compile FAILURE (names missing).

- [ ] **Step 4: implement** in `src/Evals/Grade.hs` (export `DimMetric (..)`, `clip01`, `axisScoresFromDetail`, `exampleThemes`, `dimensionalMetrics`):

```haskell
-- | One emitted metric row: the overall (tag Nothing) or a per-tag breakdown.
data DimMetric = DimMetric
  { tag      :: Maybe Text
  , mean     :: Double
  , passRate :: Maybe Double
  , count    :: Int
  } deriving (Eq, Show)

-- | Clip a mean to [0,1] (HealthBench's aggregate clip).
clip01 :: Double -> Double
clip01 = max 0 . min 1

-- | Per-tag @achieved / possible@ over one example's pointed 'Score.detail'.
-- A criterion with multiple tags contributes to each; a tag whose criteria
-- have no positive points is skipped (HealthBench's @None@). A non-pointed or
-- malformed detail yields @[]@.
axisScoresFromDetail :: Value -> [(Text, Double)]
axisScoresFromDetail v = case AT.parseMaybe parseCriteria v of
  Nothing  -> []
  Just its ->
    [ (t, achieved / possible)
    | t <- nub (concatMap (\(tags, _, _) -> tags) its)
    , let tagged   = [ (pts, m) | (tags, pts, m) <- its, t `elem` tags ]
          possible = sum [ pts | (pts, _) <- tagged, pts > 0 ]
          achieved = sum [ pts | (pts, m) <- tagged, m ]
    , possible > 0 ]
  where
    parseCriteria = AT.withObject "detail" $ \o -> do
      arr <- o AT..: "criteria"
      mapM (AT.withObject "criterion" $ \c ->
              (,,) <$> c AT..: "tags" <*> c AT..: "points" <*> c AT..: "met")
           (arr :: [Value])

-- | The @example_tags@ themes from an example's meta. Absent/malformed -> [].
exampleThemes :: Value -> [Text]
exampleThemes v = maybe [] id (AT.parseMaybe (AT.withObject "meta" (AT..: "example_tags")) v)

-- | All 'RunMetric' rows for one grader version's scored rows: the overall, a
-- per-theme breakdown (the example's value bucketed by @example_tags@), and a
-- per-axis breakdown (the pointed detail re-scored per criterion tag). Every
-- mean is clipped to [0,1]; tag-row passRate is Nothing (score-derived).
dimensionalMetrics :: [(Maybe Double, Maybe Bool, Maybe Value, Maybe Value)] -> [DimMetric]
dimensionalMetrics rows = overall : themeMetrics ++ axisMetrics
  where
    graded = [ (v, p, d, m) | (Just v, p, d, m) <- rows ]
    vals   = [ v | (v, _, _, _) <- graded ]
    judged = [ b | (_, Just b, _, _) <- graded ]
    overall = DimMetric
      { tag = Nothing
      , mean = clip01 (if null vals then 0 else avg vals)
      , passRate = if null judged then Nothing
                   else Just (fromIntegral (length (filter id judged)) / fromIntegral (length judged))
      , count = length graded }
    themePairs = [ (t, v)  | (v, _, _, Just m) <- graded, t <- exampleThemes m ]
    axisPairs  = [ (t, sc) | (_, _, Just d, _) <- graded, (t, sc) <- axisScoresFromDetail d ]
    themeMetrics = [ DimMetric (Just t) (clip01 (avg ss)) Nothing (length ss) | (t, ss) <- grouped themePairs ]
    axisMetrics  = [ DimMetric (Just t) (clip01 (avg ss)) Nothing (length ss) | (t, ss) <- grouped axisPairs ]
    avg xs = sum xs / fromIntegral (length xs)
    grouped = Map.toList . Map.fromListWith (++) . map (\(k, x) -> (k, [x]))
```

(`DimMetric`'s `tag`/`mean`/`passRate`/`count` are labels under the module's NoFieldSelectors — no clash with `RunMetric`'s. `(,,) <$> ... ` builds `([Text], Double, Bool)`.) Run to green; `nix develop -c zinc build` links.

- [ ] **Step 5: commit** `feat(grade): RunMetric.tag column + dimensional-metrics aggregator (clip, axis, theme)`.

---

### Task 2: wire `recompute` to the aggregator + engine test (TDD)

**Files:** Modify `src/Evals/Grade.hs` (`recompute`), `test/GradeSpec.hs` (engine scenario).

- [ ] **Step 1: failing engine test.** In `test/GradeSpec.hs` add `dimEngineSpec pool now` (in the `withEphemeralDb` block, after the pointed engine scenario). Seed a pointed run whose example carries axis-tagged criteria and a themed meta:

```haskell
dimEngineSpec :: Pool -> UTCTime -> IO ()
dimEngineSpec pool now = do
  sd <- withSession pool $ do
    d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "dim", slug = "dim", createdAt = now } :: Dataset)
    v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    e1 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e1"
                       , input = Aeson (toJSON ("q" :: Text))
                       , expected = Just (Aeson (toJSON
                           [ object ["criterion" .= ("A"::Text), "points" .= (4::Double), "tags" .= (["axis:accuracy"]::[Text])]
                           , object ["criterion" .= ("B"::Text), "points" .= (6::Double), "tags" .= (["axis:completeness"]::[Text])] ]))
                       , meta = Just (Aeson (object ["example_tags" .= (["theme:x"]::[Text])])) } :: Example)
    t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
    tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "SYS"
                             , params = Aeson (object []), createdAt = now } :: TargetVersion)
    r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "succeeded"
                   , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
    _  <- add (Output { id = OutputId 0, run = r.id, example = e1.id, response = Nothing, text = Just "ans"
                      , error = Nothing, latencyMs = Just 1, tokens = Nothing } :: Output)
    g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "pg", kind = "pointed", createdAt = now } :: Grader)
    gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
    pure (r.id, gv.id)
  let (rid, gvid) = sd
      judge _ _ c = pure (Right (CriterionVerdict { met = c.criterion == "A", explanation = "" }))
  _ <- scoreRun pool 1 noRunner judge rid [gvid]
  ms <- withSession pool (selectWhere [ #graderVersion ==. gvid ]) :: IO [RunMetric]
  let row t = [ (m.mean, m.count) | m <- ms, m.tag == t ]
  expect "dim engine: overall 0.4 count 1"
    (case row Nothing of [(mn, c)] -> abs (mn - 0.4) < 1e-9 && c == 1; _ -> False)
  expect "dim engine: axis:accuracy 1.0 count 1"
    (case row (Just "axis:accuracy") of [(mn, c)] -> abs (mn - 1.0) < 1e-9 && c == 1; _ -> False)
  expect "dim engine: axis:completeness 0.0 count 1"
    (case row (Just "axis:completeness") of [(mn, c)] -> mn == 0.0 && c == 1; _ -> False)
  expect "dim engine: theme:x 0.4 count 1"
    (case row (Just "theme:x") of [(mn, c)] -> abs (mn - 0.4) < 1e-9 && c == 1; _ -> False)
  expect "dim engine: exactly 4 metric rows" (length ms == 4)
```

(`noRunner :: GradeRunner` already exists in GradeSpec — pointed never calls it; `judge :: CriterionJudge`. Wire `dimEngineSpec pool now` into the `withEphemeralDb` block.) Run `nix develop -c zinc test 2>&1 | tail -6` — FAILS (recompute still emits only the overall row; `length ms == 4` and the axis/theme rows fail).

- [ ] **Step 2: rewrite `recompute`** in `src/Evals/Grade.hs`:

```haskell
    recompute :: GraderVersion -> IO ()
    recompute gv = do
      now <- getCurrentTime
      withSession pool $ do
        rows <- runQuery $ do
          s <- from @Score
          o <- innerJoin @Output  (\o -> o ?. #id .== s ?. #output)
          e <- innerJoin @Example (\e -> e ?. #id .== o ?. #example)
          where_ (o ?. #run .== val runId .&& s ?. #graderVersion .== val gv.id)
          pure (s ?. #value, (s ?. #passed, (s ?. #detail, e ?. #meta)))
        let unwrap (mv, (mp, (md, mm))) =
              (mv, mp, fmap (\(Aeson x) -> x) md, fmap (\(Aeson x) -> x) mm)
            dms = dimensionalMetrics
              (map unwrap (rows :: [(Maybe Double, (Maybe Bool, (Maybe (Aeson Value), Maybe (Aeson Value))))]))
        deleteWhere ([ #run ==. runId, #graderVersion ==. gv.id ] :: [Cond RunMetric])
        mapM_ (\dm -> add (RunMetric
          { id = RunMetricId 0, run = runId, graderVersion = gv.id
          , mean = dm.mean, passRate = dm.passRate, count = dm.count
          , tag = dm.tag, computedAt = now } :: RunMetric)) dms
```

(The Score→Output→Example joins are 1:1:1 so the row set is unchanged from before. `dm.mean`/`dm.tag` etc. via record-dot.)

- [ ] **Step 3: run to green TWICE.** `nix develop -c zinc test 2>&1 | tail -6` — `dimEngineSpec` passes AND the existing `metricSpec` (rubric grader, untagged examples → only the overall row, clip a no-op) is unchanged. If `metricSpec` now fails (e.g. an unexpected extra row), investigate: rubric `Score.detail` is `{rationale, votes}` so `axisScoresFromDetail` → `[]`, and seedScoring examples have `meta = Nothing` so no themes — it MUST stay one row; a failure means the join multiplied rows or the aggregator mis-fired.
- [ ] **Step 4: commit** `feat(grade): recompute emits per-axis/theme RunMetric breakdowns`.

---

### Task 3: dashboard overall-only + docs

**Files:** Modify `src/Evals/Dashboard.hs`, `test/ApiSpec.hs`, `README.md`.

- [ ] **Step 1: filter the dashboard metrics to overall.** In `src/Evals/Dashboard.hs` `runSummary` (line ~171), filter the fetched RunMetrics to overall rows app-side (NOT a `#tag ==. Nothing` query — manifest's `==.` won't emit `IS NULL`):

```haskell
  allMetrics <- selectWhere [ #run ==. r.id ] :: Db [RunMetric]
  let metrics = filter (\m -> isNothing m.tag) allMetrics
  metricDtos <- mapM metricDto metrics
```

(add `import Data.Maybe (isNothing)` if not already imported in Dashboard.hs.)

- [ ] **Step 2: dashboard test — overall only.** In `test/ApiSpec.hs`'s `serverSpec` (the dashboard scenarios), in the seed that creates a RunMetric for a run, ALSO seed a second RunMetric with `tag = Just "axis:accuracy"` (same run+gv, mean 1.0, count 1, passRate Nothing). Then in the `/api/runs` (or run-detail) assertion, assert the run's `metrics` list has exactly ONE entry (the overall) — i.e. the tag row is excluded. (Adapt to the existing serverSpec structure; the existing metric assertion already checks one metric — adding the tag-row seed proves the filter, so the existing `length r.metrics == 1`-style check now meaningfully excludes the tag row.)

- [ ] **Step 3: run to green** (`nix develop -c zinc test 2>&1 | tail -4`); `nix develop -c zinc build`.

- [ ] **Step 4: README.** In the scorer/metrics description, add a sentence: `RunMetric` now carries an overall row (`tag` null) plus per-tag breakdowns — `theme:*` (the example's score bucketed by its `example_tags`) and, for pointed graders, `axis:*`/`cluster:*` (the criteria re-scored per tag from the stored verdicts, no extra judge calls); all means are clipped to [0,1]. Note the dashboard shows the overall metric (tag rendering is a later slice).

- [ ] **Step 5: commit + push.** `git commit -m "feat(dashboard): show overall metric only; docs for tag breakdowns" && git push`.

---

## Self-Review

**1. Spec coverage:** §1 schema (`tag` nullable column, no new index, delete-all-then-insert) → Task 1; §2 pure aggregation (`DimMetric`, `clip01`, `axisScoresFromDetail` incl. multi-tag + no-positive-skip + malformed→[], `exampleThemes`, `dimensionalMetrics` overall+themes+axes, clip everywhere, tag-row passRate Nothing) → Task 1; §3 recompute rewrite (join Example, 4-col project, unwrap, delete+insert per DimMetric) → Task 2; §4 dashboard no-regression filter (app-side `isNothing`, no DTO change) → Task 3; §5 testing (pure: clip/axis/theme/dim incl. negative-clip; engine: pointed run → overall+axis+theme rows + metricSpec unchanged; dashboard: overall-only) → Tasks 1–3; §6 out-of-scope (no bootstrap_std, no tag rendering, no provider knob) absent everywhere.

**2. Placeholder scan:** Task 1 Step 2's "grep for RunMetric literals" is a concrete sweep with the exact edit (`tag = Nothing`); Task 3 Step 2 adapts to the existing serverSpec shape with the precise seed/assertion described. No TBDs.

**3. Type consistency:** `DimMetric {tag :: Maybe Text, mean :: Double, passRate :: Maybe Double, count :: Int}`, `clip01 :: Double -> Double`, `axisScoresFromDetail :: Value -> [(Text, Double)]`, `exampleThemes :: Value -> [Text]`, `dimensionalMetrics :: [(Maybe Double, Maybe Bool, Maybe Value, Maybe Value)] -> [DimMetric]` consistent across Tasks 1–2; `RunMetric` gains `tag :: Field f (Maybe Text)` used identically in the recompute add (Task 2) and the dashboard filter (Task 3); the recompute projection nests `(value, (passed, (detail, meta)))` matching the unwrap.
