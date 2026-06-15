# Persistence Strategies for Crucible — Shaping Document

**Date:** 2026-06-15
**Status:** Shaping (not yet a committed plan)
**Scope:** How to augment crucible for different persistence strategies, plus
the manifest-side graph support that the GraphRAG path depends on.

---

## 1. The problem we keep dancing around

Every capability in crucible is a dynamic `effectful` effect with swappable
interpreters, and **persistence is hand-rolled inside each interpreter**:

| Effect | In-memory interpreter | On-disk interpreter |
|--------|----------------------|---------------------|
| `Memory` | `runMemoryPure` (local `State`) | `runMemoryFile` (append-only JSONL) |
| `Research` | `runResearchState` | `runResearchDir` (one markdown file per page) |
| `Embed` | `runEmbedScripted` | — (compute-only; nothing persisted) |
| `Ledger` | … | … (its own format again) |

So "in-memory vs on-disk" already exists, but it is **re-implemented per
effect**, each with a bespoke format and its own caveats (`runMemoryFile`'s
non-atomic read-count-append race; `runResearchDir`'s path-safety checks).
Adding a *new* backend (Postgres, a vector index, a graph store) today means a
fresh interpreter for *every* effect — an N-effects × M-backends problem.

Two concrete pressures forced the conversation:

- **GraphRAG needs a graph store** — the memory gap analysis
  (`docs/superpowers/research/2026-06-15-memory-gap-analysis.md`) flags this as a
  "new module category … no analogue exists."
- **Embeddings exist but were never wired to a store** — `Embed` computes
  vectors; nothing persists them for retrieval.

There is no shared notion of *a store*; each effect owns its persistence.

---

## 2. Decisions taken during shaping

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | Unify the substrate, enable specific backends, or pluggable per-effect backends? | **Pluggable per-effect backends** | Keep each effect's interface; make persistence a parameter (a backend handle), not a shared universal `Store`. |
| 2 | How thick is the backend handle? | **Thick (full ops)** — handle exposes `doRemember`/`doRecall`/`doForget`; interpreter is a near-passthrough | Lets a real ORM (manifest) own the read/write cycle in its own idiom; see §4. |
| 3 | Identity model | **Store-assigned** | Drop crucible's ordinal `itemOf d n`; `Remember` returns the store's flushed key. Coherent with the thick-handle choice. |
| 4 | Packaging | **`crucible-manifest` satellite package** | Keep Postgres/`libpq` out of crucible-core; the manifest backend is opt-in, mirroring how `manifest-evals` already bridges the two projects. |
| 5 | Codec reconciliation | **crucible-JSON in a `jsonb` envelope** | Store the existing `memoryItemCodec` output in a `jsonb` column; use manifest only for the row/PK/index envelope. Minimizes the two-codec surface; reuses crucible's codecs unchanged. |
| 6 | Which effects get a thick handle now? | **`Memory`, `Research`, and `Ledger`** | Give `Ledger` the same `runLedgerWith` + `LedgerStore` treatment now rather than deferring — keeps the three persistent effects uniform. |

### Why thick + manifest fit each other

Manifest is a **unit-of-work**: it wants to own the whole read/write cycle —
snapshot-diffing dirty entities, the command path, `flush`, transactions
(`withSession`/`withTransaction`). A *thin* handle (`putItem`/`queryItems`)
would force callers to bypass the UoW and poke rows individually, fighting
manifest's design. A *thick* handle (`doRemember`/`doRecall`/`doForget`) lets
manifest **be** the backend in its natural idiom.

The risk we accepted with a thick handle — backends can silently diverge on ids,
item shape, tombstone/budget semantics — is mitigated by HKD (§4): the manifest
backend's SQL is *derived from generics*, not hand-written, so it cannot drift.
Backends HKD cannot derive (file, in-memory pure) stay covered by a shared
conformance test against the handle.

---

## 3. Part 1 — Crucible persistence refactor

### Shape

```haskell
-- crucible-core: the thick handle is the seam
data MemoryStore = MemoryStore
  { doRemember :: MemoryDraft -> IO MemoryId    -- store-assigned key
  , doRecall   :: Query       -> IO [MemoryItem]
  , doForget   :: MemoryId    -> IO ()
  }

runMemoryWith :: IOE :> es => MemoryStore -> Eff (Memory : es) a -> Eff es a
runMemoryWith s = interpret $ \_ -> \case
  Remember d -> liftIO (s.doRemember d)
  Recall q   -> liftIO (s.doRecall q)
  Forget i   -> liftIO (s.doForget i)
```

- `runMemoryFile` / `runMemoryPure` are reframed as `memoryStoreFile :: FilePath
  -> MemoryStore` and `memoryStorePure :: IORef [MemoryEntry] -> MemoryStore`,
  hand-written thick handles over the same `MemoryItem` record.
- The pure property-test interpreter (`runMemoryPure` returning `(a,
  [MemoryItem])`) is **kept** for fast IO-free property tests.
- Same treatment for `Research` (`runResearchWith` + `researchStoreDir` /
  `…State`) and `Ledger` (`runLedgerWith` + `LedgerStore`, with the existing
  on-disk and in-memory interpreters reframed as handles). The three persistent
  effects stay uniform.

### Domain types become Higher-Kinded Data (HKD)

Define each domain type **once**, parameterized by a functor `f`; the crucible
value is the `Identity` instance (callers unchanged):

```haskell
data MemoryItemT f = MemoryItem
  { memId     :: Field f (Pk Int)        -- store-assigned key
  , kind      :: Field f MemoryKind
  , content   :: Field f Text
  , tags      :: Field f [Text]
  , source    :: Field f Provenance
  , createdAt :: Field f Int
  } deriving Generic

type MemoryItem = MemoryItemT Identity            -- today's record, unchanged

-- in crucible-manifest only:
deriving via (Table "memory" MemoryItemT) instance Entity MemoryItem
```

One `deriving via` line gives a **derived** Postgres backend (row
encode/decode, PK, table meta, queries) generically — no hand-written SQL.

**Consistency gained:** (1) one field-set source of truth across backends — add
the embedding `[Double]` the gap analysis wants in *one* place; (2) the DB
backend's correctness is generic, so it can't drift; (3) the handle stays the
conformance seam for non-derived backends.

**Costs accepted:** HKD only unifies the *SQL* family (file/in-memory still
hand-map fields, as they do today via `memoryItemCodec`). Two codec worlds
(`Crucible.Codec.JSONCodec` vs `Manifest.Core.Codec`) are reconciled per
decision 5: **store the crucible-JSON blob in a `jsonb` column** and use manifest
only for the row/PK/index envelope. So the manifest entity is thin — a PK, a few
indexed columns (e.g. `tags`, `createdAt`, `kind` for query pushdown), and a
`jsonb` payload decoded by crucible's existing `memoryItemCodec`. (`zinc.toml`
already notes a Schema type shared with manifest for exactly this "shared-types
jsonb persistence".)

### "In-memory" = ephemeral Postgres cluster (no separate mock)

There is **no true in-process libpq Postgres for Haskell** (pglite is WASM/JS;
SQLite is in-process but a different dialect — no `BIGSERIAL`/`jsonb`/RLS the way
manifest generates them, and manifest is Postgres-only).

But manifest already ships `Manifest.Testing.withEphemeralDb`, which is the thing
we actually want:

```
initdb -A trust --no-sync
  → pg_ctl start -c listen_addresses=''   (private unix socket, no TCP)
  → 2-conn pool
  → bracket teardown (stop -m immediate + rm -rf)
```

No pre-running server, private socket, auto-created, auto-destroyed; already
exported for consumer packages (manifest-evals uses it). With `--no-sync` (and
optionally `fsync=off`, a tmpfs datadir) it is RAM-fast and disposable.

**Payoff:** we do **not** build a separate in-memory `MemoryStore` for the
manifest path. The "in-memory" lifetime is the *same* derived backend pointed at
an ephemeral cluster:

```haskell
withEphemeralDb $ \pool ->
  runMemoryWith (memoryStoreManifest (mkDb pool)) program
```

One backend, two lifetimes (persistent cluster vs ephemeral). Tests run against
real Postgres semantics, not a hand-rolled mock — so "in-memory" tests cannot
pass behavior the production backend won't honor.

### Packaging

```
crucible (core)         : Memory/Research/Ledger effects, thick handles,
                          memoryStoreFile/Pure, researchStoreDir/State,
                          ledgerStore{File,Pure}.
                          No manifest / libpq dependency.
crucible-manifest (new) : memoryStoreManifest, researchStoreManifest,
                          ledgerStoreManifest, HKD Entity instances (thin
                          envelope: PK + indexed columns + jsonb payload),
                          ephemeral-cluster helpers. Depends on manifest (→ libpq).
```

This inverts nothing in core: crucible-core stays dependency-light; the DB
backend is opt-in, mirroring `manifest-evals` as a bridge rather than folding
manifest into crucible.

---

## 4. Part 2 — Manifest graph support (prerequisite for GraphRAG only)

Split into "already fits", "one real addition", and "out of scope".

### Data model — already fits, no new primitive

Nodes are ordinary entities. An edge is a self-join table — the existing
`Employee` self-FK pattern generalized to its own table:

```haskell
data EdgeT f = Edge
  { edgeId   :: Field f (Pk Int)
  , edgeSrc  :: Field f Int          -- → node PK
  , edgeDst  :: Field f Int          -- → node PK
  , edgeType :: Field f Text         -- relates / contradicts / extends / …
  , edgeMeta :: Field f Jsonb        -- weight, provenance, extracted-by
  } deriving Generic
deriving via (Table "edges" EdgeT) instance Entity Edge
```

GraphRAG's "LLM extracts entities + relationships" → node rows + edge rows.
Nothing new in manifest for *storage*.

### The one real addition — recursive traversal

Today `withCte` emits `name AS (…)` (non-recursive only; confirmed in
`Manifest/Query.hs`). Multi-hop reachability needs `WITH RECURSIVE name AS
(anchor UNION ALL step)`. So the manifest work is a single new combinator beside
`withCte`, reusing the existing `qsWith`/`CteRef` plumbing (just set a
`RECURSIVE` flag and let the step reference its own CTE name):

```haskell
withRecursive
  :: Entity e
  => QueryM (Handle e)                 -- anchor (base case)
  -> (CteRef e -> QueryM (Handle e))   -- recursive step (refers to the CTE)
  -> QueryM (CteRef e)
```

Plus two ergonomic helpers — `neighborhood seed depth` and `reachable seed` —
with a depth column + `LIMIT`/visited-guard for cycle safety. GraphRAG "local
search" (seed → k-hop neighborhood → gather context) works with just this.

### Out of scope (name them so they don't sneak in)

- **Community detection (Leiden)** — an algorithm, not a query; Postgres can't do
  it in SQL. Run it in Haskell over a loaded edge set, lean on an extension
  (Apache AGE / pgrouting), or skip it (gap analysis rates GraphRAG low-priority
  "until flat RAG is solid").
- **True ANN** — `pgvector` is the real answer but an extension dep; brute-force
  cosine over a `jsonb`/array column is "sufficient to ~10k", needs no manifest
  change.

---

## 5. Types and graph databases (design background)

This section is context for the graph shaping, not a commitment.

### Position: the relational schema *is* the type graph

We do **not** adopt any specialized typed-graph formalism. A relational schema
already gives us a typed property graph: **each entity table is a node-type, each
FK / edge-table is a typed edge** (source/target enforced by the foreign keys),
and the "typing" is just "a row belongs to its table." A normal relational
database with foreign keys already enforces everything we need — so manifest
gives us a typed property graph *by construction*, with no extra machinery.

> *Background, not load-bearing:* the academic framings (the "type-graph
> homomorphism" view from graph-transformation theory; categorical databases à la
> Spivak/CQL where a schema is a category and an instance a functor; TypeDB's
> role-based ERA model; RDF/OWL/SHACL) all formalize the same "data lines up with
> the schema" idea. We don't need them. The one practical idea worth keeping in
> reach: in Haskell you can **phantom-type edge endpoints** (`EdgeT src dst f`) so
> GHC rejects an edge between incompatible node types — see §6.

What a relational schema models well: typed edges with source/target constraints,
edge-attribute typing (weight, provenance, timestamp), and cardinality. The one
weak spot is **node-type subtyping** (`Person <: Agent`) — relational has no
native inheritance, so we use an `edgeType` discriminator column instead of a
type hierarchy.

### How clustering plays with types

- **Base community detection (Leiden / Louvain) is type-blind.** It optimizes
  modularity over topology + edge weights and ignores node/edge types. GraphRAG's
  default Leiden pass is exactly this — types are descriptive metadata, not
  inputs.
- **Three ways types can enter clustering:**
  1. **Types as constraints (meta-paths)** — Heterogeneous Information Networks:
     define a *meta-path* (a typed path schema, e.g.
     `Entity —mentions→ Doc —mentions→ Entity`) and cluster by connectivity along
     it (PathSim, metapath2vec). Types decide which edges "count".
  2. **Types as features (attributed clustering)** — feed node type/attributes
     alongside topology (SA-Cluster, attributed stochastic block models). A
     cluster is topologically dense **and** type-coherent.
  3. **Clusters as emergent types (the output view)** — the clustering pass
     *produces* a new node-type: a `Community` node + `member-of` edges. The base
     typed graph is untouched; a **typed community layer** is added on top.
     Categorically this is a **quotient** (collapse each community to a point);
     the quotient lands in a new typed layer.
- **The tension to hold:** base clustering throws types away. If you want types
  to matter, you choose constraint (meta-path) vs feature (attributed). But the
  most *useful* product is the third — clustering minting a new typed layer you
  can query and traverse at a coarser grain (GraphRAG **global** vs **local**
  search).

### Mapping back to manifest / HKD

- **Clustering-as-typed-layer fits cleanly.** Add a `Community` entity +
  `community_member` edge table. The Leiden pass (Haskell or extension) **writes
  new typed rows**; the recursive-CTE traversal then runs at entity level (local
  search) or community level (global search). "Clustering" in this system is
  literally "add a typed layer of community nodes" — interpretation (3) above.
- **What HKD adds:** node/edge *types* are Haskell types (`EdgeT f`,
  `CommunityT f`), so the type graph is GHC-checked at the entity level. Endpoint
  typing on edges is *not* free (the FK is an `Int`); if wanted, **phantom-type
  the endpoints** (`EdgeT src dst f`) so GHC rejects an edge between incompatible
  node types — the in-Haskell version of "types used with graph databases".

---

## 6. Sequencing & open questions

**Recommended order**

1. **Part 1 (persistence refactor)** first — load-bearing, unblocks the
   memory/research/vector persistence story, independent of Part 2.
2. **Part 2 (manifest graph support)** when GraphRAG work actually begins.

**Resolved** (see decisions table): codec → `jsonb` envelope; `Ledger` → thick
handle now alongside `Memory`/`Research`.

**Open questions to resolve before a plan**

- Conformance test: one shared property suite run against every `MemoryStore`
  (file, pure, manifest-ephemeral) to pin tombstone/budget/ordering semantics
  the thick handle no longer enforces structurally. (Recommended — the thick
  handle's whole risk is silent divergence; this suite is the mitigation.)
- Phantom-typed edge endpoints: worth the type-level machinery, or is the
  `edgeType` discriminator enough for GraphRAG's needs? (Deferred to Part 2; the
  discriminator is the default unless a concrete need appears.)
```
