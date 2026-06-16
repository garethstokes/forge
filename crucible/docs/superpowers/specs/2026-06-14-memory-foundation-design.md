# Memory Effect Foundation Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-l9d` (sub-project 1 of 3).
**Research basis:** `docs/superpowers/research/2026-06-11-agentic-memory.md` (Recommendations for crucible, points 1-3 and 6).

**Decomposition:** the Memory work splits into three sub-projects, each its
own spec/plan/cycle. This is sub-project 1 (the foundation): the effect,
types, three interpreters, and typed recall. Sub-project 2 (consolidation
as an offline Skill + apply function) and sub-project 3 (the `memoryLift`
ablation eval hook) build on this and are out of scope here.

**Scope:** new `src/Crucible/Memory.hs`; `src/Crucible/Codec.hs` (add
`encodeText`); `test/Spec.hs`; `app/Main.hs`; new `docs/memory.md` (+ nav).

## Motivation

Crucible models capabilities as dynamic effects with scripted, pure, and
live interpreters. Agent memory fits this house style: the literature's
winning storage layer for coding agents is plain files, and the winning
write discipline is typed records with provenance, both of which crucible
already has machinery for (Codec, Decode). This adds a small `Memory`
effect (linear append-log substrate plus a typed star/profile view), three
interpreters, and typed recall whose decode failure is staleness for free.

## Decisions taken during design

- Operations: `Remember` / `Recall` / `Forget`. `Forget` supersedes (an
  appended tombstone), never erases (invalidation-not-deletion).
- The store is a linear append-only **log of entries**
  (`Remembered MemoryItem | Forgot MemoryId`); liveness is folded from the
  log, so `MemoryItem` is immutable (no mutable status field) and history
  survives for audit.
- The interpreter assigns `MemoryId` and `createdAt` (callers pass a
  draft): real per backend (POSIX seconds in the file interpreter, a
  deterministic counter in the pure/scripted ones).
- Provenance is a strong sum type, mandatory on every memory (the
  poisoning/staleness/bulk-revoke discipline made structural).
- Typed memory: a `encodeText` helper for writes (writes go through the one
  `remember` path) and `recallAs` for reads, which decodes through today's
  codec so schema drift is staleness for free. No `rememberTyped` wrapper.
- Linear + star only. Tree/graph stay future interpreters; `Recall` by
  tags/needle works unchanged against them. No embeddings in v1.

## Design

### 1. `Crucible.Memory` types and effect

```haskell
data MemoryKind = Episodic | Semantic | Procedural   -- CoALA's split
  deriving (Eq, Show)

newtype MemoryId = MemoryId Int deriving (Eq, Show)

-- Who/what wrote a memory. Mandatory; enables trust-aware retrieval,
-- bulk revocation, and raw-vs-derived distinction.
data Provenance
  = BySkill Text       -- a named skill wrote it
  | BySession Text     -- written during a session/run (an id or label)
  | ByConsolidation    -- a derived memory from the consolidation Skill (sub-project 2)
  | Curated            -- human-authored (CLAUDE.md-style), highest trust, exempt from auto-forgetting
  deriving (Eq, Show)

-- What the caller remembers. id/createdAt are assigned by the interpreter.
data MemoryDraft = MemoryDraft
  { kind    :: MemoryKind
  , content :: Text
  , tags    :: [Text]
  , source  :: Provenance
  }
  deriving (Eq, Show)

-- What a store holds. Immutable; liveness is folded from the log, not a field.
data MemoryItem = MemoryItem
  { memId     :: MemoryId
  , kind      :: MemoryKind
  , content   :: Text
  , tags      :: [Text]
  , source    :: Provenance
  , createdAt :: Int          -- interpreter-assigned: counter (pure/scripted) / POSIX secs (file)
  }
  deriving (Eq, Show)

-- A recall request. The budget lives in the type so retrieval-drowning is
-- a caller decision, not an accident.
data Query = Query
  { needle   :: Text     -- free-text lexical needle; "" matches all
  , anyTags  :: [Text]   -- match items carrying any of these tags; [] = no tag filter
  , maxItems :: Int      -- result budget
  }
  deriving (Eq, Show)

data Memory :: Effect where
  Remember :: MemoryDraft -> Memory m MemoryId
  Recall   :: Query -> Memory m [MemoryItem]
  Forget   :: MemoryId -> Memory m ()

remember :: (Memory :> es) => MemoryDraft -> Eff es MemoryId
recall   :: (Memory :> es) => Query -> Eff es [MemoryItem]
forget   :: (Memory :> es) => MemoryId -> Eff es ()
```

`Recall` semantics (uniform): fold the log to live items (a `Remembered`
item with no later `Forgot` for its id), keep those where
`(anyTags == [] || any (`elem` tags) anyTags)` and
`(needle == "" || T.toCaseFold needle `T.isInfixOf` T.toCaseFold content)`,
order most-recent-first (descending `createdAt`, ties by descending id),
take `maxItems`.

### 2. Interpreters

```haskell
-- Canned recalls popped per Recall (mirrors runLLMScripted). Remember
-- assigns sequential ids (counter); Forget is a no-op. For testing code
-- that consumes recall results.
runMemoryScripted :: [[MemoryItem]] -> Eff (Memory : es) a -> Eff es a

-- In-memory entry log in local State; returns the result plus the final
-- live items (query-all order). For property tests of the laws.
runMemoryPure :: Eff (Memory : es) a -> Eff es (a, [MemoryItem])

-- A JSONL log at the path: Remember/Forget append one line, Recall reads
-- the file, parses entries, folds, filters, budgets. id = count of prior
-- Remembered entries; createdAt = POSIX seconds. git-diffable, lexical+tag.
runMemoryFile :: (IOE :> es) => FilePath -> Eff (Memory : es) a -> Eff es a
```

Entry log model (internal):

```haskell
data MemoryEntry = Remembered MemoryItem | Forgot MemoryId
```

The file interpreter serialises one `MemoryEntry` per line. Codecs (built
with `Crucible.Codec` combinators): `MemoryKind` via `enum`; `Provenance`
as a tagged object (`{"by":"skill","name":...}`, `{"by":"session",...}`,
`{"by":"consolidation"}`, `{"by":"curated"}`); `MemoryItem` via
`object`/`field`; `MemoryEntry` as a tagged object
(`{"entry":"remembered", ...item fields...}` / `{"entry":"forgot","id":n}`).

### 3. Typed memory (star/profile + free staleness)

Add to `Crucible.Codec`:

```haskell
-- | Encode a value to compact JSON text through its codec (the encode
-- companion to 'decodeLLM'/'schemaText').
encodeText :: JSONCodec a -> a -> Text
```

(Implemented with autodocodec's `toJSONVia` + `Data.Aeson.encode`.) Typed
writes go through the one `remember` path:

```haskell
remember (MemoryDraft Semantic (encodeText profileCodec p) ["profile"] (BySkill "consolidate"))
```

Typed reads, in `Crucible.Memory`:

```haskell
-- | Recall, then decode each item's content through the codec. The item is
-- always present (recall produced it); only the content decode can fail, so
-- a 'Left' is a stale memory (it no longer fits today's schema) WITH its
-- 'MemoryItem' intact, so the caller can forget or revoke it by provenance.
recallAs :: (Memory :> es) => JSONCodec a -> Query -> Eff es [(MemoryItem, Either DecodeError a)]
recallAs c q = map (\m -> (m, decodeLLM c m.content)) <$> recall q
```

A recalled memory that fails to decode against the current codec is
automatically stale: schema evolution becomes a forgetting policy for free.
This is the star/profile pattern with a compiler behind it.

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block: classify a sentiment with the existing
`classify` skill, `remember` the typed result (`Episodic`,
`BySkill "classify"`, content via `encodeText`) into a temp
`memory.jsonl` under `runMemoryFile`, `recallAs` it back, and print the
recalled value plus a note that the JSONL is human-readable. Shows a typed
memory round-trip end to end and a git-diffable store.

## Manual (`docs/memory.md`, linked in nav)

The `Memory` effect (`Remember`/`Recall`/`Forget`, supersede-not-erase);
`MemoryItem` and the typed `Provenance`; the three interpreters; typed
memory via `encodeText` + `recallAs` and the free-staleness property; the
linear+star shape framing (linear log substrate, typed profile as the star
view, tree/graph as future interpreters); and the disciplines (a `maxItems`
budget on every recall, provenance on every write for trust and
revocation). Note consolidation and eval hooks as follow-on sub-projects.
House style: no emdashes, no hype, no manifest mentions.

## Testing (hermetic)

Pure interpreter (`runMemoryPure`, under `runPureEff`):
- remember then recall-all returns the item with its assigned id/createdAt.
- tag filter: only items overlapping `anyTags` come back; `[]` matches all.
- needle: case-folded infix match; `""` matches all.
- `maxItems` caps the result count.
- ordering: most-recent-first (descending createdAt/id).
- forget: a forgotten id is absent from live recall; remember-3 / forget-1
  / recall returns the other two.
- all four `Provenance` arms round-trip on stored items and are filterable
  by `case` on `source`.

Scripted (`runMemoryScripted`): canned recalls pop in order regardless of
the query; Remember returns sequential ids.

File (`runMemoryFile`, IO checks against a temp file):
- round-trip: remember/forget then recall reads the folded live set.
- history preserved: after `forget`, the JSONL file still contains the
  forgotten item's `Remembered` line plus the `Forgot` line.
- codec round-trip: each `Provenance` arm, `MemoryKind`, and a `MemoryItem`
  encode and decode through their codecs; a `Forgot` entry round-trips.

Typed (`recallAs`, pure interpreter):
- a value written via `encodeText` recalls as `Right value` with its item.
- a memory whose stored content does not fit the codec recalls as
  `(item, Left _)` (staleness), with the item intact.

Live: the demo round-trip before merge.

## Non-goals (v1 foundation)

- Consolidation Skill + apply function (sub-project 2).
- `memoryLift` ablation eval hook (sub-project 3).
- Embeddings-backed recall (a future interpreter over the `Embed` effect).
- Tree/graph interpreters (the ops are shape-agnostic; add when multi-hop
  recall demonstrably needs it).
- Wall-clock bi-temporal validity (t_valid/t_invalid) and hash-based ids
  (beads' merge-survival lesson) - future hardening, not v1.
- Trust scoring/sanitization, background schedulers, multi-tenant scoping
  (provenance enables the first; the rest are host concerns).
