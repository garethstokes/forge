# manifest-evals

An LLM eval-run orchestrator built on
[manifest](https://github.com/garethstokes/manifest) (the data layer — schema,
migrations, queries over Postgres) and
[crucible](https://github.com/garethstokes/crucible) (the LLM substrate —
effectful capabilities, Anthropic interpreters, skills/tools).

## Layout

- `src/Evals/` — the eval data model (sub-project A): ids, schema types,
  schema, migrations — plus the run executor (sub-project C):
  `Evals.Execute` (prompt assembly, injected `LlmRunner`, `executeRun`) and
  `Evals.Execute.Anthropic` (the live crucible-backed runner) — plus the
  scorer (sub-project: scoring): `Evals.Grade` (grader config → crucible
  `Expectation`, `scoreRun` with resume + per-grader `RunMetric` recompute)
  and `Evals.Grade.Anthropic` (the live judge edge).
- `app/` — the `manifest-evals` CLI: `migrate`, `run <runId>`, and
  `score <runId> <graderVersionId>...` (env: `MANIFEST_DATABASE_URL`,
  `ANTHROPIC_API_KEY`, `EVALS_CONCURRENCY`).
- `evals-api/` — the JSON wire DTO package: request/response types shared
  between the native warp server and the wasm Miso SPA.
- `evals-ui/` — the Miso SPA (wasm); also its own zinc workspace for wasm
  builds — see `scripts/build-ui.sh`.
- `app-dashboard/` — the warp server: serves the JSON API and the static SPA.
- `test/` — `SchemaSpec` (schema scenarios), `ExecuteSpec` (assembly,
  executeRun happy path / per-example error / resume / multi-turn recording),
  `GradeSpec` (config/exact/engine/checklist/resume/metrics/edge-cases), and
  `ApiSpec` (wire DTO round-trips) against an ephemeral Postgres
  (`Manifest.Testing.withEphemeralDb`).

## Build

GHC 9.12.2 via [zinc](https://github.com/garethstokes/zinc); Nix provides the
compiler and system deps (Postgres, libpq, zlib):

```bash
nix develop -c zinc build
nix develop -c zinc test
```

Both `manifest` and `crucible` are git-pinned in `zinc.toml` together with
their transitive closures (~111 packages under one lock).

## Dashboard

A read-only eval dashboard: browse runs, drill into per-example outputs and
scores, and compare two runs side-by-side. It is a single-page application
(one wasm Miso SPA) backed by a native warp JSON API.

### Build

```bash
# native: server + CLI
nix develop -c zinc build

# wasm UI reactor (evals-ui sub-workspace); restages static/
bash scripts/build-ui.sh
```

The generated wasm artifacts (`static/evals-ui.wasm`, `static/ghc_wasm_jsffi.js`,
`static/js/`) are gitignored — GHC-wasm links are non-reproducible, so they would
churn on every build. Run `scripts/build-ui.sh` once after cloning (it provisions
the wasm toolchain via zinc) before serving the dashboard.

### Run

Environment variables:

| Variable | Required | Default |
|---|---|---|
| `MANIFEST_DATABASE_URL` | yes | — |
| `EVALS_HTTP_PORT` | no | `8787` |
| `EVALS_STATIC_DIR` | no | `./static` |

```bash
./.zinc/build/evals-dashboard
```

Seed a demo database to explore the UI without real eval data:

```bash
bash scripts/seed-demo.sh   # creates and seeds a *demo* database
```

### Views

- `#/runs` — runs grouped by dataset, metric chips per run, pick any two to
  compare.
- `#/runs/<id>` — per-example outputs and scores; error rows flagged.
- `#/compare/<a>/<b>` — examples aligned by key, score deltas, disagreements
  highlighted.

Runs and scoring remain CLI-driven; the dashboard is read-only.

### Live updates

The dashboard self-updates via Server-Sent Events at `/api/events`. manifest's
change feed (writes to Run, Output, Score, and RunMetric tables) flows into a
broadcast hub in `Evals.Dashboard.Events`, which the SSE handler subscribes to;
each connected client receives a notification and debounces a full refetch
(~300ms). The header dot indicates connection state: green = live, gray =
reconnecting.

Events carry wake-up-only semantics — they are refetch hints, never data
payloads. A missed event means the UI stays stale until the next change arrives;
a manual browser refresh covers any gap.

**Demo / debugging note**: raw `psql` writes do NOT emit (emission is
manifest's session layer). To simulate a change without running the full CLI,
pair the write with a manual notify:

```sql
SELECT pg_notify('manifest_runs', '<run-uuid>');
```

Replace `manifest_runs` / `manifest_outputs` / `manifest_scores` /
`manifest_run_metrics` and the appropriate primary-key value for the table you
wrote to.
