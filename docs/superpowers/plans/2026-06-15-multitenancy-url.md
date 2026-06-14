# Multi-tenancy Slice 2 (org in the URL) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the dashboard multi-tenant by putting the org slug in the URL — the server resolves `/<slug>/…` to an `OrgId`, scopes the request's reads with `withTenant` (RLS), and serves the SPA/assets under the prefix.

**Architecture:** Route on `(slug : rest)`: resolve slug→OrgId (unscoped registry read, 404 unknown), dispatch the existing API handlers wrapped in `withTenant orgId` (RLS scopes the reads), serve static from `rest`. `/` is an org-picker. The SPA prepends `/<slug>` (from `window.location.pathname`) to its fetches. No auth — the URL is the gate.

**Tech Stack:** Haskell (GHC 9.12 native / 9.14 wasm), warp, manifest RLS (`withTenant`), Miso wasm SPA.

**Spec:** `docs/superpowers/specs/2026-06-15-multitenancy-url-design.md`

**CRITICAL BUILD ENVIRONMENT:** native build/test via `nix develop -c zinc test spec` / `zinc build`; wasm via `scripts/build-ui.sh` (wraps nix). A bare `zinc` fails with a libpq link error (environmental). Never add deps. Suite uses the `expect`/`rt` harness (no hspec).

**Confirmed facts:** `static/index.js` already uses RELATIVE asset URLs (`fetch("evals-ui.wasm")`, `import "./ghc_wasm_jsffi.js"`, `import "./wasi_shim/index.js"`) — they resolve under `/<slug>/` automatically; **no index.js change needed**. `Evals.Tenant.withTenant :: OrgId -> Db a -> Db a` exists. `ApiSpec.serverSpec` already runs `migrateAll` (creates the `evals_tenant` role) and seeds entities stamped `org = OrgId 1`. The dashboard handlers do single `withSession pool $ <reads>` with no internal `withTransaction`, so `withTenant` wraps them safely.

---

## File Structure

- **Modify** `src/Evals/Dashboard.hs` — `(slug:rest)` routing + slug resolve + `orgPickerHandler`; thread `OrgId` + `withTenant` into the 6 API handlers; import `Evals.Tenant (withTenant)`.
- **Modify** `evals-ui/src/Evals/Ui/Fetch.hs` — `getOrgPrefix`; prepend it in `fetchJson`.
- **Modify** `evals-ui/src/Main.hs` — prefix the SSE `connectText` URL.
- **Modify** `test/ApiSpec.hs` — seed an `Org` row + a second org's graph; move server requests to `/<slug>/…`; add cross-org isolation + unknown-slug 404 + org-picker assertions; move the static-file tests under a slug.

---

### Task 1: Server — slug routing, org-picker, `withTenant`-scoped handlers

**Files:** `src/Evals/Dashboard.hs`, `test/ApiSpec.hs` (assertions land in Task 3; here just keep it compiling)

- [ ] **Step 1: Add the import**

In `src/Evals/Dashboard.hs` imports, add:
```haskell
import Evals.Tenant (withTenant)
```
Confirm `Org`/`OrgId`/`(==.)`/`selectWhere`/`withSession`/`Cond` are in scope (they are — `Evals.Schema`, `Evals.Ids`, `Manifest` are imported).

- [ ] **Step 2: Thread `OrgId` + `withTenant` into each API handler**

Each handler currently is `… :: Pool -> … -> (Response -> IO a) -> IO a` and does `withSession pool $ <reads>`. Add an `OrgId` parameter (right after `Pool`) and wrap the session body in `withTenant orgId`. Apply to all six:

`datasetsHandler` — signature `Pool -> OrgId -> (Response -> IO a) -> IO a`; body `withSession pool $ withTenant orgId $ <existing reads>`.
`runsHandler` — `Pool -> OrgId -> Maybe T.Text -> (Response -> IO a) -> IO a`; wrap.
`runDetailHandler` — `Pool -> OrgId -> RunId -> (Response -> IO a) -> IO a`; wrap.
`exampleDetailHandler` — `Pool -> OrgId -> RunId -> T.Text -> (Response -> IO a) -> IO a`; wrap.
`compareHandler` — `Pool -> OrgId -> Request -> (Response -> IO a) -> IO a`; wrap.
`calibrationHandler` — `Pool -> OrgId -> (Response -> IO a) -> IO a`; wrap.

For each, find the `withSession pool $ <do-block>` (or `mDto <- withSession pool $ …`) and change to `withSession pool $ withTenant orgId $ …`. The inner reads are unchanged — RLS scopes them.

- [ ] **Step 3: Add `orgPickerHandler`**

Add (near the other handlers):
```haskell
-- | Root page: a minimal standalone HTML list of orgs (links to /<slug>/).
-- Unscoped — the registry has no RLS policy.
orgPickerHandler :: Pool -> (Response -> IO a) -> IO a
orgPickerHandler pool respond = do
  orgs <- withSession pool (selectWhere ([] :: [Cond Org]))
  let row o = "<li><a href=\"/" <> o.slug <> "/\">" <> o.name <> "</a></li>"
      body  = "<!doctype html><meta charset=utf-8><title>evals — orgs</title>"
           <> "<style>body{font:15px system-ui;margin:40px;max-width:540px}"
           <> "h1{font-size:18px}a{color:#2456c8;text-decoration:none}a:hover{text-decoration:underline}</style>"
           <> "<h1>Organisations</h1><ul>" <> T.concat (map row orgs) <> "</ul>"
  respond (responseLBS status200 [("Content-Type", "text/html; charset=utf-8")]
             (LBS.fromStrict (TE.encodeUtf8 body)))
```
Confirm imports: `responseLBS`, `status200` (already imported), `TE` (`Data.Text.Encoding`), `LBS` (`Data.ByteString.Lazy`) — add `import qualified Data.Text.Encoding as TE` / `import qualified Data.ByteString.Lazy as LBS` if not present, and `import qualified Data.Text as T` is present. `o.slug`/`o.name` via OverloadedRecordDot.

- [ ] **Step 4: Rewrite `dashboardApp`'s routing**

Replace the `case pathInfo req of` body. The new routing:
```haskell
dashboardApp pool staticDir hub req respond =
  case pathInfo req of
    []            -> apiWith (orgPickerHandler pool respond)
    (slug : rest) -> do
      orgs <- withSession pool (selectWhere [ #slug ==. slug ] :: IO [Org])  -- see note
      case orgs of
        []      -> respond notFound
        (o : _) -> dispatch o.id rest
  where
    apiWith action = handle
      (\(e :: SomeException) ->
        respond (json status500 (ApiError { error = "internal error: " <> T.pack (show e) })))
      action
    dispatch orgId rest = case rest of
      ["api", "datasets"]     -> apiWith (datasetsHandler pool orgId respond)
      ["api", "runs"]         -> apiWith (runsHandler pool orgId (queryParam "datasetVersion" req) respond)
      ["api", "runs", nTxt]   ->
        case readMaybe (T.unpack nTxt) :: Maybe Int of
          Nothing -> respond (badRequest "invalid run id")
          Just n  -> apiWith (runDetailHandler pool orgId (RunId n) respond)
      ["api", "runs", nTxt, "ex", key] ->
        case readMaybe (T.unpack nTxt) :: Maybe Int of
          Nothing -> respond (badRequest "invalid run id")
          Just n  -> apiWith (exampleDetailHandler pool orgId (RunId n) key respond)
      ["api", "compare"]      -> apiWith (compareHandler pool orgId req respond)
      ["api", "calibration"]  -> apiWith (calibrationHandler pool orgId respond)
      ["api", "events"]       -> respond (sseResponse hub)
      ("api" : _)             -> respond notFound
      segments                -> staticHandler staticDir (normalise segments) respond
```
NOTE on the resolve read: `withSession pool (selectWhere [ #slug ==. slug ])` runs in `IO` returning `[Org]` — match the project's exact form (it returns `IO [Org]` via `withSession`; the `:: IO [Org]` annotation may need to be `:: Db [Org]` inside the session and then `withSession pool (… :: Db [Org])`). Mirror how `datasetsHandler`/`resolveOrg` (in `app/Main.hs`) already do `withSession pool $ do os <- selectWhere [ #slug ==. … ] :: Db [Org]; …`. Use that exact shape.

- [ ] **Step 5: Build**

Run: `nix develop -c zinc build`
Expected: clean (the test will be temporarily red — `ApiSpec` still hits `/api/…` which now 404s as an unknown slug; Task 3 fixes the tests). If you prefer a green commit, do Task 1 + Task 3 together. Otherwise:

- [ ] **Step 6: Commit**

```bash
git add src/Evals/Dashboard.hs
git commit -m "feat(dashboard): org-slug routing + withTenant-scoped handlers + org picker

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: SPA — prepend the org prefix to fetches + SSE

**Files:** `evals-ui/src/Evals/Ui/Fetch.hs`, `evals-ui/src/Main.hs`

- [ ] **Step 1: Add `getOrgPrefix` to `Fetch.hs`**

`Fetch.hs` already reads `window.location` (see `getHash`: `jsg "window" ! "location" ! "hash"`). Add a sibling that reads the pathname's first segment. Export `getOrgPrefix` from the module.
```haskell
import qualified Data.Text as T
import Miso.String (MisoString, fromMisoString, ms)

-- | The org path prefix from window.location.pathname's first segment:
-- "/acme/..." -> "/acme"; "/" or "" -> "". The dashboard is served under
-- /<orgSlug>/, and all API calls are made relative to that prefix.
getOrgPrefix :: IO MisoString
getOrgPrefix = do
  p <- fromJSValUnchecked =<< jsg "window" ! "location" ! "pathname"
  let segs = filter (not . T.null) (T.splitOn "/" (fromMisoString (p :: MisoString)))
  pure $ case segs of
    (s : _) -> ms ("/" <> s)
    []      -> ""
```
(Confirm `fromJSValUnchecked`, `jsg`, `(!)` are imported — they are, used by `getHash`. Add `Data.Text`/`Miso.String` imports if missing.)

- [ ] **Step 2: Prepend the prefix in `fetchJson`**

`fetchJson` currently is roughly `fetchJson url k = getText url [] ok err` (in `IO`). Prepend the prefix:
```haskell
fetchJson url k = do
  prefix <- getOrgPrefix
  getText (prefix <> url) [] ok err
  where ok = …  -- unchanged
        err = … -- unchanged
```
(Keep the existing `ok`/`err` bodies; only the URL gains `prefix <>`.)

- [ ] **Step 3: Prefix the SSE URL in `Main.hs`**

In `evals-ui/src/Main.hs`, the `Startup` action calls `SSE.connectText "/api/events" …`. Read the prefix first:
```haskell
  Startup -> do
    io_ $ do
      prefix <- getOrgPrefix
      SSE.connectText (fromMisoString prefix <> "/api/events") (const SseOpen) SseMessage (const SseError)
    updateModel HashChanged
```
Adjust to the actual effect style in the file (it currently calls `SSE.connectText` directly in the `Startup` arm). The point: the SSE URL becomes `<prefix>/api/events`. Import `getOrgPrefix` from `Evals.Ui.Fetch` and `fromMisoString`/`ms` as needed. If `connectText` takes a `MisoString`, use `(prefix <> "/api/events")` directly without `fromMisoString`.

- [ ] **Step 4: Build the wasm UI**

Run: `scripts/build-ui.sh`
Expected: clean build, artifacts staged.

- [ ] **Step 5: Commit**

```bash
git add evals-ui/src/Evals/Ui/Fetch.hs evals-ui/src/Main.hs
git commit -m "feat(ui): prepend the /<org> path prefix to API fetches + SSE

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: ApiSpec — org-scoped server tests + isolation

**Files:** `test/ApiSpec.hs`

- [ ] **Step 1: Seed an Org row + a second org's graph**

In `serverSpec`'s seed block (after `migrateAll`, before/with the existing `add`s), add the registry rows and a second org's minimal graph. The existing demo graph is already stamped `org = OrgId 1`; add:
```haskell
    _ <- add (Org { id = OrgId 1, slug = "acme",   name = "Acme",   createdAt = now } :: Org)
    _ <- add (Org { id = OrgId 2, slug = "globex", name = "Globex", createdAt = now } :: Org)
    -- a second org's run so isolation is testable
    dB  <- add (Dataset { id = DatasetId 0, org = OrgId 2, name = "b", slug = "b", createdAt = now } :: Dataset)
    dvB <- add (DatasetVersion { id = DatasetVersionId 0, org = OrgId 2, dataset = dB.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    tB  <- add (Target { id = TargetId 0, org = OrgId 2, name = "tb", createdAt = now } :: Target)
    tvB <- add (TargetVersion { id = TargetVersionId 0, org = OrgId 2, target = tB.id, version = 1, model = "m", prompt = "", params = Aeson (object []), createdAt = now } :: TargetVersion)
    rB  <- add (Run { id = RunId 0, org = OrgId 2, datasetVersion = dvB.id, targetVersion = tvB.id, status = "succeeded", startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
```
(Match the exact field sets of these entities as they appear elsewhere in the file — copy an existing literal and change `org`/ids. Capture `rB.id`'s Int via `let RunId rBInt = rB.id`.)

- [ ] **Step 2: Move existing server requests under `/acme`**

The `getReq path` helper builds `http://localhost:<port><path>`. Change every server-test request path to be prefixed with `/acme`:
- `/api/datasets` → `/acme/api/datasets`
- `/api/runs` → `/acme/api/runs`, `/api/runs?datasetVersion=…` → `/acme/api/runs?datasetVersion=…`
- `/api/runs/<id>` → `/acme/api/runs/<id>`, `…/ex/e1` → `/acme/api/runs/<id>/ex/e1`
- `/api/calibration` → `/acme/api/calibration`
- the static-file tests `/probe.css` → `/acme/probe.css`, `/missing.css` → `/acme/missing.css` (they're served under the slug now)
- `/api/nope` → `/acme/api/nope` (still 404 — unknown api route under a valid org)
Keep the existing status/shape assertions; they should still pass because org-1's data is what `acme` sees.

- [ ] **Step 3: Add isolation + picker + unknown-slug assertions**

Add (using the existing `expect`/`statusCode`/`decode` helpers):
```haskell
    -- cross-org isolation: globex cannot see acme's runs
    rGlobex <- getReq "/globex/api/runs"
    expect "globex runs 200" (statusCode (responseStatus rGlobex) == 200)
    expect "globex sees only its own run" $
      case decode (responseBody rGlobex) :: Maybe [RunSummaryDto] of
        Just rs -> all (\r -> r.runId == rBInt) rs && not (any (\r -> r.runId == runIdInt) rs)
        Nothing -> False
    -- acme cannot fetch globex's run by id (invisible under RLS -> 404)
    rCross <- getReq ("/acme/api/runs/" <> show rBInt)
    expect "acme cannot see globex run -> 404" (statusCode (responseStatus rCross) == 404)
    -- unknown slug -> 404
    rUnknown <- getReq "/nope/api/runs"
    expect "unknown org slug -> 404" (statusCode (responseStatus rUnknown) == 404)
    -- org picker at root lists both slugs
    rRoot <- getReq "/"
    expect "root 200" (statusCode (responseStatus rRoot) == 200)
    expect "root lists orgs" $
      let b = responseBody rRoot in
      ("acme" `LBS.isInfixOf` b) && ("globex" `LBS.isInfixOf` b)
```
(Use the lazy-bytestring `isInfixOf` — `import qualified Data.ByteString.Lazy.Char8 as LBS` or whatever the file already uses for `responseBody`; match existing imports. `runIdInt`/`rBInt` are the Int ids.)

- [ ] **Step 4: Run the suite**

Run: `nix develop -c zinc test spec`
Expected: PASS — server tests work under `/acme`, isolation holds (globex can't see acme's run; acme can't fetch globex's run id; unknown slug 404s), root lists orgs.

- [ ] **Step 5: Commit**

```bash
git add test/ApiSpec.hs
git commit -m "test: org-scoped dashboard URLs + cross-org isolation + picker + 404

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Build wasm + restart + smoke (CONTROLLER)

- [ ] **Step 1: Full gate**

Run: `nix develop -c zinc test spec` (green) + `nix develop -c zinc build` (clean) + `scripts/build-ui.sh` (clean).

- [ ] **Step 2: Re-seed + restart the dashboard**

`nix develop -c bash scripts/seed-demo.sh` (two orgs from Slice 1), kill + restart `evals-dashboard` on `evals_demo` (port 8787).

- [ ] **Step 3: Smoke**

- `curl -s localhost:8787/` → HTML listing `acme` + `globex`.
- `curl -s localhost:8787/acme/api/runs` → acme's runs (2); `curl -s localhost:8787/globex/api/runs` → globex's runs (0, since the globex seed is a bare dataset).
- `curl -s -o /dev/null -w "%{http_code}" localhost:8787/nope/api/runs` → 404.
- Load `localhost:8787/acme/#/runs` in a browser → SPA loads, fetches `/acme/api/runs`, renders. (Controller eyeballs.)

---

## Self-Review

**Spec coverage:** slug routing + resolve + 404 → Task 1 Step 4. `withTenant`-scoped handlers → Task 1 Step 2. org-picker at `/` → Task 1 Step 3. SSE unscoped → Task 1 Step 4 (`["api","events"]` not wrapped). SPA prefix on fetches + SSE → Task 2. Assets relative (no change) → confirmed, noted. Isolation + picker + 404 tests → Task 3. Wasm rebuild + restart → Task 4. ✓

**Type consistency:** every handler gains `OrgId` right after `Pool`, and the `dispatch` call sites pass `orgId` in that position. `getOrgPrefix :: IO MisoString` used in `fetchJson` + `Main.hs`. `Org`/`OrgId` consistent.

**Placeholder scan:** Task 1 Step 4's resolve-read annotation (`:: IO [Org]` vs `:: Db [Org]`) is called out with the exact existing pattern to mirror (`app/Main.hs:resolveOrg`) — a real "match the codebase" note, not a placeholder. Task 1 Step 5 flags the temporary test-red window (land Task 1+3 together for a green commit).

**Known risks:** (1) the per-request `orgs` lookup adds a DB round-trip even for static assets — fine for a dev dashboard (tiny table), not optimized. (2) `responseLBS`/`status200`/`TE`/`LBS` imports in Dashboard.hs — verify presence, add if missing. (3) ApiSpec entity literals for org-B must match the exact current field sets (copy existing literals).
