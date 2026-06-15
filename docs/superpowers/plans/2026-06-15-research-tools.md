# Research Operations as Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Crucible.Research.Tools`: expose `read_page`/`write_page`/`search_pages` as tools (plus a default instruction fragment) so the stock agent loop can maintain a Research store. Export a `pageCodec` from `Crucible.Research`.

**Architecture:** The tools are `[Tool es]` whose handlers call the `Research` effect, so `(Research meta :> es)`; they drop into `runToolAgent` under a `Chat` + `Research meta` row. The tool JSON boundary uses a full `pageCodec` (slug+title+links+body+meta) added to `Crucible.Research`. Plain text `researchInstructions` ships the editing discipline as policy, not types.

**Tech Stack:** GHC 9.12.2, effectful, `Crucible.Tool`, autodocodec via `Crucible.Codec`, neat-interpolation; zinc build.

**Spec:** `docs/superpowers/specs/2026-06-15-research-tools-design.md`

## Conventions (every task)
- Build/test: `nix develop . --command timeout -s KILL 300 zinc build|test`. Judge success by exit status or "test suite(s) passed", never a pipeline tail. 137 = GHC flake, retry once; second 137 = BLOCKED. Ignore "Git tree is dirty".
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot. `(.field)` getter sections often need an inline annotation under DuplicateRecordFields. Annotate and report.
- Tests: custom harness `check "label" expected actual`; comma entries in `runChecks` at END of `test/Spec.hs`. No hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit per task; do not push.

## Confirmed facts
- `Crucible.Tool` exports `Tool`, `toolWith :: ToolName -> JSONCodec i -> JSONCodec o -> (i -> Eff es o) -> Tool es`, and `invoke :: Tool es -> Value -> Eff es (Either ToolError Value)`.
- `Crucible.Research` exports `Page (..)` (`slug`/`title`/`links`/`body`/`meta`), `Slug (..)`, `Research`, `readPage`, `writePage`, `search`, `runResearchState`, `runResearchDir`, `slugCodec`, `linkCodec`. It does NOT yet export a full `pageCodec` (Task 1 adds it).
- `Crucible.Codec` exports `JSONCodec`, `object`, `field`, `str`, `list'`, `nullable'`, `anyValue`, `encodeText`. `Crucible.Decode` exports `decodeLLM`. To round-trip a result `Value` back to a typed value in a test: `decodeLLM codec (C.encodeText C.anyValue v)`.
- `runToolAgent :: (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)`. `runChatScripted`, `Turn (..)`, `ToolUse (..)` are imported in `test/Spec.hs`.

## File Structure
- Modify `src/Crucible/Research.hs` — add and export `pageCodec` (Task 1).
- Create `src/Crucible/Research/Tools.hs` — `researchTools`, `researchInstructions` (Task 1).
- Modify `test/Spec.hs` — invoke tests + agent integration + instructions check (Task 1).
- Modify `app/Main.hs` — live demo (Task 2).
- Modify `docs/research.md` — agent-maintains-a-store section (Task 3).

---

### Task 1: `pageCodec` + `Crucible.Research.Tools` + tests

**Files:**
- Modify: `src/Crucible/Research.hs`
- Create: `src/Crucible/Research/Tools.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Add and export `pageCodec` in `src/Crucible/Research.hs`**

Add `pageCodec` to the export list (after `linkCodec`). Ensure `list'` is in the `Crucible.Codec` import (it already is). Add the definition near the other codecs:
```haskell
-- | A full page codec (slug, title, links, body, meta); used by the Research
-- tools and by callers serializing a page for a model.
pageCodec :: JSONCodec meta -> JSONCodec (Page meta)
pageCodec mc = object (Page
  <$> field "slug"  ((.slug)  :: Page meta -> Slug)   slugCodec
  <*> field "title" ((.title) :: Page meta -> Text)   str
  <*> field "links" ((.links) :: Page meta -> [Link]) (list' linkCodec)
  <*> field "body"  ((.body)  :: Page meta -> Text)   str
  <*> field "meta"  ((.meta)  :: Page meta -> meta)   mc)
```
(The explicit getter annotations avoid DuplicateRecordFields ambiguity; drop any that compile without one.)

- [ ] **Step 2: Create `src/Crucible/Research/Tools.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | The 'Crucible.Research' operations as model-callable 'Tool's, so the stock
-- agent loop ('Crucible.Chat.runToolAgent') can maintain a Research store.
-- 'researchInstructions' is a default editing-discipline prompt fragment (plain
-- text, the caller prepends and can replace). Lives apart from
-- 'Crucible.Research' so that module keeps no dependency on the tool machinery.
module Crucible.Research.Tools
  ( researchTools
  , researchInstructions
  ) where

import Data.Text (Text)
import NeatInterpolation (text)

import Effectful

import Crucible.Codec (JSONCodec, object, field, str, list', nullable')
import Crucible.Tool (Tool, toolWith)
import Crucible.Research (Page (..), Slug, Research, readPage, writePage, search, pageCodec, slugCodec)

-- | The Research operations as tools. @mc@ is the page frontmatter codec. Run
-- under a row with 'Chat' and 'Research' meta, e.g.
-- @runToolAgent (researchTools mc) (researchInstructions <> "\\n\\n" <> task)@.
researchTools :: (Research meta :> es) => JSONCodec meta -> [Tool es]
researchTools mc =
  [ toolWith "read_page"    (object (field "slug" Prelude.id slugCodec)) (nullable' (pageCodec mc)) readPage
  , toolWith "write_page"   (pageCodec mc) slugCodec (\p -> writePage p >> pure ((.slug) (p :: Page _)))
  , toolWith "search_pages" (object (field "query" Prelude.id str)) (list' slugCodec) search
  ]

-- | A default instruction fragment naming the tools and a light editing
-- discipline. Plain text the caller prepends and can replace.
researchInstructions :: Text
researchInstructions = [text|
You maintain a research knowledge base with these tools:
- search_pages: find existing pages by a query.
- read_page: read one page by its slug.
- write_page: create or update a page (slug, title, body, and typed links).

Before writing, search for an existing page and prefer updating it over creating
a near-duplicate. When a new finding conflicts with a page, add a link of type
contradicts or supersedes rather than overwriting silently. Keep each page
focused on one topic.
|]
```
Notes:
- The `read_page` input codec `object (field "slug" Prelude.id slugCodec) :: JSONCodec Slug` decodes `{"slug": "..."}`; its handler is `readPage :: Slug -> Eff es (Maybe (Page meta))`, output `nullable' (pageCodec mc)`.
- `write_page` input is the full `pageCodec mc`; handler writes then returns the slug (output `slugCodec`). `(.slug) (p :: Page _)` extracts the slug; if `PartialTypeSignatures` is not enabled, replace `(p :: Page _)` with a top-level annotation or use a `let Page{slug = s} = p`-style binding, OR just `p.slug` if it resolves. Prefer `p.slug`; if ambiguous, annotate. Report what compiled.
- `search_pages` input `object (field "query" Prelude.id str) :: JSONCodec Text`; handler `search :: Text -> Eff es [Slug]`, output `list' slugCodec`.
- `Slug` is imported (constructor not needed here; `slugCodec` does the wire work).

- [ ] **Step 3: Add tests to `test/Spec.hs`**

Add imports: `import Crucible.Research.Tools (researchTools, researchInstructions)`; ensure `Crucible.Tool`'s `invoke` is available (it is imported qualified as `Tl`, so `Tl.invoke`; verify). aeson `Value` construction (`object`, `.=`, `String`, `Null`) is already used in this file (around line 995) via its existing import; reuse that. `pageCodec` is now exported from `Crucible.Research` (add to the existing `Crucible.Research` import in Spec.hs if a test needs it directly). `meta = Text`, `mc = C.str`.

Add to `runChecks`. Build the write_page argument as an aeson `Value` matching `pageCodec` (`{slug,title,links,body,meta}`):

```haskell
  -- write_page lands the page in the store
  , let pageVal = object [ "slug" .= String "p", "title" .= String "P"
                         , "links" .= ([] :: [Value]), "body" .= String "the body", "meta" .= String "" ]
        expected = Page (Slug "p") "P" [] "the body" ("" :: Text)
        (res, pages, _) = runPureEff (runResearchState []
          (Tl.invoke (researchTools C.str !! 1) pageVal))   -- index 1 = write_page
    in check "researchTools: write_page lands the page"
         (True, [expected])
         (either (const False) (const True) res, pages)
  -- read_page returns the page for a known slug, null for an unknown one
  , let known = Page (Slug "p") "P" [] "b" ("" :: Text)
        (r1, _, _) = runPureEff (runResearchState [known]
          (Tl.invoke (researchTools C.str !! 0) (object ["slug" .= String "p"])))
        (r2, _, _) = runPureEff (runResearchState [known]
          (Tl.invoke (researchTools C.str !! 0) (object ["slug" .= String "absent"])))
        decodeRP v = decodeLLM (nullable' (pageCodec C.str)) (C.encodeText C.anyValue v)
    in check "researchTools: read_page returns the page or null"
         (Right (Just known), Right Nothing)
         ( either (Left . show) decodeRP r1
         , either (Left . show) decodeRP r2 )
  -- search_pages returns matching slugs
  , let p1 = Page (Slug "a") "Apple" [] "red fruit" ("" :: Text)
        p2 = Page (Slug "b") "Boat" [] "floats" ("" :: Text)
        (r, _, _) = runPureEff (runResearchState [p1, p2]
          (Tl.invoke (researchTools C.str !! 2) (object ["query" .= String "fruit"])))
        decodeSL v = decodeLLM (list' slugCodec) (C.encodeText C.anyValue v)
    in check "researchTools: search_pages returns matching slugs"
         (Right [Slug "a"])
         (either (Left . show) decodeSL r)
  -- agent loop maintains the store: a scripted write_page tool_use then a final answer
  , let pageVal = object [ "slug" .= String "x", "title" .= String "X"
                         , "links" .= ([] :: [Value]), "body" .= String "recorded" , "meta" .= String "" ]
        expected = Page (Slug "x") "X" [] "recorded" ("" :: Text)
        (_, pages, _) = runPureEff (runChatScripted
          [ Turn "" [ToolUse "u1" "write_page" pageVal], Turn "\"done\"" [] ]
          (runResearchState [] (runToolAgent (researchTools C.str) "record X")))
    in check "researchTools: agent loop writes a page via write_page" [expected] pages
  , check "researchInstructions: names the three tools"
      True
      (all (`T.isInfixOf` researchInstructions) ["read_page", "write_page", "search_pages"])
```
Notes:
- `researchTools C.str !! 0/1/2` selects read/write/search by position (read_page, write_page, search_pages, in that order). If positional indexing reads poorly, bind the list and name them; either is fine.
- `slugCodec`/`pageCodec` must be imported from `Crucible.Research` in Spec.hs for the decode helpers; add them to that import.
- `decodeLLM` is imported (verify). `C.encodeText C.anyValue v` re-serializes the result `Value` so it can be decoded through a typed codec.
- The agent-loop test: the row is `[Research Text, Chat]`; `runResearchState` peels `Research` (returns the `(result, pages, log)` triple), then `runChatScripted` peels `Chat`. So the nesting is `runChatScripted turns (runResearchState [] (runToolAgent ...))`. The scripted `write_page` tool_use args is the page `Value`; after the tool runs, the final dump has the page.
- `Value`/`object`/`.=`/`String`/`Null` come from the aeson import already used near line 995 (reuse the same names; if they are qualified there, qualify here too).

- [ ] **Step 4: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the five new checks pass; full suite green. If the write_page arg `Value` shape mismatches `pageCodec` (e.g. a field name), align it to `pageCodec`'s fields and pin. Retry once on 137.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Research.hs src/Crucible/Research/Tools.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(research): operations as Tools + default instruction fragment

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Live demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add an agent-maintains-a-store demo**

Read `app/Main.hs`. It imports `qualified Crucible.Research as Research`, `Anthropic.runChat`, `runToolAgent` (from `Crucible.Chat`; confirm it is imported, else add), `runEff`, `cfg`, `str`, `TIO`, `T`. Add `import Crucible.Research.Tools (researchTools, researchInstructions)`. Inside the `Just key -> do` block, after the grounded-write demo, add:
```haskell
      -- Research as tools: an agent records a fact into the store, then we read it back.
      let toolsDir = "/tmp/crucible-research-tools-demo"
          task = researchInstructions <> "\n\nRecord that Brisbane is the capital of Queensland. Use slug \"brisbane\"."
      _ <- runEff (Anthropic.runChat cfg (Research.runResearchDir str toolsDir
             (runToolAgent (researchTools str) task)))
      brisbane <- runEff (Research.runResearchDir str toolsDir (Research.readPage (Research.Slug "brisbane")))
      TIO.putStrLn ("research tools: brisbane page is "
                    <> maybe "absent" (\pg -> "present: " <> (pg :: Research.Page T.Text).title) brisbane)
```
Notes:
- Stack: `runEff (Anthropic.runChat cfg (Research.runResearchDir str toolsDir (runToolAgent (researchTools str) task)))` — `runResearchDir` discharges `Research` (needs IOE), `Anthropic.runChat` discharges `Chat`, `runEff` provides IOE. If GHC wants a different interpreter order, adjust and report.
- The readback uses a separate `runResearchDir` call; `(pg :: Research.Page T.Text).title` may need the annotation shown (DuplicateRecordFields). The model may pick a different slug than "brisbane"; the task asks it to use that slug, but if it deviates the readback prints "absent", which is acceptable for a smoke demo.
- `runToolAgent` returns `Either ChatError Text` (ignored with `_ <-`).

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. Retry once on 137. (Do not run the binary.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "$(cat <<'EOF'
demo(research): an agent maintains a store via the research tools

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: "Maintaining a store with an agent" section in `docs/research.md`

**Files:**
- Modify: `docs/research.md`

- [ ] **Step 1: Add the section and update the follow-on list**

Read `docs/research.md`. Insert a `## Maintaining a store with an agent` section after the "Grounding-gated writes" section and before "Planned follow-on work". Content (real triple-backtick fences):

```markdown
## Maintaining a store with an agent

The research operations are also tools, so an agent can keep the store itself.

```haskell
researchTools        :: (Research meta :> es) => JSONCodec meta -> [Tool es]
researchInstructions :: Text
```

`researchTools mc` returns three tools: `read_page` (a slug in, the page or null
out), `write_page` (a full page in, the slug out), and `search_pages` (a query
in, slugs out). Drop them into the stock agent loop, prepending the default
instructions:

```haskell
runToolAgent (researchTools mc) (researchInstructions <> "\n\n" <> task)
```

run under a row with `Chat` and `Research meta`. `researchInstructions` is a
plain-text starting point: it names the tools and a light editing discipline
(search before writing, prefer updating an existing page, use typed links for a
contradiction or supersession). It is policy, not types; replace it with your own
when your discipline differs.
```
(The outer ```markdown fence delimits this block in the plan only; write real markdown.)

Then in "Planned follow-on work", REMOVE the ops-as-tools / "wiki operations as Tools" item (it now exists). Keep lint as Eval cases. Reword to read naturally.

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/research.md` (expect no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/research.md` (expect no output).

- [ ] **Step 3: Commit**

```bash
git add docs/research.md
git commit -m "$(cat <<'EOF'
docs(research): Maintaining a store with an agent (researchTools)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** `pageCodec` export (T1 S1), `researchTools` + `researchInstructions` (T1 S2), invoke tests for all three tools + agent-loop integration + instructions check (T1 S3), demo (T2), docs + follow-on-list update (T3). Non-goals (list_pages/append_log, policy-in-types, grounded write_page tool) are "do not build".
- **Type consistency:** `researchTools :: (Research meta :> es) => JSONCodec meta -> [Tool es]`, `researchInstructions :: Text`, `pageCodec :: JSONCodec meta -> JSONCodec (Page meta)`. Tool order (read/write/search) is consistent between the module and the positional test indexing.
- **Placeholder scan:** no placeholder code. Judgement points flagged: the `p.slug` extraction in write_page (try `p.slug`, annotate if needed), the getter annotations in `pageCodec`, the write_page arg `Value` shape matching `pageCodec` (with a pin instruction), the interpreter nesting in the agent test and demo, and the aeson value-construction import reuse. No vague steps.
