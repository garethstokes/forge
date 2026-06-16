# Research Effect (Foundation) Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-1z4` (from `docs/superpowers/research/2026-06-11-llm-wiki.md`; the research calls it a "Wiki" effect, shipped here under the name "Research").
**Goal:** A typed, persistent, agent-maintained knowledge base: typed pages with typed links, a `Research` effect (`readPage`/`writePage`/`index`/`search`/`appendLog`), and two interpreters (a pure one for tests, a directory-of-markdown one for apps).

**Scope:** new `src/Crucible/Research.hs`; `test/Spec.hs`; `app/Main.hs`; new `docs/research.md`. This is sub-project 1 of the Research arc; ops-as-tools, grounding-gated writes, and lint-as-eval are follow-on beads.

## What problem this solves

An agent that works on a topic over many sessions has nowhere to put what it
learns. Conversation memory is per session, and the memory effect is a flat log
of items, good for recall but not for building up a structured, linked body of
knowledge that the agent reads back, revises, and cross-references. People who
run agents over long horizons converge on the same answer: keep a wiki, a set of
pages the agent reads, writes, and links, so knowledge accumulates instead of
being re-derived. crucible has no such substrate. This effect is it: typed pages
the agent can read, write, list, and search, with typed links so a page can
record not just "see also" but that one finding contradicts, extends, or
supersedes another, which an untyped wikilink cannot represent. The pure
interpreter makes a knowledge-base workflow testable without a model or a disk;
the directory interpreter stores plain markdown files in a repo, so the pages are
human-readable, git-diffable, and get version history for free. This foundation
is deliberately small; the crucible-specific payoff (grounding-gated writes, so a
page's claims must be supported by its sources) builds on it in a later cycle.

## Decisions taken during design

- **Named "Research", pages are the unit.** The module is `Crucible.Research`
  and the effect is `Research`; the research doc's "Wiki" is this, renamed.
- **Foundation + directory interpreter only.** This cycle ships the typed page,
  the effect, the pure interpreter, and the directory interpreter. Ops-as-tools,
  grounding-gated writes, and lint are follow-on beads (each independently
  useful, per the research's suggested order).
- **`meta` is a Type parameter.** `Page meta` and `Research meta` are
  parameterized by the typed frontmatter type, a plain Type (no effect-row
  indexing), so there are no infinite-type concerns. A single store has one
  `meta` type; multiple page kinds use a sum `meta`.
- **Typed links.** Outbound links carry a `LinkType`
  (`Relates`/`Contradicts`/`Extends`/`Supersedes`), the research's one settled
  structural finding (an untyped wikilink cannot represent a preserved
  contradiction or a supersession). The policy for what to do with each type
  stays in prompts, not types.
- **Naive lexical search.** `search` is a case-insensitive substring match over
  title and body (titles-then-grep), per the research; BM25/embeddings/vector
  search are out (interpreter or application concerns).
- **Directory format reuses the codec facade.** A page file is a `---`-delimited
  JSON frontmatter (`{title, links, meta}`) plus a markdown body; the directory
  interpreter takes a `JSONCodec meta` to (de)serialize frontmatter. Git is the
  provenance layer (the directory lives in a repo); no revision modeling in
  types.

## Design (`Crucible.Research`)

```haskell
newtype Slug = Slug Text
  deriving (Eq, Ord, Show)

data LinkType = Relates | Contradicts | Extends | Supersedes
  deriving (Eq, Show)

data Link = Link { target :: Slug, linkType :: LinkType }
  deriving (Eq, Show)

data Page meta = Page
  { slug  :: Slug
  , title :: Text
  , links :: [Link]
  , body  :: Text
  , meta  :: meta
  }
  deriving (Eq, Show)

data Research meta :: Effect where
  ReadPage  :: Slug -> Research meta m (Maybe (Page meta))
  WritePage :: Page meta -> Research meta m ()
  Index     :: Research meta m [Slug]
  Search    :: Text -> Research meta m [Slug]
  AppendLog :: Text -> Research meta m ()
type instance DispatchOf (Research meta) = Dynamic

readPage  :: (Research meta :> es) => Slug -> Eff es (Maybe (Page meta))
writePage :: (Research meta :> es) => Page meta -> Eff es ()
index     :: (Research meta :> es) => Eff es [Slug]
search    :: (Research meta :> es) => Text -> Eff es [Slug]
appendLog :: (Research meta :> es) => Text -> Eff es ()

-- Pure interpreter (tests): seed pages, return the result, the final pages
-- (slug order), and the appended log lines (in order).
runResearchState :: [Page meta] -> Eff (Research meta : es) a -> Eff es (a, [Page meta], [Text])

-- Directory interpreter (apps): one <slug>.md file per page, AppendLog -> log.md.
-- Takes the frontmatter codec to (de)serialize the page head.
runResearchDir :: (IOE :> es) => JSONCodec meta -> FilePath -> Eff (Research meta : es) a -> Eff es a

-- Codecs (exported for the directory format and for callers):
slugCodec     :: JSONCodec Slug
linkTypeCodec :: JSONCodec LinkType
linkCodec     :: JSONCodec Link
```

### Operation semantics

- `writePage p` stores `p` under `p.slug` (overwrites an existing page with that
  slug).
- `readPage s` returns `Just` the page or `Nothing` if absent.
- `index` returns all slugs (the pure interpreter returns them in slug order;
  the directory interpreter from the directory listing).
- `search q` returns the slugs of pages whose title or body contains `q`,
  case-insensitively (`T.toCaseFold`), in slug order.
- `appendLog line` appends `line` to a running activity log (a `[Text]` in the
  pure interpreter, `log.md` in the directory interpreter).

### Directory format

A page `s` is the file `<dir>/<unSlug s>.md`:

```
---
{"title":"...","links":[{"target":"other","linkType":"extends"}],"meta":{...}}
---
<markdown body>
```

The frontmatter is a single JSON object decoded by a `pageHead` codec
(`{title, links, meta}`) via the `Crucible.Codec` facade and
`Crucible.Decode.decodeLLM` (tolerant). The body is everything after the second
`---` line. The slug is the filename stem (not stored in the frontmatter). A
file that does not parse is treated as absent on read (tolerant, like
`runMemoryFile`'s log reader). `runResearchDir` creates the directory if needed.

## Demo (`app/Main.hs`)

Under a temp `runResearchDir` (no API key needed; place it with the other demos
for consistency): write two pages, one linking the other with `Extends`; read
one back and print its title and links; `search` for a term and print the
matching slugs; `index` and `appendLog`, then print the log. Shows the typed,
persistent, searchable store.

## Manual (`docs/research.md`, new page, nav_order 14)

The typed `Page` and typed links; the `Research` effect and its five operations;
the two interpreters (`runResearchState` for tests, `runResearchDir` for apps);
the directory file format; and that this is the foundation, with ops-as-tools,
grounding-gated writes, and lint planned as follow-ons. House style: no
emdashes/endashes, no hype words, no manifest mentions.

## Testing (hermetic)

`runResearchState` (pure):
- write-then-read: `writePage p` then `readPage p.slug` returns `Just p`.
- `readPage` of an absent slug returns `Nothing`.
- `writePage` with an existing slug overwrites.
- `index` returns the written slugs in slug order.
- `search` matches a term in the title and a term in the body (case-insensitive),
  and returns `[]` for no match.
- `appendLog` lines come back in order in the third tuple component.
- the final pages dump reflects all writes.

`runResearchDir` (temp directory; create under `/tmp`, remove after):
- write a page in one `runResearchDir` call; in a SEPARATE call on the same dir,
  `readPage` returns it with title, typed links, and `meta` intact (outlives
  sessions).
- `index` lists the written slugs; `search` greps title/body.
- a page with several typed links round-trips (link targets + link types
  preserved).

Codec:
- `linkCodec`/`linkTypeCodec` round-trip each `LinkType`; the page-head codec
  (`{title, links, meta}`) round-trips with a sample `meta`.

Live: none required (no model); the demo runs under the key-gated block but uses
no key.

## Non-goals (this cycle)

- Wiki operations exposed as `Tool`s (a follow-on bead).
- Grounding-gated writes (the crucible-specific payoff; a follow-on bead
  building on `Crucible.Eval.Grounding`).
- Lint as `Eval` cases (orphans, broken links, contradictions; a follow-on).
- BM25, embeddings, vector search, rank fusion (naive lexical only).
- Revision history / confidence scores / decay curves (git is the provenance
  layer; confidence was criticized as false precision).
- A background consolidation scheduler (the caller's loop; crucible ships the
  effect, not a daemon).
- Conversational/working memory (owned by `Chat`/`Agent` state already).
