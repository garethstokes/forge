# Grader-detail UX revision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Run-detail graders become always-open sections (no pills/expand) with values as a sub-heading, and pointed graders list the run's criteria union.

**Spec:** `docs/superpowers/specs/2026-06-14-grader-detail-ux-design.md`

**Repo facts (verified):**
- `evals-api/src/Evals/Api.hs`: `MetricDto { graderName :: Text, graderVersion :: Int, graderKind :: Text, mean :: Double, passRate :: Maybe Double, count :: Int, stderr :: Maybe Double, breakdowns :: [TagMetricDto] } deriving (Eq, Show, Generic, ToJSON, FromJSON)`. Pragmas `DeriveAnyClass, DeriveGeneric, DuplicateRecordFields`.
- `src/Evals/Dashboard.hs`: `runSummary :: Run -> Db RunSummaryDto` (`:166`) does `allMetrics <- selectWhere [#run ==. r.id]; metricDtos <- groupedMetricDtos allMetrics; …`. `groupedMetricDtos :: [RunMetric] -> Db [MetricDto]` (`:199`) — `buildOne (gvId, rows)` fetches `mg`/`mgv`, computes `gName`/`gVersion`/`gKind = maybe "?" (.kind) mg`, builds the `MetricDto`. `runsHandler` (`:144`) calls `mapM runSummary sorted` in BOTH the filtered and unfiltered branches. `runDetailHandler` (`:224`) calls `runSummary run`. `Score {output :: OutputId, graderVersion :: GraderVersionId, detail :: Maybe (Aeson Value), …}`. `Output {id, run, …}`. `selectWhere`/`get`/`Aeson (..)` available (`import Manifest`); `qualified Data.Map.Strict as Map`, `Data.Maybe (catMaybes, isNothing)`, `Data.List (sortOn, sortBy)` imported. `Data.Aeson.Types`/`Data.Aeson (Value)` may need importing.
- `test/ApiSpec.hs` `serverSpec`: seeds a `Grader {name="exactness", kind="exact"}` + `GraderVersion gv` + outputs (`o1` ok, `o2` errored) + a `Score` on `o1` + an overall `RunMetric` (`tag=Nothing`, `stderr=Just 0.05`) + a tag `RunMetric` (`tag=Just "axis:accuracy"`). Asserts `/api/runs` metric shape. The `RunMetric`/`Grader`/`GraderVersion`/`Score`/`Output` literal styles are there to copy. `dtoRoundTrips` has the `MetricDto` literals (3 of them — see the graderKind task) to extend.
- `evals-ui/src/Evals/Ui/View.hs` (current): `metricChip mc = span_ [P.class_ "chip metric"] [text (chipText mc), kindTag mc.graderKind]` (list/compare — KEEP). `graderPill`/`gKey` (the pill — REMOVE). `graderDetailSection mc` (head + `[breakdownChart mc | not (null …)]` + pointed note — REVISE). `methodLine`, `breakdownChart`, `nsHint`, `ciCol`, `kindTag` (KEEP). `runHeader expanded r` currently renders `div_ [P.class_ "metrics"] (map (graderPill expanded r.runId) r.metrics)` + `div_ [P.class_ "grader-details"] [graderDetailSection mc | mc <- r.metrics, gKey r.runId mc `elem` expanded]` (REVISE → always-open). Helpers `chipText`/`ciTxt`/`passTxt`/`fmtD`/`msShow`/`namespace`/`labelOf`/`widthStyle` exist. `RubricCriterionDto` will come from `Evals.Api`.
- `static/style.css` has `.chip.metric.expandable`/`.chip .caret`/`.gdetail`/`.gdetail-head`/`.kind.big`/`.gdesc`/`.gnote`/`.chart`/etc. (Slice A).
- wasm artifacts GITIGNORED. Native `nix develop -c zinc build 2>&1 | tail -4`; wasm `scripts/build-ui.sh 2>&1 | tail -6`; tests `nix develop -c zinc test 2>&1 | tail -8`. **After the UI change, the running dashboard binary must be RESTARTED** (the controller handles that — the subagent only builds/pushes).

---

### Task 1: DTO `MetricDto.criteria` + server union (TDD)

**Files:** `evals-api/src/Evals/Api.hs`, `src/Evals/Dashboard.hs`, `test/ApiSpec.hs`.

- [ ] **Step 1: failing tests.** In `test/ApiSpec.hs`:
  - Add a `RubricCriterionDto` round-trip in `dtoRoundTrips`:
    ```haskell
      rt "RubricCriterionDto" RubricCriterionDto
        { criterion = "names the capital", points = 5, tags = ["axis:accuracy"] }
    ```
  - Add `criteria = []` to all three `MetricDto` literals (the nested dtoRoundTrips one, the standalone `rt "MetricDto"`, and the golden); add `"criteria" .= ([] :: [Value])` to the golden expected `object`.
  - In `serverSpec`, seed a SECOND grader (pointed) + its graderVersion + an overall `RunMetric` for it + a `Score` on `o1` carrying pointed `detail.criteria`. Then assert: on `/api/runs/<rid>` (detail), the pointed grader's metric has `criteria == [the criterion]`; on `/api/runs` (list), the same grader's metric has `criteria == []`. Concretely (adapt to the seed's bindings):
    ```haskell
    -- seed (after the existing exact grader):
    pg  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "rubric", kind = "pointed", createdAt = now } :: Grader)
    pgv <- add (GraderVersion { id = GraderVersionId 0, grader = pg.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
    _   <- add (Score { id = ScoreId 0, output = o1.id, graderVersion = pgv.id, value = Just 0.5, passed = Nothing
                      , detail = Just (Aeson (object
                          [ "achieved" .= (5::Double), "possible" .= (10::Double)
                          , "criteria" .= [ object ["criterion" .= ("names the capital"::Text), "points" .= (5::Double), "tags" .= (["axis:accuracy"]::[Text]), "met" .= True, "explanation" .= (""::Text)] ] ]))
                      , error = Nothing, createdAt = now } :: Score)
    _   <- add (RunMetric { id = RunMetricId 0, run = r.id, graderVersion = pgv.id, mean = 0.5, passRate = Nothing, count = 1, computedAt = now, tag = Nothing, stderr = Just 0.0 } :: RunMetric)
    -- detail assertion (GET /api/runs/<rid>): the "rubric" metric's criteria has one entry
    --   (find it in r.metrics by graderName == "rubric"); criterion == "names the capital", points == 5.0, tags == ["axis:accuracy"]
    -- list assertion (GET /api/runs): the "rubric" metric's criteria == []
    ```
  Run `nix develop -c zinc test 2>&1 | tail -8` — compile FAIL (`RubricCriterionDto`/`criteria` missing).

- [ ] **Step 2: DTO.** In `evals-api/src/Evals/Api.hs`, add `RubricCriterionDto` (above `MetricDto`) and `criteria` to `MetricDto`:
```haskell
data RubricCriterionDto = RubricCriterionDto
  { criterion :: Text, points :: Double, tags :: [Text] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data MetricDto = MetricDto
  { graderName :: Text, graderVersion :: Int, graderKind :: Text
  , mean :: Double, passRate :: Maybe Double, count :: Int
  , stderr :: Maybe Double, breakdowns :: [TagMetricDto]
  , criteria :: [RubricCriterionDto]
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)
```
Export `RubricCriterionDto (..)`.

- [ ] **Step 3: server.** In `src/Evals/Dashboard.hs`:
  - Add imports if absent: `import qualified Data.Aeson.Types as AT` and `Data.Aeson (Value)` (it already imports `qualified Data.Aeson as Aeson`).
  - `runSummary :: Bool -> Run -> Db RunSummaryDto`; `runSummary detail r = … metricDtos <- groupedMetricDtos detail r.id allMetrics …`.
  - `groupedMetricDtos :: Bool -> RunId -> [RunMetric] -> Db [MetricDto]`; thread the args; in `buildOne`, after `gKind`, add:
    ```haskell
          crits <- if detail && gKind == "pointed" then rubricCriteriaFor runId gvId else pure []
    ```
    and set `criteria = crits` in the `MetricDto`. (`runId` is the new `groupedMetricDtos` arg.)
  - `runsHandler`: change both `mapM runSummary sorted` to `mapM (runSummary False) sorted`.
  - `runDetailHandler`: change `runSummary run` to `runSummary True run`.
  - Add the helpers:
    ```haskell
    -- | Distinct rubric criteria a pointed grader used across this run (deduped
    -- by criterion text, sorted). Per-answer met/explanation are excluded.
    rubricCriteriaFor :: RunId -> GraderVersionId -> Db [RubricCriterionDto]
    rubricCriteriaFor runId gvId = do
      outs <- selectWhere [ #run ==. runId ] :: Db [Output]
      perOut <- mapM (\o -> selectWhere [ #output ==. o.id, #graderVersion ==. gvId ] :: Db [Score]) outs
      let crits = concatMap (rubricCriteriaFromDetail . (.detail)) (concat perOut)
      pure (dedupCriteria crits)

    rubricCriteriaFromDetail :: Maybe (Aeson Value) -> [RubricCriterionDto]
    rubricCriteriaFromDetail Nothing = []
    rubricCriteriaFromDetail (Just (Aeson v)) = maybe [] id (AT.parseMaybe p v)
      where p = AT.withObject "detail" $ \o -> do
                  arr <- o AT..: "criteria"
                  mapM (AT.withObject "criterion" $ \c ->
                          RubricCriterionDto <$> c AT..: "criterion" <*> c AT..: "points" <*> c AT..: "tags")
                       (arr :: [Value])

    dedupCriteria :: [RubricCriterionDto] -> [RubricCriterionDto]
    dedupCriteria = Map.elems . Map.fromListWith (\_new old -> old) . map (\c -> (c.criterion, c))
    ```
  Run `nix develop -c zinc test 2>&1 | tail -8` — all green (the detail path populates criteria, the list path empties them). `nix develop -c zinc build 2>&1 | tail -4` — links.

- [ ] **Step 4: commit.** `git add evals-api/src/Evals/Api.hs src/Evals/Dashboard.hs test/ApiSpec.hs && git commit -m "$(printf 'feat(api): MetricDto.criteria — the run rubric criteria union (detail only)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"`

---

### Task 2: UI — always-open grader sections + sub-heading + criteria list

**Files:** `evals-ui/src/Evals/Ui/View.hs`, `static/style.css`.

- [ ] **Step 1: remove the pill + expand; make sections always-open.** In `View.hs`:
  - DELETE `graderPill` and `gKey`.
  - Change `runHeader` to drop the pills row + the expand filter — render every grader's section always:
    ```haskell
    runHeader _ r =
      div_
        [ P.class_ "run-header" ]
        [ h2_ [] [ text ("run #" <> msShow r.runId <> " — " <> ms r.datasetName <> " · v" <> msShow r.datasetVersion) ]
        , div_ [ P.class_ "meta" ]
            [ span_ [] [ text (targetLabel r) ], statusChip r.status
            , span_ [] [ text ("started " <> fmtMaybeTime r.startedAt <> " · finished " <> fmtMaybeTime r.finishedAt) ] ]
        , div_ [ P.class_ "grader-details" ] (map graderDetailSection r.metrics)
        ]
    ```
    (Keep the `runHeader :: [MisoString] -> RunSummaryDto -> View Model Action` signature and the `detailView` caller `runHeader (_expandedM m) d.run` — the first arg is now ignored via `_`.)

- [ ] **Step 2: revise `graderDetailSection`** (add the values sub-heading + the criteria block):
```haskell
graderDetailSection :: MetricDto -> View Model Action
graderDetailSection mc =
  div_ [ P.class_ "gdetail" ]
    ( div_ [ P.class_ "gdetail-head" ]
        [ strong_ [] [ text (ms mc.graderName) ], text (" v" <> msShow mc.graderVersion)
        , span_ [ P.class_ "kind big" ] [ text (ms mc.graderKind) ]
        , span_ [ P.class_ "gvals" ] [ text (valsLine mc) ]
        , span_ [ P.class_ "gdesc" ] [ text (methodLine mc.graderKind) ] ]
      : [ criteriaBlock mc.criteria | not (null mc.criteria) ]
      ++ [ breakdownChart mc | not (null mc.breakdowns) ]
      ++ [ span_ [ P.class_ "gnote" ] [ text "per-answer verdicts: open an example below" ]
         | mc.graderKind == "pointed" ] )

-- | The pill's headline values, folded into the section as a sub-heading.
valsLine :: MetricDto -> MisoString
valsLine mc = "μ " <> fmtD mc.mean <> ciTxt mc.stderr <> passTxt mc.passRate

-- | "What it checks": the run's distinct rubric criteria.
criteriaBlock :: [RubricCriterionDto] -> View Model Action
criteriaBlock cs =
  div_ [ P.class_ "criteria" ]
    ( div_ [ P.class_ "crit-cap" ] [ text ("what it checks · " <> msShow (length cs) <> " criteria") ]
      : map critRow cs )
  where
    critRow c =
      div_ [ P.class_ "crit" ]
        [ span_ [ P.class_ (if c.points < 0 then "pts neg" else "pts pos") ]
            [ text ((if c.points < 0 then "" else "+") <> fmtD c.points) ]
        , span_ [ P.class_ "crit-txt" ] [ text (ms c.criterion) ]
        , span_ [ P.class_ "crit-tags" ] (map tagChip c.tags) ]
    tagChip t = span_ [ P.class_ ("tag " <> ms (namespace t)) ] [ text (ms (labelOf t)) ]
```

- [ ] **Step 3: CSS.** In `static/style.css`: remove the now-unused `.chip.metric.expandable`/`.chip.metric.expandable:hover`/`.chip .caret` rules. Add:
```css
.gvals { display:block; font-variant-numeric:tabular-nums; color:#1e3a8a; font-size:12.5px; margin-top:5px; }
.criteria { padding:10px 14px; border-bottom:1px solid var(--muted-bg); }
.crit-cap { font-size:11px; font-weight:600; color:#4b5563; margin-bottom:7px; }
.crit { display:flex; align-items:baseline; gap:9px; padding:4px 0; font-size:12.5px; border-top:1px dotted var(--muted-bg); }
.crit:first-of-type { border-top:none; }
.crit .pts { font-variant-numeric:tabular-nums; font-weight:600; font-size:11px; border-radius:4px; padding:0 5px; }
.crit .pts.pos { background:#e3f6e8; color:#166534; }
.crit .pts.neg { background:#fde8e8; color:#991b1b; }
.crit-txt { flex:1; }
.crit-tags .tag { font-size:11px; border-radius:999px; padding:0 8px; margin-left:4px; white-space:nowrap; }
.crit-tags .tag.axis  { background:#e3f5f4; color:#0f6e69; }
.crit-tags .tag.theme { background:#fdf0e3; color:#9a5b13; }
.crit-tags .tag.cluster { background:#efe7fb; color:#5b21b6; }
```
(`.kind.big`/`.gdesc`/`.gnote`/`.gdetail`/`.chart`/`.brow`/etc. stay.)

- [ ] **Step 4: build native + wasm.** `nix develop -c zinc build 2>&1 | tail -4` (native links — confirm `graderPill`/`gKey` removal left nothing dangling; `runHeader`'s ignored first arg compiles). `scripts/build-ui.sh 2>&1 | tail -6` (wasm links, final line `done. serve with: …`).

- [ ] **Step 5: commit + push (NOT the wasm artifacts).**
```bash
git add evals-ui/src/Evals/Ui/View.hs static/style.css
git commit -m "$(printf 'feat(ui): always-open grader sections with values sub-heading + criteria list\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
git push
```
Confirm `git status` shows `static/*.wasm`/jsffi/miso.js ignored (not staged).

---

## Self-Review
- Spec §1 (RubricCriterionDto + MetricDto.criteria) → Task 1; §2 (runSummary detail flag, groupedMetricDtos, rubricCriteriaFor union/dedup, list=empty) → Task 1; §3 (no pills, always-open sections, valsLine sub-heading, criteriaBlock, reworded pointed note) → Task 2; §4 testing (round-trips + detail-vs-list criteria + UI build) → Tasks 1–2; §5 out-of-scope (no per-answer verdicts here) absent.
- Type consistency: `RubricCriterionDto {criterion :: Text, points :: Double, tags :: [Text]}` built in `rubricCriteriaFromDetail` (Task 1) and read in `criteriaBlock` (Task 2); `MetricDto.criteria :: [RubricCriterionDto]` set in `groupedMetricDtos`/read via `mc.criteria`; `runSummary :: Bool -> Run -> …` + `groupedMetricDtos :: Bool -> RunId -> …` updated at all call sites (runsHandler ×2, runDetailHandler); `valsLine`/`criteriaBlock`/`graderDetailSection` in Task 2 reuse `fmtD`/`ciTxt`/`passTxt`/`namespace`/`labelOf`. `graderPill`/`gKey` removed and unreferenced.
