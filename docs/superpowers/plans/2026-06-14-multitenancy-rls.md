# Multi-tenancy Slice 1 (RLS data isolation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make manifest-evals enforce per-org data isolation via Postgres RLS — every tenant row carries `org`, every scoped table has an `org_isolation` policy, and the CLI runs scoped to one org via `SET LOCAL ROLE evals_tenant` + `withRlsContext`.

**Architecture:** Denormalize `org :: OrgId` onto every entity; per-table RLS policy `org = current_setting('app.org')` (fail-closed); a low-privilege `evals_tenant` role the app switches into per scoped transaction (the dev connection is superuser and bypasses RLS until that switch). Provisioning/migration run as owner. The dashboard stays unscoped this slice (Slice 2 adds URL tenancy).

**Tech Stack:** Haskell (GHC 9.12), manifest ORM (RLS DSL + `withRlsContext`), Postgres RLS, zinc.

**Spec:** `docs/superpowers/specs/2026-06-14-multitenancy-rls-design.md`

**CRITICAL BUILD ENVIRONMENT:** Every `zinc` build/test runs via `nix develop -c` (e.g. `nix develop -c zinc test spec`); a bare run fails with a libpq link error that is environmental. Never add deps to fix it. The suite uses the `expect`-style harness (no hspec).

**Execution note:** Tasks 0–1 are **controller-driven** (cross-repo manifest worktree + re-pin). Tasks 2–8 are manifest-evals work, subagent-ready. **Integration decision:** `castText` lands on a dedicated manifest branch off the *currently-pinned* rev `0e414c2` (NOT manifest main, which is ~ahead) — manifest-evals gets ONLY `castText`, no manifest core upgrade. Flag to the user if that proves impossible.

---

## File Structure

- **manifest** (worktree off `0e414c2`): `src/Manifest/Query.hs` (+`castText`, export), `src/Manifest.hs` (re-export `castText`), a `Query`/`Rls` test. Push branch `feat/casttext`.
- **Modify** `zinc.toml` — manifest `rev` → the castText commit; `zinc update`.
- **Modify** `src/Evals/Schema.hs` — `Org` entity; `org` column on 9 entities; `rlsPolicies` on all 13 scoped entities.
- **Modify** `src/Evals/Migrate.hs` — register `Org`; run role/grant DDL.
- **Create** `src/Evals/Tenant.hs` — `withTenant`.
- **Modify** `src/Evals/Ingest.hs`, `src/Evals/MetaEval/Ingest.hs`, `src/Evals/MetaEval.hs`, `src/Evals/Execute.hs`, `src/Evals/Grade.hs` — thread `org` onto every `add`.
- **Modify** `app/Main.hs` — `org create`/`org list`; `--org <slug>` on write/read commands; wrap in `withTenant`.
- **Create** `test/TenantSpec.hs`; **Modify** `test/Spec.hs`.
- **Modify** `scripts/seed-demo.sh` — two orgs.

---

### Task 0: manifest `castText` (CONTROLLER, in a worktree)

Create a manifest worktree off the pinned rev (the main checkout is on `main`; do not disturb it):
```bash
cd /home/gareth/code/garethstokes/manifest
git worktree add -b feat/casttext ../manifest-casttext 0e414c29f77fe8668daefdcbbb5af56576ff1267
cd ../manifest-casttext
```

**Files:** `src/Manifest/Query.hs`, `src/Manifest.hs`, a test in `test/`

- [ ] **Step 1: Add `castText` to `Manifest.Query`**

`Expr` is constructed as `Expr "<sql-bytestring>" [params]` (see `currentSetting`). Add the helper near `currentSettingOr`:
```haskell
-- | Cast an expression to text — e.g. an Int column for comparison with a GUC
-- (which 'currentSetting' returns as text) inside an RLS policy predicate.
castText :: Expr a -> Expr Text
castText (Expr sql ps) = Expr ("(" <> sql <> ")::text") ps
```
Add `castText` to the module export list (the `( QueryM, ... )` block, near `currentSetting`/`currentSettingOr`).

- [ ] **Step 2: Re-export from `Manifest`**

In `src/Manifest.hs`, find where `currentSetting`/`currentSettingOr` are re-exported (the export list around line 201/308 mentions `policy`, `using`, …). Add `castText` alongside them so downstream code can `import Manifest (castText)`.

- [ ] **Step 3: Write a test**

manifest's tests live in `test/` (e.g. `RlsSpec.hs`, `Harness`). Add a pure assertion that `castText` renders correctly inside a policy predicate. In `test/RlsSpec.hs` (which already tests `policyDef`), add a `test` mirroring the existing "policy DSL renders the USING predicate" case but with an int column cast:
```haskell
  , test "castText renders ::text in a policy predicate" $ do
      let p = policy "c" `using` (\s -> castText (s ^. #userAge) .== currentSetting "app.org")
              :: Policy User   -- use whatever Fixtures entity has an Int column; else add a local entity
          pd = policyDef p
      assertEqual "using" (Just "(user_age)::text = current_setting('app.org')") (pdUsing pd)
```
(Read `test/Fixtures.hs` for the `User` entity's columns; if no Int column exists, define a tiny local entity in the test module with an Int field, following the `SecretT`/`VaultT` pattern already in `RlsSpec.hs`. Match the exact `import Manifest (..., castText)`.)

- [ ] **Step 4: Build + test manifest**

Run manifest's test command (check `manifest/zinc.toml` `[build.test...]` + its flake — likely `nix develop -c zinc test <suite>`). Expected: green, including the new castText assertion.

- [ ] **Step 5: Commit + push the branch**

```bash
git add src/Manifest/Query.hs src/Manifest.hs test/RlsSpec.hs
git commit -m "feat(query): castText :: Expr a -> Expr Text for RLS int-column predicates"
git push origin feat/casttext
git rev-parse HEAD    # capture the SHA for the re-pin
```

---

### Task 1: Re-pin manifest + build (CONTROLLER)

**Files:** `zinc.toml`, `zinc.lock`

- [ ] **Step 1: Bump the manifest rev**

In `zinc.toml` `[dependencies.manifest]`, set `rev` to the `feat/casttext` SHA from Task 0. Update the pin comment to note "+ castText (RLS int-column cast)".

- [ ] **Step 2: Update the lock + build**

```bash
nix develop -c zinc update
nix develop -c zinc build
```
Expected: closure delta is manifest-only (we branched off the SAME pinned rev, so no transitive changes); manifest-evals builds clean (castText is purely additive). Then:
```bash
nix develop -c zinc test spec
```
Expected: all pre-existing specs green.

- [ ] **Step 3: Commit**

```bash
git add zinc.toml zinc.lock
git commit -m "chore: re-pin manifest to feat/casttext (adds castText helper)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Org registry entity + CLI

**Files:** `src/Evals/Schema.hs`, `src/Evals/Migrate.hs`, `app/Main.hs`, `test/SchemaSpec.hs`

- [ ] **Step 1: Add the `Org` entity**

In `src/Evals/Schema.hs`, add (near the top entities). `OrgId` already exists in `Evals.Ids`:
```haskell
data OrgT f = Org
  { id        :: Field f (Pk OrgId)
  , slug      :: Field f Text
  , name      :: Field f Text
  , createdAt :: Field f UTCTime
  } deriving Generic
type Org = OrgT Identity

instance Entity Org where
  tableMeta = genericTableMeta @OrgT "orgs"
  indexes   = [ unique [#slug] ]
  -- NO rlsPolicies: the tenant registry is readable to resolve slug -> id.
```
Ensure `OrgId` has a `Pk` instance like other ids (it's `newtype OrgId = OrgId Int deriving newtype DbType` in `Evals.Ids`; `Pk OrgId` should already work since other ids use the same pattern — confirm `Pk` usage compiles).

- [ ] **Step 2: Register Org in the migration**

In `src/Evals/Migrate.hs`, prepend to `schema`:
```haskell
  [ managed (Proxy @Org)
  , managed (Proxy @Dataset), managed (Proxy @DatasetVersion), ... ]
```

- [ ] **Step 3: Add `org create` / `org list` CLI**

In `app/Main.hs`, add subcommands (run on the owner connection — no `withTenant`):
```haskell
  ("org" : "create" : flags) -> do
    slug <- reqFlag "--slug" flags
    name <- reqFlag "--name" flags
    now  <- getCurrentTime
    withEnvPool $ \pool -> withSession pool $ do
      o <- add (Org { id = OrgId 0, slug = T.pack slug, name = T.pack name, createdAt = now } :: Org)
      let OrgId n = o.id in liftIO (putStrLn ("created org " <> show n <> " (" <> slug <> ")"))
  ("org" : "list" : _) -> do
    withEnvPool $ \pool -> withSession pool $ do
      os <- selectWhere ([] :: [Cond Org])
      liftIO (mapM_ (\o -> let OrgId n = o.id in putStrLn (show n <> "  " <> T.unpack o.slug <> "  " <> T.unpack o.name)) os)
```
Add the usage string entries. (`liftIO` from `Control.Monad.IO.Class`; check it's imported. `Cond` from Manifest.)

- [ ] **Step 4: Schema test**

In `test/SchemaSpec.hs` (migrate + round-trip), add an `Org` round-trip: `add` an Org, `get`/`selectWhere` it back, assert slug/name. Match the file's harness.

- [ ] **Step 5: Build + test + commit**

```bash
nix develop -c zinc test spec   # expect green incl. Org round-trip
git add src/Evals/Schema.hs src/Evals/Migrate.hs app/Main.hs test/SchemaSpec.hs
git commit -m "feat: Org registry entity + org create/list CLI

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `org` column + RLS policies on every entity

**Files:** `src/Evals/Schema.hs`

- [ ] **Step 1: Add `org :: Field f OrgId` to the 9 entities lacking it**

These already have `org`: `Dataset`, `Target`, `Grader`, `Run`. Add `, org :: Field f OrgId` to each of these record types (place after `id`, mirroring the existing `org` placement in `Dataset`):
`DatasetVersionT`, `ExampleT`, `GraderVersionT`, `TargetVersionT`, `OutputT`, `ScoreT`, `RunMetricT`, `CriterionLabelT`, `MetaEvalT`.

Example for `OutputT` (apply the analogous one-line addition to each):
```haskell
data OutputT f = Output
  { id   :: Field f (Pk OutputId)
  , org  :: Field f OrgId
  , run  :: Field f RunId
  , ...
```

- [ ] **Step 2: Add `import Manifest (castText)` availability**

`src/Evals/Schema.hs` imports `Manifest`. Confirm `Manifest` re-exports `policy`, `using`, `withCheck`, `currentSettingOr`, `castText`, `(.==)`, `(^.)` (added in Task 0/1). If any aren't re-exported by `Manifest`, add explicit imports (`import Manifest.Rls (policy, using, withCheck)`, `import Manifest.Query (castText, currentSettingOr, (.==), (^.))`).

- [ ] **Step 3: Add `rlsPolicies` to every scoped Entity instance**

To EACH of these 13 `instance Entity X where` blocks — `Dataset, DatasetVersion, Example, Target, TargetVersion, Grader, GraderVersion, Run, Output, Score, RunMetric, CriterionLabel, MetaEval` — add this method (identical for all; `#org` resolves per entity):
```haskell
  rlsPolicies =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]
```
Do NOT add it to `Org` (the registry stays unscoped).

- [ ] **Step 4: Build (no test yet — every insert still needs org; tests come in Task 7)**

Run: `nix develop -c zinc build`
Expected: `Evals.Schema` compiles. **The test suite WILL break here** (existing `add` sites don't set `org`, and other specs construct these entities) — that's expected; Task 5 + Task 7 fix the call sites. To keep this task's commit green-compiling, you may need to land Task 3 + Task 5 together if the build requires all `add` sites updated. PREFER: do Step 4 as `zinc build` of the library only; if record-construction sites across `src/` fail to compile (missing `org` field), proceed directly into Task 5 in the SAME working session and commit them together. Note this coupling in the commit.

- [ ] **Step 5: Commit (possibly combined with Task 5)**

```bash
git add src/Evals/Schema.hs
git commit -m "feat: org column + org_isolation RLS policy on every scoped entity

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: tenant role/grants + `withTenant`

**Files:** `src/Evals/Migrate.hs`, `src/Evals/Tenant.hs` (create), the cabal/zinc module list if needed

- [ ] **Step 1: Create `src/Evals/Tenant.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Run a Db body scoped to one org: switch to the low-privilege evals_tenant
-- role (so RLS applies — the default connection is superuser and bypasses it)
-- and set the app.org GUC, both transaction-local.
module Evals.Tenant (withTenant) where

import qualified Data.Text as T
import Manifest (Db, withTransaction, withRlsContext)
import Manifest.Session (execDb)
import Evals.Ids (OrgId (..))

withTenant :: OrgId -> Db a -> Db a
withTenant (OrgId n) body =
  withTransaction $ do
    _ <- execDb "SET LOCAL ROLE evals_tenant" []
    withRlsContext [("app.org", T.pack (show n))] body
```
(Confirm `withTransaction`/`withRlsContext` are exported from `Manifest` and `execDb` from `Manifest.Session`; adjust imports to match — `RlsSpec.hs` imports `Manifest.Session (Db, execDb)`.)

- [ ] **Step 2: Add role/grant DDL to `migrateAll`**

In `src/Evals/Migrate.hs`, change `migrateAll` to run the role/grant DDL after `migrateUp` (idempotent; runs as the owner/superuser connection):
```haskell
import Manifest.Session (execDb)
...
migrateAll :: Db MigrationPlan
migrateAll = do
  plan <- migrateUp schema
  _ <- execDb "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='evals_tenant') THEN CREATE ROLE evals_tenant NOLOGIN; END IF; END $$" []
  _ <- execDb "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO evals_tenant" []
  _ <- execDb "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO evals_tenant" []
  pure plan
```
(`execDb :: ByteString -> [Param] -> Db [[Maybe ByteString]]` per `RlsSpec`; the `[]` is the params list. Confirm the arity/return.)

- [ ] **Step 3: Register `Evals.Tenant` in the build**

`src/` modules are auto-discovered by zinc (`source-dirs = ["src"]`), so no config edit. Confirm `nix develop -c zinc build` picks it up.

- [ ] **Step 4: Build + commit**

```bash
nix develop -c zinc build
git add src/Evals/Migrate.hs src/Evals/Tenant.hs
git commit -m "feat: evals_tenant role + grants in migrate; withTenant session helper

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: thread `org` through every write path + CLI `--org`

**Files:** `src/Evals/Ingest.hs`, `src/Evals/MetaEval/Ingest.hs`, `src/Evals/MetaEval.hs`, `src/Evals/Execute.hs`, `src/Evals/Grade.hs`, `app/Main.hs`

- [ ] **Step 1: Thread org into the ingest paths**

`Evals.Ingest` and `Evals.MetaEval.Ingest` currently hardcode `org = OrgId 1` and create the whole graph. Add an `OrgId` to their opts (or a function arg) and replace EVERY `org = OrgId 1` and every child `add` (DatasetVersion/Example/Target/TargetVersion/Run/Output/Score/CriterionLabel) with `org = theOrg`. Search each file for entity `add` calls and set `org`.

- [ ] **Step 2: Thread org through the executor + grader**

In `src/Evals/Execute.hs` (creates `Output`) and `src/Evals/Grade.hs` (creates `Score`/`RunMetric`), set `org` = the run's org. These functions have the `Run` in scope (or its id) — use `run.org`. Where only a `RunId` is available, `get @Run` to read its org, or thread the org from the caller. Set `org` on every `Output`/`Score`/`RunMetric` `add`.

- [ ] **Step 3: `saveMetaEval` org**

In `src/Evals/MetaEval.hs`, `saveMetaEval` builds a `MetaEval`; add `org = <run's org>` (read via `get @Run rid` or thread it from the CLI).

- [ ] **Step 4: CLI `--org <slug>` + `withTenant` wrapping**

In `app/Main.hs`, for `ingest`, `run`, `score`, `metaeval load`, `metaeval report`: read `--org <slug>` (required), resolve to `OrgId` via an owner read `selectWhere [#slug ==. T.pack slug] :: Db [Org]` (die if not found), then run the command body inside `withTenant orgId`. Pass the `OrgId` into the ingest/execute/grade/metaeval functions so their `add`s stamp it. Example shape:
```haskell
  ("ingest" : fileArg : flags) -> do
    slug <- reqFlag "--org" flags
    ...
    withEnvPool $ \pool -> do
      org <- resolveOrg pool slug    -- owner read; die if missing
      withSession pool $ withTenant org $ <ingest body using org>
```
Add a helper `resolveOrg :: Pool -> String -> IO OrgId` (owner `withSession` + `selectWhere [#slug ==. ...]`).

- [ ] **Step 5: Build + commit**

```bash
nix develop -c zinc build
git add src/Evals/Ingest.hs src/Evals/MetaEval/Ingest.hs src/Evals/MetaEval.hs src/Evals/Execute.hs src/Evals/Grade.hs app/Main.hs
git commit -m "feat: stamp org on every write; CLI --org resolves + scopes via withTenant

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: two-org demo seed

**Files:** `scripts/seed-demo.sh`

- [ ] **Step 1: Create two orgs + stamp org on every row**

`seed-demo.sh` runs raw `psql` as the superuser (bypasses RLS), so it sets the `org` column directly — no role switch needed. Add at the top of the SQL: `INSERT INTO orgs (id, slug, name, created_at) VALUES (1,'acme','Acme',now()), (2,'globex','Globex',now());` and add `org` to the column list + value (`1` for the existing demo graph) of every INSERT (datasets/dataset_versions/examples/targets/target_versions/graders/grader_versions/runs/outputs/scores/run_metrics/meta_evals). Add a small second graph under `org = 2` (e.g. one dataset + one run) to make isolation visible. Update the `setval` line to include `orgs_id_seq`.

- [ ] **Step 2: Re-seed + verify**

```bash
nix develop -c bash scripts/seed-demo.sh
nix develop -c psql -d evals_demo -tAc "select distinct org from datasets order by org;"   # expect 1 and 2
```

- [ ] **Step 3: Commit**

```bash
git add scripts/seed-demo.sh
git commit -m "chore: seed two orgs (acme/globex) with org-stamped rows

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: isolation tests (`TenantSpec`)

**Files:** `test/TenantSpec.hs` (create), `test/Spec.hs`

- [ ] **Step 1: Write `test/TenantSpec.hs`**

On an ephemeral DB (`withEphemeralDb` connects as superuser): `migrateAll` (creates tables, policies, role, grants), then seed two orgs' graphs as owner (org 1 and org 2 rows), then assert isolation under the tenant role. Model the RLS activation on manifest's `RlsSpec` (`SET LOCAL ROLE` via `withTenant`):
```haskell
{-# LANGUAGE OverloadedStrings #-}
module TenantSpec (main) where

import Control.Monad (unless)
import Manifest
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)
import Evals.Schema
import Evals.Ids
import Evals.Migrate (migrateAll)
import Evals.Tenant (withTenant)
import Data.Time (getCurrentTime)

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = withEphemeralDb $ \pool -> do
  now <- getCurrentTime
  -- migrate (tables + RLS + role + grants) and seed two orgs as owner
  withSession pool $ do
    _ <- migrateAll
    _ <- add (Org { id = OrgId 1, slug = "acme",   name = "Acme",   createdAt = now } :: Org)
    _ <- add (Org { id = OrgId 2, slug = "globex", name = "Globex", createdAt = now } :: Org)
    _ <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "a", slug = "a", createdAt = now } :: Dataset)
    _ <- add (Dataset { id = DatasetId 0, org = OrgId 2, name = "g", slug = "g", createdAt = now } :: Dataset)
    pure ()
  -- org 1's context sees only org 1's dataset
  ds1 <- withSession pool $ withTenant (OrgId 1) (selectWhere ([] :: [Cond Dataset]))
  expect "org1 sees exactly its own dataset" (map (.org) ds1 == [OrgId 1])
  ds2 <- withSession pool $ withTenant (OrgId 2) (selectWhere ([] :: [Cond Dataset]))
  expect "org2 sees exactly its own dataset" (map (.org) ds2 == [OrgId 2])
  -- WITH CHECK rejects a cross-org insert under org 1's context
  crossOk <- (withSession pool $ withTenant (OrgId 1) $ do
                _ <- add (Dataset { id = DatasetId 0, org = OrgId 2, name = "x", slug = "x", createdAt = now } :: Dataset)
                pure True)
             `catchAny` (\_ -> pure False)
  expect "cross-org insert rejected by WITH CHECK" (not crossOk)
  putStrLn "manifest-evals TenantSpec: rls isolation + with-check OK"
  where
    catchAny = \a h -> Control.Exception.catch a (\(_ :: Control.Exception.SomeException) -> h undefined)
```
(Fix up the `catchAny`/imports to the project's style — add `import Control.Exception (catch, SomeException)` and write a clean `catch`. The KEY assertions: org-scoped reads return only that org's rows; a cross-org `add` throws.)

- [ ] **Step 2: Wire into `test/Spec.hs`**

Add `import qualified TenantSpec` and run `TenantSpec.main` (e.g. after `SchemaSpec`).

- [ ] **Step 3: Run**

Run: `nix develop -c zinc test spec`
Expected: `manifest-evals TenantSpec: rls isolation + with-check OK`; all specs green.

- [ ] **Step 4: Commit**

```bash
git add test/TenantSpec.hs test/Spec.hs
git commit -m "test: RLS cross-org isolation + WITH CHECK rejection

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: full gate (CONTROLLER)

- [ ] **Step 1: Full suite + build**

Run: `nix develop -c zinc test spec` (green) + `nix develop -c zinc build` (clean). The dashboard still builds and (as superuser, unscoped) still serves — confirm `nix develop -c bash scripts/seed-demo.sh` + a quick `curl /api/runs` still returns rows.

- [ ] **Step 2: Clean up the manifest worktree**

```bash
git -C /home/gareth/code/garethstokes/manifest worktree remove ../manifest-casttext
```

---

## Self-Review

**Spec coverage:** manifest castText → Task 0/1 ✓. Org registry + CLI → Task 2 ✓. org on every entity → Task 3 ✓. RLS policies (using+withCheck, fail-closed) → Task 3 ✓. role/grants + withTenant → Task 4 ✓. write-path threading + CLI --org → Task 5 ✓. two-org seed → Task 6 ✓. isolation + with-check tests → Task 7 ✓. Dashboard unchanged (no task touches its connection) ✓.

**Type consistency:** `withTenant :: OrgId -> Db a -> Db a`, `castText :: Expr a -> Expr Text`, `Org`/`OrgId`, `org :: Field f OrgId` consistent across tasks. The RLS snippet is byte-identical across all 13 entities.

**Placeholder scan:** Task 3 Step 4 calls out a real coupling (org-on-entity breaks `add` sites until Task 5) and instructs landing 3+5 together if needed — a genuine sequencing note, not a lazy placeholder. Task 0 Step 3 and Task 7 Step 1 ask the implementer to match the target file's test harness/imports (exact helper names not knowable from here) — bounded, with the assertion semantics fully specified.

**Known risks:** (1) the org-on-entity → broken-add-sites coupling (Tasks 3+5 may need to land together to keep a green commit). (2) `execDb`'s exact signature/return — confirm against `RlsSpec.hs`. (3) whether `Manifest` re-exports the RLS DSL + castText or needs explicit `Manifest.Rls`/`Manifest.Query` imports in Schema.hs. (4) the `evals_tenant` GRANT must re-run after new tables exist — `migrateAll` runs it every invocation, idempotently.
