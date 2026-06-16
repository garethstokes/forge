# forge

A Haskell monorepo unifying **crucible**, **manifest**, and **manifest-evals** into a single [zinc](https://github.com/garethstokes/zinc) workspace (GHC 9.12.2).

Design spec: [`docs/superpowers/specs/2026-06-16-forge-monorepo-design.md`](docs/superpowers/specs/2026-06-16-forge-monorepo-design.md)

## Members

The workspace has 8 members across three top-level packages:

| Member | Description |
|---|---|
| `crucible` | Typed LLM-agent substrate — effectful capabilities, Anthropic/OpenAI interpreters, skills, tools, and eval grading primitives |
| `crucible/crucible-manifest` | Crucible × manifest integration — persistence layer for crucible artefacts |
| `crucible/crucible-worker` | Background worker substrate built on crucible |
| `manifest` | Haskell database / ORM library — a Unit-of-Work layer (identity map, change tracking, snapshot-diff CRUD) over Postgres via Higher-Kinded-Data |
| `manifest/manifest-core` | Core HKD schema, CRUD, relationship, and migration primitives used by manifest |
| `manifest-evals` | LLM eval-run orchestrator (run, score, ingest, metaeval CLI) built on manifest (data layer) + crucible (LLM substrate) |
| `manifest-evals/evals-api` | JSON wire DTO package shared between the warp API server and the wasm Miso SPA |
| `manifest-evals/evals-ui` | Miso SPA compiled to wasm32-wasi — eval dashboard browser reactor (own sub-workspace for wasm builds) |

## Build

Enter the Nix dev shell (provides GHC 9.12.2, libpq, zlib, and tooling):

```bash
nix develop
```

Then use zinc to build or test all members:

```bash
zinc build
zinc test
```

The `evals-ui` member builds separately to wasm:

```bash
cd manifest-evals/evals-ui
zinc build --target wasm32-wasi
```

Or via the convenience script (also restages `static/`):

```bash
bash manifest-evals/scripts/build-ui.sh
```
