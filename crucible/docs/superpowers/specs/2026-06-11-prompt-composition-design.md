# Prompt Composition — Design Spec

**Date:** 2026-06-11
**Status:** Approved design, pending implementation
**Research basis:** `docs/superpowers/research/2026-06-11-prompt-performance.md` recommendation 2 (few-shot from attached cases). Discharges part of tracker issue `crucible-2ce`.
**Scope:** `src/Crucible/Skill.hs` (examples field, `withExamples`, `examplesFromTests`, `prompt` rendering), `test/Spec.hs`, `app/Main.hs` (demo), `docs/typed-functions.md` (new "Composing prompts" section).

## Motivation

Prompts in crucible already compose through the host language (shared `Text`
fragments, instruction-transformer functions, monadic skill chaining), but
none of that is documented, and the highest-value composition from the
prompt-performance research has no library support: few-shot examples. A
skill's `Exactly` test cases are typed input/output pairs encoded by the same
codecs the prompt uses, which makes them examples that cannot drift from the
schema. The trap is contamination: a case that appears in the prompt scores
meaninglessly in `testSkill` (the model can copy it). The design prevents
that structurally.

## Decisions taken during design

- Example source: both forms. `withExamples [(i, o)]` is the explicit
  primitive; `examplesFromTests n` MOVES the first n `Exactly` cases from
  `tests` into `examples` (a case is taught or tested, never both).
- Placement: real User/Assistant message pairs before the live exchange
  (highest fidelity; the model sees a perfect exchange including the output
  contract). The token cost (instruction repeats per pair) is documented.
- Docs land as a "Composing prompts" section in `typed-functions.md`, not a
  new page.

## Design

### 1. Skill surface (`src/Crucible/Skill.hs`)

```haskell
data Skill i o = Skill
  { name        :: Text
  , instruction :: i -> Text
  , input       :: JSONCodec i
  , output      :: JSONCodec o
  , retries     :: Int
  , tests       :: [Case i o]
  , examples    :: [(i, o)]   -- few-shot exchanges rendered into the prompt
  }
```

The `skill` builder defaults `examples = []`.

```haskell
-- | Replace the skill's few-shot examples (rendered oldest first).
withExamples :: [(i, o)] -> Skill i o -> Skill i o

-- | Move the first n 'Exactly' test cases into the examples (appending to
-- any existing examples, preserving tests order). Moving rather than copying
-- means a case is either taught or tested, never both, so 'testSkill'
-- scores stay meaningful with no special handling. Non-'Exactly' cases are
-- skipped and remain tests. Fewer than n available moves what exists;
-- n <= 0 moves nothing.
examplesFromTests :: Int -> Skill i o -> Skill i o
```

Semantics of `examplesFromTests n`:

- Walk `tests` in order. A case `Case i' _ (Exactly o')` is moved (becomes
  `(i', o')` appended to `examples`) until n have been moved; all other
  cases, and `Exactly` cases beyond the first n, remain in `tests` in their
  original relative order.
- `withExamples` REPLACES the examples list; `examplesFromTests` APPENDS.

### 2. Prompt rendering

`prompt sk i` becomes:

```
System:    Respond ONLY with JSON matching this schema: <schema>   (unchanged)
-- one pair per example, in order:
User:      <instruction applied to the example input>
           Input: <example input rendered via the input codec>
Assistant: <example output encoded via the output codec>           (compact JSON)
-- then the live exchange:
User:      <instruction applied to the live input>
           Input: <live input rendered via the input codec>
```

- The example User turns use the SAME template as the live User turn (the
  existing `[text| ${task} ... Input: ${rendered} |]` body), applied to the
  example input.
- The Assistant turns are `jsonText (toJSONVia outC exampleOutput)`: exactly
  the reply a perfect model would produce, demonstrating the output contract.
- Zero examples produce a message list identical to today's, byte for byte.
  Every existing skill, test, cassette, and the retry loop are untouched
  (`call` builds on whatever `prompt` returns; the retry appends after it).

### 3. Edge semantics

- No enforced cap on example count; the manual recommends 3 to 5 (research
  guidance) and notes the token cost: the instruction text repeats once per
  example pair.
- Example order is render order. Explicit lists render as given; moved test
  cases render in their original `tests` order.
- `prompt` remains the single source of message shape, so recording,
  cassettes, and the streaming path all carry exampled prompts with no
  changes elsewhere.
- `testSkill` needs no changes: it runs `sk.tests`, which no longer contains
  moved cases.

### 4. Manual: "Composing prompts" in `docs/typed-functions.md`

New section after "Writing instructions", covering in order:

1. **Shared fragments.** Prompts are `Text`; define house style or domain
   context once and splice it with `${...}`.
2. **Instruction transformers.** `(i -> Text) -> (i -> Text)` wrappers
   compose with `.`; show a `withAudience` example that APPENDS the
   constraint (instructions near the end are followed more reliably).
3. **Skill chaining.** `call` composes monadically; show the
   `call extract doc >>= either (pure . Left) (call summarise)` pattern.
4. **Few-shot examples.** `withExamples` / `examplesFromTests`, the
   User/Assistant pair rendering, why moving beats copying (contamination),
   the 3-5 guidance, and the token-cost note.

House style throughout: no emdashes, no hype words, no mention of the
sibling project manifest.

### 5. Demo (`app/Main.hs`)

The existing `classify` skill gains one example pair via `withExamples`
(e.g. `("The packaging was damaged but the product works.", Sentiment "neutral")`),
so the live smoke exercises the exampled prompt path against a real provider.
Expected output is unchanged ("typed fn: positive").

## Testing (hermetic via runLLMScripted unless noted)

- `prompt` with one example yields exactly four messages with roles
  System/User/Assistant/User; the Assistant turn equals the codec-encoded
  example output; the first User turn contains the instruction applied to
  the EXAMPLE input and its rendered JSON.
- Zero-example regression pin: a skill without examples produces the same
  messages as before this change (assert count and per-message containment,
  matching the existing prompt tests' style).
- `examplesFromTests 1` on a skill with tests `[Exactly, Rubric, Exactly]`
  moves only the first `Exactly`: one example pair; two remaining tests with
  the `Rubric` intact.
- `examplesFromTests` with n larger than available moves what exists;
  `examplesFromTests 0` moves nothing.
- `call` on an exampled skill under `runLLMScripted` decodes normally.
- `testSkill` after `examplesFromTests` scores only the remaining cases
  (scripted-reply counting: the moved case consumes no replies).
- Live smoke via the demo before merge.

## Non-goals

- Structured or sectioned instructions (waits for an `improveSkill` cycle;
  the opaque `i -> Text` stays).
- Dynamic per-input example selection.
- A pipeline combinator for skill chaining (monadic composition suffices).
- Example support on the Chat/tool-agent path.
