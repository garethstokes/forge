# Eval Orchestrator — Miso Dashboard (sub-project B) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-11 · **Issue:** manifest-1hl

**Goal:** A read-only dashboard over the eval data model: browse datasets and
runs, drill into a run's per-example outputs and scores, and compare two runs
side-by-side by example key. A Miso UI compiled to WebAssembly, served by a
native warp API server, with a shared DTO package as the JSON boundary.

---

## 0. Context

The pipeline is complete end-to-end (A data model, C executor, scoring), all
CLI-driven. zinc builds WebAssembly (`zinc build --target wasm32-wasi`)
including a browser reactor module with the JavaScript FFI, so a real
client-side Miso app is buildable from this repo with no extra toolchain. No
sibling repo has Miso precedent — the build is the primary risk and is
de-risked first (§6).

**Decisions** (user-approved): real WASM UI (not jsaddle-only, not a separate
repo); v1 is READ-ONLY (no run/score triggering — that arrives with D's live
progress); wai/warp with hand-rolled routing (no servant — matches the
codebase's minimal-closure taste); plain aeson DTOs (no autodocodec schemas —
no external consumers yet); no auth (single-user internal tool); no
pagination v1.

## 1. Workspace shape — three artifacts

The repo becomes a multi-member zinc workspace:

- **`evals-api/`** (new member package): the JSON boundary. `Evals.Api` DTO
  records (plain aeson `Generic` instances), depending ONLY on
  `base/text/time/aeson` so the closure cross-compiles to wasm. Entities
  never cross the wire; the server maps entity → DTO.
- **root package** (existing): gains `[build.exe.evals-dashboard]` — a native
  warp server. Depends on the existing lib (Manifest queries) + `evals-api`.
- **`evals-ui/`** (new member package): the Miso app, depending on
  `evals-api` + miso. One source, two builds:
  - `zinc build --target wasm32-wasi` → the browser reactor module shipped to
    production;
  - native build → a jsaddle-warp dev server for fast iteration (miso
    supports both from the same code).

The dashboard server serves `/api/*` JSON and the static assets (index.html,
the JS shim, the wasm module) from a configurable directory.

## 2. The API (read-only)

Hand-rolled wai routing on warp. All responses JSON; errors are
`{"error": <text>}` with proper status codes (404 unknown id, 400 bad params).
Endpoints:

- `GET /api/datasets` — datasets with their versions (id, name, slug,
  version, finalizedAt, example count).
- `GET /api/runs` — runs (optionally `?datasetVersion=<id>`): id, dataset
  version, target name/version/model, status, started/finished, and the run's
  `RunMetric` summaries (grader name/version, mean, passRate, count).
- `GET /api/runs/<id>` — the run header plus one row per output: example key,
  output text/error/latency/tokens, and that output's scores (grader
  name/version, value, passed, error, detail rationale).
- `GET /api/compare?a=<runId>&b=<runId>` — both runs must share a dataset
  version (else 400). Run headers (with metric summaries) + rows aligned by
  example key: each side's output text/error and score values, plus the
  per-example delta where both sides have a graded score (v1 compares one
  grader's scores; the response names it).

Config via env, like the CLI: `MANIFEST_DATABASE_URL`, `EVALS_HTTP_PORT`
(default 8787), `EVALS_STATIC_DIR` (default `./static`). Read-only: the
server never writes; `executeRun`/`scoreRun` remain CLI-only in v1.

## 3. DTOs (`Evals.Api`)

Plain records mirroring what each endpoint returns (e.g. `DatasetDto`,
`DatasetVersionDto`, `RunSummaryDto`, `MetricDto`, `RunDetailDto`,
`OutputRowDto`, `ScoreDto`, `CompareDto`, `CompareRowDto`), ids as plain
`Int`s (the typed ids stay server-side), `ToJSON`/`FromJSON` via `Generic`.
The UI decodes the same types — one definition, both sides of the wire.
Compare rows carry per-side passed/error and the `CompareDto` names the
single grader v1 compares on. No autodocodec (YAGNI until an external
consumer appears).

## 4. The UI (Miso SPA)

Hash-fragment routing (no server-side route handling): `#/runs` (default),
`#/runs/<id>`, `#/compare/<a>/<b>`. Three views:

- **Runs** — runs grouped by dataset version, with status and metric chips
  (grader: mean/passRate); click-through to detail; pick-two-to-compare.
- **Run detail** — the output table: example key, output text (truncated,
  expandable), latency, per-grader score value/passed; error rows (output or
  score) visibly flagged.
- **Compare** — A/B headers with metric headline diff; aligned example rows
  with both outputs and per-example score delta; rows where the sides
  disagree (pass vs fail) highlighted.

Model/update kept pure where possible (fetch effects at the edges via miso's
JS FFI fetch); views are functions of the model. Styling: a single hand-written
CSS file; no framework.

## 5. Testing

- **DTO/mapping**: pure round-trip (`decode . encode`) and entity→DTO mapping
  tests in the native suite.
- **API**: handler-level tests against ephemeral Postgres — seed via the
  existing helpers, call the wai `Application` directly (no real socket;
  `wai`'s test request machinery or a direct handler call), assert decoded
  DTOs. Covers: empty DB, the happy paths, 404/400 cases, compare-mismatched
  dataset versions.
- **UI**: the update function and any non-trivial view selectors tested as
  pure functions in the native build of `evals-ui` (if cheap); browser-level
  testing out of scope v1.

## 6. Risks & gating spike

**Task 1 of the plan MUST be the spike** (the C-rehome gating pattern): a
miso hello-world in `evals-ui` that (a) builds natively, (b) builds as a
`wasm32-wasi` browser reactor via zinc, and (c) renders + handles a click in
a real browser served by a stub server. Unknowns it retires: miso's
compatibility with the wasm toolchain's GHC, jsaddle/miso package resolution
under zinc, the reactor JS-shim wiring, and the static-serving glue. If the
spike fails after reasonable effort, STOP and reassess (fallback: Approach 2,
jsaddle-warp single binary, same API and DTO layers unchanged).

Secondary risks: warp's closure under zinc native (expected fine — pure
Haskell + network), DTO divergence (none possible — one shared package).

## 7. Out of scope

- Triggering runs/scoring from the UI; any POST endpoint.
- Live progress / websockets (sub-project D, blocked on manifest-z8h).
- Auth, multi-tenancy (org is ignored), pagination, search.
- autodocodec JSON schemas.
- Browser-automation tests.
