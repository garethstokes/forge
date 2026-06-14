# Grader-detail UX (Slice A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use `- [ ]`.

**Goal:** Kind tags on grader pills + an expandable full-width run-level grader-detail section (method line + charted tag breakdown).

**Spec:** `docs/superpowers/specs/2026-06-14-grader-detail-ux-design.md`

**Repo facts (verified):**
- `evals-api/src/Evals/Api.hs`: `MetricDto { graderName :: Text, graderVersion :: Int, mean :: Double, passRate :: Maybe Double, count :: Int, stderr :: Maybe Double, breakdowns :: [TagMetricDto] } deriving (Eq, Show, Generic, ToJSON, FromJSON)`; `TagMetricDto {tag :: Text, mean :: Double, stderr :: Maybe Double, count :: Int}`. Pragmas `DeriveAnyClass, DeriveGeneric, DuplicateRecordFields`.
- `src/Evals/Dashboard.hs` `groupedMetricDtos`: per grader-version group, `case [rm | rm <- rows, isNothing rm.tag] of (overall:_) -> do { mgv <- get @GraderVersion (Key gvId); mg <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv; let gName = maybe "?" (.name) mg; gVersion = maybe 0 (.version) mgv; …; pure (Just MetricDto {…}) }`. `Grader.kind :: Text` is a field of the fetched `mg`.
- `test/ApiSpec.hs`: a `dtoRoundTrips` MetricDto literal `{graderName="exact-match", graderVersion=1, mean=0.85, passRate=Just 0.9, count=100, stderr=Just 0.02, breakdowns=[TagMetricDto {tag="theme:x", mean=0.7, stderr=Nothing, count=8}]}`, a standalone `rt "MetricDto"` literal, and a "MetricDto wire key set" golden `object` assertion — ALL three must gain `graderKind`. The `serverSpec` seeds a `Grader {name="exactness", kind="exact"}` and asserts `case r.metrics of [m] -> m.graderName == "exactness" && m.mean == 1.0 && m.passRate == Just 1.0 && m.stderr == Just 0.05 && (case m.breakdowns of [b] -> b.tag == "axis:accuracy" && b.mean == 1.0 && b.count == 1; _ -> False); _ -> False`.
- `evals-ui/src/Evals/Ui/View.hs` (current, from the tag-chips slice): `metricChip mc = span_ [P.class_ "chip metric"] [text (chipText mc)]`; `chipText mc = ms mc.graderName <> " v" <> msShow mc.graderVersion <> " · μ " <> fmtD mc.mean <> ciTxt mc.stderr <> passTxt mc.passRate`; `ciTxt = maybe "" (\s -> " ±" <> fmtD (1.96*s))`; `passTxt = maybe "" (\p -> " · pass " <> msShow (round (p*100)::Int) <> "%")`. `metricChipDetail expanded rid mc = div_ [P.class_ "metric-block"] (span_ chipAttrs [text (chipText mc <> caret)] : [breakdownPanel mc | hasBrk && isOpen]) where {hasBrk = not (null mc.breakdowns); key = "m:" <> msShow rid <> ":" <> ms mc.graderName <> "v" <> msShow mc.graderVersion; isOpen = key `elem` expanded; caret = …; chipAttrs = P.class_ "chip metric" : [onClick (ToggleExpand key) | hasBrk]}`. `breakdownPanel mc = div_ [P.class_ "brk"] (concatMap grp nsOrder) where {nss = nub (map (namespace . (.tag)) mc.breakdowns); known = filter (`elem` nss) ["theme","axis","cluster"]; nsOrder = known <> filter (`notElem` ["theme","axis","cluster"]) nss; grp n = div_ [P.class_ "grp-label"] [text (ms n)] : [brkRow n b | b <- mc.breakdowns, namespace b.tag == n]; brkRow n b = div_ [P.class_ "row"] [span_ [P.class_ ("chip " <> ms n)] [text (ms (labelOf b.tag))], div_ [P.class_ ("bar " <> ms n)] [span_ [widthStyle b.mean] []], span_ [P.class_ "num"] [text (fmtD b.mean <> ciTxt b.stderr)], span_ [P.class_ "n"] [text (msShow b.count)]]}`. Helpers `namespace :: Text -> Text = T.takeWhile (/= ':')`, `labelOf :: Text -> Text`, `widthStyle :: Double -> Attribute Action = styleInline_ ("width:" <> pct ...)` (uses `Miso.CSS (styleInline_)`), `fmtD`/`msShow`. `runHeader :: [MisoString] -> RunSummaryDto -> View Model Action`; `runHeader expanded r = div_ [P.class_ "run-header"] [h2_ …, div_ [P.class_ "meta"] […], div_ [P.class_ "metrics"] (map (metricChipDetail expanded r.runId) r.metrics)]`; called `runHeader (_expandedM m) d.run` in `detailView`. `runRow`/`runCard` call plain `metricChip`. Imports: `Data.List (nub)`, `Data.Text (Text)` + `qualified Data.Text as T`, `Miso.Html`, `qualified Miso.Html.Property as P`, `Miso.String (MisoString, ms)`, `Miso (Attribute, View, text)`, `Miso.CSS (styleInline_)`, `Evals.Api`, `Evals.Ui.Model` (`msShow`, `Action (..)`, `Model`). `strong_`/`h2_`/`span_`/`div_`/`text` from `Miso.Html`.
- `static/style.css`: `.chip { … }`, `.chip.metric { background:#e8eefb; color:#1e3a8a; }`, `.chip.theme/.axis/.cluster`, `.metric-block`, `.brk`, `.grp-label`, `.brk .row`, `.brk .bar`, `.brk .num`, `.brk .n`. `:root` vars `--muted:#6b7280; --line:#e3e7ee; --muted-bg:#eef0f4; --accent:#2456c8; --fg:#1c2330`.
- wasm artifacts (`static/evals-ui.wasm`/`ghc_wasm_jsffi.js`/`js/miso.js`) are GITIGNORED — never commit them. Native build `nix develop -c zinc build 2>&1 | tail -4`; wasm `scripts/build-ui.sh 2>&1 | tail -6`; tests `nix develop -c zinc test 2>&1 | tail -8`.

---

### Task 1: `MetricDto.graderKind` (DTO + server, TDD)

**Files:** `evals-api/src/Evals/Api.hs`, `src/Evals/Dashboard.hs`, `test/ApiSpec.hs`.

- [ ] **Step 1: failing tests.** In `test/ApiSpec.hs`: add `graderKind = "exact"` to the `dtoRoundTrips` `MetricDto` literal, the standalone `rt "MetricDto"` literal, and the "MetricDto wire key set" golden `object` (add `"graderKind" .= ("exact"::Text)` to the expected object — match the field name aeson derives: the record label `graderKind`). In `serverSpec`, extend the metric assertion to also require `m.graderKind == "exact"`:
```haskell
                    && (case r.metrics of
                          [m] -> m.graderName == "exactness" && m.graderKind == "exact"
                                   && m.mean == 1.0 && m.passRate == Just 1.0 && m.stderr == Just 0.05
                                   && (case m.breakdowns of
                                         [b] -> b.tag == "axis:accuracy" && b.mean == 1.0 && b.count == 1
                                         _   -> False)
                          _ -> False)
```
Run `nix develop -c zinc test 2>&1 | tail -6` — compile FAIL (`graderKind` not a field).

- [ ] **Step 2: DTO.** In `evals-api/src/Evals/Api.hs`, add `graderKind :: Text` to `MetricDto` (place after `graderVersion`):
```haskell
data MetricDto = MetricDto
  { graderName :: Text, graderVersion :: Int, graderKind :: Text
  , mean :: Double, passRate :: Maybe Double, count :: Int
  , stderr :: Maybe Double, breakdowns :: [TagMetricDto]
  } deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

- [ ] **Step 3: server.** In `src/Evals/Dashboard.hs` `groupedMetricDtos`'s `buildOne`, after `gVersion`, add `gKind = maybe "?" (.kind) mg`, and set `graderKind = gKind` in the `MetricDto` record. Run `nix develop -c zinc test 2>&1 | tail -8` — all specs green (the dtoRoundTrips + golden + serverSpec all pass). `nix develop -c zinc build 2>&1 | tail -4` — links.

- [ ] **Step 4: commit.** `git add evals-api/src/Evals/Api.hs src/Evals/Dashboard.hs test/ApiSpec.hs && git commit -m "$(printf 'feat(api): MetricDto.graderKind\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"`

---

### Task 2: UI — kind tags, expandable pills, grader-detail section + chart

**Files:** `evals-ui/src/Evals/Ui/View.hs`, `static/style.css`. (No unit harness; verify via native + wasm build.)

- [ ] **Step 1: kind tag on the plain chip.** In `View.hs`, change `metricChip` (used by list/compare) to append a kind sub-label:
```haskell
metricChip :: MetricDto -> View Model Action
metricChip mc = span_ [ P.class_ "chip metric" ] [ text (chipText mc), kindTag mc.graderKind ]

kindTag :: Text -> View Model Action
kindTag k = span_ [ P.class_ "kind" ] [ text (ms k) ]
```

- [ ] **Step 2: expandable grader pill + the full-width section.** REPLACE `metricChipDetail` and `breakdownPanel` with these (the grader pill is always expandable; the section shows the method line always + the chart when there are breakdowns + a pointed note):
```haskell
-- | A run-detail grader pill: always clickable, opens the grader-detail section.
graderPill :: [MisoString] -> Int -> MetricDto -> View Model Action
graderPill expanded rid mc =
  span_ [ P.class_ "chip metric expandable", onClick (ToggleExpand (gKey rid mc)) ]
    [ text (chipText mc), kindTag mc.graderKind
    , span_ [ P.class_ "caret" ] [ text (if gKey rid mc `elem` expanded then " ▾" else " ▸") ] ]

gKey :: Int -> MetricDto -> MisoString
gKey rid mc = "m:" <> msShow rid <> ":" <> ms mc.graderName <> "v" <> msShow mc.graderVersion

-- | Full-width run-level grader detail: how it scores + the charted breakdown.
graderDetailSection :: MetricDto -> View Model Action
graderDetailSection mc =
  div_ [ P.class_ "gdetail" ]
    ( div_ [ P.class_ "gdetail-head" ]
        [ strong_ [] [ text (ms mc.graderName) ], text (" v" <> msShow mc.graderVersion)
        , span_ [ P.class_ "kind big" ] [ text (ms mc.graderKind) ]
        , span_ [ P.class_ "gdesc" ] [ text (methodLine mc.graderKind) ] ]
      : [ breakdownChart mc | not (null mc.breakdowns) ]
      ++ [ span_ [ P.class_ "gnote" ] [ text "criteria vary per example — open an example to see its criteria" ]
         | mc.graderKind == "pointed" ] )

methodLine :: Text -> MisoString
methodLine k = case k of
  "pointed"   -> "An LLM judges each criterion; score = points met ÷ points possible (partial credit, no pass/fail)."
  "exact"     -> "Compares the answer to the expected value — all-or-nothing."
  "rubric"    -> "An LLM judges the answer pass/fail against a rubric."
  "checklist" -> "A weighted yes/no checklist; score = the weighted fraction satisfied."
  _           -> "Scores each answer in this run."

-- | The tag breakdown as a labeled horizontal bar chart.
breakdownChart :: MetricDto -> View Model Action
breakdownChart mc =
  div_ [ P.class_ "chart" ]
    ( div_ [ P.class_ "chart-head" ]
        [ span_ [] [], span_ [] []
        , span_ [ P.class_ "r" ] [ text "score" ], span_ [ P.class_ "r" ] [ text "95% CI" ], span_ [ P.class_ "r" ] [ text "n" ] ]
      : concatMap grp nsOrder
      ++ [ div_ [ P.class_ "scale" ] [ span_ [] [], div_ [ P.class_ "ticks" ] [ span_ [] [text "0"], span_ [] [text "0.5"], span_ [] [text "1.0"] ], span_ [] [] ]
         , div_ [ P.class_ "legend" ] [ text "μ mean · ± 95% CI (bootstrap) · n = examples" ] ] )
  where
    nss     = nub (map (namespace . (.tag)) mc.breakdowns)
    known   = filter (`elem` nss) ["theme", "axis", "cluster"]
    nsOrder = known <> filter (`notElem` ["theme", "axis", "cluster"]) nss
    grp n   = div_ [ P.class_ "grp-label" ] [ text (ms n), span_ [ P.class_ "muted" ] [ text (nsHint n) ] ]
            : [ brow n b | b <- mc.breakdowns, namespace b.tag == n ]
    brow n b = div_ [ P.class_ ("brow " <> ms n) ]
      [ span_ [ P.class_ ("tag " <> ms n) ] [ text (ms (labelOf b.tag)) ]
      , div_ [ P.class_ "track" ] [ span_ [ widthStyle b.mean ] [] ]
      , span_ [ P.class_ "val" ] [ text (fmtD b.mean) ]
      , span_ [ P.class_ "ci" ]  [ text (ciCol b.stderr) ]
      , span_ [ P.class_ "n" ]   [ text (msShow b.count) ] ]

nsHint :: Text -> MisoString
nsHint n = case n of
  "axis"  -> " — criteria, grouped by what they measure"
  "theme" -> " — each example's score, grouped by topic"
  _       -> ""

-- | CI column: "±X" (95% half-width) or an em-dash when no stderr.
ciCol :: Maybe Double -> MisoString
ciCol = maybe "—" (\s -> "±" <> fmtD (1.96 * s))
```

- [ ] **Step 3: restructure `runHeader`.** Render the pills row, then the expanded graders' sections full-width below:
```haskell
runHeader expanded r =
  div_
    [ P.class_ "run-header" ]
    [ h2_ [] [ text ("run #" <> msShow r.runId <> " — " <> ms r.datasetName <> " · v" <> msShow r.datasetVersion) ]
    , div_ [ P.class_ "meta" ]
        [ span_ [] [ text (targetLabel r) ], statusChip r.status
        , span_ [] [ text ("started " <> fmtMaybeTime r.startedAt <> " · finished " <> fmtMaybeTime r.finishedAt) ] ]
    , div_ [ P.class_ "metrics" ] (map (graderPill expanded r.runId) r.metrics)
    , div_ [ P.class_ "grader-details" ] [ graderDetailSection mc | mc <- r.metrics, gKey r.runId mc `elem` expanded ]
    ]
```
(The signature `runHeader :: [MisoString] -> RunSummaryDto -> View Model Action` and the `detailView` caller `runHeader (_expandedM m) d.run` are unchanged. `metricChipDetail` is gone — confirm nothing else references it.)

- [ ] **Step 4: CSS.** In `static/style.css`, replace the old `.brk`-panel rules (`.brk`, `.grp-label`, `.brk .row`, `.brk .bar*`, `.brk .num`, `.brk .n`, `.metric-block`) with the grader-detail + chart styles, and add the kind tag + expandable affordance:
```css
.chip.metric.expandable { cursor:pointer; }
.chip.metric.expandable:hover { box-shadow:0 0 0 2px #c9d7f6; }
.chip .kind { font-size:10px; text-transform:uppercase; letter-spacing:.04em; opacity:.7; margin-left:6px;
              border-left:1px solid rgba(30,58,138,.25); padding-left:6px; }
.chip .caret { margin-left:4px; opacity:.65; }

.grader-details { }
.gdetail { margin:8px 0 4px; border:1px solid var(--line); border-radius:10px; background:#fbfcfe; overflow:hidden; }
.gdetail-head { padding:11px 14px; border-bottom:1px solid var(--muted-bg); }
.gdetail-head strong { font-size:14px; }
.kind.big { background:#ede9fe; color:#5b21b6; border-radius:5px; font-size:11px; padding:1px 7px; margin-left:8px;
            text-transform:none; letter-spacing:0; border-left:none; opacity:1; }
.gdesc { display:block; color:var(--muted); font-size:12px; margin-top:4px; }
.gnote { display:block; color:#9aa1ad; font-size:11.5px; padding:0 14px 11px; }

.chart { padding:12px 16px; }
.chart-head, .brow { display:grid; grid-template-columns:120px 1fr 52px 56px 28px; align-items:center; gap:10px; }
.chart-head { font-size:10px; color:#b3b9c4; text-transform:uppercase; letter-spacing:.05em; padding-bottom:3px; }
.chart-head .r { text-align:right; }
.brow { padding:2px 0; }
.brow .tag { font-size:11px; border-radius:999px; padding:0 8px; white-space:nowrap; }
.brow .tag.axis  { background:#e3f5f4; color:#0f6e69; }
.brow .tag.theme { background:#fdf0e3; color:#9a5b13; }
.brow .tag.cluster { background:#efe7fb; color:#5b21b6; }
.track { position:relative; height:9px; background:var(--muted-bg); border-radius:5px; }
.track > span { position:absolute; left:0; top:0; bottom:0; border-radius:5px; background:var(--accent); }
.brow.axis  .track > span { background:#13a59c; }
.brow.theme .track > span { background:#d08023; }
.brow.cluster .track > span { background:#7c3aed; }
.track::after { content:""; position:absolute; left:50%; top:-2px; bottom:-2px; width:1px; background:#dfe3ea; }
.val { text-align:right; font-variant-numeric:tabular-nums; font-size:12.5px; }
.ci  { text-align:right; font-variant-numeric:tabular-nums; font-size:11px; color:#8b93a1; }
.brow .n { text-align:right; font-variant-numeric:tabular-nums; font-size:11px; color:#b3b9c4; }
.grp-label { font-size:10px; letter-spacing:.06em; text-transform:uppercase; color:#9aa1ad; margin:11px 0 4px; }
.grp-label .muted { text-transform:none; letter-spacing:0; font-size:11px; color:#b3b9c4; }
.scale { display:grid; grid-template-columns:120px 1fr 84px; margin-top:5px; }
.scale .ticks { display:flex; justify-content:space-between; font-size:9px; color:#c2c8d2; }
.legend { margin-top:10px; font-size:11px; color:#9aa1ad; border-top:1px dotted var(--muted-bg); padding-top:7px; }
```
(If a `.brk`/`.metric-block` rule has no replacement above and is now unused, remove it; leave unrelated CSS alone.)

- [ ] **Step 5: build native + wasm.** `nix develop -c zinc build 2>&1 | tail -4` (native links). `scripts/build-ui.sh 2>&1 | tail -6` (wasm links; final line `done. serve with: …`). Fix any `View.hs` compile error (e.g. an unused-import warning for a now-removed helper, or `strong_` not in scope — it is, from `Miso.Html`) and rebuild.

- [ ] **Step 6: commit + push (NOT the gitignored wasm artifacts).**
```bash
git add evals-ui/src/Evals/Ui/View.hs static/style.css
git commit -m "$(printf 'feat(ui): grader kind tags + full-width grader-detail section with charted breakdown\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
git push
```
Confirm `git status` shows `static/*.wasm`/jsffi/miso.js as ignored (not staged).

---

## Self-Review
- Spec §1 (MetricDto.graderKind) → Task 1; §2 (server sets graderKind) → Task 1; §3 (kind tags on pills + every detail pill expandable + grader-detail section with method line + charted breakdown + pointed note) → Task 2; §4 testing (graderKind round-trip + serverSpec; UI build) → Tasks 1–2; §5 out-of-scope (no inspector/criteria, no grader-config wire, no a11y) absent.
- Type consistency: `MetricDto.graderKind :: Text` (Task 1) read as `mc.graderKind` in `kindTag`/`graderPill`/`graderDetailSection`/`methodLine` (Task 2); `gKey :: Int -> MetricDto -> MisoString` used in `graderPill` + `runHeader`; `breakdownChart`/`ciCol`/`nsHint`/`methodLine`/`graderDetailSection`/`graderPill`/`kindTag` all defined in Task 2; reuses existing `chipText`/`ciTxt`/`passTxt`/`namespace`/`labelOf`/`widthStyle`/`fmtD`/`msShow`. `metricChipDetail`/`breakdownPanel` removed and unreferenced after the `runHeader` rewrite.
