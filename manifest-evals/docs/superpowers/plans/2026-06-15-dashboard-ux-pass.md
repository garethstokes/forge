# Dashboard UX Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Breadcrumbs, tabbed run-detail + runs-index pages, a per-row `⋮` compare menu, example prev/next, and the org list as a runs-style table.

**Architecture:** Mostly `evals-ui` (View + Model). Two small server changes: `ExampleDetailDto` gains prev/next keys, and the org picker emits a table. The SPA Model+View+Main changes are tightly coupled (removing `_selectedM`, adding tab state) so they land in one atomic, build-gated task.

**Tech Stack:** Haskell (GHC 9.12 native / 9.14 wasm), warp, Miso wasm SPA, zinc.

**Spec:** `docs/superpowers/specs/2026-06-15-dashboard-ux-pass-design.md`

**CRITICAL BUILD ENVIRONMENT:** native via `nix develop -c zinc test spec`/`zinc build`; wasm via `scripts/build-ui.sh`. Bare `zinc` fails with an environmental libpq link error. The suite uses the `expect`/`rt` harness (no hspec). No wasm unit harness — view code is verified by a clean `scripts/build-ui.sh` + a browser smoke.

---

## File Structure

- **Modify** `evals-api/src/Evals/Api.hs` — `ExampleDetailDto` +`prevKey`/`nextKey`.
- **Modify** `src/Evals/Dashboard.hs` — `exampleDetailHandler` computes prev/next; `orgPickerHandler` emits a table.
- **Modify** `test/ApiSpec.hs` — prev/next assertions; org-picker still lists slugs.
- **Modify** `evals-ui/src/Evals/Ui/Model.hs` — `_orgSlugM`/`_runTabM`/`_compareMenuM`, `SetRunTab`/`ToggleCompareMenu`; remove `_selectedM`/`ToggleSelect`/`pruneSelection`.
- **Modify** `evals-ui/src/Main.hs` — read org slug at Startup; wire new actions; drop `_selectedM` handling; reset `_runTabM` on `RunR`.
- **Modify** `evals-ui/src/Evals/Ui/View.hs` — breadcrumb, tabBar, runs restructure, run-detail tabs, example prev/next, header link.
- **Modify** `static/style.css` — `.breadcrumb`, `.tabbar`, `.row-menu`, `.orgs`, prev/next.

---

### Task 1: Server — ExampleDetailDto prev/next + org-picker table

**Files:** `evals-api/src/Evals/Api.hs`, `src/Evals/Dashboard.hs`, `test/ApiSpec.hs`

- [ ] **Step 1: Add fields to `ExampleDetailDto`**

In `evals-api/src/Evals/Api.hs`:
```haskell
data ExampleDetailDto = ExampleDetailDto
  { runId :: Int, exampleKey :: Text
  , input :: Value, prompt :: [PromptMsgDto]
  , responseText :: Maybe Text, responseError :: Maybe Text
  , grades :: [GradeDto]
  , prevKey :: Maybe Text, nextKey :: Maybe Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

- [ ] **Step 2: Compute prev/next in `exampleDetailHandler`**

In `src/Evals/Dashboard.hs`, the handler already builds `paired :: [(Output, Maybe Example)]`. Add, in the matched-example branch (where it builds the DTO), an ordered distinct key list and the neighbours:
```haskell
          ((o, e) : _) -> do
            scores <- selectWhere [ #output ==. o.id ] :: Db [Score]
            grades <- mapM gradeDto scores
            let Aeson inputV = e.input
                prompt = case mtv of
                  Just tv -> either (const []) (map msgDto) (assembleMessages tv e)
                  Nothing -> []
                RunId rn = rid
                keys  = Data.List.sort (Data.List.nub [ ek.key | (_, Just ek) <- paired ])
                neigh = case break (== key) keys of
                          (before, _ : after) -> ( lastMay before, headMay after )
                          _                   -> ( Nothing, Nothing )
            pure (Just ExampleDetailDto
              { runId = rn, exampleKey = key, input = inputV, prompt = prompt
              , responseText = o.text, responseError = o.error
              , grades = sortOn (\g -> g.graderName) grades
              , prevKey = fst neigh, nextKey = snd neigh })
```
Add tiny helpers near the handler (or use `Data.Maybe`/list idioms already imported):
```haskell
    headMay (x:_) = Just x; headMay [] = Nothing
    lastMay [] = Nothing; lastMay xs = Just (last xs)
```
Ensure `Data.List (sort, nub, break)` are available (`sortOn`/`nub` already imported from `Data.List`; add `sort` to that import).

- [ ] **Step 3: Org picker → table**

In `src/Evals/Dashboard.hs` `orgPickerHandler`, replace the `<ul>` body with a runs-style table (reuse the dashboard's table CSS + a `.orgs` class):
```haskell
  let row o = "<tr onclick=\"location='/" <> htmlEscape o.slug <> "/'\" style=\"cursor:pointer\">"
           <> "<td class=\"key\">" <> htmlEscape o.slug <> "</td><td>" <> htmlEscape o.name <> "</td></tr>"
      body  = "<!doctype html><meta charset=utf-8><title>evals — orgs</title>"
           <> "<link rel=\"stylesheet\" href=\"/style.css\">"
           <> "<div class=\"content\"><h2>organisations</h2>"
           <> "<table class=\"orgs\"><thead><tr><th>org</th><th>name</th></tr></thead><tbody>"
           <> T.concat (map row orgs) <> "</tbody></table></div>"
```
(`/style.css` is reachable at root — but NOTE the slug router treats `["style.css"]` as a slug → 404. So the org-picker page must inline its needed CSS OR the router must allow `style.css` at root. SIMPLEST: inline a small `<style>` block here instead of linking `/style.css`, reusing the same visual (white card table). Use an inline `<style>` matching `.content`/`table`/`th`/`td`/`.key` from `static/style.css` — copy those few rules inline. Do NOT link `/style.css` (it would 404 under slug routing).)

Replace the link approach with an inline style block; keep `htmlEscape`. The table columns are **slug** and **name** (the org id is internal; slug is the user-facing key).

- [ ] **Step 4: Update ApiSpec**

In `test/ApiSpec.hs`: (a) the existing "root lists orgs" assertion still holds (table contains `acme`/`globex`) — leave it. (b) Add `ExampleDetailDto` prev/next: the run has examples `e1`,`e2` (and the demo seed has capital-*). For the `/acme/api/runs/<id>/ex/e1` request (already in the test), assert the decoded `ExampleDetailDto`'s `prevKey`/`nextKey` are correct for the run's sorted keys. If the server test's run has 2 examples `e1`<`e2`: `e1` → `prevKey = Nothing`, `nextKey = Just "e2"`. Add:
```haskell
    expect "example prev/next" $
      case decode (responseBody rEx) :: Maybe ExampleDetailDto of
        Just d  -> d.prevKey == Nothing && d.nextKey == Just "e2"
        Nothing -> False
```
(Confirm the seeded example keys — match whatever `rEx` requests and the run's other example key. Adjust the expected `nextKey` to the actual sibling.)

- [ ] **Step 5: Build + test**

Run: `nix develop -c zinc test spec`
Expected: PASS — prev/next asserted; org picker still lists slugs.

- [ ] **Step 6: Commit**

```bash
git add evals-api/src/Evals/Api.hs src/Evals/Dashboard.hs test/ApiSpec.hs
git commit -m "feat(dashboard): ExampleDetailDto prev/next keys + org picker as a table

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: SPA — model + view restructure (ATOMIC, build-gated)

This is one task: removing `_selectedM` and adding tab/breadcrumb state touches Model, Main, and View together; the wasm build is the gate. Verify with `scripts/build-ui.sh` after each sub-step group.

**Files:** `evals-ui/src/Evals/Ui/Model.hs`, `evals-ui/src/Main.hs`, `evals-ui/src/Evals/Ui/View.hs`

- [ ] **Step 1: Model — fields + actions**

In `evals-ui/src/Evals/Ui/Model.hs`:
- In `Model`, REMOVE `_selectedM :: [Int]`. ADD `_orgSlugM :: MisoString`, `_runTabM :: MisoString`, `_compareMenuM :: Maybe Int`.
- `emptyModel`: drop the `_selectedM` `[]`; add `""` (orgSlug), `"examples"` (runTab), `Nothing` (compareMenu) in the matching positions.
- Lenses: remove `selectedL`; add `orgSlugL`, `runTabL`, `compareMenuL` (mirror an existing lens). Export the new lenses; remove `selectedL` from exports.
- `Action`: REMOVE `ToggleSelect Int`. ADD `SetRunTab MisoString`, `ToggleCompareMenu (Maybe Int)`, and `SetOrgSlug MisoString`.
- REMOVE `pruneSelection` (function + export).
- Keep `compareHash`, `CompareR`, `runHash`, `calibrationHash`, etc.

- [ ] **Step 2: Main — wire the new actions, drop old ones**

In `evals-ui/src/Main.hs`:
- `Startup`: also read the org slug — `io (SetOrgSlug <$> getOrgPrefix)` (getOrgPrefix returns e.g. `"/acme"`; store as-is or strip the leading `/` — store the bare slug; in `SetOrgSlug s` set `orgSlugL .= dropPrefixSlash s`). Add `SetOrgSlug s -> orgSlugL .= s` (store the `/acme` form; the breadcrumb link is `/` and the label strips the slash — simplest: store `"/acme"` and the breadcrumb shows `T.drop 1`). Pick one and be consistent with the View.
- `SetRoute (RunR _)`: also `runTabL .= "examples"` and `compareMenuL .= Nothing`.
- `SetRoute _` (others): `compareMenuL .= Nothing` (close any open menu on navigation).
- Add arms: `SetRunTab t -> runTabL .= t`; `ToggleCompareMenu mi -> compareMenuL .= mi`.
- REMOVE the `ToggleSelect` arm and the `GotRuns` `pruneSelection` line (just `runsL %= \old -> keepStale old (fromEither e)`).

- [ ] **Step 3: View — shared breadcrumb + tabBar**

In `evals-ui/src/Evals/Ui/View.hs`, add:
```haskell
-- | A breadcrumb trail. Each crumb is (label, Just hash-or-href) link, or
-- (label, Nothing) for the current page. The first crumb (org) uses a full
-- href; the rest use hash links.
breadcrumb :: [(MisoString, Maybe MisoString)] -> View Model Action
breadcrumb crumbs =
  nav_ [ P.class_ "breadcrumb" ]
    (intersperse sep (map crumb crumbs))
  where
    sep = span_ [ P.class_ "sep" ] [ text "/" ]
    crumb (label, Just href) = a_ [ P.href_ href ] [ text label ]
    crumb (label, Nothing)   = span_ [ P.class_ "here" ] [ text label ]

-- | The org root crumb from the model's slug: ("acme", Just "/").
orgCrumb :: Model -> (MisoString, Maybe MisoString)
orgCrumb m = (T.dropWhile (== '/') (_orgSlugM m), Just "/")

-- | A tab bar: (label, hashHref, isActive). Active tab is bold + underlined.
tabBar :: [(MisoString, MisoString, Bool)] -> View Model Action
tabBar tabs = div_ [ P.class_ "tabbar" ] (map one tabs)
  where
    one (label, href, active) =
      a_ [ P.class_ ("tab" <> if active then " active" else ""), P.href_ href ] [ text label ]
```
(Add `import Data.List (intersperse)` and `intercalate` if needed; `T.dropWhile` needs `Data.Text as T` — already imported. `_orgSlugM` is the model field.)

- [ ] **Step 4: View — runs index (breadcrumb + tabs + ⋮ compare; remove compareBar/checkbox/nav-link)**

Replace `runsView`:
```haskell
runsView :: Model -> View Model Action
runsView m =
  remoteView (_runsM m) $ \rs ->
    div_ []
      ( breadcrumb [ orgCrumb m, ("runs", Nothing) ]
      : runsTabBar RunsR
      : map (runGroup m rs) (groupRuns rs) )

-- shared by runsView + calibrationView
runsTabBar :: Route -> View Model Action
runsTabBar active = tabBar
  [ ("Runs", runsHash, active == RunsR)
  , ("Grader calibration", calibrationHash, active == CalibrationR) ]
```
`runGroup` gains the full run list `rs` (for the compare menu's candidate siblings) and drops the "compare" column:
```haskell
runGroup :: Model -> [RunSummaryDto] -> ((Text, Int), [RunSummaryDto]) -> View Model Action
runGroup m allRs ((dn, dv), rs) =
  section_ [ P.class_ "run-group" ]
    [ h2_ [] [ text (ms dn <> " · v" <> msShow dv) ]
    , table_ []
        [ thead_ [] [ tr_ [] (map thTxt [ "run", "target", "status", "started", "metrics", "" ]) ]
        , tbody_ [] (map (runRow m allRs) rs) ] ]
```
`runRow` drops the checkbox cell; the last cell is the `⋮` menu:
```haskell
runRow :: Model -> [RunSummaryDto] -> RunSummaryDto -> View Model Action
runRow m allRs r =
  tr_ [ P.class_ "clickable", onClick (Navigate (runHash r.runId)) ]
    [ td_ [ P.class_ "key" ] [ text ("#" <> msShow r.runId) ]
    , td_ [] [ text (targetLabel r) ]
    , td_ [] [ statusChip r.status ]
    , td_ [] [ text (fmtMaybeTime r.startedAt) ]
    , td_ [ P.class_ "metrics" ] (map metricChip r.metrics)
    , td_ [ P.class_ "row-menu" ] [ compareMenu m allRs r ]
    ]

-- | The ⋮ button + (when open) a dropdown of same-dataset-version runs to
-- compare with. Clicks here must not bubble into the row's navigate handler.
compareMenu :: Model -> [RunSummaryDto] -> RunSummaryDto -> View Model Action
compareMenu m allRs r =
  span_ [ P.class_ "menu-wrap" ]
    ( a_ [ P.class_ "kebab"
         , onClickWithOptions (Options { _preventDefault = True, _stopPropagation = True })
             (ToggleCompareMenu (if _compareMenuM m == Just r.runId then Nothing else Just r.runId)) ]
        [ text "⋮" ]
    : [ dropdown | _compareMenuM m == Just r.runId ] )
  where
    sibs = [ o | o <- allRs, o.runId /= r.runId, o.datasetVersionId == r.datasetVersionId ]
    dropdown = div_ [ P.class_ "menu" ]
      ( div_ [ P.class_ "menu-head" ] [ text ("compare #" <> msShow r.runId <> " with") ]
      : if null sibs
          then [ div_ [ P.class_ "menu-empty" ] [ text "no comparable runs" ] ]
          else map item sibs )
    item o = a_ [ P.class_ "menu-item"
                , onClickWithOptions (Options { _preventDefault = True, _stopPropagation = True })
                    (Navigate (compareHash r.runId o.runId)) ]
               [ text ("#" <> msShow o.runId), span_ [ P.class_ "muted" ] [ text (" · " <> fmtMaybeTime o.startedAt) ] ]
```
DELETE `compareBar`, the `metricChip`'s checkbox usage is unaffected, and the `nav-link` "grader calibration →" (it's now a tab). `groupRuns` is unchanged. Confirm `onClickWithOptions`/`Options` are still imported (they were used by the old checkbox).

- [ ] **Step 5: View — run detail tabs**

Replace `detailView`:
```haskell
detailView :: Model -> Int -> View Model Action
detailView m _ =
  remoteView (_detailM m) $ \d ->
    let graders = d.run.metrics
        tabKey mc = ms mc.graderName <> "v" <> msShow mc.graderVersion
        active = _runTabM m
        tabs = ("Examples", "examples", active == "examples")
             : [ (ms mc.graderName, tabKey mc, active == tabKey mc) | mc <- graders ]
        content
          | active == "examples" = outputsTable d.run.runId (_expandedM m) d.run.metrics d.outputs
          | otherwise = case [ mc | mc <- graders, tabKey mc == active ] of
              (mc : _) -> graderTabPanel d mc
              []       -> outputsTable d.run.runId (_expandedM m) d.run.metrics d.outputs
    in div_ [ P.class_ "detail" ]
         [ breadcrumb [ orgCrumb m, ("runs", Just runsHash), ("run #" <> msShow d.run.runId, Nothing) ]
         , runHeader d.run
         , detailTabBar tabs
         , content ]

-- | Tab bar whose tabs set view-local run-detail tab state (not routes).
detailTabBar :: [(MisoString, MisoString, Bool)] -> View Model Action
detailTabBar tabs = div_ [ P.class_ "tabbar" ] (map one tabs)
  where one (label, key, active) =
          a_ [ P.class_ ("tab" <> if active then " active" else "")
             , onClick (SetRunTab key) ] [ text label ]

-- | A grader tab: its detail section (μ / method / criteria / breakdown bars)
-- plus its calibration card (if any).
graderTabPanel :: RunDetailDto -> MetricDto -> View Model Action
graderTabPanel d mc =
  div_ [ P.class_ "grader-tab" ]
    ( graderDetailSection mc
    : [ calibCard s | s <- d.calibration, s.graderName == mc.graderName, s.graderVersion == mc.graderVersion ] )
```
`runHeader` no longer renders the grader-details loop (it moved into tabs). Change `runHeader`:
```haskell
runHeader :: RunSummaryDto -> View Model Action
runHeader r =
  div_ [ P.class_ "run-header" ]
    [ h2_ [] [ text ("run #" <> msShow r.runId <> " — " <> ms r.datasetName <> " · v" <> msShow r.datasetVersion) ]
    , div_ [ P.class_ "meta" ]
        [ span_ [] [ text (targetLabel r) ]
        , statusChip r.status
        , span_ [] [ text ("started " <> fmtMaybeTime r.startedAt <> " · finished " <> fmtMaybeTime r.finishedAt) ] ] ]
```
DELETE the standalone `calibrationSection` call from detailView (its content is in grader tabs now); the `calibrationSection` FUNCTION may become unused — remove it if so. `graderDetailSection` already includes its `breakdownChart`, so the grader tab needs no extra breakdown call.

- [ ] **Step 6: View — example prev/next + breadcrumb; calibrationView + compareView breadcrumbs; header link**

Replace `exampleView`'s back link with a breadcrumb + prev/next:
```haskell
exampleView :: Model -> Int -> Text -> View Model Action
exampleView m _ _ =
  remoteView (_exampleM m) $ \d ->
    div_ [ P.class_ "example" ]
      [ breadcrumb [ orgCrumb m, ("runs", Just runsHash)
                   , ("run #" <> msShow d.runId, Just (runHash d.runId))
                   , (ms d.exampleKey, Nothing) ]
      , div_ [ P.class_ "ex-card" ]
          [ div_ [ P.class_ "ex-head" ]
              [ h2_ [] [ text ("example " <> ms d.exampleKey) ]
              , div_ [ P.class_ "ex-nav" ]
                  [ navBtn "← prev" (fmap (exampleHash d.runId) d.prevKey)
                  , navBtn "next →" (fmap (exampleHash d.runId) d.nextKey) ] ]
          , div_ [ P.class_ "ex-cols" ]
              [ div_ [ P.class_ "ex-main" ]
                  [ exSection "Input" [ pre_ [ P.class_ "io" ] [ text (renderJson d.input) ] ]
                  , exSection "Generated prompt" (map promptMsg d.prompt)
                  , exSection "Response" [ responseBlock d.responseText d.responseError ] ]
              , div_ [ P.class_ "ex-side" ] [ exSection "Grades" (map gradeBlock d.grades) ] ] ] ]
  where
    exSection title kids = div_ [ P.class_ "ex-section" ] (h3_ [] [ text title ] : kids)
    navBtn label Nothing     = span_ [ P.class_ "ex-navbtn disabled" ] [ text label ]
    navBtn label (Just href) = a_ [ P.class_ "ex-navbtn", P.href_ href ] [ text label ]
```
`calibrationView` — give it the runs breadcrumb + the shared runs tab bar (Grader calibration active) instead of its own back link/heading:
```haskell
calibrationView :: Model -> View Model Action
calibrationView m =
  remoteView (_calibrationM m) $ \ss ->
    div_ [ P.class_ "calib calib-page" ]
      ( breadcrumb [ orgCrumb m, ("runs", Just runsHash) ]
      : runsTabBar CalibrationR
      : div_ [ P.class_ "calib-legend" ] [ text "κ measures judge–human agreement beyond chance; the 0.6 tick is the trust threshold." ]
      : if null ss then [ p_ [ P.class_ "empty" ] [ text "no calibration runs yet." ] ]
        else map calibCard ss )
```
`compareView` — replace its `backLink` with `breadcrumb [ orgCrumb m, ("runs", Just runsHash), ("compare #" <> msShow a <> " × #" <> msShow b, Nothing) ]` (it already takes a,b).
DELETE `backLink`. Header link in `viewModel`: change `a_ [ P.href_ runsHash ]` to `a_ [ P.href_ "/" ]`.

- [ ] **Step 7: Build the wasm UI**

Run: `scripts/build-ui.sh`
Expected: clean. Fix any compile errors (unused imports after deletions: `pruneSelection`, `compareBar`, `backLink`, `calibrationSection`; possibly `onClickWithOptions` still used by the kebab — keep it).

- [ ] **Step 8: Commit**

```bash
git add evals-ui/src/Evals/Ui/Model.hs evals-ui/src/Main.hs evals-ui/src/Evals/Ui/View.hs
git commit -m "feat(ui): breadcrumbs, tabbed run-detail + runs index, row-menu compare, example prev/next

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Styles

**Files:** `static/style.css`

- [ ] **Step 1: Add the new classes**

Append:
```css
/* breadcrumbs */
.breadcrumb { font-size: 13px; color: var(--muted); margin: 4px 0 14px; }
.breadcrumb a { color: var(--accent); text-decoration: none; }
.breadcrumb a:hover { text-decoration: underline; }
.breadcrumb .sep { margin: 0 7px; color: #c2c8d2; }
.breadcrumb .here { color: var(--fg); }
/* tab bar */
.tabbar { display: flex; align-items: center; border-bottom: 1px solid var(--line); margin-bottom: 14px; }
.tab { padding: 8px 16px; color: var(--muted); text-decoration: none; border-bottom: 2px solid transparent; margin-bottom: -1px; }
.tab:hover { color: var(--fg); }
.tab.active { color: var(--fg); font-weight: 600; border-bottom-color: var(--accent); }
/* run-row ⋮ compare menu */
.row-menu { width: 28px; text-align: center; position: relative; }
.kebab { color: var(--muted); font-weight: 700; cursor: pointer; text-decoration: none; }
.kebab:hover { color: var(--accent); }
.menu-wrap { position: relative; }
.menu { position: absolute; right: 0; top: 100%; z-index: 10; background: #fff; border: 1px solid var(--line); border-radius: 8px; box-shadow: 0 6px 20px rgba(20,30,50,.12); min-width: 180px; font-size: 13px; overflow: hidden; }
.menu-head { padding: 7px 12px; color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: .04em; }
.menu-item { display: block; padding: 8px 12px; color: var(--fg); text-decoration: none; }
.menu-item:hover { background: #f2f6ff; }
.menu-item .muted { color: var(--muted); }
.menu-empty { padding: 8px 12px; color: var(--muted); }
/* org list table */
.orgs td.key { color: var(--accent); }
/* example prev/next */
.ex-head { display: flex; align-items: center; gap: 12px; }
.ex-nav { margin-left: auto; display: flex; gap: 6px; }
.ex-navbtn { font-size: 13px; padding: 3px 10px; border: 1px solid var(--line); border-radius: 6px; color: var(--accent); text-decoration: none; }
.ex-navbtn:hover { background: #f2f6ff; }
.ex-navbtn.disabled { color: #c2c8d2; border-color: var(--line); pointer-events: none; }
```

- [ ] **Step 2: Commit**

```bash
git add static/style.css
git commit -m "style: breadcrumbs, tab bar, row-menu compare, example prev/next

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Full gate + restart + smoke (CONTROLLER)

- [ ] **Step 1: Gate** — `nix develop -c zinc test spec` (green), `nix develop -c zinc build` (clean), `scripts/build-ui.sh` (clean).
- [ ] **Step 2: Re-seed + restart** the dashboard on `evals_demo` (port 8787).
- [ ] **Step 3: Browser smoke** (controller eyeballs): `/` shows the org table → click `acme` → `/acme/#/runs` shows breadcrumb `acme / runs` + Runs/Grader-calibration tabs; a run row's `⋮` → compare menu; open run #1 → Examples + exactness + rubric tabs (grader tab shows detail + breakdown + calibration); open an example → breadcrumb + prev/next step through examples; the "Grader calibration" tab shows the calibration page.

---

## Self-Review

**Spec coverage:** header→`/` (Task 2 Step 6) ✓; org table (Task 1 Step 3) ✓; breadcrumbs (Task 2 Steps 3–6) ✓; runs tabs + ⋮ compare (Task 2 Step 4) ✓; run-detail tabs + grader panel (Task 2 Step 5) ✓; example prev/next + server fields (Task 1 Steps 1–2, Task 2 Step 6) ✓; calibration as a runs tab (Task 2 Step 6) ✓.

**Type consistency:** `_orgSlugM`/`_runTabM :: MisoString`, `_compareMenuM :: Maybe Int`; `SetRunTab`/`ToggleCompareMenu`/`SetOrgSlug`; `breadcrumb`/`orgCrumb`/`tabBar`/`runsTabBar`/`detailTabBar`/`graderTabPanel`/`compareMenu` defined once and used consistently. `ExampleDetailDto.prevKey/nextKey :: Maybe Text` server + consumed in `exampleView`.

**Placeholder scan:** Task 1 Step 3 flags the real `/style.css`-under-slug-routing trap and resolves it (inline `<style>`, don't link). Task 1 Step 4 asks the implementer to match the actual seeded example keys for the prev/next assertion (the seed's keys are `e1`/`e2` or `capital-*` — read the file). Task 2 notes the unused-import cleanup after deletions.

**Known risks:** (1) the org-picker must NOT link `/style.css` (slug-routing 404) — inline the styles. (2) Task 2 is large/atomic (wasm build coupling); the build is the gate. (3) `_orgSlugM` form (`/acme` vs `acme`) — store one form and have `orgCrumb` strip consistently (plan stores `"/acme"`, `orgCrumb` does `T.dropWhile (=='/')`). (4) wasm view behavior needs the browser smoke (no unit harness).
