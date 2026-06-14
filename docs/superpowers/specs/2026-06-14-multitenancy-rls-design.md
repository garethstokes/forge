# Multi-tenancy Slice 1 — RLS data-isolation substrate — design

**Date:** 2026-06-14
**Status:** approved (pending spec review)

## Goal

Make manifest-evals safely hold many orgs' data in one database, with Postgres
Row-Level Security so a session scoped to org X can only ever read or write org X's rows.
This is **Slice 1 of 2**: the isolation substrate, drivable and proven from the CLI. Slice 2
(org in the URL for the dashboard) builds on it and is out of scope here.

**Success criteria:** an ephemeral-DB test proves (a) a session in org A's context sees only
A's rows across every entity, and (b) an insert carrying the wrong org is rejected by the
policy `WITH CHECK`. The CLI can provision orgs and run ingest/score/etc. scoped to one org.

## Architecture

Every tenant-owned row carries `org :: OrgId`. Each scoped table has an `org_isolation` RLS
policy: `org = current_setting('app.org')`, with a fail-closed default (a session with no
context, or an unknown org, sees nothing). `migrate` emits `ENABLE`/`FORCE ROW LEVEL
SECURITY`. **Postgres bypasses RLS only for superusers (and `BYPASSRLS` roles); `FORCE`
subjects even the table owner.** The local/dev connection is a superuser, so RLS is inactive
by default and is **activated** by `SET LOCAL ROLE evals_tenant` (a plain non-superuser role)
+ `withRlsContext`, per scoped transaction (manifest's tested `RlsSpec` pattern). Provisioning,
migration, and the slug→id registry lookup run on the superuser connection (no role switch),
so they bypass RLS. The GUC is transaction-local (`set_config(..., true)`), so pooled
connections never leak tenant context.

After this slice: the **CLI is tenant-isolated and tested** (it switches to `evals_tenant`);
the **dashboard stays unscoped** — it never switches role, so on the superuser connection it
keeps seeing all orgs — until Slice 2 wires per-request tenancy. Nothing breaks in between.
(A production deployment that connects the app as a non-superuser role would have RLS bite
everything via `FORCE`; that hardening is a Slice 2 / deploy concern, noted but not built here.)

## Component 1 — Manifest `castText` (cross-repo, small)

manifest's RLS comparison `(.==) :: Expr t -> Expr t -> Expr Bool` needs both sides the same
type, and `currentSetting :: Expr Text`. Our org column is `OrgId` (Int). Add a one-helper
cast to `Manifest.Query` (exported):
```haskell
-- | Cast an expression to text, e.g. an Int org column for comparison with a GUC.
castText :: Expr a -> Expr Text
castText (Expr sql ps) = Expr ("(" <> sql <> ")::text") ps
```
Implement in a manifest worktree (the main checkout may be in use), merge to manifest
`master`, push, then re-pin manifest's `rev` in `zinc.toml` + `zinc update` (a rev change is
not lock drift — see [[zinc-rev-change-needs-update]]). manifest is currently pinned at
`0e414c2`.

## Component 2 — Org registry

New entity in `src/Evals/Schema.hs`, **not** RLS-scoped (the tenant directory the server
reads to resolve a slug before setting context):
```haskell
data OrgT f = Org
  { id        :: Field f (Pk OrgId)
  , slug      :: Field f Text
  , name      :: Field f Text
  , createdAt :: Field f UTCTime
  } deriving Generic
-- Entity Org: tableMeta "orgs"; indexes [btree #slug] (unique slug enforced app-side
-- or via a unique index); NO rlsPolicies.
```
`OrgId` stays the typed Int id (already exists in `Evals.Ids`). The `org` FK on other
entities now references this table conceptually (no DB-level FK is required, but the value is
an `OrgId`).

CLI: `manifest-evals org create --slug <s> --name <n> [--org-id N]` (auto-id if omitted) and
`org list`. Provisioning runs as owner (no tenant context).

## Component 3 — Org on every entity

Add `org :: Field f OrgId` to the entities that lack it: `DatasetVersion`, `Example`,
`GraderVersion`, `TargetVersion`, `Output`, `Score`, `RunMetric`, `CriterionLabel`,
`MetaEval`. (`Dataset`, `Target`, `Grader`, `Run` already have it.) `migrate` is additive
(`ALTER TABLE ADD COLUMN`); ephemeral/demo DBs are recreated. Each gets a snake_case `org`
column.

## Component 4 — RLS policies

Every scoped entity's `Entity` instance gains:
```haskell
  rlsPolicies =
    [ policy "org_isolation"
        `using`     (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0")
        `withCheck` (\s -> castText (s ^. #org) .== currentSettingOr "app.org" "0") ]
```
`withCheck` blocks cross-tenant writes; `"0"` is the fail-closed sentinel (no org has id 0).
`Org` itself has **no** policy. `migrate` already emits `ENABLE`/`FORCE ROW LEVEL SECURITY`
+ `CREATE POLICY` from `rlsPolicies`.

## Component 5 — Role, grants, and the `withTenant` helper

A new `src/Evals/Tenant.hs`:
```haskell
-- | Run a body scoped to one org: switch to the low-privilege tenant role (so
-- RLS applies) and set the app.org GUC, both transaction-local.
withTenant :: OrgId -> Db a -> Db a
withTenant (OrgId n) body =
  withTransaction $ do
    _ <- execDb "SET LOCAL ROLE evals_tenant" []
    withRlsContext [("app.org", T.pack (show n))] body
```
Role + grants are ensured by an extended migration step (`Evals.Migrate` or a
`manifest-evals migrate` addition): idempotent DDL —
```sql
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='evals_tenant')
    THEN CREATE ROLE evals_tenant NOLOGIN; END IF;
END $$;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO evals_tenant;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO evals_tenant;
GRANT SELECT ON orgs TO evals_tenant;   -- registry readable (slug enumeration acceptable for data-isolation-only)
```
(Run as owner during `migrate`, after the tables exist. The grants must re-run after new
tables are added; `migrate` runs them each time, idempotently.)

## Component 6 — Write-path threading

Every `add` site sets `org`. Concretely: `Evals.Ingest` and `Evals.MetaEval.Ingest` take the
resolved `OrgId` and stamp it on Dataset/Version/Example/Target/Run/Output/Labels; the run
executor (`Evals.Execute`) and grader (`Evals.Grade`) stamp the run's org onto
`Output`/`Score`/`RunMetric`. With the policy `WITH CHECK` active under the tenant role, an
omitted/wrong org is rejected — so the threading is enforced, not merely conventional.

The CLI commands (`ingest`, `run`, `score`, `metaeval load`/`report`) gain `--org <slug>`:
resolve slug→`OrgId` via the registry (owner read), then run the work inside `withTenant org`.

## Component 7 — Seed + tests

- `scripts/seed-demo.sh`: create **two** orgs (e.g. `acme`, `globex`); seed the existing
  demo graph under `acme`, plus a tiny second graph under `globex`, each insert stamped with
  its org and wrapped so RLS round-trips. Demonstrates isolation in the demo DB.
- `test/TenantSpec.hs` (new, wired into `test/Spec.hs`): on an ephemeral DB, migrate + create
  role, seed two orgs' graphs as owner, then under `withTenant orgA` (+ `SET LOCAL ROLE`)
  assert: every `selectWhere` returns only A's rows (Dataset/Run/Output/Score/MetaEval/…); an
  `add` with `org = orgB` under A's context throws (WITH CHECK violation); a context-less
  session (sentinel "0") sees nothing.

## Out of scope (Slice 2)

Dashboard URL org-routing, SPA org-awareness, asset serving under `/<slug>/`. The dashboard
keeps its owner connection (unscoped, sees all orgs) this slice. No auth/login (the org is a
trusted CLI flag here; a URL path in Slice 2).

## File map

- **manifest** (worktree): `src/Manifest/Query.hs` (+ export `castText`) + a `RlsSpec`/Query
  test. Push master; re-pin in `zinc.toml`.
- **Create**: `src/Evals/Tenant.hs`, `test/TenantSpec.hs`.
- **Modify**: `src/Evals/Schema.hs` (Org entity + org on 9 entities + rlsPolicies on all
  scoped entities), `src/Evals/Migrate.hs` (role/grant DDL + register Org), `src/Evals/Ids.hs`
  (Org `Pk`/already has OrgId), `src/Evals/Ingest.hs`, `src/Evals/MetaEval/Ingest.hs`,
  `src/Evals/MetaEval.hs`, `src/Evals/Execute.hs`, `src/Evals/Grade.hs`, `app/Main.hs`
  (`org` subcommands + `--org` flag + `withTenant`), `scripts/seed-demo.sh`, `test/Spec.hs`.
- Build/test via `nix develop -c zinc test spec` (see [[build-needs-nix-develop]]).
