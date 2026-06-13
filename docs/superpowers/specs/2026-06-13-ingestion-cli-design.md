# Eval Orchestrator — Ingestion CLI (HealthBench slice 2) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-13

**Goal:** A `manifest-evals ingest` subcommand turning a JSONL file into a
Dataset / DatasetVersion / Examples graph, so defining an eval no longer means
hand-written SQL. A thin generic core plus a `healthbench` format adapter, so
the 5,000-example HealthBench sets import directly and other benchmarks need
only a ~20-line adapter.

---

## 0. Context

The pipeline runs end-to-end (data model, executor, scoring incl. the
`pointed` HealthBench-rubric kind, dashboard, live progress), but every
example is currently inserted by hand-written SQL (`scripts/seed-demo.sh`,
the README's INSERT shapes). Ingestion is purely a front door — no engine
changes; the existing run/score/dashboard machinery consumes whatever lands.

The crucible research (`2026-06-12-eval-schemas-and-domain-evals.md`) endorses
this shape: the OpenAI Evals API pattern of typed case fields, generic core +
format adapters, kept thin because no definition-interchange standard exists.

**Decisions** (user-approved): ingestion ONLY (the OpenAI judge provider knob
is a later micro-slice); generic core `{key, input, expected?, meta?}` + a
`healthbench` adapter (not a HealthBench-specific importer, not a shell
pre-transform); the three HealthBench variants become three separate datasets
(distinct slugs), not versions of one; re-ingest of an existing
`(dataset, version)` REFUSES by default, `--force` replaces.

## 1. CLI

A new subcommand in `app/Main.hs` (the existing migrate/run/score style):

```
manifest-evals ingest <file.jsonl> --name <name> --slug <slug>
                       [--version N] [--format generic|healthbench]
                       [--limit N] [--skip-bad] [--force]
```

- `--name` (required): human dataset name. `--slug` (required): the stable
  identifier the `(dataset, version)` uniqueness keys on.
- `--version N` (default 1): the DatasetVersion number.
- `--format` (default `generic`).
- `--limit N`: import only the first N lines (deterministic; for cheap trial
  runs). Seeded random sampling is a later nicety, not v1.
- `--skip-bad`: a malformed/un-adaptable line is skipped and counted instead
  of aborting (default: abort on the first bad line, reporting its number).
- `--force`: replace an existing `(dataset, version)` (see §3).

Env: `MANIFEST_DATABASE_URL` (as the other subcommands). No API key needed.

Output on success: `ingested <slug> v<version>: N examples (M skipped)`.

## 2. `Evals.Ingest` (new lib module)

Logic in the library (testable); `Main` parses args and calls it.

```haskell
-- The four Example payload fields; ids assigned by `add`.
data IngestRow = IngestRow
  { key      :: Text
  , input    :: Value
  , expected :: Maybe Value
  , meta     :: Maybe Value
  }

-- A format adapts one parsed JSONL object to a row, or rejects it.
type Format = Value -> Either Text IngestRow
```

Two adapters:

- **generic**: top-level `{key, input, expected?, meta?}` mapped 1:1.
  Missing/empty `key` or missing `input` → `Left`.
- **healthbench**: the three documented moves —
  - `prompt` (a bare array of `{role, content}`) wrapped as
    `{"messages": <prompt>}` → `input` (the existing `decodeInput` expects
    that shape);
  - `rubrics` (`[{criterion, points, tags}]`) passed through VERBATIM →
    `expected` (the `pointed` kind reads HealthBench rubric items unchanged);
  - `prompt_id` → `key`; `example_tags`, `ideal_completions_data`, `canary`
    folded into `meta` (an object preserving them under their own keys).
  A row lacking `prompt_id`, `prompt`, or `rubrics` → `Left`.

## 3. The import driver

`ingestFile :: Pool -> IngestOpts -> IO IngestResult` (opts = file, name,
slug, version, format, limit, skipBad, force). One `withTransaction`:

1. Load the Dataset by slug; load its DatasetVersion at `version` if present.
2. **Exists check**: if that `(dataset, version)` exists and NOT `--force` →
   abort (typed error, no writes). If `--force` → `delete` the existing
   DatasetVersion first. The recursive cascade removes its Examples; the
   `DatasetVersion → Run Restrict` rule blocks the delete if any Run
   references the version — `--force` then reports "version has runs; delete
   them first" and aborts. (Correct by construction; no silent destruction of
   scored data.)
3. `add` the Dataset (only if the slug is new), the DatasetVersion
   (`finalizedAt = now`), and one Example per adapted row.

Streaming: read the file line-by-line (`Data.ByteString.Char8.lines` over the
contents, or a lazy line reader — 60 MB / 5,000 rows; do not hold all parsed
`Value`s plus all rows in memory at once beyond what the single transaction
needs). `--limit` truncates the line list first.

Atomicity: the whole import is one transaction — a mid-file failure rolls
back, leaving no half-imported dataset. Consequence: change-feed
notifications all fire at COMMIT, so the dashboard fills in at the end, not
row-by-row (acceptable — ingestion is not the live-watched operation).

Per-line handling: parse the line as JSON, then run the `Format`. A failure
(parse or adapt) is reported with the 1-based line number; `--skip-bad`
skips+counts instead of aborting.

## 4. Testing

- **Pure adapters**: generic (1:1 map; missing key/input → Left); healthbench
  (the three moves on a representative row — assert input is `{messages:[...]}`,
  expected is the verbatim rubrics array, meta carries tags/canary/ideal;
  missing prompt_id/prompt/rubrics → Left).
- **Driver** (ephemeral Postgres, a temp JSONL file written by the test):
  a 2-row generic file ingests → one Dataset, one DatasetVersion, two
  Examples with the right key/input/expected; re-ingest same `(slug, version)`
  → refused (no new rows); `--force` → replaces (old examples gone, new ones
  present); `--force` blocked when a Run references the version (the Restrict
  fires → typed error, version kept); `--limit 1` → one Example; `--skip-bad`
  → a malformed middle line is skipped, count reported, good rows present.
- A small `test/fixtures/*.jsonl` (generic + a healthbench row) committed.

## 5. Out of scope

- The OpenAI judge provider knob (next micro-slice).
- Downloading the HealthBench blobs (the user supplies the file path).
- Seeded random sampling (`--limit` is first-N only).
- Multi-file / glob ingest; updating individual examples in place.
- The tag/axis dimensional-metrics slice that consumes the folded-in tags.
