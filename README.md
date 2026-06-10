# manifest-evals

An LLM eval-run orchestrator built on
[manifest](https://github.com/garethstokes/manifest) (the data layer — schema,
migrations, queries over Postgres) and
[crucible](https://github.com/garethstokes/crucible) (the LLM substrate —
effectful capabilities, Anthropic interpreters, skills/tools).

## Layout

- `src/Evals/` — the eval data model (sub-project A): ids, schema types,
  schema, migrations.
- `test/` — `SchemaSpec`: migrate + round-trip + cascade + restrict +
  aggregate + compare-runs against an ephemeral Postgres
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
