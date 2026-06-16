# Run-detail Examples pagination — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline; tasks are tightly coupled through a shared DTO).

**Goal:** Paginate the run-detail Examples table server-side via `?offset=&limit=` on the existing run-detail endpoint.

**Architecture:** `RunDetailDto.outputs` becomes a page; add `totalOutputs`. Server slices the stable-ordered rows. UI holds an offset, refetches on Prev/Next, derives grader columns from `run.metrics` so they stay stable across pages.

**Tech Stack:** Haskell (GHC 9.12 native / 9.14 wasm), zinc, warp/WAI, Miso, hspec.

Spec: `docs/superpowers/specs/2026-06-15-examples-pagination-design.md`.

---

### Task 1: Add `totalOutputs` to the wire DTO

**Files:**
- Modify: `evals-api/src/Evals/Api.hs:67-72`

- [ ] **Step 1:** Add the field:

```haskell
data RunDetailDto = RunDetailDto
  { run          :: RunSummaryDto
  , outputs      :: [OutputRowDto]
  , totalOutputs :: Int
  , calibration  :: [CalibrationSeriesDto]
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

- [ ] **Step 2:** Build evals-api: `nix develop -c zinc build` (will fail at the construction site in Dashboard.hs — expected; fixed in Task 2).

---

### Task 2: Paginate the server handler

**Files:**
- Modify: `src/Evals/Dashboard.hs:89-104` (dispatch — pass `req`)
- Modify: `src/Evals/Dashboard.hs:395-411` (`runDetailHandler`)

- [ ] **Step 1:** At the dispatch site, pass `req` to the handler:

```haskell
        case readMaybe (T.unpack nTxt) :: Maybe Int of
          Nothing -> respond (badRequest "invalid run id")
          Just n  -> apiWith (runDetailHandler pool orgId (RunId n) req respond)
```

- [ ] **Step 2:** Change the signature and add pagination. Add `readMaybeInt` is already available (used by compareHandler at line 527). Use it for parsing.

```haskell
runDetailHandler :: Pool -> OrgId -> RunId -> Request -> (Response -> IO a) -> IO a
runDetailHandler pool orgId rid req respond = do
  let off = max 0 (maybe 0 id (queryParam "offset" req >>= readMaybeInt))
      lim = clampLimit (maybe defLimit id (queryParam "limit" req >>= readMaybeInt))
      defLimit = 50
      clampLimit n = max 1 (min 200 n)
  mDto <- withSession pool $ withTenant orgId $ do
    mRun <- get @Run (Key rid)
    case mRun of
      Nothing  -> pure Nothing
      Just run -> do
        summary <- runSummary True run
        outputs <- selectWhere [ #run ==. rid ] :: Db [Output]
        rows <- mapM (outputRowDto rid) outputs
        let sortedRows = sortOn (\r -> r.exampleKey) rows
            page = take lim (drop off sortedRows)
        cal <- runCalibration rid
        pure (Just RunDetailDto
          { run = summary, outputs = page
          , totalOutputs = length sortedRows, calibration = cal })
  case mDto of
    Nothing  -> respond notFound
    Just dto -> respond (json status200 dto)
```

- [ ] **Step 3:** Build: `nix develop -c zinc build`. Expected: PASS.

---

### Task 3: Server tests for pagination

**Files:**
- Modify: `test/ApiSpec.hs`

- [ ] **Step 1:** Confirm how many outputs the seed creates per run (read the seed in ApiSpec). Let `N` = that count for the run under `/acme`. If `N < 2`, extend the seed so the run has ≥ 3 outputs with distinct example keys (so paging is observable).

- [ ] **Step 2:** Add tests against `/acme/api/runs/<id>`:

```haskell
  it "reports totalOutputs independent of limit" $ \app -> do
    dto <- getJson app "/acme/api/runs/1?limit=1"
    totalOutputs dto `shouldBe` <N>
    length (outputs dto) `shouldBe` 1

  it "pages by offset in key order" $ \app -> do
    p0 <- getJson app "/acme/api/runs/1?offset=0&limit=1"
    p1 <- getJson app "/acme/api/runs/1?offset=1&limit=1"
    let k0 = exampleKey (head (outputs p0))
        k1 = exampleKey (head (outputs p1))
    k0 `shouldSatisfy` (< k1)

  it "defaults to offset 0 limit 50" $ \app -> do
    dto <- getJson app "/acme/api/runs/1"
    length (outputs dto) `shouldBe` min <N> 50

  it "clamps garbage offset/limit" $ \app -> do
    dto <- getJson app "/acme/api/runs/1?offset=-5&limit=abc"
    length (outputs dto) `shouldBe` min <N> 50
```

Match the existing helper names in ApiSpec (e.g. `getJson`) — read the file and reuse them rather than inventing new ones.

- [ ] **Step 3:** Run: `nix develop -c zinc test spec`. Expected: PASS.

---

### Task 4: UI model — offset state + action

**Files:**
- Modify: `evals-ui/src/Evals/Ui/Model.hs`

- [ ] **Step 1:** Add `_outputsOffsetM :: Int` to `Model` (default `0` in the initial model), its lens `outputsOffsetL`, and a module-level `outputsPageSize :: Int; outputsPageSize = 50`.

- [ ] **Step 2:** Add `SetOutputsOffset Int` to `Action`.

- [ ] **Step 3:** Build wasm lib: `nix develop -c zinc build --target wasm` (or the project's wasm build invocation — check `zinc.toml`). Expected: compiles (update site fixed in Task 5).

---

### Task 5: UI fetch + update wiring

**Files:**
- Modify: `evals-ui/src/Main.hs`

- [ ] **Step 1:** In `fetchRoute (RunR i)`, append the page query using the model's current offset:

```haskell
fetchRoute m (RunR i) =
  fetchJson ("/api/runs/" <> msShow i
             <> "?offset=" <> msShow m._outputsOffsetM
             <> "&limit=" <> msShow outputsPageSize) (GotDetail i)
```

(Thread the model into `fetchRoute` if it doesn't already take it; otherwise read offset from where the route fetch is issued.)

- [ ] **Step 2:** In `SetRoute (RunR _)`, reset offset: add `outputsOffsetL .= 0` next to the existing `runTabL`/`compareMenuL` resets.

- [ ] **Step 3:** Handle the new action:

```haskell
SetOutputsOffset n -> do
  outputsOffsetL .= n
  m <- get
  -- re-issue the detail fetch for the current run at the new offset
  <issue fetchRoute for the current RunR using m>
```

Use the existing route-dispatch path so the same `GotDetail` handler updates the table.

- [ ] **Step 4:** Build wasm: expected PASS.

---

### Task 6: View — pager + stable grader columns

**Files:**
- Modify: `evals-ui/src/Evals/Ui/View.hs`

- [ ] **Step 1:** In `outputsTable`, confirm `gs` (grader columns) and the mean footer are derived from the `[MetricDto]` argument, not from `outputs`. If still `nub [... | o <- outputs ...]`, change to source from metrics.

- [ ] **Step 2:** Add a pager, rendered only under the Examples tab, below the table. It receives `totalOutputs` and the current offset (thread from the model + fetched `RunDetailDto`):

```haskell
pager :: Int -> Int -> View Model Action
pager off total =
  div_ [P.class_ "pager"]
    [ button_ (disAttrs (off <= 0) (SetOutputsOffset (max 0 (off - outputsPageSize)))) [text "‹ Prev"]
    , span_ [P.class_ "pager-label"] [text rangeLabel]
    , button_ (disAttrs (off + outputsPageSize >= total) (SetOutputsOffset (off + outputsPageSize))) [text "Next ›"]
    ]
  where
    lo = if total == 0 then 0 else off + 1
    hi = min (off + outputsPageSize) total
    rangeLabel = "showing " <> msShow lo <> "–" <> msShow hi <> " of " <> msShow total
    disAttrs disabled act =
      if disabled then [P.class_ "pager-btn", P.disabled_ True]
                  else [P.class_ "pager-btn", onClick act]
```

- [ ] **Step 3:** Wire `pager` into `detailView` on the Examples tab only.

- [ ] **Step 4:** Build wasm: expected PASS.

---

### Task 7: Pager styling

**Files:**
- Modify: `static/style.css`

- [ ] **Step 1:** Add:

```css
.pager { display: flex; align-items: center; justify-content: center; gap: 1rem; margin: 1rem 0; }
.pager-label { color: var(--muted, #888); font-size: 0.9rem; }
.pager-btn[disabled] { opacity: 0.4; cursor: default; }
```

(Match existing CSS variable names/conventions in the file.)

---

### Task 8: End-to-end verification

- [ ] **Step 1:** `nix develop -c zinc test spec` — all pass.
- [ ] **Step 2:** Rebuild wasm + restart the :8788 (hb, 200 rows) dashboard; load a run detail, confirm 50 rows, Prev disabled, Next advances, range label correct, grader columns stable across pages.
- [ ] **Step 3:** Commit.
