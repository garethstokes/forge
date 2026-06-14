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

## Consolidation

`Crucible.Memory.Consolidate` ships an offline pass that reads the current
memories and compacts them. The shape is a plain `Skill`:

```haskell
consolidationSkill :: Skill [MemoryItem] ConsolidationPlan
```

The skill receives the live items rendered as a JSON array in `<input>` and
proposes a `ConsolidationPlan`: a list of `ConsolidationOp` values. The LLM
picks each operation; the host decides when to run the pass.

### The four operations

```haskell
data ConsolidationOp
  = Keep      MemoryId
  | Drop      MemoryId
  | Supersede MemoryId   MemoryKind Text
  | Merge     [MemoryId] MemoryKind Text
```

An item the plan never mentions is kept implicitly. `Keep` records a
deliberate retention -- a no-op for the store, useful when you want an
explicit audit trail of what the LLM considered and chose to leave alone.
`Drop` forgets a noisy or redundant item. `Supersede` replaces one item with
a corrected or refined version, optionally changing its kind (for example
promoting an `Episodic` observation to a `Semantic` fact). `Merge` combines
several related items into one, taking the union of their tags.

### Applying a plan

`applyPlan` executes the plan as `Memory` operations:

```haskell
applyPlan :: (Memory :> es) => [MemoryItem] -> ConsolidationPlan -> Eff es ()
```

Under the hood: `Keep` is a no-op; `Drop` calls `forget`; `Supersede` calls
`forget` then `remember`; `Merge` calls `forget` for each source then
`remember` for the result. Every new item written by `applyPlan` is stamped
`ByConsolidation`. The original entries remain in the JSONL log (supersede-
not-erase), so the full history survives for audit; only `Recall` filters
them out as live.

The LLM chooses the `MemoryKind` and `content` for each derived item.
`applyPlan` unions the source tags onto the result automatically.

### Auditing implicit keeps

```haskell
unaddressed :: [MemoryItem] -> ConsolidationPlan -> [MemoryItem]
```

Returns the items the plan never referenced. These are the implicitly kept
items. Useful when you want to log what the consolidation pass chose not to
touch.

### The `consolidate` convenience

```haskell
consolidate :: (Memory :> es, LLM :> es)
            => Skill [MemoryItem] ConsolidationPlan -> Query
            -> Eff es (Either DecodeError ConsolidationPlan)
```

`consolidate` composes recall, skill call, and apply in one step: it recalls
items under the query, calls the skill, and if decoding succeeds applies the
plan and returns `Right plan`. A decode failure returns `Left` and applies
nothing, leaving the store unchanged.

The effect order places `Anthropic.run` (or any LLM interpreter) inside
`runMemoryFile`, since `consolidate` needs both `LLM` and `Memory` in scope:

```haskell
runEff (runMemoryFile path (Anthropic.run cfg
          (consolidate consolidationSkill (Query "" [] 50))))
```

### Short example

```haskell
import Crucible.Memory (MemoryKind (..), MemoryItem (..), Provenance (..), MemoryDraft (..), Query (..), remember, recall, runMemoryFile)
import Crucible.Memory.Consolidate (ConsolidationPlan (..), ConsolidationOp, consolidationSkill, consolidate)

let path = "/tmp/demo.jsonl"

-- seed two redundant episodic items
_ <- runEff (runMemoryFile path (do
       _ <- remember (MemoryDraft Episodic "The user prefers dark mode." ["pref"] (BySession "s1"))
       _ <- remember (MemoryDraft Episodic "The user switched to dark theme again." ["pref"] (BySession "s1"))
       pure ()))

-- consolidate: the LLM merges both into one semantic fact
plan <- runEff (runMemoryFile path (Anthropic.run cfg
          (consolidate consolidationSkill (Query "" [] 50))))

-- store now holds one ByConsolidation item, the two originals tombstoned
items <- runEff (runMemoryFile path (recall (Query "" [] 50)))
-- items ~ [MemoryItem { content = "The user prefers dark mode.", source = ByConsolidation, ... }]
```

Running this live produces:

```
consolidate: plan 1 op(s); store now ["The user prefers dark mode."]
```

The skill compressed two `Episodic + BySession` entries into one item; the
plan had one operation (a `Merge`).

### Iteration and scheduling

The skill is iterable with `testSkill` and composable with `withTests` and
`withExamples` like any other skill, so you can drive an improvement loop
over consolidation quality using `Crucible.Skill.Improve`. crucible ships
the skill and `applyPlan`; when to run the pass is the host's decision.
A reasonable policy is to trigger consolidation when the store exceeds a
token budget or after a fixed number of sessions.

### Linear to star

The JSONL log is the linear substrate: one append per `Remember` or
`Forget`, full ordered history. Consolidation is the pump from that linear
log to star-shaped facts: a single `Semantic + ByConsolidation` item that
represents what the agent currently knows about a topic, with the raw
episodes it was distilled from available in the log for audit.

## Evaluating memories (does a memory pay rent?)

Consolidation compacts the store. The next question is whether the surviving
memories actually help: does putting a memory in a skill's context raise the
skill's scores, or does it add noise that changes nothing? `memoryLift`
answers that question by running a set ablation: the skill's attached test
cases run once without the candidate memories (baseline) and once with them
rendered into the preamble (lifted). A positive delta means the memories paid
rent.

### Rendering memories into a skill

Two helpers in `Crucible.Memory.Eval` connect the memory store to the skill
evaluation pipeline:

```haskell
renderMemories :: [MemoryItem] -> Text
withMemories   :: [MemoryItem] -> Skill i o -> Skill i o
```

`renderMemories` formats a list of items into a plain text block. `withMemories`
appends that block to the skill's instruction preamble, producing a new skill
that runs with those memories in context. An empty list leaves the skill
unchanged, so the same call is safe at every call-site regardless of whether
retrieval returned anything.

`withMemories` is not only for evaluation. It is how a skill runs with recalled
context in production: recall from the store, call `withMemories`, call the
skill.

### The ablation

```haskell
memoryLift
  :: (Eq o, LLM :> es, Embed :> es)
  => (o -> Text)
  -> Skill i o
  -> [MemoryItem]
  -> Eff es (Report i (Either DecodeError o), Report i (Either DecodeError o))
```

`memoryLift` takes a render function for the output type, the skill under
review, and a candidate `[MemoryItem]` list. It runs `testSkill` twice: once
on the bare skill (baseline) and once on `withMemories candidates skill`
(lifted), and returns both `Report` values. The candidates can come from a
`recall` call on the live store or be a single proposed memory you want to
evaluate before committing it. The function needs only `LLM` and `Embed` (the
same constraints as `testSkill`); it is decoupled from the `Memory` effect
entirely.

### Reading the result

```haskell
liftDelta :: (Report i a, Report i a) -> (Double, Double)
```

`liftDelta` is a pure function that takes the pair of reports and returns
`(passRate delta, meanScore delta)` as lifted minus baseline. A positive delta
on either dimension means the memories moved the needle in the right direction.

```haskell
-- A skill whose test cases can only be answered from a memory.
(base, lifted) <- memoryLift render mySkill candidateMemories
let (dPass, dScore) = liftDelta (base, lifted)
-- dPass > 0  =>  the memories paid rent; keep them.
```

This is the write gate: keep memories whose delta is positive, drop those whose
delta is zero or negative.

### Closing the loop with consolidation

Consolidation and `memoryLift` address the same store from different angles.
Consolidation compacts what you have, merging duplicates and dropping noise at
the structural level. `memoryLift` measures which of the surviving memories
are worth keeping at the performance level: if adding a memory does not raise
scores, it is not contributing anything the skill could not already do on its
own.

Like consolidation, crucible reports the delta and leaves the policy to the
host. The typical threshold is straightforward: keep if `dPass > 0` or
`dScore > 0`. The host can set a stricter bar (for example, requiring a
minimum delta to justify the token cost) or a looser one (retaining memories
that break even but carry provenance the operator wants to preserve). crucible
provides the measurement; the decision is yours.
