# Prompt Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Few-shot examples on skills (`withExamples` / `examplesFromTests` with contamination-proof case moving, rendered as User/Assistant pairs in `prompt`), plus a "Composing prompts" manual section documenting the existing composition idioms.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-11-prompt-composition-design.md`. Everything code-side lands in `src/Crucible/Skill.hs` (one new field, two combinators, `prompt` rendering); zero examples renders byte-identical messages to today, so nothing else in the library moves. Docs land in `docs/typed-functions.md`.

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec, neat-interpolation. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). On exit 137 retry once; second 137 = BLOCKED. Judge success by exit status or the "1 test suite(s) passed" line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/prompt-composition` from master; work in place, no worktrees.
- House style: prefix-free fields, `OverloadedRecordDot`, prompts via `[text| |]` (interpolated values must be `Text` identifiers). Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- `src/Crucible/Skill.hs` currently: `Skill {name, instruction, input, output, retries, tests}`, builder `skill` (retries 2, tests []), `withRetries`, `withTests`, `prompt` (System schema message + one User message), `call` (retry loop over `prompt`), `testSkill`. It already imports `Crucible.Eval (Case (..), Expectation (..), Report, runEval)` so `Exactly` is in scope.
- `Message` (from `Crucible.LLM`) is `Message Role Text` with Role in {System, User, Assistant, Tool}; it derives Eq, so tests can compare messages directly.
- `test/Spec.hs` has `classifyFn :: Skill T.Text T.Text` (`skill "classify" C.str C.str (\s -> "Classify the sentiment of: " <> s)`) and imports `Crucible.Skill (Skill (..), skill, withRetries, withTests, prompt, call, testSkill)`.

---

### Task 1: examples on Skill + pair rendering + tests

**Files:**
- Modify: `src/Crucible/Skill.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: extend the record, builder, and exports** in `src/Crucible/Skill.hs`:

Export list gains `withExamples` and `examplesFromTests` (after `withTests`). The record and builder become:

```haskell
-- | A declared LLM skill: a task instruction plus input/output codecs.
data Skill i o = Skill
  { name        :: Text        -- ^ for introspection / evals
  , instruction :: i -> Text   -- ^ the task (may reference input fields)
  , input       :: JSONCodec i -- ^ used to render the input value into the prompt
  , output      :: JSONCodec o -- ^ schema injection + tolerant decode
  , retries     :: Int         -- ^ decode-failure retries
  , tests       :: [Case i o]  -- ^ attached test cases; run with 'testSkill'
  , examples    :: [(i, o)]    -- ^ few-shot exchanges rendered into the prompt
  }

-- | Construct a 'Skill'; @retries@ defaults to 2, @tests@ and @examples@ to none.
skill :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> Skill i o
skill n inC outC instr =
  Skill { name = n, instruction = instr, input = inC, output = outC
        , retries = 2, tests = [], examples = [] }
```

- [ ] **Step 2: add the combinators** (after `withTests`):

```haskell
-- | Replace the skill's few-shot examples. Each pair renders as a real
-- User/Assistant exchange before the live one (see 'prompt'); the Assistant
-- turn is the output encoded via the output codec, so examples demonstrate
-- the exact reply contract and cannot drift from the schema. Three to five
-- examples capture most of the benefit; the instruction text repeats once
-- per pair, so each example costs prompt tokens.
withExamples :: [(i, o)] -> Skill i o -> Skill i o
withExamples exs fn = fn { examples = exs }

-- | Move the first @n@ 'Exactly' test cases into the examples (appending to
-- any existing examples, preserving order). Moving rather than copying means
-- a case is either taught or tested, never both, so 'testSkill' scores stay
-- meaningful with no special handling. Non-'Exactly' cases are skipped and
-- remain tests; fewer than @n@ available moves what exists; @n <= 0@ moves
-- nothing.
examplesFromTests :: Int -> Skill i o -> Skill i o
examplesFromTests n fn = fn { examples = fn.examples ++ moved, tests = kept }
  where
    (moved, kept) = go (max 0 n) fn.tests
    go :: Int -> [Case i o] -> ([(i, o)], [Case i o])
    go 0 cs = ([], cs)
    go _ [] = ([], [])
    go k (Case i' _ (Exactly o') : cs) =
      let (ms, ks) = go (k - 1) cs in ((i', o') : ms, ks)
    go k (c : cs) =
      let (ms, ks) = go k cs in (ms, c : ks)
```

(If the local `go` signature trips over scoped type variables, add `{-# LANGUAGE ScopedTypeVariables #-}` is NOT available implicitly here without `forall`; simplest fix is to delete the local signature and let GHC infer.)

- [ ] **Step 3: rewrite `prompt`** to render example pairs (replacing the current two-message body; the System and User templates are character-identical to today's):

```haskell
-- | The seed messages 'call' sends for a given input: a System message
-- carrying the output-schema contract, one User/Assistant pair per attached
-- example (the User turn is the instruction applied to the example input;
-- the Assistant turn is the codec-encoded example output, a perfect reply),
-- and finally the live User message. With no examples this is exactly the
-- two-message prompt it has always been. Exposed for introspection/debugging
-- and tested directly.
prompt :: Skill i o -> i -> [Message]
prompt sk inp =
  systemMsg : concatMap pair sk.examples ++ [userMsg inp]
  where
    schema = schemaText sk.output
    systemMsg = Message System [text|
      Respond ONLY with JSON matching this schema:
      ${schema}|]
    userMsg i' =
      let task     = sk.instruction i'
          rendered = jsonText (toJSONVia sk.input i')
      in Message User [text|
      ${task}

      Input:
      ${rendered}|]
    pair (ei, eo) = [userMsg ei, Message Assistant (jsonText (toJSONVia sk.output eo))]
```

Note the switch from field-pattern matching to record-dot (`sk.output`, `sk.instruction`, `sk.input`): `prompt`'s old `Skill{output = outC, ...}` pattern must go, and `call`'s internal use (`loop rets (prompt fn inp)`) is unchanged. Operator note: `a : b ++ c` parses as `a : (b ++ c)`, which is what we want.

- [ ] **Step 4: build.** `nix develop . --command timeout -s KILL 300 zinc build` → exit 0. (`call`, `testSkill`, app/Main.hs, and all tests compile unchanged: the new field has a default in `skill` and no other construction site builds `Skill` positionally.)

- [ ] **Step 5: add six checks to `test/Spec.hs`** (extend the Skill import with `withExamples, examplesFromTests`; insert after the existing `prompt:` checks):

```haskell
  -- prompt composition: few-shot examples
  , check "prompt: example renders as a User/Assistant pair"
      (4, Just (Message Assistant "\"positive\""), True)
      (let sk = withExamples [("I love it", "positive")] classifyFn
           msgs = prompt sk "meh"
       in ( length msgs
          , case msgs of (_ : _ : a : _) -> Just a; _ -> Nothing
          , case msgs of
              (_ : Message User u : _) ->
                T.isInfixOf "Classify the sentiment of: I love it" u
                  && T.isInfixOf "\"I love it\"" u
              _ -> False ))
  , check "prompt: zero examples keeps the two-message shape"
      2
      (length (prompt classifyFn "hi"))
  , check "examplesFromTests: moves Exactly cases, keeps the rest"
      (1, 2)
      (let sk = examplesFromTests 1
                  (withTests [ Case "a" "t1" (Exactly "A")
                             , Case "b" "t2" (Rubric "r")
                             , Case "c" "t3" (Exactly "C") ] classifyFn)
       in (length sk.examples, length sk.tests))
  , check "examplesFromTests: caps at available; zero moves nothing"
      ((2, 1), (0, 3))
      (let base = withTests [ Case "a" "t1" (Exactly "A")
                            , Case "b" "t2" (Rubric "r")
                            , Case "c" "t3" (Exactly "C") ] classifyFn
           big  = examplesFromTests 5 base
           zero = examplesFromTests 0 base
       in ((length big.examples, length big.tests), (length zero.examples, length zero.tests)))
  , check "call: exampled skill still decodes"
      (Right "positive")
      (runPureEff (runLLMScripted ["\"positive\""]
        (call (withExamples [("I love it", "positive")] classifyFn) "meh")))
  , check "testSkill: moved cases consume no replies"
      (1.0, "leftover")
      (runPureEff (runLLMScripted ["\"B\"", "leftover"]
        (do rep <- testSkill id (examplesFromTests 1
                     (withTests [ Case "a" "ex" (Exactly "A")
                                , Case "b" "kept" (Exactly "B") ] classifyFn))
            extra <- complete []
            pure (rep.passRate, extra))))
```

(The existing `prompt: system message carries the output schema` and `prompt: user message carries instruction + rendered input` checks double as the zero-example content pin; the new length check pins the shape.)

- [ ] **Step 6: run the suite.** `nix develop . --command timeout -s KILL 300 zinc test` → `1 test suite(s) passed` (189 ok lines).

- [ ] **Step 7: commit.**

```bash
git add src/Crucible/Skill.hs test/Spec.hs
git commit -m "$(printf 'feat(skill): few-shot examples (withExamples, examplesFromTests, pair rendering)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: "Composing prompts" manual section

**Files:**
- Modify: `docs/typed-functions.md` (new section after "Writing instructions")

- [ ] **Step 1: write the section.** Read `src/Crucible/Skill.hs` first and mirror real signatures. Insert `## Composing prompts` between "Writing instructions" and "Schema injection", covering in order, each with a compact snippet:

1. **Shared fragments**: instructions are `Text`, so a house style or domain
   context is a value spliced with `${...}`:

```haskell
houseStyle :: Text
houseStyle = [text|
  Be terse. Do not use markdown. Never apologise.|]

classify = skill "classify" str codec $ \review ->
  [text|
    ${houseStyle}

    Classify the sentiment of this product review: ${review}|]
```

2. **Instruction transformers**: `(i -> Text) -> (i -> Text)` wrappers compose
   with `.`; APPEND constraints (instructions near the end are followed more
   reliably):

```haskell
withAudience :: Text -> (i -> Text) -> (i -> Text)
withAudience aud instr = \i ->
  let body = instr i
  in [text|
    ${body}

    Write for this audience: ${aud}|]
```

3. **Skill chaining**: `call` composes monadically; the only wrinkle is
   threading the `Either`:

```haskell
extractThenSummarise doc =
  call extract doc >>= either (pure . Left) (call summarise)
```

4. **Few-shot examples**: `withExamples [(i, o)]` and `examplesFromTests n`;
   each pair renders as a real User/Assistant exchange before the live one,
   with the Assistant turn encoded by the output codec (examples cannot
   drift from the schema). Explain the move-not-copy rule: a case in the
   prompt would score meaninglessly in `testSkill`, so `examplesFromTests`
   removes what it moves. Three to five examples capture most of the
   benefit; the instruction repeats once per pair, so examples cost tokens.

House style: no emdashes or endashes, no hype words, no mention of the
sibling project manifest.

- [ ] **Step 2: sweep + commit.** `grep -n '—\|–' docs/typed-functions.md` empty.

```bash
git add docs/typed-functions.md
git commit -m "$(printf 'docs(site): composing prompts (fragments, transformers, chaining, few-shot)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: demo example + live smoke + merge

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: add an example pair to the demo's classify skill.** In `app/Main.hs`, extend the Skill import with `withExamples` and wrap the existing definition:

```haskell
      let classify :: Skill T.Text Sentiment
          classify = withExamples
            [ ("The packaging was damaged but the product works.", Sentiment "neutral") ]
            (skill "classify" str codec
              (\s -> [text|Classify the sentiment as positive, negative, or neutral for: ${s}|]))
```

- [ ] **Step 2: build + live smoke.** (Keys in `.env`, gitignored; NEVER print them.)

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 300 .zinc/build/crucible-anthropic'
```

Expected: output unchanged, including `typed fn: positive` (now produced through an exampled prompt) and `openai typed fn: positive`.

- [ ] **Step 3: commit.**

```bash
git add app/Main.hs
git commit -m "$(printf 'demo: classify skill carries a few-shot example\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

- [ ] **Step 4: merge + publish.** Full suite once more, then `superpowers:finishing-a-development-branch` (the user historically picks "merge back to master locally"); after merge: suite on master, `git push`, confirm the Pages build goes `built`. Update tracker: `bd update crucible-2ce --notes="Few-shot from cases shipped (withExamples/examplesFromTests). Remaining: reasoning-field convention, prompt tweaks, retry contract restatement, improveSkill."`

---

## Self-Review

**1. Spec coverage:** examples field + builder default → Task 1 Step 1. withExamples (replace) / examplesFromTests (append, move-only-Exactly, order, caps, n<=0) → Task 1 Step 2 + checks 3-4. Pair rendering with identical templates + zero-example identity → Task 1 Step 3 + checks 1-2. call/retry untouched → check 5. testSkill contamination guard → check 6. Manual section with the four idioms → Task 2. Demo + live smoke → Task 3. Non-goals absent. ✅

**2. Placeholder scan:** none; Task 2 gives the snippets verbatim plus a content brief for the few-shot prose, the established doc-task pattern. ✅

**3. Type consistency:** `examples :: [(i, o)]` consistent across record/combinators/prompt/tests; `withExamples exs fn` replaces while `examplesFromTests n fn` appends (matches spec); `prompt` returns `[Message]` with `Message Assistant (jsonText ...)` matching check 1's expected `Message Assistant "\"positive\""` (str codec encodes to a quoted JSON string); `classifyFn` is `Skill Text Text` so example pairs are `(Text, Text)`. ✅
