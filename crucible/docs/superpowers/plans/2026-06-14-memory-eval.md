# memoryLift Ablation Eval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Crucible.Memory.Eval` with `renderMemories`, `withMemories`, `memoryLift`, and `liftDelta` so a memory's value to a skill becomes a measurable ablation delta.

**Architecture:** A new module decoupled from the `Memory` effect. `withMemories` appends rendered memory content to a skill's instruction preamble via the existing `withPreamble`; `memoryLift` runs `testSkill` on both the bare and lifted skill and returns both `Report`s; `liftDelta` reduces the pair to `(passRate delta, meanScore delta)`. Builds on `Crucible.Skill` (testSkill, withPreamble) and `Crucible.Eval` (Report) only.

**Tech Stack:** GHC 9.12.2, effectful, autodocodec, neat-interpolation; zinc build (`nix develop . --command timeout -s KILL 300 zinc build|test`).

**Spec:** `docs/superpowers/specs/2026-06-14-memory-eval-design.md`

---

### Task 1: `Crucible.Memory.Eval` module with `renderMemories` and `withMemories`

**Files:**
- Create: `src/Crucible/Memory/Eval.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Write the module skeleton and `renderMemories`/`withMemories`**

Create `src/Crucible/Memory/Eval.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | Measuring whether a memory pays rent. 'memoryLift' runs a skill's
-- attached test cases with and without candidate memories rendered into the
-- preamble and returns both reports; 'liftDelta' reduces the pair to the
-- pass-rate and mean-score deltas. Decoupled from the 'Crucible.Memory'
-- effect: the candidates are a plain '[MemoryItem]', so this needs only LLM
-- and Embed (via 'Crucible.Skill.testSkill'). 'withMemories' also stands
-- alone for running a skill with recalled context in production.
module Crucible.Memory.Eval
  ( renderMemories
  , withMemories
  , memoryLift
  , liftDelta
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Effectful

import Crucible.Decode (DecodeError)
import Crucible.Embed (Embed)
import Crucible.Eval (Report (..))
import Crucible.LLM (LLM)
import Crucible.Memory (MemoryItem (..))
import Crucible.Skill (Skill (..), Instruction (..), testSkill, withPreamble)

-- | Render memory contents as a labelled preamble block. Content only;
-- kind/tags/source are internal taxonomy and are not rendered. Empty list
-- renders the empty string.
renderMemories :: [MemoryItem] -> Text
renderMemories [] = ""
renderMemories ms =
  "Relevant memories from past sessions:\n"
    <> T.concat ["- " <> m.content <> "\n" | m <- ms]

-- | Append rendered memories to a skill's instruction preamble (after any
-- existing preamble, separated by a blank line). An empty list returns the
-- skill unchanged.
withMemories :: [MemoryItem] -> Skill i o -> Skill i o
withMemories [] sk = sk
withMemories ms sk = withPreamble newPreamble sk
  where
    existing    = sk.instruction.preamble
    rendered    = renderMemories ms
    newPreamble = if T.null existing then rendered
                                     else existing <> "\n\n" <> rendered
```

Note: use `T.concat [... <> "\n"]` not `T.unlines` for deterministic trailing-newline behavior consistent with the codebase's prompt-assembly idiom.

- [ ] **Step 2: Add the failing tests to `test/Spec.hs`**

Find the memory test group (search for `runMemoryPure` or `memoryItemCodec` tests). Add a new group near it. Build `MemoryItem`s directly (the constructor is exported via `MemoryItem (..)`):

```haskell
  describe "Memory.Eval renderMemories/withMemories" $ do
    let mi c = MemoryItem (MemoryId 0) Semantic c [] Curated 0
        m1 = mi "The user prefers dark mode."
        m2 = mi "The user's name is Gareth."

    it "renderMemories lists content with a header, in order" $
      renderMemories [m1, m2] `shouldBe`
        "Relevant memories from past sessions:\n\
        \- The user prefers dark mode.\n\
        \- The user's name is Gareth.\n"

    it "renderMemories [] is empty" $
      renderMemories [] `shouldBe` ""

    it "withMemories appends to an empty preamble" $ do
      let sk  = skill "s" str str (const "do it")
          sk' = withMemories [m1] sk
      sk'.instruction.preamble `shouldBe` renderMemories [m1]

    it "withMemories appends after an existing preamble" $ do
      let sk  = withPreamble "BASE" (skill "s" str str (const "do it"))
          sk' = withMemories [m1] sk
      sk'.instruction.preamble `shouldBe` ("BASE\n\n" <> renderMemories [m1])

    it "withMemories [] leaves the preamble unchanged" $ do
      let sk  = withPreamble "BASE" (skill "s" str str (const "do it"))
          sk' = withMemories [] sk
      sk'.instruction.preamble `shouldBe` "BASE"
```

Ensure the test file imports what it needs: `Crucible.Memory.Eval` (renderMemories, withMemories), `Crucible.Memory` (MemoryItem (..), MemoryId (..), MemoryKind (..), Provenance (..)), `Crucible.Skill` (skill, withPreamble, Skill (..), Instruction (..)), `Crucible.Codec` (str). Add only the imports not already present; check the existing import block first to avoid duplicate-import errors.

- [ ] **Step 3: Build and run the suite**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the new five examples pass; existing suite still passes (judge by the "test suite(s) passed" line or exit status, not a pipeline tail). Retry once on exit 137 (GHC iserv flake).

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/Memory/Eval.hs test/Spec.hs
git commit -m "feat(memory): renderMemories + withMemories (Eval module)"
```

---

### Task 2: `memoryLift` and `liftDelta`

**Files:**
- Modify: `src/Crucible/Memory/Eval.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Add `memoryLift` and `liftDelta`**

Append to `src/Crucible/Memory/Eval.hs` (the `Report` import already brings `passRate`/`meanScore` via `Report (..)`):

```haskell
-- | Ablation: run the skill's attached test cases without memories
-- (baseline) and with them (lifted), returning both reports as
-- (baseline, lifted). Needs only LLM + Embed (via 'testSkill'); decoupled
-- from the Memory effect, so the candidates can come from 'recall' or be a
-- literal proposed memory under review.
memoryLift :: (Eq o, LLM :> es, Embed :> es)
           => (o -> Text) -> Skill i o -> [MemoryItem]
           -> Eff es (Report i (Either DecodeError o), Report i (Either DecodeError o))
memoryLift render sk ms = do
  base   <- testSkill render sk
  lifted <- testSkill render (withMemories ms sk)
  pure (base, lifted)

-- | The headline deltas of an ablation, lifted minus baseline:
-- (passRate delta, meanScore delta). Positive means the memories paid rent.
liftDelta :: (Report i a, Report i a) -> (Double, Double)
liftDelta (base, lifted) =
  ( lifted.passRate  - base.passRate
  , lifted.meanScore - base.meanScore )
```

Add `memoryLift` and `liftDelta` to the module export list.

- [ ] **Step 2: Add the failing tests to `test/Spec.hs`**

`liftDelta` is pure; build `Report`s with empty `results` and explicit `passRate`/`meanScore` (the `Report` constructor is exported via `Report (..)`). The phantom `i`/`a` are unconstrained, so annotate to a concrete type, e.g. `Report () ()`:

```haskell
  describe "Memory.Eval liftDelta/memoryLift" $ do
    let rep pr ms = Report [] pr ms :: Report () ()

    it "liftDelta is lifted minus baseline" $
      liftDelta (rep 0.5 0.4, rep 1.0 0.9) `shouldBe` (0.5, 0.5)

    it "liftDelta is negative when memories hurt" $
      liftDelta (rep 1.0 1.0, rep 0.5 0.5) `shouldBe` (-0.5, -0.5)

    it "liftDelta of equal reports is zero" $
      liftDelta (rep 0.7 0.7, rep 0.7 0.7) `shouldBe` (0.0, 0.0)
```

For `memoryLift`, run under `runLLMScripted` (find its name/signature in the existing LLM tests) with `Crucible.Embed.none`, a skill with one `Exactly` test case, and enough canned replies for two runs (baseline + lifted = 2 calls if the skill `call` succeeds first try; provide the same canned reply twice). Assert both arms produced a report and `liftDelta` is `(0, 0)` for identical canned outputs:

```haskell
    it "memoryLift runs both arms; identical outputs give zero delta" $ do
      let c   = -- the test case: Case input "name" (Exactly expectedOutput)
                ...
          sk  = withTests [c] (skill "s" str str (const "answer"))
          mems = [ MemoryItem (MemoryId 0) Semantic "hint" [] Curated 0 ]
          prog = memoryLift id sk mems
      (base, lifted) <- runEffWith prog   -- discharge LLM (scripted, with 2 canned replies) + Embed.none
      liftDelta (base, lifted) `shouldBe` (0.0, 0.0)
```

Replace the `...`/`runEffWith` placeholders by copying the exact scripted-LLM + Embed.none discharge pattern already used by the skill/eval tests in this file (search for `runLLMScripted` and `Embed.none`/`runEmbedNone`). The canned reply must be the JSON the output codec decodes to `expectedOutput` so the case passes in both arms; with `str` output and `Exactly "X"`, the reply is the JSON string `"X"` encoded as the skill expects (match how other scripted skill tests format replies). Provide the canned reply list with two entries (one per arm).

- [ ] **Step 3: Build and run the suite**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: new examples pass; full suite green. Retry once on exit 137.

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/Memory/Eval.hs test/Spec.hs
git commit -m "feat(memory): memoryLift ablation + liftDelta"
```

---

### Task 3: Live demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a memoryLift demo to the Anthropic-key-gated block**

Find the existing key-gated demo block (search for `consolidate` or `runMemoryFile`, added in the consolidation cycle; follow the same style and the same `getEnv`/key guard). Add a self-contained demo:

```haskell
-- A skill whose single test case can only be answered from a memory.
-- Baseline misses; lifting the memory in should make it pass.
let editorSkill =
      withTests
        [ Case "What is the user's preferred editor? Answer with one word."
               "editor"
               (Predicate (\o -> "neovim" `T.isInfixOf` T.toLower o)) ]
        (skill "recall-editor" str str id)
    candidateMems =
      [ MemoryItem (MemoryId 0) Semantic
          "The user's preferred editor is Neovim." [] Curated 0 ]
(base, lifted) <- memoryLift id editorSkill candidateMems
let (dPass, dScore) = liftDelta (base, lifted)
liftIO $ TIO.putStrLn $ "memoryLift: baseline pass " <> tshow base.passRate
  <> ", lifted pass " <> tshow lifted.passRate
  <> "; delta (pass,score) = (" <> tshow dPass <> ", " <> tshow dScore <> ")"
```

Match the actual types/imports already in `Main.hs`: reuse its `tshow`/`T.pack . show` helper if one exists (otherwise add `let tshow = T.pack . show`), its `Case`/`Predicate`/`skill`/`withTests` imports (add any missing from `Crucible.Eval`/`Crucible.Skill`), and add `import Crucible.Memory.Eval (memoryLift, liftDelta)` plus `Crucible.Memory (MemoryItem (..), MemoryId (..), MemoryKind (..), Provenance (..))` if not already imported. The block runs inside whatever effect stack the existing live demos use (it already discharges `LLM` live and must discharge `Embed`; if the surrounding block lacks `Embed`, wrap this demo with `Crucible.Embed.none` or the live embed interpreter already in use).

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: builds clean. Retry once on exit 137.

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "demo(memory): live memoryLift ablation in Main"
```

---

### Task 4: Manual section in `docs/memory.md`

**Files:**
- Modify: `docs/memory.md`

- [ ] **Step 1: Replace the "Planned follow-on work" stub with a real section**

Find the trailing section:

```markdown
## Planned follow-on work

`memoryLift` (an ablation eval that measures what the agent loses without a
given memory) is a planned sub-project. It operates through the same
`Memory` effect and composes with the existing interpreters.
```

Replace it with an "Evaluating memories" section covering: `renderMemories`
and `withMemories` (note the production use beyond eval: run a skill with
recalled context), `memoryLift` (set ablation: two runs, with and without the
candidate memories; decoupled from the `Memory` effect so candidates come
from `recall` or a literal proposal; returns both `Report`s), `liftDelta`
(the write gate, keep memories whose delta is positive), and the framing that
this closes the loop with consolidation (compact what helps, drop what does
not). Use a short Haskell snippet mirroring the demo. House style: no
emdashes/endashes, no hype words (powerful/seamless/robust), no manifest
mentions.

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/memory.md`
Expected: no output (no em/en dashes).
Run: `grep -niE "powerful|seamless|robust|manifest" docs/memory.md`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add docs/memory.md
git commit -m "docs(memory): Evaluating memories (memoryLift) section"
```

---

## Self-Review

- **Spec coverage:** renderMemories (T1), withMemories (T1), memoryLift (T2), liftDelta (T2), demo (T3), manual (T4), non-goals are all "do not build". All spec sections map to a task.
- **Type consistency:** `Report (..)` exports `passRate`/`meanScore`; `MemoryItem (..)`/`MemoryId (..)` give the constructors; `Skill (..)`/`Instruction (..)` give `.instruction.preamble`; signatures match the spec verbatim. `memoryLift` and `withMemories` share the `withMemories` helper.
- **Placeholder scan:** the only intentional placeholders are in Task 2 Step 2 / Task 3 Step 1 where the engineer must copy the exact in-repo scripted-LLM + Embed.none discharge and the exact `Case` reply formatting (these are repo-specific patterns the engineer must read from `test/Spec.hs`/`app/Main.hs` rather than invent); every other step is complete code.
