# Structured Instructions + improveSkill Design Spec

**Date:** 2026-06-11
**Status:** Approved design, pending implementation
**Research basis:** `docs/superpowers/research/2026-06-11-prompt-performance.md` recommendations 3 (prompt tweaks) and 5 (testSkill-driven optimization); closes out the deferred remainder of tracker issue `crucible-2ce` (the schema-field-docs tweak stays out; `genericCodec` has no doc source to surface).
**Scope:** `src/Crucible/Skill.hs` (Instruction, slots, prompt assembly, tweaks), new `src/Crucible/Skill/Improve.hs`, `test/Spec.hs`, `docs/typed-functions.md`, `app/Main.hs` (demo round).

## Motivation

`instruction :: i -> Text` is opaque: nothing can inspect or revise a
skill's prompt programmatically, so the research's highest-leverage
remaining item (an optimizer that hill-climbs the instruction against the
skill's own test cases) has nothing to mutate. Separately, three measured
prompt tweaks (machine-parse motivation, input delimiters, trailing format
reminder) were deferred because they rewrite the core prompt contract; they
land here, in the same cycle that already has to touch prompt assembly.

## Decisions taken during design

- Full structured instruction: `Instruction i { preamble, task, constraints }`
  replaces the bare function as the `Skill.instruction` field type. The
  `skill` builder keeps its exact signature (wraps the function with empty
  slots), so existing code and the manual's idioms compile unchanged.
- Optimizer fitness: strict `meanScore` improvement (finer gradient than
  passRate; passRate still reported per step).
- Reflector context: failing cases only, with originals (full rendered
  prompt, output, rationale) re-injected every round.
- Bundled tweaks: machine-parse line (System, after the schema), `<input>`
  delimiters, trailing format reminder (User, last). Schema field docs
  excluded.

## Design

### 1. `Instruction` and slots (`src/Crucible/Skill.hs`)

```haskell
-- | A skill's instruction, structured so tooling can revise the prompt
-- around a fixed task. 'preamble' renders before the task; 'constraints'
-- renders after the input (instructions near the end are followed most
-- reliably). Both default to empty and are the slots 'improveSkill'
-- mutates; 'task' is the core instruction and is never machine-edited.
data Instruction i = Instruction
  { preamble    :: Text
  , task        :: i -> Text
  , constraints :: Text
  }

data Skill i o = Skill
  { name        :: Text
  , instruction :: Instruction i   -- was: i -> Text
  , input       :: JSONCodec i
  , output      :: JSONCodec o
  , retries     :: Int
  , tests       :: [Case i o]
  , examples    :: [(i, o)]
  }
```

Builders and combinators:

```haskell
-- unchanged signature; wraps the function with empty slots
skill :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> Skill i o

-- declare all three parts
skillWith :: Text -> JSONCodec i -> JSONCodec o -> Instruction i -> Skill i o

withPreamble    :: Text -> Skill i o -> Skill i o   -- replaces the slot
withConstraints :: Text -> Skill i o -> Skill i o   -- replaces the slot
```

Export `Instruction (..)`, `skillWith`, `withPreamble`, `withConstraints`
alongside the existing surface. Breaking change is limited to the
`instruction` field's type; the only readers are `prompt`'s internals
(updated here). `call`, `withRetries`, `withTests`, `withExamples`,
`examplesFromTests`, `withReasoning`, `testSkill` are untouched in
signature and semantics.

### 2. Prompt assembly with the bundled tweaks

System message (first line unchanged so existing prefix assertions hold;
motivation line appended after the schema):

```
Respond ONLY with JSON matching this schema:
<schema>
Your reply is parsed by a machine; any text outside the JSON is an error.
```

User message template (used for the live exchange AND for each few-shot
example pair, which therefore inherit the new shape automatically):

```
<preamble, when non-empty, followed by a blank line>
<task applied to the input>

<input>
<rendered input JSON>
</input>

<constraints, when non-empty, followed by a blank line>
Respond with JSON only; your reply is parsed by a machine.
```

Empty slots contribute nothing (no stray blank lines: the preamble block
and the constraints block are omitted entirely when empty). The retry
reprompt and `withReasoning` are unchanged. `Skill.prompt` remains the
single source of message shape, so cassettes/recording/streaming follow.

### 3. `Crucible.Skill.Improve` (new module)

Leaf module; imports `Crucible.Skill`, `Crucible.Eval`, `Crucible.Codec`,
`Crucible.Codec.Generic`. No new dependencies; no cycles (nothing imports
it).

```haskell
-- | One optimizer round's record.
data ImproveStep = ImproveStep
  { round'      :: Int
  , accepted    :: Bool
  , passRate    :: Double   -- of that round's candidate
  , meanScore   :: Double
  , preamble    :: Text     -- the proposed slots
  , constraints :: Text
  }
  deriving (Eq, Show)

improveSkill :: (Eq o, LLM :> es)
             => Int            -- rounds (budget)
             -> (o -> Text)    -- render, for judging and the failure digest
             -> Skill i o
             -> Eff es (Skill i o, [ImproveStep])
```

Algorithm (GEPA-lite hill-climb):

1. If `sk.tests` is empty, return `(sk, [])` immediately.
2. Score the current best with `testSkill render`. If every case passes
   (passRate >= 1.0) or the budget is exhausted, return the best skill and
   the chronological steps.
3. Build the failure digest (Text):
   - the current `preamble` and `constraints`, labelled as the only parts
     that may be revised (the task body is fixed);
   - for each failing case (score value < 1.0): its name, the FULL rendered
     prompt (`prompt best input`, one block per message with the role
     labelled), the rendered output, and the score rationale.
   Originals are re-injected every round; the reflector never works from
   its own prior summaries. (This is an optimizer, not a judge protocol,
   but it follows the no-closed-loop discipline anyway.)
4. The reflector is itself a skill:

   ```haskell
   data Revision = Revision { preamble :: Text, constraints :: Text }
     deriving (Show, Generic)
   instance HasCodec Revision where codec = genericCodec
   -- reflector :: Skill Text Revision, instruction: revise the preamble and
   -- constraints so the failing cases pass, without contradicting the task;
   -- built with `skill` so schema injection, tolerant decode, and the
   -- schema-restating retry come free.
   ```

   `call reflector digest`:
   - `Left _` (decode failure after retries): record the round as a
     rejected `ImproveStep` carrying the CURRENT slots and the current
     scores; continue to the next round.
   - `Right rev`: build the candidate
     (`withPreamble rev.preamble (withConstraints rev.constraints best)`),
     score it with `testSkill`, and accept iff its meanScore is STRICTLY
     greater than the current best's. Record the step (accepted or not)
     with the candidate's passRate/meanScore and the proposed slots.
5. Rounds count reflector attempts, accepted or not.

Cost note (haddock + manual): each round costs one full `testSkill` run
(cases x judge calls, doubled by verdict repairs) plus one reflection call.

Honesty rails (haddock + manual, non-negotiable phrasing):

- Optimizing against an LLM judge is Goodhart territory: calibrate the
  judge (`calibrate`, kappa > 0.6) BEFORE trusting the optimizer's gains.
- Keep held-out cases OUT of `sk.tests`; verify the winner against the
  holdout by hand. `improveSkill` does no splitting itself.
- The accepted slots are text the reflector wrote; review them before
  committing a skill to production.

### 4. Manual (`docs/typed-functions.md`)

- "Skill and skill" section: introduce `Instruction`, `skillWith`,
  `withPreamble`, `withConstraints`; note `skill` is unchanged.
- "Composing prompts": note the transformer idiom still applies to the
  task function; slots are the machine-editable layer around it.
- New "Improving a skill" section: `improveSkill` signature, the loop, the
  cost note, and the honesty rails (calibrate first, hold out cases,
  review accepted slots).
- Update the prompt-shape description in "Calling a typed skill" /
  "Schema injection" for the motivation line, `<input>` delimiters, and
  trailing reminder.
- House style: no emdashes, no hype words, no manifest mentions.

### 5. Demo (`app/Main.hs`)

One `improveSkill 1` round over a deliberately weak skill (e.g. a classify
variant whose preamble is empty and whose test case demands a strict
one-word answer the base prompt tends to miss), printing each
`ImproveStep`'s accepted flag and scores. Keep it to a handful of lines;
live smoke proves the reflector round-trips against a real provider.

## Testing (hermetic via runLLMScripted unless noted)

- Prompt assembly: slots render in order (preamble before task, constraints
  after the `</input>` line, built-in reminder last); `<input>`/`</input>`
  delimiters wrap the rendered JSON; the System message starts with the
  unchanged first line and contains the motivation line; empty slots add no
  blank-line residue (assert the exact User text for a slot-less skill).
- Builder compat: a `skill`-built value has empty slots; `withPreamble` /
  `withConstraints` replace them; `skillWith` carries all three.
- Few-shot pairs inherit the new template (example User turn contains the
  delimiters and reminder).
- `improveSkill` end-to-end: a skill with one `Exactly` test case; round 1
  baseline fails (scripted wrong answer), reflector proposes slots
  (scripted Revision JSON), candidate passes (scripted right answer);
  result: returned skill carries the new slots, one accepted step with the
  right scores.
- Rejection: candidate scores equal to baseline -> step recorded with
  accepted = False, returned skill keeps the original slots.
- Reflector junk through its retries -> rejected step, loop continues to
  the next round (scripted: junk x3 for retries=2 reflector, then a valid
  next round).
- Empty `tests` -> immediate `(sk, [])` with zero LLM calls (leftover-reply
  check).
- All-passing baseline -> immediate return after one testSkill run, no
  reflection call.
- Existing prompt assertions (prefix/infix style) keep passing; update any
  that pinned the old User-message text exactly.
- Live smoke via the demo before merge.

## Non-goals

- Schema field docs in `schemaText` (no doc source in genericCodec).
- Mutating the task function, examples, or codecs from the optimizer.
- Train/holdout splitting inside `improveSkill`.
- Population-based or multi-candidate search (one candidate per round).
- Optimizing Chat/tool-agent prompts.
