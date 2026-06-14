# Memory Eval (memoryLift) Design Spec

**Date:** 2026-06-14
**Status:** Approved design (autonomous-cycle design call), pending implementation
**Tracker:** `crucible-fhc` (sub-project 3 of the Memory cycle; depends on `crucible-l9d`, shipped).
**Research basis:** `docs/superpowers/research/2026-06-11-agentic-memory.md` point 5 ("memories must pay rent": an ablation eval that turns a memory's value into a number).

**Scope:** new `src/Crucible/Memory/Eval.hs`; `test/Spec.hs`; `app/Main.hs`;
`docs/memory.md` (replace the "Planned follow-on work" stub with a real
"Evaluating memories" section). No `zinc.toml` change (modules are
auto-discovered from `source-dirs`).

## Motivation

The foundation writes memories cheaply and consolidation compacts them. The
open question is whether a given memory is worth keeping: does adding it to a
skill's context actually raise that skill's scores? `memoryLift` answers it
by ablation. Run a skill's attached test cases twice, once without the
candidate memories and once with them rendered into the skill's preamble, and
compare the two `Report`s. The difference in pass rate and mean score is the
rent the memories pay. That makes "keep memories that help" a measurable write
gate instead of a guess, the natural counterpart to consolidation's "compact
what we have".

## Decisions taken during design

- **Set ablation, not leave-one-out.** Two runs: with all candidate memories
  vs none. This answers "do these memories collectively help this skill". Per
  memory attribution (leave-one-out, N+1 runs) is a future variant and a
  non-goal here; the signature does not change for it.
- **Decoupled from the `Memory` effect.** `memoryLift` takes a plain
  `[MemoryItem]`, so it needs only `LLM` and `Embed` (via `testSkill`), not
  `Memory`. The caller pairs it with `recall` when the candidates come from a
  store; passing a literal list (a proposed memory under review) is equally
  valid and is the common write-gate case.
- **Return the pair, derive the metric purely.** `memoryLift` returns the two
  full `Report`s `(baseline, withMemories)` so the caller keeps every per-case
  result; `liftDelta` is a pure function that reduces the pair to the two
  headline deltas. This mirrors the foundation/consolidation choice to return
  rich data and let a small pure helper compute the summary (e.g. `recallAs`
  returning the item alongside the decode result).
- **`withMemories` is production-useful, not eval-only.** Rendering recalled
  memories into a skill's preamble and running it is exactly how a skill uses
  remembered context in production. `memoryLift` is `withMemories` applied to
  both arms of an ablation; the function stands alone.
- **Render content only.** `renderMemories` emits a labelled block of memory
  `content` lines, the form a skill would actually receive. `kind`, `tags`,
  and `source` are crucible's internal taxonomy, not instructions to the
  model, so they are deliberately not rendered. Richer rendering is a future
  option, not this spec.
- **Empty is identity.** `renderMemories [] == ""` and `withMemories [] sk`
  returns `sk` unchanged (preamble untouched), so `memoryLift render sk []`
  yields two identical reports and a zero delta. A clean degenerate.

## Design (`Crucible.Memory.Eval`)

```haskell
-- | Render memory contents as a labelled preamble block. Content only;
-- kind/tags/source are internal taxonomy and are not rendered. Empty list
-- renders the empty string.
renderMemories :: [MemoryItem] -> Text

-- | Append rendered memories to a skill's instruction preamble (after any
-- existing preamble, separated by a blank line). An empty list returns the
-- skill unchanged. Useful in production to run a skill with recalled context,
-- and the building block of 'memoryLift'.
withMemories :: [MemoryItem] -> Skill i o -> Skill i o

-- | Ablation: run the skill's attached test cases without memories
-- (baseline) and with them (lifted), returning both reports as
-- (baseline, lifted). Needs only LLM + Embed (via 'testSkill'); decoupled
-- from the Memory effect, so the candidates can come from 'recall' or be a
-- literal proposed memory under review.
memoryLift :: (Eq o, LLM :> es, Embed :> es)
           => (o -> Text) -> Skill i o -> [MemoryItem]
           -> Eff es (Report i (Either DecodeError o), Report i (Either DecodeError o))

-- | The headline deltas of an ablation, lifted minus baseline:
-- (passRate delta, meanScore delta). Positive means the memories paid rent.
-- Pure; pair order matches 'memoryLift's return.
liftDelta :: (Report i a, Report i a) -> (Double, Double)
```

### `renderMemories` format

A fixed header line followed by one bullet per memory content, in the order
given (recall order is most-recent-first):

```
Relevant memories from past sessions:
- The user prefers dark mode.
- The user's name is Gareth.
```

Implementation: `"Relevant memories from past sessions:\n" <> T.unlines ["- " <> m.content | m <- ms]` for a non-empty list; `""` for `[]`.

### `withMemories`

```haskell
withMemories ms sk
  | null ms   = sk
  | otherwise = withPreamble newPreamble sk
  where
    existing     = sk.instruction.preamble
    newPreamble  = if T.null existing then rendered
                                      else existing <> "\n\n" <> rendered
    rendered     = renderMemories ms
```

Uses the existing `withPreamble`/`instruction.preamble` machinery; no new
fields on `Skill`.

### `memoryLift`

```haskell
memoryLift render sk ms = do
  base    <- testSkill render sk
  lifted  <- testSkill render (withMemories ms sk)
  pure (base, lifted)
```

### `liftDelta`

```haskell
liftDelta (base, lifted) =
  ( lifted.passRate  - base.passRate
  , lifted.meanScore - base.meanScore )
```

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block: declare a tiny skill whose test case can
only be answered from a fact carried in a memory (e.g. a skill asked for the
user's preferred editor, with one `Exactly`/`Predicate` test case; the answer
lives only in a `[MemoryItem]`). Run `memoryLift`, print both pass rates and
`liftDelta`. Shows a memory paying rent live (baseline misses, lifted passes,
positive delta). No `Memory` interpreter needed; the candidate memories are a
literal list.

## Manual (`docs/memory.md`)

Replace the existing "Planned follow-on work" stub with an "Evaluating
memories (does a memory pay rent?)" section: `renderMemories`/`withMemories`
(noting the production use beyond eval), `memoryLift` (set ablation, decoupled
from the `Memory` effect, returns both reports), `liftDelta` (the write gate:
keep memories whose delta is positive), and the framing that this closes the
loop with consolidation (compact what helps, drop what does not). House style:
no emdashes/endashes, no hype words, no manifest mentions.

## Testing (hermetic)

`renderMemories` (pure):
- A two-item list renders the header plus one `- content` line per item, in
  order.
- `[]` renders `""`.

`withMemories` (pure):
- Empty preamble: the new preamble equals `renderMemories ms`.
- Non-empty preamble: the new preamble is `existing <> "\n\n" <> rendered`.
- `[]`: the skill's preamble is unchanged (identity).

`liftDelta` (pure):
- Hand-built report pairs: passRate 0.5 -> 1.0 gives delta 0.5; meanScore
  delta computed likewise; a negative case (lifted worse) gives a negative
  delta; equal reports give `(0, 0)`.

`memoryLift` (scripted LLM + `Crucible.Embed.none`):
- A skill with one test case and enough canned replies for two runs returns a
  pair of reports; with identical canned outputs both arms score the same and
  `liftDelta` is `(0, 0)` (confirms both arms run and the wiring is correct).

Live: the demo ablation before merge (set `-a; . ./.env`, gated on the
Anthropic key).

## Non-goals

- Per-memory leave-one-out attribution (a future variant; set ablation
  answers the collective question without changing the signature).
- Automatic write-gating: crucible reports the delta; the host picks the
  threshold and policy (keep, drop, flag for review).
- Recall integration inside `memoryLift` (it takes `[MemoryItem]` so the
  caller decides whether candidates come from `recall` or are a literal
  proposal; this keeps the `Memory` effect off the constraint list).
- Rendering `kind`/`tags`/`source` into the preamble (content only; richer
  rendering is a future option).
- A statistical significance test on the delta (small eval suites; the delta
  is a direct measurement, not an inference).
