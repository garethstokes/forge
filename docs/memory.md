---
title: Memory
nav_order: 10
---

# Memory

`Crucible.Memory` gives an agent a place to remember things across calls. The
effect has three operations: `Remember` (append a draft to the store),
`Recall` (query the live items under a budget), and `Forget` (append a
tombstone that supersedes a prior item). Forget never erases: the original
entry stays in the log, so the full history survives for audit. Only `Recall`
filters it out as live.

## The effect and its operations

```haskell
remember :: (Memory :> es) => MemoryDraft -> Eff es MemoryId
recall   :: (Memory :> es) => Query       -> Eff es [MemoryItem]
forget   :: (Memory :> es) => MemoryId   -> Eff es ()
```

`remember` appends the draft and returns the assigned `MemoryId`. `recall`
queries the store, returning live items most-recent-first under the budget
declared in the `Query`. `forget` appends a tombstone; subsequent recalls
exclude the target item, but the original `Remembered` line remains in the
log.

## MemoryDraft vs MemoryItem

You write a `MemoryDraft`; the interpreter produces a `MemoryItem`:

```haskell
data MemoryDraft = MemoryDraft
  { kind    :: MemoryKind
  , content :: Text
  , tags    :: [Text]
  , source  :: Provenance
  }

data MemoryItem = MemoryItem
  { memId     :: MemoryId
  , kind      :: MemoryKind
  , content   :: Text
  , tags      :: [Text]
  , source    :: Provenance
  , createdAt :: Int
  }
```

The interpreter assigns `memId` and `createdAt`; everything else comes from
the draft. `MemoryKind` partitions the store into three independent buckets:

- `Episodic` for facts tied to a particular run or session.
- `Semantic` for general, context-free knowledge.
- `Procedural` for instructions, workflows, and how-to content.

## Provenance

Every draft carries a mandatory `Provenance`:

```haskell
data Provenance
  = BySkill    Text   -- written by a named skill
  | BySession  Text   -- written during a named session
  | ByConsolidation   -- written by an offline consolidation pass
  | Curated           -- hand-written or curated externally
```

Provenance is mandatory for three reasons. First, trust-aware retrieval:
`BySkill "classify"` items have a known quality floor (the skill produced
them); `ByConsolidation` items have been reviewed. Second, bulk revocation:
if a skill drifts, you can forget all its memories by provenance without
touching items from other sources. Third, a raw-vs-derived distinction:
`Episodic + BySession` is raw experience; `Semantic + ByConsolidation` is
something a consolidation pass distilled from it.

## Query

```haskell
data Query = Query
  { needle   :: Text
  , anyTags  :: [Text]
  , maxItems :: Int
  }
```

`recall` returns live items that satisfy the query: the item's tags must
overlap with `anyTags` (or `anyTags` is empty, matching all), and if
`needle` is non-empty it must appear as a case-folded infix in the item's
content. Matching items are returned most-recent-first, capped at
`maxItems`. The budget lives in the type, so retrieval-drowning is a caller
decision, not a store policy: pass `maxItems = 5` for agent context
windows, `maxItems = maxBound` for audits.

Matching is lexical: infix substring on content, tag intersection. There are
no embeddings; semantic similarity retrieval stays a future interpreter.

## Interpreters

Three interpreters ship in `Crucible.Memory`:

| Interpreter | When to use |
|---|---|
| `runMemoryScripted` | Canned recalls popped per call. Unit tests and golden tests. `Remember` returns sequential ids; `Forget` is a no-op. |
| `runMemoryPure` | An in-memory append log in local `State`. Returns `(result, liveItems)`. Property tests. |
| `runMemoryFile` | A JSONL log at a file path. One line per `Remember` or `Forget`, git-diffable. `IOE :> es` required. Single-writer. |

```haskell
runMemoryScripted :: [[MemoryItem]] -> Eff (Memory : es) a -> Eff es a
runMemoryPure     :: Eff (Memory : es) a -> Eff es (a, [MemoryItem])
runMemoryFile     :: (IOE :> es) => FilePath -> Eff (Memory : es) a -> Eff es a
```

`runMemoryFile` reads the whole log on every `Recall`, folds the tombstones
to find live items, filters, sorts, and budgets. It is simple and
git-diffable: each `Remember` and `Forget` is a single JSON line. It is
single-writer: concurrent writes from separate threads or processes can
interleave lines or assign duplicate ids. For multi-writer use, a future
interpreter backed by a database applies the same `Memory` effect without
changing the agent code.

## Typed memory

Content is stored as `Text`. To store and retrieve typed values, encode with
`encodeText` and decode with `recallAs`:

```haskell
encodeText :: JSONCodec a -> a -> Text
recallAs   :: (Memory :> es) => JSONCodec a -> Query -> Eff es [(MemoryItem, Either DecodeError a)]
```

`encodeText` serialises a value to the JSON text the codec produces.
`recallAs` recalls matching items and attempts to decode each one's content
through the codec. A `Left DecodeError` is a stale memory: the schema
changed after this item was written, and the old JSON no longer fits the
current type. Schema drift becomes forgetting for free, with the item still
available in the `Left` for inspection or explicit eviction.

A short round-trip showing the pattern from `app/Main.hs`:

```haskell
import Crucible.Memory
  ( MemoryKind (..), Provenance (..), MemoryDraft (..)
  , Query (..), remember, recallAs, runMemoryFile )
import Crucible.Codec (encodeText)
import Crucible.Codec.Generic (HasCodec (codec))

-- after running `call classify`, typed :: Either DecodeError Sentiment
let memPath = "/tmp/crucible-memory-demo.jsonl"
_ <- runEff (runMemoryFile memPath (case typed of
       Right s -> remember (MemoryDraft Episodic (encodeText (codec @Sentiment) s) ["sentiment"] (BySkill "classify"))
       Left _  -> remember (MemoryDraft Episodic "decode failed" ["sentiment"] (BySkill "classify"))))
recalled <- runEff (runMemoryFile memPath (recallAs (codec @Sentiment) (Query "" ["sentiment"] 5)))
-- recalled :: [(MemoryItem, Either DecodeError Sentiment)]
-- Right s  => live, current-schema item
-- Left _   => stale: the stored JSON no longer matches Sentiment
```

Re-running appends to the same file, so `recalled` grows across runs.
That is the persistence property: the file is the durable store.

## Linear and star shapes

The JSONL log is the linear substrate: one append per operation, full
ordered history. A typed profile record written whole with `encodeText` and
recalled whole with `recallAs` is the star view: a single item that
represents a structured snapshot of what the agent knows about a topic. The
two shapes compose: recall by tags or needle works the same way whether the
content is free text or encoded JSON.

Tree and graph shapes, and richer querying over structured fields, stay
future interpreters. The `Memory` effect interface does not change when
the interpreter does.

## Planned follow-on work

Consolidation (an offline `Skill` that reads `Episodic` items and writes
distilled `Semantic + ByConsolidation` summaries) and `memoryLift` (an
ablation eval that measures what the agent loses without a given memory) are
planned sub-projects. Both operate through the same `Memory` effect and
compose with the existing interpreters.
