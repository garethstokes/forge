---
title: Research
nav_order: 14
---

# Research

An agent that works on a topic across sessions needs somewhere to accumulate
what it learns. The research effect is a typed, persistent knowledge base: typed
pages with typed links, read, written, listed, and searched through one effect.

## Typed pages

```haskell
newtype Slug = Slug Text
data LinkType = Relates | Contradicts | Extends | Supersedes
data Link = Link { target :: Slug, linkType :: LinkType }
data Page meta = Page
  { slug :: Slug, title :: Text, links :: [Link], body :: Text, meta :: meta }
```

A page carries typed frontmatter (`meta`, any type with a codec) and typed
outbound links. The link type matters: an untyped link cannot say that one
finding contradicts, extends, or supersedes another. The policy for what to do
with each link type stays in your prompts; the structure stays in the type.

## The effect

```haskell
readPage  :: (Research meta :> es) => Slug -> Eff es (Maybe (Page meta))
writePage :: (Research meta :> es) => Page meta -> Eff es ()
index     :: (Research meta :> es) => Eff es [Slug]
search    :: (Research meta :> es) => Text -> Eff es [Slug]
appendLog :: (Research meta :> es) => Text -> Eff es ()
```

`writePage` overwrites the page with that slug. `search` is a case-insensitive
substring match over title and body (titles-then-grep covers the cases where a
wiki wins; richer ranking is left to interpreters). `appendLog` records a line in
a running activity log.

`index`, `search`, and `appendLog` do not mention `meta` in their result, so when
a call is not next to a `readPage` or `writePage` that fixes it, give the type
explicitly: `index @MyMeta`, `search @MyMeta "term"`.

## Interpreters

```haskell
runResearchState :: [Page meta] -> Eff (Research meta : es) a -> Eff es (a, [Page meta], [Text])
runResearchDir   :: (IOE :> es) => JSONCodec meta -> FilePath -> Eff (Research meta : es) a -> Eff es a
```

`runResearchState` keeps the pages in memory and returns the final pages and log
alongside the result, for tests. `runResearchDir` stores one `<slug>.md` file per
page in a directory: a `---`-delimited JSON frontmatter (`title`, `links`,
`meta`) followed by the markdown body, with the activity log in `log.md`. The
files are plain markdown in a repo, so they are human-readable, git-diffable, and
get version history for free. A later session reading the same directory sees the
earlier pages.

## Planned follow-on work

This is the foundation. Exposing the operations as `Tool`s for the stock agent
loop, grounding-gated writes (verifying a page's claims against its sources with
`Crucible.Eval.Grounding` before a write commits), and lint as `Eval` cases
(orphans, broken links, contradictions) are planned as separate work.
