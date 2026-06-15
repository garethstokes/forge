# Research Operations as Tools Design Spec

**Date:** 2026-06-15
**Status:** Approved design, pending implementation
**Tracker:** `crucible-63g` (follow-on to `crucible-1z4`, the Research foundation; from `docs/superpowers/research/2026-06-11-llm-wiki.md` rec 3).
**Goal:** Expose the Research read/write/search operations as `Tool`s so the stock agent loop can maintain a Research store, with a default editing-discipline instruction fragment.

**Scope:** new `src/Crucible/Research/Tools.hs`; `src/Crucible/Research.hs` (export a `pageCodec`); `test/Spec.hs`; `app/Main.hs`; `docs/research.md` (an "agent maintains a store" section, and remove ops-as-tools from the follow-on list). No change to the `Research` effect or `Crucible.Tool`/`Crucible.Chat`.

## What problem this solves

The Research effect lets code read and write a knowledge base, but the point of a
knowledge base is that the agent maintains it while it works: it should be able
to look something up, find an existing page, and record what it learns, all from
inside its own tool loop, not only from host code written ahead of time. Without
that, a human has to wire every read and write by hand and the agent cannot grow
its own notes mid-task. crucible already has a typed tool boundary
(`Crucible.Tool`) and a stock agent loop (`Crucible.Chat.runToolAgent`). This
work connects the two: it exposes `read_page`, `write_page`, and `search_pages`
as typed tools an agent can call, so dropping them into the loop turns any agent
into one that keeps a wiki as it goes. It also ships a default instruction
fragment describing the tools and a light editing discipline, so the common case
works without the caller having to discover the prompt wording themselves, while
leaving that policy as plain text they can replace.

## Decisions taken during design

- **Three tools: read/write/search.** `read_page`, `write_page`, `search_pages`
  (the research's set). No `list_pages` (avoids an empty-input tool) and no
  `append_log` (the activity log is a harness concern, not a model action).
- **A default instruction fragment.** `researchInstructions :: Text` names the
  three tools and a light editing discipline; it is plain text (policy, not
  types) the caller prepends and can replace.
- **Export `pageCodec` from `Research`.** The tools serialize a full `Page meta`
  (slug, title, links, body, meta) at the JSON boundary; `pageCodec` is a small,
  generally useful addition to `Crucible.Research`, built from the existing
  `slugCodec`/`linkCodec`.
- **Plain `writePage` in `write_page`.** The tool commits with the unverified
  `writePage`; a grounded write tool (using `writeGrounded`) is a future variant,
  not this cycle.
- **Lives apart from `Research`.** `Crucible.Research.Tools` imports
  `Crucible.Tool` and `Crucible.Research`, so the `Research` effect keeps no
  dependency on the tool machinery (mirrors the other follow-on modules).

## Design

### `Crucible.Research` (one addition)

```haskell
-- | A full page codec (slug, title, links, body, meta); used by the tools and
-- by callers serializing a page for a model.
pageCodec :: JSONCodec meta -> JSONCodec (Page meta)
pageCodec mc = object (Page
  <$> field "slug"  (.slug)  slugCodec
  <*> field "title" (.title) str
  <*> field "links" (.links) (list' linkCodec)
  <*> field "body"  (.body)  str
  <*> field "meta"  (.meta)  mc)
```
Added to the export list. (`list'` is added to the `Crucible.Codec` import in `Research` if not already imported.)

### `Crucible.Research.Tools`

```haskell
-- | The Research operations as model-callable tools, for the stock agent loop.
-- @mc@ is the page frontmatter codec. Run under a row with 'Chat' and
-- 'Research' meta, e.g. @runToolAgent (researchTools mc) (researchInstructions <> "\n\n" <> task)@.
researchTools :: (Research meta :> es) => JSONCodec meta -> [Tool es]
researchTools mc =
  [ toolWith "read_page"    (object (field "slug" Prelude.id slugCodec)) (nullable' (pageCodec mc)) readPage
  , toolWith "write_page"   (pageCodec mc) slugCodec (\p -> writePage p >> pure p.slug)
  , toolWith "search_pages" (object (field "query" Prelude.id str)) (list' slugCodec) search
  ]

-- | A default instruction fragment naming the tools and a light editing
-- discipline. Plain text the caller prepends and can replace.
researchInstructions :: Text
```

Tool contracts (what the model sees):
- `read_page`: input `{"slug": "<slug>"}`; output the page object (`pageCodec`) or `null`.
- `write_page`: input a page object (`{slug, title, links, body, meta}`); output the written slug.
- `search_pages`: input `{"query": "<text>"}`; output an array of slugs.

`researchInstructions` text (the starting point):

```
You maintain a research knowledge base with these tools:
- search_pages: find existing pages by a query.
- read_page: read one page by its slug.
- write_page: create or update a page (slug, title, body, and typed links).

Before writing, search for an existing page and prefer updating it over creating
a near-duplicate. When a new finding conflicts with a page, add a link of type
contradicts or supersedes rather than overwriting silently. Keep each page
focused on one topic.
```

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block, under a temp `runResearchDir` plus the live
`Chat` interpreter: run `runToolAgent (researchTools str)
(researchInstructions <> "\n\n" <> task)` with a task like "record that Brisbane
is in Queensland", then `readPage` (or `search_pages`) to show a page was
written. Stack:
`runEff (Anthropic.runChat cfg (runResearchDir str dir (runToolAgent (researchTools str) prompt)))`
followed by a `runResearchDir` read to print the resulting page. Confirm the
interpreter order compiles; the plan resolves the exact nesting.

## Manual (`docs/research.md`)

Add a "Maintaining a store with an agent" section: `researchTools`, the three
tool contracts, `researchInstructions` (a default the caller prepends and can
replace), and the one-liner to drop them into `runToolAgent`. Remove the
ops-as-tools item from "planned follow-on work" (lint remains). House style: no
emdashes/endashes, no hype words, no manifest mentions.

## Testing (hermetic)

Direct tool tests via `Crucible.Tool.invoke` under `runResearchState` (`meta =
Text`, `mc = str`), which need no `Chat`:

- **write_page lands the page:** `invoke` the `write_page` tool with a page JSON
  value; the result is `Right` the slug, and the page appears in the
  `runResearchState` final dump.
- **read_page returns the page or null:** after a write, `invoke read_page`
  with `{"slug": ...}` returns `Right` the page JSON; for an unknown slug it
  returns `Right` `null`.
- **search_pages returns matching slugs:** after writing two pages, `invoke
  search_pages` with a `{"query": ...}` matching one body returns `Right` the
  array with that slug.

Agent-loop integration (one test): `runToolAgent (researchTools str) task` under
`runChatScripted` (a scripted `write_page` tool_use then a final answer) and
`runResearchState`; assert the page is in the final dump (the loop maintained the
store with no model).

Instruction fragment:
- `researchInstructions` is non-empty and mentions `read_page`, `write_page`,
  and `search_pages`.

Live: the demo agent maintaining a store before merge (gated on the Anthropic
key).

## Non-goals

- `list_pages` and `append_log` tools.
- Encoding the editing policy in types (it is the `Text` fragment).
- A grounded `write_page` tool (uses plain `writePage`; combining with
  `writeGrounded` is a future variant).
- Changing the `Research` effect beyond exporting `pageCodec`.
- Per-page line budgets, archive compression, or the other mechanical editing
  variants (prompt content for the application, not the library).
