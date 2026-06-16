# Miso Dashboard (sub-project B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only eval dashboard: a wasm Miso SPA (runs list → run detail → compare) served by a native warp JSON API, with a shared DTO package as the wire boundary.

**Architecture:** Three artifacts in one zinc workspace — `evals-api` (pure DTO package, cross-compiles to wasm), the root package's `evals-dashboard` exe (warp server: `/api/*` JSON from Manifest queries + static files incl. the wasm module), and `evals-ui` (Miso app; wasm reactor for production, native jsaddle for dev if cheap). The spike comes first and is allowed to fail the whole approach back to jsaddle-only.

**Tech Stack:** GHC 9.12.2 native + zinc's `wasm32-wasi` cross target (reactor flavor via `wasm-exports`), miso (git pin, resolved in the spike), wai/warp (hand-rolled routing), aeson, the existing Manifest layer.

**Spec:** `docs/superpowers/specs/2026-06-11-miso-dashboard-design.md` · **Issue:** manifest-1hl

**Verified zinc facts:** `zinc build --target wasm32-wasi`; a `[build.exe.*]` with non-empty `wasm-exports = [...]` builds a browser REACTOR module and generates `ghc_wasm_jsffi.js` glue (src/Zinc/Manifest.hs:121); zinc's cabal layer already handles miso's wasm-gated `js-sources` (`js/miso.js`, src/Zinc/Cabal.hs:130) — zinc has met miso before. Caches are keyed by target (native and wasm coexist). Workspace members are directories with their own `zinc.toml` `[package]`; members depend on each other by package name (the pre-rehome manifest workspace used exactly this).

**Known-unknowns the spike owns:** the miso rev that builds on the wasm toolchain's GHC; the browser boot wiring (index.html + WASI shim + jsffi glue + miso.js); whether native jsaddle dev mode is cheap; warp's closure under zinc. Tasks 3–5 are written against the STABLE parts (DTOs, queries, behaviours) with explicit adapt-latitude where the spike's findings bind.

## File structure

- Create `evals-ui/zinc.toml`, `evals-ui/src/Main.hs` (+ `evals-ui/static/index.html` boot page) — Task 1 hello-world, Task 5 real app.
- Create `evals-api/zinc.toml`, `evals-api/src/Evals/Api.hs` — Task 2.
- Modify root `zinc.toml` (workspace members, new deps, `[build.exe.evals-dashboard]`) — Tasks 1–3.
- Create `src/Evals/Dashboard.hs` (wai app: routing, queries, entity→DTO mapping, static serving) + `app-dashboard/Main.hs` (env + warp boot) — Task 3.
- Create `test/ApiSpec.hs`; modify `test/Spec.hs` — Tasks 2–4.
- Modify `README.md` — Task 6.

---

### Task 1: GATING SPIKE — miso hello-world as a zinc wasm reactor, served and human-verified

**Files:** Create `evals-ui/zinc.toml`, `evals-ui/src/Main.hs`, `static/index.html` (repo root; the server's default static dir), `app-dashboard/Main.hs` stub, root `zinc.toml` edits.

This task has DELIBERATE exploratory latitude: package revs, exact loader JS, and miso API details are discovered here. Hard success criteria at the end. If blocked after reasonable effort (~a few hours of iteration), STOP and report — the fallback (jsaddle-warp single binary) is a spec-level decision, not yours to make.

- [ ] **Step 1: workspace + ui member.** Root `zinc.toml`: `members = [".", "evals-ui"]`. Create `evals-ui/zinc.toml`:

```toml
[package]
name = "evals-ui"
version = "0.1.0.0"

[build.exe.evals-ui]
source-dirs = ["src"]
main = "Main.hs"
ghc-options = ["-Wall"]
depends = ["base", "miso", "text"]
# non-empty wasm-exports => browser REACTOR module + ghc_wasm_jsffi.js glue.
# The export set the GHC wasm JS-FFI boot needs; adjust per the spike findings
# (miso's wasm examples export hs_start / use the jsffi default exports).
wasm-exports = ["hs_start"]
```

- [ ] **Step 2: resolve miso.** Add to the ROOT `zinc.toml` `[dependencies]` (shared registry): `[dependencies.miso]` with `repo = "https://github.com/dmjio/miso.git"` and a rev: try latest master first (`git ls-remote https://github.com/dmjio/miso.git HEAD`); miso ≥ 1.9 has the wasm backend support. Run `nix develop -c zinc update miso` (or `zinc add miso` if the stanza route fights — report which worked). Expect transitive pins to need adding (the C-rehome pattern: "no repo in [registry] for dependency X" → add X's URL from miso's repo or Hackage vendoring via `zinc vendor`). Iterate until `nix develop -c zinc build` (NATIVE — just resolution, the ui exe may fail to compile natively without jsaddle; that's fine at this step, resolution is what's being tested) resolves the closure.

- [ ] **Step 3: hello-world Miso app.** `evals-ui/src/Main.hs` — a counter, adapted to the resolved miso version's API (this is miso's canonical README example; adjust imports/`startApp` vs `run`/`miso` entry to the pinned version):

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Miso
import Miso.String (ms)

data Action = Inc | Dec | NoOp

main :: IO ()
main = run (startApp App { model = (0 :: Int), update = updateModel, view = viewModel
                         , subs = [], events = defaultEvents, initialAction = NoOp
                         , mountPoint = Nothing, logLevel = Off })
  where
    updateModel Inc n = noEff (n + 1)
    updateModel Dec n = noEff (n - 1)
    updateModel NoOp n = noEff n
    viewModel n = div_ []
      [ button_ [ onClick Dec ] [ text "-" ]
      , text (ms (show n))
      , button_ [ onClick Inc ] [ text "+" ]
      ]
```

(Whatever the pinned miso's idiom is — `run`, `startApp`, `miso`, `App {..}` field names — use it; keep the BEHAVIOUR: a counter with two buttons.)

- [ ] **Step 4: wasm build.** `nix develop -c zinc build --target wasm32-wasi 2>&1 | tail -5`. Expected: an `evals-ui.wasm` artifact + a `ghc_wasm_jsffi.js` glue file (find both under the wasm build dir; report exact paths). This step is the heart of the spike — iterate on miso rev/flags until green or blocked.

- [ ] **Step 5: stub server.** Root `zinc.toml` gains the dashboard exe (deps minimal for now):

```toml
[build.exe.evals-dashboard]
source-dirs = ["app-dashboard"]
main = "Main.hs"
ghc-options = ["-Wall", "-XOverloadedStrings", "-lpq"]
depends = ["base", "text", "bytestring", "wai", "warp", "http-types", "filepath"]
```

plus `[dependencies.wai]`/`[dependencies.warp]` stanzas if zinc needs URLs (try plain names first — `zinc add warp`; warp's closure is pure Haskell + network; if `network`'s configure step fights wasm THAT'S FINE — this exe is native-only). `app-dashboard/Main.hs`, a static file server (the /api routes arrive in Task 3):

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import qualified Data.ByteString.Char8 as BC
import qualified Data.Text as T
import Network.HTTP.Types (status200, status404)
import Network.Wai (Application, pathInfo, responseFile, responseLBS)
import Network.Wai.Handler.Warp (run)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeExtension)

main :: IO ()
main = do
  port <- maybe 8787 read <$> lookupEnv "EVALS_HTTP_PORT"
  dir  <- maybe "static" id <$> lookupEnv "EVALS_STATIC_DIR"
  putStrLn ("evals-dashboard on http://localhost:" <> show port)
  run port (staticApp dir)

-- Static files only (the JSON API lands with Evals.Dashboard). Path traversal
-- is blocked by rejecting ".." segments.
staticApp :: FilePath -> Application
staticApp dir req respond = do
  let segs = map T.unpack (pathInfo req)
      path = case segs of [] -> "index.html"; _ -> foldr1 (</>) segs
  if any (== "..") segs
    then respond (responseLBS status404 [] "not found")
    else respond (responseFile status200
            [("Content-Type", contentType (takeExtension path))]
            (dir </> path) Nothing)

contentType :: String -> BC.ByteString
contentType ".html" = "text/html; charset=utf-8"
contentType ".js"   = "text/javascript"
contentType ".mjs"  = "text/javascript"
contentType ".wasm" = "application/wasm"
contentType ".css"  = "text/css"
contentType _       = "application/octet-stream"
```

(`responseFile` on a missing file: warp turns the IO error into a 500 — acceptable for the spike; Task 3 adds an existence check when this moves into `Evals.Dashboard`.)

- [ ] **Step 6: browser boot page.** Create `static/index.html` + loader that: loads a WASI shim (miso's ghc-wasm examples use `@bjorn3/browser_wasi_shim` as an ES module — vendor the file into `static/` rather than hitting a CDN at runtime if practical), imports `ghc_wasm_jsffi.js`, instantiates `evals-ui.wasm`, runs the reactor's exports (`_initialize`/`hs_start` per the GHC wasm JS-FFI docs and miso's wasm example). Copy the built artifacts into `static/` (document the copy commands; a `scripts/build-ui.sh` with the 3 cp lines is fine). Follow miso's official wasm example layout — it exists in the miso repo under `examples`/`sample-app-wasm` or the `ghc-wasm-miso-examples` upstream; ADAPT, don't invent.

- [ ] **Step 7: verify what an agent can verify.** Start the server (`nix develop -c ./.zinc/build/evals-dashboard` with `EVALS_STATIC_DIR=static`, background), then: `curl -sI localhost:8787/index.html` (200, text/html), `curl -sI localhost:8787/evals-ui.wasm` (200, **application/wasm**), `curl -sI localhost:8787/ghc_wasm_jsffi.js` (200, text/javascript). Kill the server.

- [ ] **Step 8: HUMAN CHECKPOINT.** Commit, then STOP and report to the controller: artifacts built, server serves them, and ask the human to open `http://localhost:8787` and confirm the counter renders and the buttons increment/decrement. DO NOT proceed to Task 2 without that confirmation (the controller will relay it).

```bash
git add -A
git commit -m "spike(ui): miso hello-world as a zinc wasm32-wasi reactor + static stub server"
```

---

### Task 2: `evals-api` — the DTO package

**Files:** Create `evals-api/zinc.toml`, `evals-api/src/Evals/Api.hs`; Modify root `zinc.toml` (members + test deps), `test/Spec.hs`; Create `test/ApiSpec.hs` (round-trip section only).

- [ ] **Step 1: member.** Root `zinc.toml`: `members = [".", "evals-api", "evals-ui"]`. Create `evals-api/zinc.toml`:

```toml
[package]
name = "evals-api"
version = "0.1.0.0"

[build.lib]
source-dirs = ["src"]
ghc-options = ["-Wall"]
depends = ["base", "text", "time", "aeson"]
```

- [ ] **Step 2: failing round-trip test.** Create `test/ApiSpec.hs`:

```haskell
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
module ApiSpec (main) where

import Control.Monad (unless)
import Data.Aeson (decode, encode)
import Data.Time (UTCTime (..), fromGregorian)
import Evals.Api

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 11) 0

main :: IO ()
main = do
  roundTripSpec
  putStrLn "manifest-evals ApiSpec: dto round-trips OK"

roundTrip :: (Eq a, Show a, ToJSONFromJSON a) => String -> a -> IO ()
-- NOTE: write this as a small local helper with the right constraints:
-- roundTrip msg x = expect msg (decode (encode x) == Just x)
roundTripSpec :: IO ()
roundTripSpec = do
  rt "MetricDto" (MetricDto { graderName = "g", graderVersion = 1, mean = 0.5, passRate = Just 0.5, count = 2 })
  rt "ScoreDto" (ScoreDto { graderName = "g", graderVersion = 1, value = Just 1.0
                          , passed = Just True, scoreError = Nothing, rationale = Just "ok" })
  rt "OutputRowDto" (OutputRowDto { exampleKey = "e1", outputText = Just "t", outputError = Nothing
                                  , latencyMs = Just 12, scores = [] })
  rt "RunSummaryDto" (RunSummaryDto { runId = 1, datasetVersionId = 2, datasetName = "d", datasetVersion = 1
                                    , targetName = "t", targetVersion = 1, model = "m"
                                    , status = "succeeded", startedAt = Just t0, finishedAt = Just t0
                                    , metrics = [] })
  rt "DatasetDto" (DatasetDto { datasetId = 1, name = "d", slug = "d"
                              , versions = [DatasetVersionDto { datasetVersionId = 2, version = 1
                                                              , finalizedAt = Just t0, exampleCount = 3 }] })
  rt "RunDetailDto" (RunDetailDto { run = RunSummaryDto { runId = 1, datasetVersionId = 2, datasetName = "d"
                                                        , datasetVersion = 1, targetName = "t", targetVersion = 1
                                                        , model = "m", status = "s", startedAt = Nothing
                                                        , finishedAt = Nothing, metrics = [] }
                                  , outputs = [] })
  rt "CompareDto" (CompareDto { runA = ..., runB = ..., rows = [CompareRowDto { exampleKey = "e1"
                              , outputA = Just "x", outputB = Just "y", scoreA = Just 1.0, scoreB = Just 0.0
                              , delta = Just (-1.0) }] })
  where rt msg x = expect msg (decode (encode x) == Just x)
-- (For CompareDto, construct two real RunSummaryDto values inline — no `...` in the actual file;
-- the two placeholder dots above are PLAN shorthand for the same RunSummaryDto shape already shown.)
```

Wire into `test/Spec.hs` (`import qualified ApiSpec`, append `>> ApiSpec.main`). Root `zinc.toml` test target deps += `"evals-api"`.

- [ ] **Step 3: run** — compile failure (Evals.Api missing). **Step 4: implement** `evals-api/src/Evals/Api.hs`:

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

-- | The dashboard's JSON wire types. Pure data — this package is compiled
-- into BOTH the native server and the wasm UI, so it depends only on
-- base/text/time/aeson. Entities never cross the wire; the server maps
-- entity -> DTO ("Evals.Dashboard"). Ids are plain Ints (typed ids stay
-- server-side).
module Evals.Api
  ( DatasetDto (..), DatasetVersionDto (..)
  , RunSummaryDto (..), MetricDto (..)
  , RunDetailDto (..), OutputRowDto (..), ScoreDto (..)
  , CompareDto (..), CompareRowDto (..)
  , ApiError (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

data DatasetDto = DatasetDto
  { datasetId :: Int, name :: Text, slug :: Text, versions :: [DatasetVersionDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data DatasetVersionDto = DatasetVersionDto
  { datasetVersionId :: Int, version :: Int, finalizedAt :: Maybe UTCTime, exampleCount :: Int }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data MetricDto = MetricDto
  { graderName :: Text, graderVersion :: Int, mean :: Double, passRate :: Maybe Double, count :: Int }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data RunSummaryDto = RunSummaryDto
  { runId :: Int, datasetVersionId :: Int, datasetName :: Text, datasetVersion :: Int
  , targetName :: Text, targetVersion :: Int, model :: Text
  , status :: Text, startedAt :: Maybe UTCTime, finishedAt :: Maybe UTCTime
  , metrics :: [MetricDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data ScoreDto = ScoreDto
  { graderName :: Text, graderVersion :: Int, value :: Maybe Double
  , passed :: Maybe Bool, scoreError :: Maybe Text, rationale :: Maybe Text }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data OutputRowDto = OutputRowDto
  { exampleKey :: Text, outputText :: Maybe Text, outputError :: Maybe Text
  , latencyMs :: Maybe Int, scores :: [ScoreDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data RunDetailDto = RunDetailDto
  { run :: RunSummaryDto, outputs :: [OutputRowDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data CompareRowDto = CompareRowDto
  { exampleKey :: Text, outputA :: Maybe Text, outputB :: Maybe Text
  , scoreA :: Maybe Double, scoreB :: Maybe Double, delta :: Maybe Double }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data CompareDto = CompareDto
  { runA :: RunSummaryDto, runB :: RunSummaryDto, rows :: [CompareRowDto] }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

newtype ApiError = ApiError { error :: Text }
  deriving (Eq, Show, Generic)
instance ToJSON ApiError
instance FromJSON ApiError
```

(NO NoFieldSelectors here — plain selectors keep aeson `Generic` simple, and `DuplicateRecordFields` covers the name reuse. This package has its own style: it's a wire-format module.)

- [ ] **Step 5: run to green** (`ApiSpec: dto round-trips OK`). **Step 6: also verify the wasm cross-compile**: `nix develop -c zinc build --target wasm32-wasi 2>&1 | tail -3` (evals-api must build for wasm; evals-ui still hello-world). **Step 7: commit** `feat(api): evals-api DTO package (the JSON wire boundary)`.

---

### Task 3: the dashboard server — routing + datasets/runs endpoints (TDD)

**Files:** Create `src/Evals/Dashboard.hs`; Modify `app-dashboard/Main.hs` (use the lib app), root `zinc.toml` (lib deps += `evals-api`, `wai`, `http-types`; exe deps += `manifest`, `manifest-evals`, `evals-api`), `test/ApiSpec.hs` (server section), `test/Spec.hs` if needed.

- [ ] **Step 1: failing tests.** Extend `test/ApiSpec.hs` with a server section. Test technique: bind warp on a free port inside the test, hit it with the in-closure `http-client`, decode DTOs:

```haskell
-- imports to add: Network.Wai.Handler.Warp (testWithApplication), Network.HTTP.Client
-- (httpLbs, parseRequest, newManager, defaultManagerSettings, responseBody, responseStatus),
-- Network.HTTP.Types (statusCode), Manifest/Evals seeding imports as in GradeSpec,
-- Evals.Dashboard (dashboardApp)

serverSpec :: IO ()
serverSpec = withEphemeralDb $ \pool -> do
  _ <- withSession pool migrateAll
  now <- getCurrentTime
  -- seed: one dataset/version with 2 examples; one target; one run with
  -- 2 outputs (one scored 1.0 by grader g v1, one errored output); one RunMetric
  -- (reuse the GradeSpec seeding style; ~25 lines, write it concretely in the file)
  mgr <- newManager defaultManagerSettings
  testWithApplication (pure (dashboardApp pool "static")) $ \port -> do
    let get path = parseRequest ("http://localhost:" <> show port <> path) >>= flip httpLbs mgr
    -- datasets
    r1 <- get "/api/datasets"
    expect "datasets: 200" (statusCode (responseStatus r1) == 200)
    expect "datasets: one dataset, one version, exampleCount 2"
      (case decode (responseBody r1) :: Maybe [DatasetDto] of
         Just [d] -> length d.versions == 1 && (head d.versions).exampleCount == 2
         _ -> False)
    -- runs
    r2 <- get "/api/runs"
    expect "runs: status + metrics present"
      (case decode (responseBody r2) :: Maybe [RunSummaryDto] of
         Just [r] -> r.status == "succeeded" && length r.metrics == 1
         _ -> False)
    -- 404
    r3 <- get "/api/runs/999999"
    expect "unknown run: 404 + ApiError body"
      (statusCode (responseStatus r3) == 404
         && (decode (responseBody r3) :: Maybe ApiError) /= Nothing)
```

(Write the seeding concretely; assert one or two more fields you seeded — model, mean. `testWithApplication` is in warp. Call `serverSpec` from ApiSpec's `main` after the round-trips, and update the final putStrLn to `dto round-trips + api OK`.)

- [ ] **Step 2: run — fails** (no `Evals.Dashboard`). **Step 3: implement** `src/Evals/Dashboard.hs`:

Structure (write in full; ~150 lines):
- `dashboardApp :: Pool -> FilePath -> Application` — routes on `pathInfo`:
  `["api","datasets"]` → datasets; `["api","runs"]` → runs (read optional `datasetVersion` query param); `["api","runs",n]` → runDetail; `["api","compare"]` → compare (Task 4); anything else under `"api"` → 404 json; everything else → the static handler (moved here from the spike's Main, with an existence check via `System.Directory.doesFileExist` → 404).
- JSON helpers: `jsonResponse :: ToJSON a => Status -> a -> Response` (Content-Type application/json); `notFound`/`badRequest` returning `ApiError`.
- Queries with the existing Manifest DSL (same idioms as GradeSpec/SchemaSpec):
  - datasets: `selectWhere ([] :: [Cond Dataset])`, versions per dataset via `selectWhere [#dataset ==. d.id]`, example count via `runQuery` countRows per version (or selectWhere length — datasets are small, keep it simple).
  - runs: `selectWhere` (filter by datasetVersion when the query param parses), then per run: its TargetVersion + Target + DatasetVersion + Dataset via `get`, metrics via `selectWhere [#run ==. r.id]` joined to GraderVersion→Grader names.
  - runDetail: the run + outputs (`selectWhere [#run ==. rid]`), example keys via `get @Example`, scores per output (`selectWhere [#output ==. o.id]`) with grader names; order outputs by example key.
- Mapping helpers entity→DTO live here (small pure functions; `rationale` extracted from the Score's `detail` jsonb `{"rationale": ...}` via aeson).
- `app-dashboard/Main.hs` shrinks to: read env (port/static dir/db url via the CLI's `requireEnv` pattern), `newPool`, `run port (dashboardApp pool dir)`.

- [ ] **Step 4: run to green.** Full suite (`nix develop -c zinc test`): SchemaSpec/ExecuteSpec/GradeSpec untouched + ApiSpec green. **Step 5: commit** `feat(dashboard): warp JSON API — datasets, runs, run detail (+static)`.

(Run detail endpoint may land in this task or Task 4 — keep tests and implementation in the same commit either way; report where the seam fell.)

---

### Task 4: compare endpoint (TDD)

**Files:** Modify `src/Evals/Dashboard.hs`, `test/ApiSpec.hs`.

- [ ] **Step 1: failing tests.** Seed (in a fresh section of serverSpec or a second `withEphemeralDb`): two runs over the SAME dataset version (reuse the SchemaSpec scenario-D shape: 2 examples, run A scores c1=1.0/c2=0.0, run B the opposite — seed Scores directly, no engine needed). Assertions:
  - `GET /api/compare?a=<A>&b=<B>` → 200; rows aligned by example key (`[("c1", Just 1.0, Just 0.0, Just (-1.0)), ("c2", ...)]` — assert exampleKey/scoreA/scoreB/delta per row); both run headers present with metrics.
  - `GET /api/compare?a=<A>&b=<otherDatasetRun>` → 400 ApiError (mismatched dataset versions). Seed the mismatched run minimally.
  - missing/garbage params → 400.
- [ ] **Step 2: implement** the `["api","compare"]` route: parse `a`/`b` ints from the query string (400 otherwise); load both runs (404 if either missing); 400 if `datasetVersion` differs; build rows by example key — for each example of the shared dataset version: each side's output text + its FIRST graded score value (v1 simplification: compare assumes one grader version of interest per run; delta = scoreA - scoreB when both Just). Order rows by key.
- [ ] **Step 3: green; full suite. Step 4: commit** `feat(dashboard): compare endpoint (aligned by example key)`.

---

### Task 5: the real Miso UI

**Files:** Rewrite `evals-ui/src/Main.hs` (split into `Main.hs` + `evals-ui/src/Evals/Ui/{Model,Update,View,Fetch}.hs` if it grows past ~250 lines); modify `evals-ui/zinc.toml` (deps += `evals-api`, `aeson`); `static/style.css`; rebuild+copy script.

Adapt to the spike-pinned miso version's API. The BEHAVIOUR contract (assert these manually; the model/update split should make them obvious in code):

- [ ] **Step 1: model + routing.** `Model = { route :: Route, runs :: RemoteData [RunSummaryDto], detail :: RemoteData RunDetailDto, compare :: RemoteData CompareDto, compareSel :: Maybe Int }` with `Route = RunsR | RunR Int | CompareR Int Int` parsed from/written to the location hash (`#/runs`, `#/runs/<id>`, `#/compare/<a>/<b>`); `RemoteData a = NotAsked | Loading | Failed Text | Got a`. miso's URI/hash machinery (or a tiny JS FFI `getHash`/`onhashchange` sub) — whichever the pinned version supports; hash change → route change → fetch dispatch.
- [ ] **Step 2: fetch.** JSON GETs against same-origin `/api/...`: use the pinned miso's fetch/xhr helper if present; otherwise a small JS FFI wrapper (`fetch(url).then(r => r.text())` into a callback) decoded with aeson (`evals-api` types — the whole point). Failures land in `Failed`.
- [ ] **Step 3: views.**
  - Runs: table grouped under dataset/version headings; columns run id, target (name vMaj + model), status, started; metric chips (`graderName vN: mean μ / pass p%`); row click → `#/runs/<id>`; a "compare" checkbox per row — when two are picked, a button navigates to `#/compare/<a>/<b>` (enabled only when both picked runs share `datasetVersionId`).
  - Run detail: header (run summary + metric chips), table: example key, output text (CSS-truncated with title-attr full text; click toggles a `expanded` class), latency, one column per grader (value + ✓/✗), output errors as a red row with the error text; score errors as an inline ⚠ with the error text.
  - Compare: A/B header cards (metrics side by side), rows: key, A text, B text, scoreA, scoreB, delta (signed, colored), disagreement rows (one passed, one failed) highlighted.
- [ ] **Step 4: styling** — one hand-written `static/style.css` (system font stack, a table style, chip badges, red/green status colors). No framework.
- [ ] **Step 5: builds.** Native `nix develop -c zinc build` stays green (the ui exe may need miso's jsaddle path for native — if jsaddle drags an unreasonable closure, make the native build a stub `main = putStrLn "wasm only"` behind CPP `#ifdef wasm32_HOST_ARCH` — REPORT the choice); wasm build green; copy artifacts to `static/` (update the script).
- [ ] **Step 6: HUMAN CHECKPOINT.** Seed a real local DB (document: createdb + `manifest-evals migrate` + a tiny seed via ghci or a `scripts/seed-demo.hs` runghc script seeding 1 dataset/2 examples/2 runs/outputs/scores — write it), start the server, ask the human to click through all three views and confirm. STOP for confirmation.
- [ ] **Step 7: commit** `feat(ui): the dashboard SPA — runs, run detail, compare`.

---

### Task 6: docs + close-out

**Files:** Modify `README.md`; beads (manifest repo).

- [ ] **Step 1:** README: new "Dashboard" section — build commands (`zinc build`, `zinc build --target wasm32-wasi`, the copy script), run (`EVALS_HTTP_PORT/EVALS_STATIC_DIR/MANIFEST_DATABASE_URL`, `./.zinc/build/evals-dashboard`), the three views, read-only note. Layout bullets gain `evals-api/`, `evals-ui/`, `app-dashboard/`.
- [ ] **Step 2:** full suite + both builds one final time. **Step 3:** commit + push; `cd /home/gareth/code/garethstokes/manifest && bd close manifest-1hl --reason "..."` + commit/push beads.

---

## Self-Review

**1. Spec coverage:** §1 three artifacts → Tasks 1 (ui+server stub), 2 (api), 3 (server); §2 endpoints/errors/env → Tasks 3–4; §3 DTOs → Task 2; §4 SPA views/routing/fetch/CSS → Task 5; §5 testing (round-trips, handler tests vs ephemeral PG incl. 404/400/mismatch, thin UI) → Tasks 2–4 (UI pure tests folded into Task 5 only if cheap — spec says "if cheap"); §6 spike-first with STOP + fallback → Task 1; §7 out-of-scope absent everywhere (no POST routes, no auth, no pagination, no autodocodec).

**2. Placeholder scan:** Task 1 and Task 5 carry DECLARED exploratory latitude (miso rev/API, loader wiring) with hard success criteria and human checkpoints — that's the spike pattern, not a TBD. Two literal `...` in Task 2's CompareDto test sketch are flagged inline as plan shorthand with instructions to construct real values. Task 3's seeding is specified by reference to an existing in-repo pattern plus concrete assertions. No unmarked placeholders.

**3. Type consistency:** DTO names/fields match between Task 2 (definitions), Task 3–4 (decode assertions: `d.versions`, `r.status`, `r.metrics`, ApiError), and Task 5 (model holds `[RunSummaryDto]`/`RunDetailDto`/`CompareDto`; compare gating uses `datasetVersionId`). `dashboardApp :: Pool -> FilePath -> Application` consistent across Tasks 3–4 and the test's `testWithApplication`.
