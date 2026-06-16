# Eval Orchestrator — Data Model (sub-project A) — Design

**Status:** Approved design (brainstorm complete). · **Date:** 2026-06-10

**Goal:** The Manifest schema for an LLM-eval orchestrator: datasets and their examples,
the systems under test, reusable graders, and the run/output/score graph that ties them
together, with full reproducibility. This is **sub-project A** of a four-part platform
(A data model → B Miso dashboard → C run orchestrator → D live progress); A is the
contract B and C are written against.

---

## 0. Context

The platform lets a team trigger eval runs from a UI, call model providers, grade the
outputs, and browse + compare results. It decomposes into:

- **A — Data model (this spec):** the Manifest entities. Pure Manifest; the foundation.
- **B — Dashboard:** a Miso UI to browse datasets/runs and compare runs. Reads A.
- **C — Orchestrator:** the job runner that triggers runs, calls models, runs graders,
  writes results. The heaviest piece; produces the data in A.
- **D — Live progress:** server-to-client push of run progress (the event-sourcing /
  `LISTEN`/`NOTIFY` proposal, `manifest-z8h`).

Build order A → B → C → D. This spec covers only A.

**Single team for now, RLS-ready** (see §6). The eval payloads (inputs, outputs, configs)
vary in shape, so they are raw `jsonb` (`Aeson Value`) in v1; typed per-family codecs are
a later refinement.

**App housing (decided):** the eval project is a **new package** at
`examples/manifest-evals/`, added to Manifest's zinc `[workspace] members`, depending on
the local `manifest` library via a workspace/path dependency. It is a separate project that
uses Manifest, but co-located so library changes are instantly available during the heavy
co-development phase (it can be extracted to a sibling repo later). The Manifest library
extensions in §5 land in `manifest` itself first; the eval package builds on top.

---

## 1. Typed identifiers

Every entity gets a distinct newtype key (typed-fields), so ids never cross and foreign
keys are typed:

```haskell
newtype OrgId            = OrgId Int            deriving newtype DbType
newtype DatasetId        = DatasetId Int        deriving newtype DbType
newtype DatasetVersionId = DatasetVersionId Int deriving newtype DbType
newtype ExampleId        = ExampleId Int        deriving newtype DbType
newtype TargetId         = TargetId Int         deriving newtype DbType
newtype TargetVersionId  = TargetVersionId Int  deriving newtype DbType
newtype GraderId         = GraderId Int         deriving newtype DbType
newtype GraderVersionId  = GraderVersionId Int  deriving newtype DbType
newtype RunId            = RunId Int            deriving newtype DbType
newtype OutputId         = OutputId Int         deriving newtype DbType
newtype ScoreId          = ScoreId Int          deriving newtype DbType
newtype RunMetricId      = RunMetricId Int      deriving newtype DbType
```

The flexible JSON payload type is `Aeson Value` (raw jsonb via the `Aeson a` column; `Value`
already has `ToJSON`/`FromJSON`).

### Record style

The eval package enables **`DuplicateRecordFields`** + **`NoFieldSelectors`** +
**`OverloadedRecordDot`** (plus `OverloadedLabels`, which the query builder needs), so
records use **bare, unprefixed field names** and are read with `.field`:

```haskell
data ExampleT f = Example { id :: Field f (Pk ExampleId), datasetVersion :: Field f DatasetVersionId, input :: Field f (Aeson Value) }
-- ex.input  ::  Aeson Value      ex.id  ::  ExampleId      map (.input) examples
```

This was verified to cooperate with Manifest's machinery: two records sharing a bare `id`
field derive `Entity` via `Table`, `genericTableMeta` reads the bare names as columns
(`camelToSnake "datasetVersion" = "dataset_version"`), `OverloadedRecordDot` sees through
the `Field f a` family at `Identity`, and the `?.` typed projection resolves the bare-named
labels (`run ?. #status`). **`OverloadedRecordUpdate` is NOT used** (experimental); record
updates use plain `r { field = x }`, disambiguated by the record's type. The entity
declarations in §2 follow this bare-name style.

One caveat: bare field names become bare column names, and Manifest renders DDL unquoted,
so avoid SQL **reserved** words as field names (`order`, `user`, `default`, `table`, ...).
The names chosen in §2 (`id`, `name`, `version`, `key`, `value`, `text`, `count`, ...) are
non-reserved keywords, which Postgres accepts as unquoted column names.

---

## 2. Entities

Root-owned tables (`Dataset`, `Target`, `Grader`, `Run`) carry `org :: OrgId` for
RLS-readiness (§6). `createdAt :: UTCTime` everywhere needs the timestamp extension (§5).

### Datasets (inputs)

```haskell
data DatasetT f = Dataset
  { id        :: Field f (Pk DatasetId)
  , org       :: Field f OrgId
  , name      :: Field f Text
  , slug      :: Field f Text
  , createdAt :: Field f UTCTime
  } deriving Generic                                       -- table "datasets"

data DatasetVersionT f = DatasetVersion
  { id          :: Field f (Pk DatasetVersionId)
  , dataset     :: Field f DatasetId                       -- FK -> datasets
  , version     :: Field f Int                             -- UNIQUE (dataset, version)
  , note        :: Field f (Maybe Text)
  , finalizedAt :: Field f (Maybe UTCTime)
  , createdAt   :: Field f UTCTime
  } deriving Generic                                       -- table "dataset_versions"

data ExampleT f = Example
  { id             :: Field f (Pk ExampleId)
  , datasetVersion :: Field f DatasetVersionId             -- FK -> dataset_versions
  , key            :: Field f Text                         -- stable id within the dataset (cross-version compare)
  , input          :: Field f (Aeson Value)                -- jsonb
  , expected       :: Field f (Maybe (Aeson Value))        -- jsonb (reference answer / rubric target)
  , meta           :: Field f (Maybe (Aeson Value))        -- jsonb
  } deriving Generic                                       -- table "examples"
```

### Targets (system under test)

```haskell
data TargetT f = Target
  { id        :: Field f (Pk TargetId)
  , org       :: Field f OrgId
  , name      :: Field f Text
  , createdAt :: Field f UTCTime
  } deriving Generic                                       -- table "targets"

data TargetVersionT f = TargetVersion
  { id        :: Field f (Pk TargetVersionId)
  , target    :: Field f TargetId
  , version   :: Field f Int                               -- UNIQUE (target, version)
  , model     :: Field f Text                              -- provider model id
  , prompt    :: Field f Text                              -- prompt template
  , params    :: Field f (Aeson Value)                     -- jsonb: temperature, max_tokens, ...
  , createdAt :: Field f UTCTime
  } deriving Generic                                       -- table "target_versions"
```

### Graders (reusable judges)

```haskell
data GraderT f = Grader
  { id        :: Field f (Pk GraderId)
  , org       :: Field f OrgId
  , name      :: Field f Text
  , kind      :: Field f Text                              -- exact | judge | rubric | ...
  , createdAt :: Field f UTCTime
  } deriving Generic                                       -- table "graders"

data GraderVersionT f = GraderVersion
  { id        :: Field f (Pk GraderVersionId)
  , grader    :: Field f GraderId
  , version   :: Field f Int                               -- UNIQUE (grader, version)
  , config    :: Field f (Aeson Value)                     -- jsonb: judge prompt / rubric / match rule
  , createdAt :: Field f UTCTime
  } deriving Generic                                       -- table "grader_versions"
```

### Run / Output / Score

```haskell
data RunT f = Run
  { id             :: Field f (Pk RunId)
  , org            :: Field f OrgId
  , datasetVersion :: Field f DatasetVersionId             -- FK -> dataset_versions (frozen inputs)
  , targetVersion  :: Field f TargetVersionId              -- FK -> target_versions (frozen system)
  , status         :: Field f Text                         -- queued | running | succeeded | failed
  , startedAt      :: Field f (Maybe UTCTime)
  , finishedAt     :: Field f (Maybe UTCTime)
  , meta           :: Field f (Maybe (Aeson Value))        -- jsonb
  , createdAt      :: Field f UTCTime
  } deriving Generic                                       -- table "runs"

data OutputT f = Output
  { id        :: Field f (Pk OutputId)
  , run       :: Field f RunId                             -- FK -> runs
  , example   :: Field f ExampleId                         -- FK -> examples
  , response  :: Field f (Maybe (Aeson Value))             -- jsonb: raw provider response (null if errored)
  , text      :: Field f (Maybe Text)                      -- extracted completion text
  , error     :: Field f (Maybe Text)
  , latencyMs :: Field f (Maybe Int)
  , tokens    :: Field f (Maybe (Aeson Value))             -- jsonb: usage
  } deriving Generic                                       -- table "outputs"

data ScoreT f = Score
  { id            :: Field f (Pk ScoreId)
  , output        :: Field f OutputId                      -- FK -> outputs
  , graderVersion :: Field f GraderVersionId               -- FK -> grader_versions
  , value         :: Field f Double                        -- needs DbType Double (§5)
  , passed        :: Field f (Maybe Bool)
  , detail        :: Field f (Maybe (Aeson Value))         -- jsonb: judge reasoning
  , createdAt     :: Field f UTCTime
  } deriving Generic                                       -- table "scores"

data RunMetricT f = RunMetric
  { id            :: Field f (Pk RunMetricId)
  , run           :: Field f RunId                         -- FK -> runs
  , graderVersion :: Field f GraderVersionId               -- FK -> grader_versions
  , mean          :: Field f Double
  , passRate      :: Field f (Maybe Double)
  , count         :: Field f Int
  , computedAt    :: Field f UTCTime
  } deriving Generic                                       -- table "run_metrics"
```

`RunMetric` is the cached rollup the dashboard reads; the query builder computes the same
numbers live (§4). `Score` is per `(output, graderVersion)`, so re-scoring outputs with a
new grader version is just inserting more `Score` rows. `key` lets the dashboard line up
the same logical example across two runs on different dataset versions.

---

## 3. Relationships & cascades

`HasRelation` instances wire the graph; `cascadeRules` mix `Cascade` (ownership trees) with
`Restrict` (protect frozen versions a run depends on):

- `Dataset →hasMany→ DatasetVersion` (`dataset`); on delete **Cascade**.
- `DatasetVersion →hasMany→ Example` (`datasetVersion`); on delete **Cascade**.
  `DatasetVersion`'s delete is **Restrict**ed if any `Run` references it (reproducibility).
- `Target →hasMany→ TargetVersion`; Cascade. `TargetVersion` delete **Restrict**ed by `Run`.
- `Grader →hasMany→ GraderVersion`; Cascade. `GraderVersion` delete **Restrict**ed by `Score`.
- `Run belongsTo DatasetVersion + TargetVersion`; `Run →hasMany→ Output` (Cascade) and
  `→hasMany→ RunMetric` (Cascade).
- `Output belongsTo Run + Example`; `Output →hasMany→ Score` (Cascade).
- `Score belongsTo Output + GraderVersion`.
- **`Run` ↔ `Grader` is many-to-many through `Score`** (via `Output`): the join row carries
  the score value. This is the join-entity-with-data pattern.

---

## 4. Indexes & aggregate queries

**Indexes** (the declarative `indexes` feature):

- `gin` on the queried jsonb: `Example.input`, `Output.response`, `Run.meta`
  (filter by document contents with `@>` / `->>`).
- `btree` on the hot foreign keys joins traverse: `Output.run`, `Score.output`,
  `Example.datasetVersion`, `Run.datasetVersion`, `Run.targetVersion`.
- **Unique** on `DatasetVersion (dataset, version)`, `TargetVersion (target, version)`,
  `GraderVersion (grader, version)`
  — see §5 (needs a unique-index extension or a manual migration).

**Aggregates** are the query builder. `RunMetric`'s numbers are `avg_`/`countRows` over
`Score` joined to `Output` for a run, grouped by grader version:

```haskell
runQuery $ do
  o <- from @Output
  s <- innerJoin @Score (\s -> s ?. #output .== o ?. #id)
  where_ (o ?. #run .== val theRunId)
  groupBy (s ?. #graderVersion)
  pure (s ?. #graderVersion, avg_ (s ?. #value), countRows)
```

"Compare run A vs B" joins two runs' outputs on `key` (same logical example) and diffs
their scores. jsonb operators (`->>`, `@>`, `#>>`) filter on input/response contents, with
`?.` keeping those projections annotation-free.

---

## 5. Manifest extensions this schema needs

Dogfooding surfaces two small gaps in Manifest itself; both are prerequisites for A and are
in scope here (or as tiny pre-tasks in the plan):

1. **Timestamp columns.** The schema uses `UTCTime` (`createdAt`, run timing). Manifest has
   no timestamp support yet: add `SqlTimestamptz` to `SqlType` (`TIMESTAMPTZ` / `timestamp
   with time zone`) and a `DbType UTCTime` instance (encode/decode the Postgres ISO-8601
   text via the `time` library, already a dependency).
2. **`DbType Double`.** `Score.value`/`RunMetric.mean` are `Double`; add a `DbType Double` instance
   (`SqlDouble` → `double precision`). Small, parallel to the existing `Int` instance.
3. **Unique indexes (decided: extend the feature).** The `(dataset, version)` uniqueness
   wants a `UNIQUE` index; the just-built `indexes` feature does `gin`/`btree` (single
   column) only. We extend it with a multi-column **`unique`** builder
   (`unique [#dataset, #version]` → `CREATE UNIQUE INDEX … (dataset, version)`),
   mirroring `gin`/`btree` and reconciled the same create-only way. This is reusable beyond
   the eval schema and is a Manifest library change (§5 lands in `manifest` first).

---

## 6. RLS-readiness (off in v1)

The four root tables carry `org :: OrgId`, populated with one team's id; **no `rlsPolicies`
are declared**. Child rows (versions, examples, outputs, scores, metrics) are reachable only
through an org-scoped root, so the roots are the isolation boundary. Going multi-tenant later
is additive: attach an `org_isolation` policy
(`policy "org_isolation" \`using\` (\r -> r ^. #org .== currentSetting "app.current_org")`)
to each root and wrap sessions in `withRlsContext` — no schema reshape, no backfill.

---

## 7. Immutability

Reproducibility is structural: a `Run` references frozen `DatasetVersion`/`TargetVersion`
rows (and `Score`s reference frozen `GraderVersion`s), so re-running or comparing just
re-references the same rows. Immutability of a finalized version is an app-level convention
(never `UPDATE` a finalized version; "editing" a dataset is a Unit-of-Work *create* of a
new `DatasetVersion`, copying then changing examples), backed by the `(dataset, version)`
unique index and the `Restrict` cascades that stop a referenced version being deleted. A
`dvFinalizedAt` timestamp marks the freeze point. A DB trigger that rejects `UPDATE`s on
finalized rows is a later hardening, out of scope for v1.

---

## 8. Scope & testing

**In scope (A):** the entities of §2 with their typed-id newtypes, relationships, cascades
(§3), GIN/btree indexes (§4), the timestamp + `Double` + unique-index extensions (§5), and
the migration to create the schema. Tests (ephemeral Postgres, the existing harness):

- the schema migrates cleanly via `managed`/`migrateUp` (and is idempotent on a second run);
- a full round-trip persists and reads back: a `Dataset` → `DatasetVersion` → `Example`s, a
  `TargetVersion`, a `Run` with `Output`s and `Score`s, and a `RunMetric`;
- the cascade behaviour: deleting a `Run` removes its outputs and scores; deleting a
  `DatasetVersion` that a `Run` references is **rejected** (Restrict);
- the aggregate query returns the correct mean/count per grader version against seeded
  scores, and a two-run comparison lines examples up by `key`;
- round-trips of the timestamp (`UTCTime`) and `Double` columns and the `Aeson Value` jsonb
  payloads.

**Out of scope (later sub-projects):** the Miso dashboard (B), the run orchestrator /
model-provider calls / grader execution (C), live progress (D), RLS policies (ready but
off), typed per-family payload codecs (raw `Aeson Value` for now), and the immutability DB
trigger.
