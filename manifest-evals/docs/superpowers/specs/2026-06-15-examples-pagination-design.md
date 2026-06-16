# Run-detail Examples pagination — design

**Date:** 2026-06-15
**Status:** approved

## Problem

The run-detail **Examples** tab renders every output row for the run in one
table. For the HealthBench reproduction that is 200 rows; for larger runs it
will be worse. The table is unusable and the payload is large. We need
pagination.

## Decision

Server-side pagination on the **existing** run-detail endpoint. No new route.

```
GET /<org>/api/runs/<id>?offset=N&limit=M
```

- `offset` — number of output rows to skip (default `0`).
- `limit`  — page size (default `50`).
- Both are clamped: `offset >= 0`, `1 <= limit <= 200`. Out-of-range or
  unparseable values fall back to the defaults.

The response shape (`RunDetailDto`) is unchanged except:

- `outputs` now holds **only the requested page** (≤ `limit` rows), in stable
  key order.
- A new field `totalOutputs :: Int` reports the full count for the run, so the
  UI can render "showing X–Y of N" and decide whether Prev/Next are enabled.

Everything else (`run`, `calibration`) is returned whole as before — those are
small and per-run, not per-row.

### Why modify the existing endpoint

The run detail already returns `outputs`; pagination is a refinement of that
field, not a new resource. A second endpoint would duplicate the org/tenant
wrapping, the run summary load, and the calibration load, and force the UI to
juggle two fetches for one screen. One endpoint, two extra query params.

### Why `outputs` keeps its name

The wire field matches the `outputs` table and the existing `OutputRowDto`. The
*display* label on the tab/column stays "Examples"/"Example" as-is — this change
is data-shape only, no rename.

## Server changes

### `RunDetailDto` (evals-api)

```haskell
data RunDetailDto = RunDetailDto
  { run          :: RunSummaryDto
  , outputs      :: [OutputRowDto]          -- the requested page
  , totalOutputs :: Int                     -- full row count for the run
  , calibration  :: [CalibrationSeriesDto]
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)
```

### `runDetailHandler` (src/Evals/Dashboard.hs)

Currently builds the full `sortedRows` and returns them all. It gains access to
the `Request` (it is already in scope at the dispatch site) to read the two
query params via the existing `queryParam :: BS8.ByteString -> Request -> Maybe Text`.

1. Parse `offset`/`limit` from the request, applying defaults + clamps.
2. Build the full stable-ordered `sortedRows` exactly as today.
3. `totalOutputs = length sortedRows`.
4. `page = take limit (drop offset sortedRows)`.
5. Return `RunDetailDto { run, outputs = page, totalOutputs, calibration }`.

Ordering must be deterministic so paging is stable across requests — the
existing sort already provides this; the page is a pure slice of it.

Tenant wrapping is unchanged: still `withSession pool $ withTenant orgId $ ...`.

## UI changes

### Model (evals-ui/src/Evals/Ui/Model.hs)

- Add `_outputsOffsetM :: Int` (default `0`) — the offset currently displayed.
- Add a page-size constant `outputsPageSize = 50` (module-level, shared with the
  fetch URL builder).
- Add action `SetOutputsOffset Int` to request a different page.

### Fetch (evals-ui/src/Main.hs / Fetch.hs)

- `fetchRoute (RunR i)` builds
  `"/api/runs/" <> msShow i <> "?offset=" <> msShow off <> "&limit=" <> msShow outputsPageSize`
  where `off` is the model's current `_outputsOffsetM`.
- `SetRoute (RunR _)` resets `outputsOffsetL .= 0` (alongside the existing
  `runTabL`/`compareMenuL` resets) so switching runs starts at page 1.
- `SetOutputsOffset n` sets `outputsOffsetL .= n` and re-issues the detail fetch
  for the current run at the new offset.

### View (evals-ui/src/Evals/Ui/View.hs)

- `outputsTable` already takes the metric list; its grader **columns** and the
  mean **footer** are derived from `[MetricDto]` (the run's metrics), NOT from
  the page's `outputs`. This is the existing change-in-progress and is required
  so columns stay stable across pages. Confirm `gs` is sourced from metrics.
- Add a pager below the Examples table, rendered only on the Examples tab:
  - "showing {offset+1}–{min(offset+limit, total)} of {total}".
  - "‹ Prev" button — disabled when `offset == 0`; dispatches
    `SetOutputsOffset (max 0 (offset - pageSize))`.
  - "Next ›" button — disabled when `offset + pageSize >= total`; dispatches
    `SetOutputsOffset (offset + pageSize)`.
- The pager needs `totalOutputs` and the current offset; thread them in from the
  model + the fetched `RunDetailDto`.

### Style (static/style.css)

Add a `.pager` block: a flex row, centred, gap between the label and the two
buttons; a `.pager-btn` with a disabled state (dimmed, `cursor: default`).

## Scope

- **In:** run-detail Examples table only.
- **Out:** the compare table (small, not paged — YAGNI); the grader/calibration
  tabs (per-run aggregates, not per-row); any prev/next *example* navigation
  (already exists via `prevKey`/`nextKey`, unaffected).

## Tests (test/ApiSpec.hs)

Server tests hit `/<org>/api/runs/<id>`. With the existing seed (which has a
small number of outputs per run), add a run with enough outputs to page, or
assert against the seeded count:

1. **`totalOutputs` is the full count** regardless of `limit` — request with a
   small `limit`, assert `totalOutputs == <seeded full count>` while
   `length outputs <= limit`.
2. **`offset`/`limit` returns the right slice in key order** — request
   `?offset=0&limit=1` and `?offset=1&limit=1`; assert the two `outputs` pages
   are disjoint and that page-2's key sorts after page-1's key (deterministic
   ordering).
3. **Defaults** — request with no query params; assert `length outputs == min
   totalOutputs 50` and the first page starts at the lowest key.
4. **Clamp/garbage** — `?offset=-5&limit=abc` behaves as `offset=0,
   limit=50` (no 500).

Tenant isolation assertions already in ApiSpec are unaffected.
