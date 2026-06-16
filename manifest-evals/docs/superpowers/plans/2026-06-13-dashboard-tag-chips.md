# Dashboard tag-chips + stderr Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Render `RunMetric` per-tag breakdowns (run-detail only, expandable bars) + the bootstrap `±CI` on the Miso dashboard.

**Architecture:** `MetricDto` gains `stderr` + nested `breakdowns :: [TagMetricDto]`; the server groups a run's RunMetrics by grader (overall row + tagged rows); the UI shows `±CI` on every overall chip and, in the run-detail header only, an expandable grouped bar panel.

**Tech Stack:** evals-api (shared derived-JSON DTOs), warp server (`Evals.Dashboard`), Miso 1.11 wasm UI (`evals-ui`), static CSS.

**Spec:** `docs/superpowers/specs/2026-06-13-dashboard-tag-chips-design.md`

**Repo facts (verified):**
- `evals-api/src/Evals/Api.hs`: `MetricDto { graderName :: Text, graderVersion :: Int, mean :: Double, passRate :: Maybe Double, count :: Int } deriving (Eq, Show, Generic, ToJSON, FromJSON)`; module exports `MetricDto (..)`. `RunSummaryDto { …, metrics :: [MetricDto] }`. Pragmas: `DeriveAnyClass, DeriveGeneric, DuplicateRecordFields`. Imports `Data.Aeson (FromJSON, ToJSON, Value)`, `Data.Text (Text)`.
- `src/Evals/Dashboard.hs` `runSummary` (lines ~166-195): builds `allMetrics <- selectWhere [#run ==. r.id]; let metrics = filter (\m -> isNothing m.tag) allMetrics; metricDtos <- mapM metricDto metrics; let sortedMetrics = sortOn (\m -> m.graderName) metricDtos`. `metricDto :: RunMetric -> Db MetricDto` (lines ~197-209) resolves grader name/version via `get @GraderVersion (Key rm.graderVersion)` / `get @Grader (Key gv.grader)` (fallbacks `"?"`/`0`) and reads `rm.mean/passRate/count`. `RunMetric` has `.tag :: Maybe Text`, `.stderr :: Maybe Double`. Imports include `Data.Maybe (isNothing)`, `Data.List (sortOn)`. `runDetailHandler` reuses `runSummary` (no change needed).
- `evals-ui/src/Evals/Ui/View.hs`: `metricChip :: MetricDto -> View Model Action = span_ [P.class_ "chip metric"] [text (ms mc.graderName <> " v" <> msShow mc.graderVersion <> " · μ " <> fmtD mc.mean <> passTxt)] where passTxt = maybe "" (\p -> " · pass " <> msShow (round (p*100)::Int) <> "%") mc.passRate`. Used in `runRow` (list, line 95), `runHeader` (detail, line 160 — `runHeader :: RunSummaryDto -> View`, called `runHeader d.run` at 145), `runCard` (compare, line 239). `_expandedM :: [MisoString]` + `ToggleExpand :: MisoString -> Action` are the existing expand mechanism (see `outputCell`, line 213: `onClick (ToggleExpand k)`). `onClick` from `Miso.Html`; `ms`/`MisoString` from `Miso.String`; `msShow` from `Evals.Ui.Model` (in scope); `nub` from `Data.List`; `fmtD :: Double -> MisoString` (3dp). Pragmas: `OverloadedRecordDot, OverloadedStrings`.
- `evals-ui/zinc.toml` `[build.exe.evals-ui] depends = ["base", "miso", "text", "time", "aeson", "evals-api"]`. `containers` is in the wasm lock closure already (aeson depends on it) — adding it to `depends` needs NO lock change.
- `static/style.css`: `.chip { display:inline-block; border-radius:999px; padding:1px 9px; font-size:12px; background:var(--muted-bg); color:var(--fg); margin:1px 4px 1px 0; white-space:nowrap; }`, `.chip.metric { background:#e8eefb; color:#1e3a8a; }`, `:root` has `--muted:#6b7280; --line:#e3e7ee`.
- `test/ApiSpec.hs`: a `dtoRoundTrips` section uses `rt "Name" value` (JSON encode→decode→`==`) — has a `MetricDto {graderName="exact-match", graderVersion=1, mean=0.85, passRate=Just 0.9, count=100}` literal inside a `RunSummaryDto` (lines ~111-117). The `serverSpec` dashboard scenario seeds an overall RunMetric (`ApiSpec.hs:315`, `tag=Nothing`) + a tag RunMetric (`:317`, `tag=Just "axis:accuracy"`) and asserts `/api/runs` returns `case r.metrics of [m] -> m.graderName == "exactness" && m.mean == 1.0 && m.passRate == Just 1.0; _ -> False` (`:335`). Both RunMetric seed literals already carry `stderr = Nothing` (slice 1).
- Build: native `nix develop -c zinc build 2>&1 | tail -4` / `nix develop -c zinc test 2>&1 | tail -8`; wasm UI `scripts/build-ui.sh` (run from repo root; restages `static/*.wasm`/`ghc_wasm_jsffi.js`/`js/miso.js`). Demo: `scripts/seed-demo.sh` then `EVALS_STATIC_DIR=static .zinc/build/evals-dashboard` (port 8787).

---

### Task 1: DTO — `MetricDto.stderr` + `breakdowns` + `TagMetricDto` (TDD)

**Files:** `evals-api/src/Evals/Api.hs`, `test/ApiSpec.hs`.

- [ ] **Step 1: failing round-trip test.** In `test/ApiSpec.hs`'s `dtoRoundTrips`, (a) add a `TagMetricDto` round-trip near the `MetricDto` usage, and (b) extend the existing `MetricDto` literal (lines ~111-117, inside the `RunSummaryDto` `metrics`) with the two new fields:
```haskell
  rt "TagMetricDto" TagMetricDto
    { tag = "axis:accuracy", mean = 0.8, stderr = Just 0.03, count = 20 }
```
and change the `MetricDto` literal to:
```haskell
        [ MetricDto
            { graderName = "exact-match"
            , graderVersion = 1
            , mean = 0.85
            , passRate = Just 0.9
            , count = 100
            , stderr = Just 0.02
            , breakdowns = [ TagMetricDto { tag = "theme:x", mean = 0.7, stderr = Nothing, count = 8 } ]
            }
        ]
```
Ensure `TagMetricDto` is imported (it comes from `Evals.Api`, already imported wholesale or via the DTO import list — if ApiSpec imports specific names, add `TagMetricDto (..)`). Run `nix develop -c zinc test 2>&1 | tail -6` — compile FAIL (`TagMetricDto`/`stderr`/`breakdowns` not in scope).

- [ ] **Step 2: extend the DTOs.** In `evals-api/src/Evals/Api.hs`: add `TagMetricDto (..)` to the module export list (beside `MetricDto (..)`), and replace the `MetricDto` definition + add `TagMetricDto`:
```haskell
data TagMetricDto = TagMetricDto
  { tag :: Text, mean :: Double, stderr :: Maybe Double, count :: Int }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data MetricDto = MetricDto
  { graderName :: Text, graderVersion :: Int, mean :: Double, passRate :: Maybe Double, count :: Int
  , stderr :: Maybe Double
  , breakdowns :: [TagMetricDto]
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)
```
(`DuplicateRecordFields` is already on, so `tag`/`mean`/`stderr`/`count` reused across DTOs is fine.) Run `nix develop -c zinc test 2>&1 | tail -6` — the round-trips pass; the `serverSpec` may now FAIL to compile (its seed/assert predate the new fields) — that's expected, fixed in Task 2. If ApiSpec won't compile solely due to `serverSpec`, proceed to Task 2 before the full green (or temporarily build just evals-api: `nix develop -c zinc build 2>&1 | tail -4`).

- [ ] **Step 3: commit.** `git add evals-api/src/Evals/Api.hs test/ApiSpec.hs && git commit -m "$(printf 'feat(api): MetricDto.stderr + nested breakdowns (TagMetricDto)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"`

---

### Task 2: server — `runSummary` groups by grader (TDD)

**Files:** `src/Evals/Dashboard.hs`, `test/ApiSpec.hs`.

- [ ] **Step 1: update the failing server test.** In `test/ApiSpec.hs` `serverSpec`: set the overall seed's stderr to a value and assert the new shape. Change the overall RunMetric seed (`:315`) to include `stderr = Just 0.05` (it currently has `stderr = Nothing`). Change the `/api/runs` metric assertion (`:335`) to:
```haskell
                    && (case r.metrics of
                          [m] -> m.graderName == "exactness" && m.mean == 1.0 && m.passRate == Just 1.0
                                   && m.stderr == Just 0.05
                                   && (case m.breakdowns of
                                         [b] -> b.tag == "axis:accuracy" && b.mean == 1.0 && b.count == 1
                                         _   -> False)
                          _ -> False)
```
(The tag seed at `:317` — `tag = Just "axis:accuracy", mean = 1.0, count = 1` — becomes the single breakdown.) Run `nix develop -c zinc test 2>&1 | tail -8` — FAILS (server still filters to overall + `MetricDto` has no breakdowns populated).

- [ ] **Step 2: rewrite the grouping.** In `src/Evals/Dashboard.hs`: add imports `import qualified Data.Map.Strict as Map` and extend `Data.Maybe` to `import Data.Maybe (catMaybes, isNothing)` (keep any other names it imports). Replace the `runSummary` metric lines:
```haskell
  allMetrics <- selectWhere [ #run ==. r.id ] :: Db [RunMetric]
  let metrics = filter (\m -> isNothing m.tag) allMetrics
  metricDtos <- mapM metricDto metrics
```
with
```haskell
  allMetrics <- selectWhere [ #run ==. r.id ] :: Db [RunMetric]
  metricDtos <- groupedMetricDtos allMetrics
```
and REPLACE the old `metricDto :: RunMetric -> Db MetricDto` helper with:
```haskell
-- | One MetricDto per grader version: the overall (tag Nothing) row supplies
-- mean/passRate/stderr/count; the tagged rows become sorted breakdowns. A group
-- with no overall row is dropped (recompute always writes one).
groupedMetricDtos :: [RunMetric] -> Db [MetricDto]
groupedMetricDtos rms =
  fmap catMaybes (mapM buildOne (Map.toList byGrader))
  where
    byGrader = Map.fromListWith (++) [ (rm.graderVersion, [rm]) | rm <- rms ]
    buildOne (gvId, rows) =
      case [ rm | rm <- rows, isNothing rm.tag ] of
        []          -> pure Nothing
        (overall:_) -> do
          mgv <- get @GraderVersion (Key gvId)
          mg  <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv
          let gName    = maybe "?" (.name) mg
              gVersion = maybe 0 (.version) mgv
              brks = sortOn (.tag)
                       [ TagMetricDto { tag = t, mean = rm.mean, stderr = rm.stderr, count = rm.count }
                       | rm <- rows, Just t <- [rm.tag] ]
          pure (Just MetricDto
            { graderName = gName, graderVersion = gVersion
            , mean = overall.mean, passRate = overall.passRate, count = overall.count
            , stderr = overall.stderr, breakdowns = brks })
```
(`TagMetricDto`/`MetricDto` come from `Evals.Api`, already imported by Dashboard.hs. `sortOn (.tag)` orders breakdowns; the outer `sortOn (\m -> m.graderName)` in `runSummary` is unchanged and still orders the MetricDtos.) Run `nix develop -c zinc test 2>&1 | tail -8` — the dashboard assertion passes; all specs green. `nix develop -c zinc build 2>&1 | tail -4` — links.

- [ ] **Step 3: commit.** `git add src/Evals/Dashboard.hs test/ApiSpec.hs && git commit -m "$(printf 'feat(dashboard): runSummary groups RunMetrics into per-grader breakdowns\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"`

---

### Task 3: UI — ±CI chips + expandable breakdown panel + CSS + wasm build

**Files:** `evals-ui/src/Evals/Ui/View.hs`, `evals-ui/zinc.toml`, `static/style.css`. (No unit test — the wasm UI has no harness; verification is the wasm build linking + a native build.)

- [ ] **Step 1: shared chip text + ±CI helpers.** In `evals-ui/src/Evals/Ui/View.hs`, replace the `metricChip` definition (lines ~293-299) with the plain chip + shared helpers:
```haskell
metricChip :: MetricDto -> View Model Action
metricChip mc = span_ [ P.class_ "chip metric" ] [ text (chipText mc) ]

chipText :: MetricDto -> MisoString
chipText mc = ms mc.graderName <> " v" <> msShow mc.graderVersion
            <> " · μ " <> fmtD mc.mean <> ciTxt mc.stderr <> passTxt mc.passRate

-- | 95% CI half-width (1.96·stderr), blank when no stderr.
ciTxt :: Maybe Double -> MisoString
ciTxt = maybe "" (\s -> " ±" <> fmtD (1.96 * s))

passTxt :: Maybe Double -> MisoString
passTxt = maybe "" (\p -> " · pass " <> msShow (round (p * 100) :: Int) <> "%")
```

- [ ] **Step 2: detail expandable chip + breakdown panel.** Add, in the same file:
```haskell
-- | A grader chip for the run-detail header: clickable (toggling an expand key)
-- when it has breakdowns, revealing a grouped bar panel below.
metricChipDetail :: [MisoString] -> Int -> MetricDto -> View Model Action
metricChipDetail expanded rid mc =
  div_ [ P.class_ "metric-block" ]
    ( span_ chipAttrs [ text (chipText mc <> caret) ]
      : [ breakdownPanel mc | hasBrk && isOpen ] )
  where
    hasBrk  = not (null mc.breakdowns)
    key     = "m:" <> msShow rid <> ":" <> ms mc.graderName <> "v" <> msShow mc.graderVersion
    isOpen  = key `elem` expanded
    caret   = if hasBrk then (if isOpen then " ▾" else " ▸") else ""
    chipAttrs = P.class_ "chip metric" : [ onClick (ToggleExpand key) | hasBrk ]

-- | The grouped per-tag breakdown: namespace label (theme/axis/cluster, then
-- any other), then a bar row per tag.
breakdownPanel :: MetricDto -> View Model Action
breakdownPanel mc = div_ [ P.class_ "brk" ] (concatMap grp nsOrder)
  where
    nss     = nub (map (namespace . (.tag)) mc.breakdowns)
    known   = filter (`elem` nss) ["theme", "axis", "cluster"]
    nsOrder = known <> filter (`notElem` ["theme", "axis", "cluster"]) nss
    grp n   = div_ [ P.class_ "grp-label" ] [ text (ms n) ]
            : [ brkRow n b | b <- mc.breakdowns, namespace b.tag == n ]
    brkRow n b =
      div_ [ P.class_ "row" ]
        [ span_ [ P.class_ ("chip " <> ms n) ] [ text (ms (labelOf b.tag)) ]
        , div_ [ P.class_ ("bar " <> ms n) ] [ span_ [ widthStyle b.mean ] [] ]
        , span_ [ P.class_ "num" ] [ text (fmtD b.mean <> ciTxt b.stderr) ]
        , span_ [ P.class_ "n" ] [ text (msShow b.count) ]
        ]

-- | "theme:cardiology" -> ("theme", "cardiology"); no colon -> ("", whole).
namespace :: Text -> Text
namespace = T.takeWhile (/= ':')

labelOf :: Text -> Text
labelOf t = case T.dropWhile (/= ':') t of
  "" -> t
  d  -> T.drop 1 d

widthStyle :: Double -> Attribute Action
widthStyle m = P.style_ (Map.singleton "width" (msShow (max 0 (min 100 (round (m * 100) :: Int))) <> "%"))
```
Add imports: `import qualified Data.Text as T`, `import qualified Data.Map.Strict as Map`, and `Attribute` (from `Miso.Html` — it likely re-exports `Attribute`; if not, `import Miso (Attribute)`). NOTE: confirm miso 1.11's `P.style_` signature — if it is `style_ :: Map MisoString MisoString -> Attribute action`, the above is correct; if it takes a list `[(MisoString,MisoString)]`, use `P.style_ [("width", …)]` and drop the `Map` import. The implementer must check `Miso.Html.Property.style_` and adapt; the value is a `width:NN%` string either way.

- [ ] **Step 3: use the expandable chip in the detail header.** Change `runHeader` to take the expanded list and render expandable chips. Replace `runHeader :: RunSummaryDto -> View Model Action` / `runHeader r = …` so it is `runHeader :: [MisoString] -> RunSummaryDto -> View Model Action` / `runHeader expanded r = …`, and change its metrics line from `div_ [ P.class_ "metrics" ] (map metricChip r.metrics)` to `div_ [ P.class_ "metrics" ] (map (metricChipDetail expanded r.runId) r.metrics)`. Update the caller in `detailView` (line ~145) from `runHeader d.run` to `runHeader (_expandedM m) d.run`. (Leave `runRow` and `runCard` using the plain `metricChip` — list/compare get `±CI` only, no breakdowns.)

- [ ] **Step 4: add the dep + CSS.** In `evals-ui/zinc.toml`, add `"containers"` to `[build.exe.evals-ui] depends` (already in the wasm lock closure — no lock edit). In `static/style.css`, after the existing `.chip.metric` rule, add:
```css
.chip.theme   { background:#fdf0e3; color:#9a5b13; }
.chip.axis    { background:#e3f5f4; color:#0f6e69; }
.chip.cluster { background:#efe7fb; color:#5b21b6; }
.metric-block { display:inline-block; vertical-align:top; }
.brk { margin:6px 0 2px; padding:7px 0 2px; border-top:1px dashed var(--line); max-width:440px; }
.grp-label { font-size:10px; letter-spacing:.06em; text-transform:uppercase; color:var(--muted); margin:5px 0 2px; }
.brk .row { display:grid; grid-template-columns:120px 1fr 96px 30px; align-items:center; gap:8px; padding:1px 0; }
.brk .bar { height:7px; background:var(--muted-bg); border-radius:4px; overflow:hidden; }
.brk .bar > span { display:block; height:100%; background:var(--accent); }
.brk .bar.theme > span { background:#d08023; }
.brk .bar.axis > span { background:#13a59c; }
.brk .bar.cluster > span { background:#7c3aed; }
.brk .num { font-variant-numeric:tabular-nums; text-align:right; font-size:12px; }
.brk .n { color:var(--muted); text-align:right; font-size:12px; }
```

- [ ] **Step 5: build native + wasm.** `nix develop -c zinc build 2>&1 | tail -4` (native links — the evals-ui member also typechecks under native). Then `scripts/build-ui.sh 2>&1 | tail -8` — the wasm reactor builds and `static/evals-ui.wasm` (+ jsffi + js/miso.js) restage; expected final line `done. serve with: …`. If the wasm build fails on `P.style_`/`Attribute`/`containers`, fix per Step 2's note and rebuild. (No test runs here — the UI has no unit harness.)

- [ ] **Step 6: commit + push.** The wasm artifacts (`static/evals-ui.wasm`, `static/ghc_wasm_jsffi.js`, `static/js/miso.js`) are **gitignored** (non-reproducible GHC-wasm links) — do NOT commit them; they are rebuilt locally via `scripts/build-ui.sh`. Commit only the source + CSS + zinc.toml:
```bash
git add evals-ui/src/Evals/Ui/View.hs evals-ui/zinc.toml static/style.css
git commit -m "$(printf 'feat(ui): per-tag breakdown panel + bootstrap CI on metric chips\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
git push
```
(`git status` should show the `static/*.wasm`/jsffi/miso.js as ignored — confirm they are NOT staged.)

---

## Self-Review
- Spec §1 (MetricDto.stderr + breakdowns, TagMetricDto) → Task 1; §2 (runSummary group-by-grader, overall→fields, tagged→breakdowns, drop overall-less group) → Task 2; §3 (metricChip ±CI everywhere; detail-only expandable breakdownPanel keyed in _expandedM; namespace split + colors; bars; CSS) → Task 3; §4 testing (DTO round-trip incl. TagMetricDto; serverSpec now asserts one MetricDto with one breakdown; wasm build verify) → Tasks 1–3; §5 out-of-scope (no κ surface, no sparkline/sort/filter, no list/compare breakdowns) absent.
- Type consistency: `TagMetricDto {tag :: Text, mean :: Double, stderr :: Maybe Double, count :: Int}` and `MetricDto {…, stderr :: Maybe Double, breakdowns :: [TagMetricDto]}` defined in Task 1, consumed identically in Task 2 (`groupedMetricDtos`) and Task 3 (`breakdownPanel`/`chipText`). `runHeader :: [MisoString] -> RunSummaryDto -> View` (Task 3 Step 3) updates its one caller. `ciTxt`/`passTxt`/`chipText`/`metricChipDetail`/`breakdownPanel`/`namespace`/`labelOf`/`widthStyle` all defined in Task 3. `msShow` is pre-existing (from `Evals.Ui.Model`).
- KNOWN RISK flagged: miso 1.11 `P.style_` signature (Map vs list) + `Attribute` import + whether `static/*.wasm` is git-tracked — Task 3 Steps 2/5/6 note the checks/fallbacks.
