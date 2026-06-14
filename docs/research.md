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

A slug becomes a filename in the directory interpreter, so validate model-chosen
slugs with `mkSlug :: Text -> Maybe Slug` (it rejects an empty slug, a path
separator, or a parent reference). The directory interpreter also refuses a
path-unsafe slug itself: a read returns `Nothing` and a write is a no-op, so a
slug can never escape the directory.

## Interpreters

```haskell
runResearchState :: [Page meta] -> Eff (Research meta : es) a -> Eff es (a, [Page meta], [Text])
runResearchDir   :: (IOE :> es) => JSONCodec meta -> FilePath -> Eff (Research meta : es) a -> Eff es a
```

`runResearchState` keeps the pages in memory and returns the final pages and log
alongside the result, for tests. `runResearchDir` stores one `<slug>.md` file per
page in a directory: a `---`-delimited JSON frontmatter (`title`, `links`,
`meta`) followed by the markdown body, with the activity log in `activity.log`
(a non-`.md` name, so no page slug collides with it). The files are plain
markdown in a repo, so they are human-readable, git-diffable, and get version
history for free. A later session reading the same directory sees the earlier
pages. `index` lists the `.md` files on disk, which may include a file whose
head no longer decodes.

## Grounding-gated writes

A page is only as trustworthy as the write that created it. `writeGrounded`
commits a page only when its body's claims are supported by a source trace.

```haskell
data NoClaimsPolicy = CommitNoClaims | RejectNoClaims
data GroundGate = GroundGate { threshold :: Double, votes :: Int, onNoClaims :: NoClaimsPolicy }
defaultGroundGate :: GroundGate   -- threshold 1.0, votes 1, CommitNoClaims

writeGrounded :: (Research meta :> es, LLM :> es)
              => GroundGate -> Text -> Page meta -> Eff es (Either GroundingOutcome ())
```

`writeGrounded gate evidence page` decomposes the page body into claims, verifies
each against the evidence with the judge, and commits the page with `writePage`
only if the supported fraction meets `threshold`. `Right ()` means committed;
`Left outcome` means it was not written, and the outcome names the unsupported
claims. A body with no factual claims commits or is rejected per `onNoClaims`; a
verifier breakdown always rejects, so an edit is never committed unverified. This
is automated claim-level verified ingest: an agent can write to its knowledge
base and have unsupported claims kept out by default.

To flag rather than gate (always write, but record the grounding result), call
`groundingOutcome` and then `writePage` and `appendLog` yourself; the gate is the
strict default, and the building blocks are public.

## Planned follow-on work

This is the foundation. Exposing the operations as `Tool`s for the stock agent
loop and lint as `Eval` cases (orphans, broken links, contradictions) are planned
as separate work.
