# Memory Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `Crucible.Memory.Consolidate` — `ConsolidationOp`/`ConsolidationPlan`, `consolidationSkill`, pure-ish `applyPlan` (a Memory-effect program), `unaddressed`, and the `consolidate` convenience — plus exporting `memoryItemCodec`/`memoryKindCodec` from `Crucible.Memory`.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-14-memory-consolidation-design.md` (tracker `crucible-cyx`, sub-project 2; depends on shipped `crucible-l9d`). The skill proposes per-item ops (keep/drop/supersede/merge); `applyPlan` executes them as `forget`/`remember` under any Memory interpreter, stamping derived memories `ByConsolidation`.

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec, neat-interpolation. No -Werror. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). Exit 137 = retry once. Judge by exit status or the pass line, never a pipeline tail.

---

## Background

- Branch `feat/memory-consolidation` from master. House style: DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot. `(.field)` getters may need annotation under DuplicateRecordFields; annotate and report. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- READ `src/Crucible/Memory.hs` (current: exports the types/effect/interpreters; `memoryItemCodec` exists internally, `kindCodec` is the internal MemoryKind codec), `src/Crucible/Skill.hs` (`skill :: Text -> JSONCodec i -> JSONCodec o -> (i -> Text) -> Skill i o`; `call :: (LLM :> es) => Skill i o -> i -> Eff es (Either DecodeError o)`; the input is rendered as JSON via the input codec into an `<input>` block), `src/Crucible/Codec.hs` (combinators incl. `bimapCodec`, `dimapCodec`, `optField`, `enum`, `list'`).
- The suite passes (verify the live count; report before/after).
- API keys in `.env` (gitignored). NEVER print/echo/cat them.

---

### Task 1: export the codecs + `Crucible.Memory.Consolidate` + tests

**Files:** Modify `src/Crucible/Memory.hs`; create `src/Crucible/Memory/Consolidate.hs`; modify `test/Spec.hs`.

- [ ] **Step 1: export codecs from `Crucible.Memory`.** Rename the internal `kindCodec` to `memoryKindCodec` (update its definition and every use, e.g. inside `memoryItemCodec`). Add `memoryItemCodec` and `memoryKindCodec` to the module export list. (Both already exist; this only renames `kindCodec` and widens the exports.)

- [ ] **Step 2: create `src/Crucible/Memory/Consolidate.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | Offline memory consolidation: a 'Skill' proposes a 'ConsolidationPlan'
-- (keep/drop/supersede/merge per item) over the current memories, and
-- 'applyPlan' executes it as 'Memory' operations, stamping derived memories
-- 'Crucible.Memory.ByConsolidation'. crucible ships the skill and the apply;
-- when consolidation runs is the host's business. The skill is iterable with
-- 'Crucible.Skill.testSkill' like any other.
module Crucible.Memory.Consolidate
  ( ConsolidationOp (..)
  , ConsolidationPlan (..)
  , consolidationSkill
  , applyPlan
  , unaddressed
  , consolidate
  ) where

import Control.Monad (void)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import NeatInterpolation (text)

import Crucible.Codec (JSONCodec, object, field, optField, str, int, list', bimapCodec, dimapCodec)
import Crucible.Decode (DecodeError)
import Crucible.LLM (LLM)
import Crucible.Memory
  ( Memory, MemoryItem (..), MemoryId (..), MemoryKind (..), MemoryDraft (..)
  , Provenance (..), Query, recall, remember, forget
  , memoryItemCodec, memoryKindCodec )
import Crucible.Skill (Skill, skill, call)

-- | One consolidation operation. 'Keep' records a deliberate retention (a
-- no-op for the store; an item the plan never mentions is also kept).
data ConsolidationOp
  = Keep      MemoryId
  | Drop      MemoryId
  | Supersede MemoryId   MemoryKind Text
  | Merge     [MemoryId] MemoryKind Text
  deriving (Eq, Show)

newtype ConsolidationPlan = ConsolidationPlan { ops :: [ConsolidationOp] }
  deriving (Eq, Show)

-- The wire shape for one op (a tagged object).
data RawOp = RawOp
  { op      :: Text
  , id      :: Maybe Int
  , ids     :: Maybe [Int]
  , kind    :: Maybe MemoryKind
  , content :: Maybe Text
  }

opCodec :: JSONCodec ConsolidationOp
opCodec = bimapCodec toOp fromOp
  (object (RawOp <$> field    "op"      (.op)      str
                 <*> optField "id"      (.id)      int
                 <*> optField "ids"     (.ids)     (list' int)
                 <*> optField "kind"    (.kind)    memoryKindCodec
                 <*> optField "content" (.content) str))
  where
    toOp r = case r.op of
      "keep"      -> Keep . MemoryId <$> need "id" r.id
      "drop"      -> Drop . MemoryId <$> need "id" r.id
      "supersede" -> Supersede <$> (MemoryId <$> need "id" r.id)
                               <*> need "kind" r.kind <*> need "content" r.content
      "merge"     -> Merge <$> (map MemoryId <$> need "ids" r.ids)
                           <*> need "kind" r.kind <*> need "content" r.content
      other       -> Left ("unknown op: " <> T.unpack other)
    need _    (Just v) = Right v
    need name Nothing  = Left ("op missing field: " <> name)
    fromOp (Keep (MemoryId i))          = RawOp "keep" (Just i) Nothing Nothing Nothing
    fromOp (Drop (MemoryId i))          = RawOp "drop" (Just i) Nothing Nothing Nothing
    fromOp (Supersede (MemoryId i) k t) = RawOp "supersede" (Just i) Nothing (Just k) (Just t)
    fromOp (Merge is k t)               = RawOp "merge" Nothing (Just [i | MemoryId i <- is]) (Just k) (Just t)

planCodec :: JSONCodec ConsolidationPlan
planCodec = dimapCodec ConsolidationPlan (.ops) (list' opCodec)

-- | The consolidation skill: live items as JSON in <input>, a plan array out.
consolidationSkill :: Skill [MemoryItem] ConsolidationPlan
consolidationSkill = skill "consolidate" (list' memoryItemCodec) planCodec
  (\_ -> [text|
    You are consolidating an agent's memory. The current memories are in the
    <input> block as a JSON array; each has an id, kind, tags, and content.
    Propose a consolidation plan as a JSON array of operations:
    - {"op":"drop","id":N} to forget a memory that is noise, redundant, or wrong.
    - {"op":"supersede","id":N,"kind":K,"content":"..."} to replace one memory
      with a corrected or refined version. You may change its kind, for example
      promoting an episodic observation into a semantic fact.
    - {"op":"merge","ids":[N,...],"kind":K,"content":"..."} to combine several
      related memories into one; choose the kind of the result.
    - {"op":"keep","id":N} to record that a memory is deliberately retained.
    Any memory you do not mention is kept. Only drop, supersede, or merge when it
    clearly improves the store. K is one of episodic, semantic, procedural.|])

opIds :: ConsolidationOp -> [MemoryId]
opIds (Keep i)          = [i]
opIds (Drop i)          = [i]
opIds (Supersede i _ _) = [i]
opIds (Merge is _ _)    = is

-- | Execute a plan as Memory operations. Keep is a no-op; Drop forgets;
-- Supersede forgets the old and remembers a new (kind, content) with that
-- item's tags; Merge forgets all referenced and remembers one new (kind,
-- content) with the union of their tags. Derived memories are stamped
-- 'ByConsolidation'. Items the plan never mentions are untouched.
applyPlan :: (Memory :> es) => [MemoryItem] -> ConsolidationPlan -> Eff es ()
applyPlan items (ConsolidationPlan os) = mapM_ step os
  where
    tagsOf is = nub [t | it <- items, it.memId `elem` is, t <- it.tags]
    step (Keep _)          = pure ()
    step (Drop i)          = forget i
    step (Supersede i k t) = forget i >> void (remember (MemoryDraft k t (tagsOf [i]) ByConsolidation))
    step (Merge is k t)    = mapM_ forget is >> void (remember (MemoryDraft k t (tagsOf is) ByConsolidation))

-- | The items a plan never references (implicitly kept), for auditing.
unaddressed :: [MemoryItem] -> ConsolidationPlan -> [MemoryItem]
unaddressed items (ConsolidationPlan os) =
  [it | it <- items, it.memId `notElem` mentioned]
  where mentioned = concatMap opIds os

-- | Recall under a query, ask the skill for a plan, apply it, return the plan.
-- A plan that fails to decode is returned as 'Left' and applies nothing.
consolidate :: (Memory :> es, LLM :> es)
            => Skill [MemoryItem] ConsolidationPlan -> Query
            -> Eff es (Either DecodeError ConsolidationPlan)
consolidate sk q = do
  items <- recall q
  r <- call sk items
  case r of
    Right plan -> applyPlan items plan >> pure (Right plan)
    Left e     -> pure (Left e)
```

Notes: `RawOp`'s `kind`/`content`/`id` labels overlap other records under DuplicateRecordFields; if the `(.kind)`/`(.content)`/`(.id)`/`(.op)`/`(.ids)` getters are ambiguous, annotate inline (e.g. `((.kind) :: RawOp -> Maybe MemoryKind)`) and report. `id` as a field label does not clash with `Prelude.id` (NoFieldSelectors generates no selector). If `memoryKindCodec`/`memoryItemCodec` are not exported by `Crucible.Memory` yet, Step 1 adds them.

- [ ] **Step 3: tests in `test/Spec.hs`.** Add `import Crucible.Memory.Consolidate (ConsolidationOp (..), ConsolidationPlan (..), consolidationSkill, applyPlan, unaddressed, consolidate)`. The Memory names (MemoryItem(..), MemoryId(..), MemoryKind(..), MemoryDraft(..), Provenance(..), Query(..), remember, recall, runMemoryPure) are already imported from Task-1-of-l9d. Add:

```haskell
  -- crucible-cyx: memory consolidation
  , check "consolidate applyPlan: drop/supersede/merge rewrite the store, ByConsolidation"
      (["CD", "B2"], Semantic, ["t3", "t4"], ByConsolidation)
      (let prog = do
             mapM_ remember
               [ MemoryDraft Episodic "a" ["t1"] Curated
               , MemoryDraft Episodic "b" ["t2"] Curated
               , MemoryDraft Episodic "c" ["t3"] Curated
               , MemoryDraft Episodic "d" ["t4"] Curated ]
             cur <- recall (Query "" [] 100)
             applyPlan cur (ConsolidationPlan
               [ Drop (MemoryId 0)
               , Supersede (MemoryId 1) Semantic "B2"
               , Merge [MemoryId 2, MemoryId 3] Semantic "CD" ])
             recall (Query "" [] 100)
           (out, _) = runPureEff (runMemoryPure prog)
           cd = head out  -- most-recent-first: the merged item
       in (map (.content) out, cd.kind, cd.tags, cd.source))
  , check "consolidate unaddressed: items no op references"
      ["b"]
      (let items = [ MemoryItem (MemoryId 0) Episodic "a" [] Curated 0
                   , MemoryItem (MemoryId 1) Episodic "b" [] Curated 1 ]
       in map (.content) (unaddressed items (ConsolidationPlan [Drop (MemoryId 0)])))
  , check "consolidationSkill: decodes a scripted plan array"
      (ConsolidationPlan [Drop (MemoryId 0), Merge [MemoryId 1, MemoryId 2] Semantic "merged"])
      (runPureEff (runLLMScripted
         ["[{\"op\":\"drop\",\"id\":0},{\"op\":\"merge\",\"ids\":[1,2],\"kind\":\"semantic\",\"content\":\"merged\"}]"]
         (either (const (ConsolidationPlan [])) Prelude.id <$> call consolidationSkill [])))
  , check "consolidate end to end: scripted plan applied to the pure store"
      ["merged"]
      (let prog = do mapM_ remember [ MemoryDraft Episodic "x" ["a"] Curated
                                    , MemoryDraft Episodic "y" ["a"] Curated ]
                     _ <- consolidate consolidationSkill (Query "" [] 100)
                     recall (Query "" [] 100)
           (out, _) = runPureEff (runLLMScripted
                        ["[{\"op\":\"merge\",\"ids\":[0,1],\"kind\":\"semantic\",\"content\":\"merged\"}]"]
                        (runMemoryPure prog))
       in map (.content) out)
```

`head out` is safe (the store is non-empty after the rewrite). If a getter is ambiguous, annotate. If a result differs, the expectation about ordering may be off; investigate the ACTUAL deterministic output and pin it, reporting; never weaken a checkable value.

- [ ] **Step 4: build + suite.** Build exit 0; `1 test suite(s) passed`, +4 (report the count).

- [ ] **Step 5: commit.**

```bash
git add src/Crucible/Memory.hs src/Crucible/Memory/Consolidate.hs test/Spec.hs
git commit -m "$(printf 'feat(memory): consolidation skill + applyPlan (keep/drop/supersede/merge)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: demo + docs

**Files:** Modify `app/Main.hs`, `docs/memory.md`.

- [ ] **Step 1: demo.** In the Anthropic-key-gated block, after the existing memory demo, add a live consolidation. Add `import Crucible.Memory.Consolidate (consolidationSkill, consolidate)` and ensure `runMemoryFile`, `recall`, `remember`, `MemoryDraft (..)`, `MemoryKind (..)`, `Provenance (..)`, `Query (..)` are imported (extend the existing `Crucible.Memory` import). Add:

```haskell
      let consoPath = "/tmp/crucible-consolidate-demo.jsonl"
      _ <- runEff (runMemoryFile consoPath (do
             _ <- remember (MemoryDraft Episodic "The user said they prefer dark mode." ["pref"] (BySession "demo"))
             _ <- remember (MemoryDraft Episodic "The user switched the theme to dark again." ["pref"] (BySession "demo"))
             pure ()))
      consoPlan <- runEff (runMemoryFile consoPath (Anthropic.run cfg
                     (consolidate consolidationSkill (Query "" [] 50))))
      consoItems <- runEff (runMemoryFile consoPath (recall (Query "" [] 50)))
      TIO.putStrLn ("consolidate: plan " <> T.pack (show (either (const 0) (length . (.ops)) consoPlan))
                    <> " op(s); store now " <> T.pack (show (map (.content) consoItems)))
```

(If re-running accumulates the /tmp file across runs, that is acceptable; or use `openTempFile` for a fresh store and report. The effect order `runMemoryFile path (Anthropic.run cfg (consolidate ...))` discharges LLM then Memory; adapt if the stack ordering needs flipping and report.)

- [ ] **Step 2: build + live smoke.**

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: a `consolidate: plan N op(s); store now [...]` line where the two episodic prefs have been merged (store shows roughly one consolidated item); exit 0. REPORT the exact line.

- [ ] **Step 3: docs.** Add a "Consolidation" section to `docs/memory.md` (after the typed-memory material): the `Skill [MemoryItem] ConsolidationPlan` shape; the four ops with explicit-vs-implicit keep; `applyPlan` as a Memory-effect program (Drop/Supersede/Merge -> forget/remember, derived memories stamped `ByConsolidation`, supersede-not-erase); `unaddressed` for auditing implicit keeps; the `consolidate` convenience; that the skill is `testSkill`-iterable; the linear-to-star framing; and that the scheduler is the host's job (crucible ships skill + apply, not a daemon). Show a short example. House style STRICT: `grep -nP "—|–" docs/memory.md` empty; no hype; no "manifest".

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/memory.md
git commit -m "$(printf 'docs(site)+demo: memory consolidation, linear-to-star pump proven live\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: merge + publish + close

- [ ] **Step 1:** full suite `1 test suite(s) passed`.
- [ ] **Step 2:** merge via `superpowers:finishing-a-development-branch` (the user picks "merge to master locally"); `git pull` first (master may have moved); suite on master; push; Pages `built`.
- [ ] **Step 3:** `bd close crucible-cyx --reason="Shipped sub-project 2: Crucible.Memory.Consolidate with ConsolidationOp (keep/drop/supersede/merge, explicit + implicit keep), consolidationSkill (testSkill-iterable, items rendered as JSON via memoryItemCodec), applyPlan (Memory-effect program; derived memories stamped ByConsolidation; supersede-not-erase; LLM picks kind+content, apply unions tags), unaddressed, consolidate convenience; memoryItemCodec/memoryKindCodec now exported from Crucible.Memory. 4 tests, live linear-to-star demo, docs/memory.md Consolidation section. memoryLift eval hook (crucible-fhc) remains the last sub-project."`

---

## Self-Review

**1. Spec coverage:** ConsolidationOp (4 ops, explicit+implicit keep) + ConsolidationPlan -> Task 1 Step 2. consolidationSkill (input as JSON via memoryItemCodec, plan array out) -> Step 2 + the memoryItemCodec export (Step 1). applyPlan as Memory-effect program (Keep no-op, Drop forget, Supersede/Merge forget+remember with ByConsolidation, tags union) -> Step 2. unaddressed -> Step 2. consolidate convenience -> Step 2. metadata split (LLM kind+content, apply tags+ByConsolidation) -> applyPlan + the op type. memoryKindCodec/memoryItemCodec exports -> Step 1. Tests cover apply (drop/supersede/merge/kind-change/tag-union/ByConsolidation), unaddressed, skill decode, end-to-end -> Step 3. Demo linear-to-star live -> Task 2. Docs Consolidation section -> Task 2. Non-goals (scheduler, graph consolidation, provenance filter on Query, dedup heuristics) absent. ✅

**2. Placeholder scan:** the test block contains an explicitly-labelled illustrative placeholder that Step 3 instructs to DELETE, keeping only the four concrete checks; no real placeholder ships. ✅

**3. Type consistency:** `ConsolidationOp` constructors match opCodec's toOp/fromOp and opIds/applyPlan/unaddressed; `planCodec = dimapCodec ConsolidationPlan (.ops) (list' opCodec)`; `consolidationSkill :: Skill [MemoryItem] ConsolidationPlan` uses `list' memoryItemCodec` (input) and planCodec (output); `applyPlan :: (Memory :> es) => [MemoryItem] -> ConsolidationPlan -> Eff es ()`; `consolidate :: (Memory :> es, LLM :> es) => Skill ... -> Query -> Eff es (Either DecodeError ConsolidationPlan)`; ids are `Int` on the wire, wrapped to `MemoryId`. memoryKindCodec/memoryItemCodec exported from Memory. ✅
