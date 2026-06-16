# Memory Consolidation Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-cyx` (sub-project 2 of the Memory cycle; depends on `crucible-l9d`, shipped).
**Research basis:** `docs/superpowers/research/2026-06-11-agentic-memory.md` point 4 (consolidation as an offline Skill + apply function; the linear-to-star pump).

**Scope:** new `src/Crucible/Memory/Consolidate.hs`; `src/Crucible/Memory.hs` (export `memoryItemCodec`, `memoryKindCodec`); `test/Spec.hs`; `app/Main.hs`; `docs/memory.md` (a Consolidation section).

## Motivation

The Memory foundation writes a linear log cheaply. Consolidation is the
offline pass that compacts it: merge related memories, supersede stale
ones with corrected text, drop noise. The research's shape is a
`Skill [MemoryItem] ConsolidationPlan` (the LLM proposes per-item
operations) plus a pure apply that executes the plan. crucible ships the
skill and the apply, not a scheduler; when consolidation runs (cron,
session end) is the host's business. Because it is just a Skill, its
prompt is iterable with `testSkill` and it runs under scripted/cassette
interpreters. In shape terms this is the linear-to-star pump: transcript
-derived items in, a pruned log and promoted facts out.

## Decisions taken during design

- Operation set: `Keep | Drop | Supersede | Merge`, supporting BOTH explicit
  and implicit keep. A `Keep` op records a deliberate retention; an item the
  plan never mentions is also kept. `applyPlan` treats `Keep` as a no-op, so
  the two flows produce the identical store; only the plan's audit trail
  differs. `unaddressed` reports the implicitly-kept items.
- Metadata split: the LLM chooses the new memory's `kind` + `content` on
  `Supersede`/`Merge` (the semantic call, e.g. promoting episodic
  observations to a semantic fact); `applyPlan` mechanically unions the
  referenced items' tags and stamps `source = ByConsolidation` (the payoff
  of the typed Provenance).
- `applyPlan` is itself a `Memory`-effect program (issues `forget`/
  `remember`), so it runs under any interpreter and `MemoryEntry` stays
  internal. Supersede-not-erase holds (replaced items remain as tombstones).
- The Skill renders its `[MemoryItem]` input as JSON via the exported
  `memoryItemCodec` (the `<input>` block), so the LLM sees exact ids; the
  plan is a bare JSON array of tagged ops.

## Design (`Crucible.Memory.Consolidate`)

```haskell
data ConsolidationOp
  = Keep      MemoryId
  | Drop      MemoryId
  | Supersede MemoryId   MemoryKind Text   -- replace one item with (kind, content)
  | Merge     [MemoryId] MemoryKind Text   -- replace several items with one (kind, content)
  deriving (Eq, Show)

newtype ConsolidationPlan = ConsolidationPlan { ops :: [ConsolidationOp] }
  deriving (Eq, Show)

-- | The consolidation skill: live items as JSON in <input>, a plan array out.
consolidationSkill :: Skill [MemoryItem] ConsolidationPlan

-- | Execute a plan as Memory operations. Keep -> no-op; Drop -> forget;
-- Supersede -> forget the old, remember a new (kind, content) tagged with the
-- old item's tags and source ByConsolidation; Merge -> forget all referenced,
-- remember one new (kind, content) with the union of their tags, ByConsolidation.
-- Items the plan never mentions are untouched.
applyPlan :: (Memory :> es) => [MemoryItem] -> ConsolidationPlan -> Eff es ()

-- | The items a plan never references (implicitly kept), for auditing.
unaddressed :: [MemoryItem] -> ConsolidationPlan -> [MemoryItem]

-- | Recall under a query, ask the skill for a plan, apply it, return the plan.
-- A decode failure of the plan is returned as Left and applies nothing.
consolidate :: (Memory :> es, LLM :> es)
            => Skill [MemoryItem] ConsolidationPlan -> Query
            -> Eff es (Either DecodeError ConsolidationPlan)
```

### Plan codec (the LLM contract)

`ConsolidationPlan` encodes as a bare JSON array of tagged ops (the skill's
output codec, via `dimapCodec ConsolidationPlan (.ops) (list' opCodec)`):

- `{"op":"keep","id":N}`
- `{"op":"drop","id":N}`
- `{"op":"supersede","id":N,"kind":"semantic","content":"..."}`
- `{"op":"merge","ids":[N,...],"kind":"semantic","content":"..."}`

`opCodec` is a tagged-object `bimapCodec` over a raw record with `op :: Text`,
optional `id :: Int`, `ids :: [Int]`, `kind :: MemoryKind`, `content :: Text`;
it wraps ints in `MemoryId` and rejects an op tag missing its required fields
(driving the `call` repair loop). `MemoryKind` uses the exported
`memoryKindCodec`. Ids are plain `Int` on the wire (no need to export
`MemoryId`'s codec).

### `consolidationSkill` prompt

Built with `skill "consolidate" (list' memoryItemCodec) planCodec taskFn`,
where the task function (ignoring its argument, since the `<input>` JSON
carries the items) instructs: the memories are in `<input>` as a JSON array
with ids, kinds, tags, content; propose a plan array using `drop` (noise,
redundant, wrong), `supersede` (replace one with a corrected/refined version,
you may change its kind), `merge` (combine several related memories into one,
choose the result kind), and `keep` (record a deliberate retention); any
memory not mentioned is kept; only change the store when it clearly improves
it; `kind` is one of episodic/semantic/procedural.

### Sub-project-1 exports

`Crucible.Memory` adds two exports used here: `memoryItemCodec :: JSONCodec
MemoryItem` (the skill's input rendering) and `memoryKindCodec :: JSONCodec
MemoryKind` (the op `kind` field). Both already exist internally
(`memoryItemCodec`, `kindCodec`); rename `kindCodec` to `memoryKindCodec`
and add both to the export list.

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block, under a temp `runMemoryFile` store:
`remember` two related episodic observations (e.g. the user mentioning a
preference twice), then `consolidate consolidationSkill (Query "" [] 50)`
(the live LLM proposes a merge into a semantic fact), `recall` the result,
and print the plan op count and the resulting items. Shows the linear-to
-star pump live and a `ByConsolidation` memory in the store.

## Manual (`docs/memory.md`)

A "Consolidation" section: the `Skill [MemoryItem] ConsolidationPlan` shape,
the four ops (explicit vs implicit keep), `applyPlan` (Memory-effect program,
ByConsolidation stamping, supersede-not-erase), `unaddressed`, the
`consolidate` convenience, that the skill is `testSkill`-iterable like any
other, and the linear-to-star framing. Note the scheduler is the host's job
(crucible ships skill + apply, not a daemon). House style: no emdashes, no
hype, no manifest mentions.

## Testing (hermetic)

`applyPlan` (pure interpreter):
- Drop forgets the item (absent from live recall).
- Supersede forgets the old and adds a new item with the chosen kind +
  content, the old item's tags, and `source = ByConsolidation`; the old id is
  a tombstone (gone from live).
- Merge forgets all referenced items and adds one new item with the chosen
  kind + content, the union of their tags, `ByConsolidation`.
- Keep is a no-op; an unmentioned item is untouched (both flows equal).
- `unaddressed` returns exactly the items no op references.

Codec / skill (scripted):
- The plan codec round-trips each op (keep/drop/supersede/merge) and rejects
  an op tag missing a required field.
- `consolidationSkill` under `runLLMScripted` with a canned plan-array reply
  decodes to the expected `ConsolidationPlan`.
- `consolidate` end to end (scripted LLM + pure Memory): remember items, feed
  a canned plan, and the recalled store reflects the applied plan.

Live: the demo consolidation before merge.

## Non-goals

- A scheduler / sleep-time daemon (the host decides when to run it).
- Graph-building consolidation (the same signature with a different output
  type; a future variant).
- Automatic avoidance of re-consolidating derived memories beyond the caller
  scoping the recall (a `[MemoryItem]` filter on `source`); `Query` gains no
  provenance filter here.
- Dedup/salience heuristics beyond what the LLM proposes in the plan.
