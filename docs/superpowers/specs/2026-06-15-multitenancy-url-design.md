# Multi-tenancy Slice 2 — org in the URL + per-request dashboard tenancy — design

**Date:** 2026-06-15
**Status:** approved (pending spec review)
**Builds on:** Slice 1 (`docs/superpowers/specs/2026-06-14-multitenancy-rls-design.md`) — the RLS substrate, `Org` registry, `withTenant`.

## Goal

Make the dashboard multi-tenant by putting the org slug in the URL. The server resolves the
slug, scopes the request's DB session with `withTenant` (so RLS isolates all reads), and
dispatches the existing handlers. After this slice, `GET /<slug>/api/runs` returns only that
org's runs, and `/<slug>/#/runs/1` shows only that org's data.

**Success criteria:** an `ApiSpec` test seeds two orgs and asserts org A's URL (`/acme/api/...`)
cannot see org B's rows; an unknown slug 404s; the root `/` lists the orgs. No auth — the URL
is the only tenant gate (the agreed data-isolation model; a trusted/internal deployment).

## Architecture

The org slug is the first path segment for **everything** served under it. The server:
1. resolves `(slug : rest)` → `OrgId` via an unscoped read of `orgs` (the registry has no RLS
   policy), 404 on unknown slug;
2. runs the matched API handler inside `withTenant orgId`, so the handlers' existing
   `selectWhere`s become RLS-scoped automatically — **no per-query org filters**;
3. serves static/SPA files from `rest` (slug stripped).

Why `withTenant` works here (it didn't for the CLI executor): the dashboard handlers are
single-session reads that do NOT call `withTransaction` themselves, so wrapping them in
`withTenant` (which opens one transaction + `SET LOCAL ROLE` + sets `app.org`) introduces no
nested-transaction conflict. This is the clean payoff of the Slice 1 substrate.

The warp pool connects as superuser (RLS bypassed by default); the slug→id resolution runs on
that superuser connection BEFORE `withTenant`, and `withTenant`'s `SET LOCAL ROLE evals_tenant`
is what activates RLS for the request's reads.

## Component 1 — Server routing (`src/Evals/Dashboard.hs`)

`dashboardApp` `case pathInfo req of`:
- `[]` → **org-picker** (`orgPickerHandler`): `withSession pool (selectWhere ([] :: [Cond Org]))`,
  emit a minimal standalone HTML page (inline CSS, no wasm) listing `<a href="/<slug>/">name</a>`
  for each org. Content-Type text/html.
- `(slug : rest)` → resolve: `withSession pool (selectWhere [ #slug ==. slug ] :: Db [Org])`.
  - `[]` → `respond notFound` (unknown slug).
  - `(o : _)` → dispatch on `rest`:
    - `["api","datasets"]` → `apiWith (datasetsHandler pool o.id respond)` — and analogously for
      every existing API route (`runs`, `runs/:n`, `runs/:n/ex/:key`, `compare`, `calibration`).
      Each handler gains an `OrgId` argument and wraps its session body in `withTenant orgId`
      (see Component 2).
    - `["api","events"]` → `respond (sseResponse hub)` UNSCOPED (refetch-hint stream; the
      refetch is org-scoped so no data leaks; per-org SSE channels are a future refinement —
      note the cross-org wake-up is harmless/noisy only).
    - `("api":_)` → `respond notFound`.
    - other `rest` → `staticHandler staticDir (normalise rest) respond` (slug already stripped;
      `normalise [] = ["index.html"]`).

Helper `apiWith` (the 500-catcher) is unchanged. Add an `Org`-aware resolve helper, e.g.
`withResolvedOrg :: Pool -> Text -> (OrgId -> IO a) -> IO a -> IO a` (runs the action with the
resolved id, or the not-found fallback).

## Component 2 — Scope the API handlers with `withTenant`

Each API handler currently does `withSession pool $ <reads>`. Change each to take an `OrgId`
and do `withSession pool $ withTenant orgId $ <reads>`. Affected handlers in
`src/Evals/Dashboard.hs`: `datasetsHandler`, `runsHandler`, `runDetailHandler`,
`exampleDetailHandler`, `compareHandler`, `calibrationHandler`. The reads inside are unchanged
— RLS scopes them. (`runSummary`/`groupedMetricDtos`/etc. are called within the wrapped
session, so they're scoped too.)

Note: `runDetailHandler`/`exampleDetailHandler` already 404 when the run/example isn't found;
under RLS a cross-org run id simply isn't visible, so it naturally 404s — correct.

## Component 3 — SPA org-awareness (`evals-ui`)

- New IO edge in `Evals.Ui.Fetch` (alongside `getHash`): `getOrgPrefix :: IO MisoString` that
  reads `window.location.pathname`, takes the first non-empty segment, and returns `"/" <>
  slug` (or `""` if none). Read once at startup (in `Startup`/`main`) and thread into the model,
  OR read lazily per fetch — simplest: read once and store the prefix in the model.
- `fetchJson` and the SSE `connectText` call prepend the prefix: `<prefix> <> "/api/..."`.
  Currently they use absolute `"/api/..."`; they become `"/<slug>/api/..."`.
- Hash routing (`parseHash`/`runHash`/etc.) is UNCHANGED — the org is in the path, not the
  hash; in-app navigation only changes the hash within `/<slug>/`.
- `index.html` is UNCHANGED — its `href="style.css"`/`src="index.js"` are relative, so loaded
  under `/<slug>/` they resolve to `/<slug>/style.css` etc., which the slug-stripping static
  handler serves.

**Plan-time verification:** confirm the wasm loader `static/index.js` references
`evals-ui.wasm` and `ghc_wasm_jsffi.js` with RELATIVE URLs. If it uses absolute `/evals-ui.wasm`,
that path would be parsed as a slug (`evals-ui.wasm`) and 404. Fix by making those references
relative (or, fallback, special-case known asset filenames before the slug branch). The
preferred fix is relative URLs in the loader.

## Component 4 — Testing (`test/ApiSpec.hs`)

The server specs currently hit `/api/...`. Update to the org-scoped URLs and add isolation:
- Seed an `Org` (`acme`, id 1) + the existing run graph stamped `org = OrgId 1`, AND a second
  org (`globex`, id 2) with a small graph (one dataset + one run) stamped `org = OrgId 2`.
- The DB-backed server tests must run `migrateAll` (creates the `evals_tenant` role + grants) so
  `withTenant` works; `withEphemeralDb` connects as superuser (seed bypasses RLS).
- Assertions:
  - `GET /acme/api/runs` returns only org 1's runs; `GET /globex/api/runs` only org 2's.
  - `GET /acme/api/runs/<org-2-run-id>` → 404 (cross-org run invisible under RLS).
  - `GET /nope/api/runs` → 404 (unknown slug).
  - `GET /` → 200 text/html listing both org slugs.
- The pure DTO round-trip tests are unchanged.

## Out of scope

- Authentication / login (still none; the URL is the gate).
- Per-org SSE channels (the global hint stream stays; refetch is scoped).
- Changing the CLI (Slice 1 owns it).
- The org-picker styling beyond a minimal usable list.

## File map

- **Modify** `src/Evals/Dashboard.hs` — `(slug:rest)` routing, slug resolve, `orgPickerHandler`,
  thread `OrgId` + `withTenant` into the 6 API handlers, import `Evals.Tenant (withTenant)`.
- **Modify** `evals-ui/src/Evals/Ui/Fetch.hs` — `getOrgPrefix` + prefix in `fetchJson`/SSE.
- **Modify** `evals-ui/src/Main.hs` and/or `Evals.Ui.Model` — read + store the org prefix at
  startup, thread to fetches.
- **Verify/Modify** `static/index.js` — relative asset URLs.
- **Modify** `test/ApiSpec.hs` — org-scoped server tests + isolation + org-picker + 404.
- Rebuild wasm (`scripts/build-ui.sh`) + restart `evals-dashboard`. Build/test via
  `nix develop -c` ([[build-needs-nix-develop]]).
