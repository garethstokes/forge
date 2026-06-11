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
- `test/` — `SchemaSpec` (schema scenarios), `ExecuteSpec` (assembly,
  executeRun happy path / per-example error / resume / multi-turn recording),
  and `GradeSpec` (config/exact/engine/checklist/resume/metrics/edge-cases)
  against an ephemeral Postgres (`Manifest.Testing.withEphemeralDb`).

## Build

GHC 9.12.2 via [zinc](https://github.com/garethstokes/zinc); Nix provides the
compiler and system deps (Postgres, libpq, zlib):

```bash
nix develop -c zinc build
nix develop -c zinc test
```

Both `manifest` and `crucible` are git-pinned in `zinc.toml` together with
their transitive closures (~111 packages under one lock).
