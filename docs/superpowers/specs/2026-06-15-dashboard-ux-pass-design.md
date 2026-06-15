# Dashboard UX pass — design

**Date:** 2026-06-15
**Status:** approved (pending spec review)

## Goal

A cohesive navigation + layout polish of the dashboard: breadcrumbs everywhere, tabbed run-detail
and runs-index pages, a quieter run-compare affordance, prev/next on the example page, and the
org list rendered with the runs-table look. One slice; mostly `evals-ui` (View + Model), with two
small server changes.

## 1. Header link → org list

The topbar "manifest evals" title links to `/` (the org list) — a real navigation (`P.href_ "/"`),
not the `#/runs` hash. Visiting `/` leaves the org-scoped SPA and loads the org picker.

## 2. Org index (`/`) as a runs-style table

`orgPickerHandler` (server, `Evals.Dashboard`) keeps rendering server HTML, but emits the **same
table structure + CSS classes as the runs index** instead of a `<ul>`: a `<table class="orgs">`
(reusing the runs table styling) with columns **id · slug · name**, each row a link to `/<slug>/`.
Org name/slug stay HTML-escaped (`htmlEscape`). A short page heading ("organisations"); no
breadcrumb (it is the root). The CSS classes the runs table uses are added to `static/style.css`
for the `.orgs` table if any are page-specific; otherwise it reuses the existing table styling.

## 3. Breadcrumbs (shared, replaces `← runs`)

A new `breadcrumb :: [(MisoString, Maybe MisoString)] -> View` in `Evals.Ui.View` renders
`a / b / c` where each crumb is `(label, Just hrefHash)` (link) or `(label, Nothing)` (current
page, no link). The org slug — read from the URL via `Evals.Ui.Fetch.getOrgPrefix` — is the root
crumb, linking to `/` (a non-hash absolute link). Per page:

- runs index: `acme / runs` (acme→`/`, runs current)
- run detail: `acme / runs / run #<id>` (acme→`/`, runs→`#/runs`, run current)
- example: `acme / runs / run #<id> / <key>` (… run→`#/runs/<id>`, key current)
- compare: `acme / runs / compare #a × #b`

The org slug is needed in the pure view. Since `getOrgPrefix` is `IO`, read it once at `Startup`
and store it in the model (`_orgSlugM :: MisoString`), then the breadcrumb is pure over the model.
`backLink` is removed; every `detailView`/`exampleView`/`compareView`/`runsView` uses `breadcrumb`.

## 4. Runs index — tabs + `⋮` compare

- **Breadcrumb** `acme / runs`.
- **Two tabs: Runs · Grader calibration**, a shared `tabBar` rendered on both `RunsR` and
  `CalibrationR` (the tabs ARE these two routes; the active tab follows `_routeM`). The old
  `grader calibration →` nav-link is deleted; `calibrationView` loses its own `backLink`/heading and
  gains the shared breadcrumb + tab bar.
- **Compare via a per-row `⋮` menu.** Each run row's last cell is a `⋮` button; clicking toggles a
  dropdown listing the OTHER runs in the same `datasetVersionId` ("compare run #X with → run #Y ·
  <when>"); selecting one `Navigate (compareHash x y)`. The whole `compareBar`, the `_selectedM`
  state, the checkboxes, and all "tick two runs…" copy are removed. New model state: an open-menu
  marker, e.g. `_compareMenuM :: Maybe Int` (the run id whose menu is open; `Nothing` = closed),
  toggled by a `ToggleCompareMenu Int` action; a click elsewhere / selecting closes it.

## 5. Run detail — tabs (Examples + per grader)

`detailView` becomes: breadcrumb, run-header card, then a **tab bar** + the active tab's content.
Tabs: **Examples** (default) plus **one tab per grader** in `d.run.metrics` (label = grader name,
small kind tag). Active tab is view-local model state `_runTabM :: MisoString` (`"examples"` or the
grader key `"<name>v<ver>"`), set by `SetRunTab MisoString`, reset to `"examples"` on `SetRoute (RunR _)`.

- **Examples tab** = the existing `outputsTable` (with its mean footer row).
- **Each grader tab** = one panel combining, in order: the grader's `graderDetailSection`
  content (μ / pass / method line / criteria) + its `breakdownChart` (theme/axis bars) + its
  **calibration card** for that grader (the `CalibrationSeriesDto` whose `(graderName, graderVersion)`
  matches), i.e. `calibCard` inline. The standalone `graderDetailSection` loop and the bottom
  `calibrationSection` are removed from `detailView` — their content now lives in the grader tabs.
  A grader with no calibration row simply omits the calibration sub-panel.

Matching a metric to its calibration series: `[ s | s <- d.calibration, s.graderName == m.graderName,
s.graderVersion == m.graderVersion ]` (first match).

## 6. Example detail — breadcrumb + prev/next

- **Breadcrumb** `acme / runs / run #<id> / <key>`.
- **Prev / Next** buttons (in the example card header, near the breadcrumb): `Navigate
  (exampleHash runId prevKey)` / `…nextKey`, disabled when absent.
- **Server:** `ExampleDetailDto` (evals-api) gains `prevKey :: Maybe Text` and `nextKey :: Maybe Text`.
  `exampleDetailHandler` already loads the run's outputs sorted by example key; it computes the
  current key's neighbours in that ordered key list and sets prev/next (`Nothing` at the ends).
  `ApiSpec` asserts prev/next on a multi-example run (first has `prevKey = Nothing`, a middle has both).

## Components / files

- **Server:** `src/Evals/Dashboard.hs` (orgPickerHandler → table; exampleDetailHandler prev/next),
  `evals-api/src/Evals/Api.hs` (`ExampleDetailDto` +2 fields).
- **SPA:** `evals-ui/src/Evals/Ui/Model.hs` — add `_orgSlugM`, `_runTabM`, `_compareMenuM` and the
  actions `SetRunTab`/`ToggleCompareMenu`; REMOVE `_selectedM`, `ToggleSelect`, `pruneSelection`
  (compare is now the `⋮` menu, not row-ticks); KEEP `compareHash`/`CompareR`/`compareView` (still
  reached from the menu); reset `_runTabM` on `SetRoute (RunR _)`. `evals-ui/src/Main.hs` (read org slug at Startup;
  wire new actions), `evals-ui/src/Evals/Ui/View.hs` (breadcrumb, tabBar, run-detail tabs, grader-tab
  panel, `⋮` compare menu, orgs handled server-side so no SPA org view), `evals-ui/src/Evals/Ui/Fetch.hs`
  (reuse `getOrgPrefix`).
- **Styles:** `static/style.css` (`.breadcrumb`, `.tabbar`/`.tab`/`.tab.active`, `.row-menu`/`⋮`
  dropdown, `.orgs` table, prev/next buttons).
- **Tests:** `test/ApiSpec.hs` (org-picker now a table — update the "root lists orgs" assertion to
  still match `acme`/`globex`; `ExampleDetailDto` prev/next). Wasm UI verified by `scripts/build-ui.sh`
  + the controller browser smoke (no unit harness for views).

## Out of scope

- Making the org list a live SPA view (chosen: server-rendered table).
- Deep-linking a specific run-detail grader tab (tab state is view-local).
- Per-org SSE channels; auth.

## Notes / risks

- The breadcrumb needs the org slug in the pure view → store it at `Startup` (`_orgSlugM`). If a deep
  link loads mid-app, `Startup` still runs first (mount), so the slug is set before any view renders.
- Removing `_selectedM`/compareBar touches `GotRuns` (drops `pruneSelection`) and the runs view; keep
  `compareHash`/`CompareR`/`compareView` (still reachable via the `⋮` menu).
- Run-detail tab reset: `SetRoute (RunR _)` sets `_runTabM = "examples"` so switching runs starts on
  Examples.
