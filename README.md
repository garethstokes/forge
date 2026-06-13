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
  and `Evals.Grade.Live` (the live judge edge); the `pointed` grader kind
  uses per-example signed-point criteria (HealthBench-style) living in
  `Example.expected` as `[{"criterion","points","tags"}]`, each judged with
  full conversation context, scored sum(met points)/sum(positive points)
  unclipped, with grader config carrying judge knobs only. A grader config
  jsonb may set `"provider": "openai"` (default `"anthropic"`) to route
  judging through crucible's OpenAI interpreter instead of Anthropic; set
  `OPENAI_API_KEY` when any grader uses it (`ANTHROPIC_API_KEY` is always
  required). The model/knob keys (`model`/`max_tokens`/`timeout`/`retries`/
  `votes`) apply to either provider. `RunMetric` now
  carries an overall row (`tag` null) plus per-tag breakdowns — `theme:*` (the
  example's score bucketed by its `example_tags`) and, for pointed graders,
  `axis:*`/`cluster:*` (the criteria re-scored per tag from the stored verdicts,
  with no extra judge calls); all means are clipped to [0,1]. The dashboard
  currently shows the overall metric (tag rendering is a later slice).
- `app/` — the `manifest-evals` CLI: `migrate`, `run <runId>`,
  `score <runId> <graderVersionId>...`, and `ingest <file.jsonl>` (env:
  `MANIFEST_DATABASE_URL`, `ANTHROPIC_API_KEY`, `EVALS_CONCURRENCY`).
- `src/Evals/Ingest.hs` — the JSONL dataset loader: per-format row adapters
  (`generic`, `healthbench`) feeding `ingestFile` (refuse-by-default driver
  with `--force`/`--limit`/`--skip-bad`).
- `evals-api/` — the JSON wire DTO package: request/response types shared
  between the native warp server and the wasm Miso SPA.
- `evals-ui/` — the Miso SPA (wasm); also its own zinc workspace for wasm
  builds — see `scripts/build-ui.sh`.
- `app-dashboard/` — the warp server: serves the JSON API and the static SPA.
- `test/` — `SchemaSpec` (schema scenarios), `ExecuteSpec` (assembly,
  executeRun happy path / per-example error / resume / multi-turn recording),
  `GradeSpec` (config/exact/engine/checklist/pointed/resume/metrics/edge-cases), and
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

## Ingesting datasets

Load a JSONL file as a dataset version:

```bash
manifest-evals ingest <file.jsonl> --name N --slug S \
  [--version N] [--format generic|healthbench] [--limit N] [--skip-bad] [--force]
```

The `generic` format (default) expects one object per line shaped
`{key, input, expected?, meta?}`. `input` must be the `{"messages":[...]}`
conversation shape that `decodeInput` expects, or a JSON string for a single
user turn. `expected` and `meta` are passed through verbatim.

The `healthbench` format adapts HealthBench rows with three moves: it wraps the
bare `prompt` array into the `{"messages":[...]}` conversation shape, passes
`rubrics` straight through to `expected` (consumed by the `pointed` grader), and
folds `example_tags`/`canary`/`ideal_completions_data` into `meta`. `prompt_id`
becomes the example key.

Ingestion refuses by default if the dataset version already exists; `--force`
replaces it, but is blocked if any run references that version. `--limit N`
ingests only the first `N` rows; `--skip-bad` reports the count of malformed
lines skipped instead of aborting on the first one (without it, the first bad
line fails the whole ingest).

```bash
manifest-evals ingest healthbench_hard.jsonl \
  --name "HealthBench Hard" --slug healthbench-hard --format healthbench
```

## Meta-evaluation (grader calibration)

`manifest-evals metaeval load <file.jsonl> --name N --slug S` seeds a labelled
run from records `{key, input, completion, rubric:[{criterion,points,tags}],
labels:[{criterion,met}]}` — each `labels` entry is a human verdict for a rubric
criterion; a label naming a criterion absent from its rubric is refused (or
skipped with `--skip-bad`).

`manifest-evals metaeval report <runId> <graderVersionId> [--mode live|stored]
[--seed N]` prints agreement, Cohen's κ (+95% CI), and fail-class
precision/recall: `--mode live` re-judges each labelled criterion with the real
grader (needs `ANTHROPIC_API_KEY`); `--mode stored` reads the verdicts from a
prior `score` of that run. The statistics are crucible's (`reportFromVerdicts` /
`renderCalibration`).

Note: re-loading the same `--slug`+`--version` is refused even with `--force`
(the synthetic run blocks replacement) — load a new version instead.

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
SELECT pg_notify('manifest_runs', '<run-id>');  -- pks are Ints, e.g. '1'
```

Replace `manifest_runs` / `manifest_outputs` / `manifest_scores` /
`manifest_run_metrics` and the appropriate primary-key value for the table you
wrote to.
