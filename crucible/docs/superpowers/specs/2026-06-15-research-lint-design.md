# Research Lint Design Spec

**Date:** 2026-06-15
**Status:** Approved design, pending implementation
**Tracker:** `crucible-38q` (follow-on to `crucible-1z4`, the Research foundation; from `docs/superpowers/research/2026-06-11-llm-wiki.md` rec 5). The last Research follow-on.
**Goal:** Lint a Research page set: pure structural checks (orphans, broken links, sparse pages) and judge-based semantic checks (contradiction between pages, staleness against current facts), returning typed findings.

**Scope:** new `src/Crucible/Research/Lint.hs`; `test/Spec.hs`; `app/Main.hs`; `docs/research.md` (a "Linting a store" section, and remove the last follow-on item). No change to `Crucible.Research` or `Crucible.Eval`.

## What problem this solves

A knowledge base degrades silently as it grows: pages get orphaned when the links
that pointed to them are rewritten, links dangle when a page is renamed, stubs
accumulate, two pages drift into saying opposite things, and a page that was
right last month is now contradicted by what the agent has since learned. None of
this throws an error; the store just quietly gets less trustworthy. Lint surfaces
it. The structural checks are pure and free: they catch the mechanical decay
(orphans, broken links, thin pages) over the page set with no model call. The
semantic checks reuse crucible's judge: they flag pages that contradict each
other, and pages that conflict with a current-facts trace the caller supplies, so
the agent (or a human, or a scheduled pass) can find and fix the rot instead of
discovering it when a downstream read returns something wrong. It is the lint pass
for an agent's notes, the counterpart to the grounding gate on the way in.

## Decisions taken during design

- **Structural lint is pure.** orphans, broken links, sparse pages are functions
  over `[Page meta]` returning `[Finding]`. No `LLM`, deterministic.
- **Semantic lint reuses the judge vote.** Contradiction and staleness call
  `Crucible.Eval.Judge.vote` (the bead's "reuse the judge vote machinery"), so
  they run under the scripted and live interpreters.
- **Staleness is judged against caller-supplied current facts**, not a page
  timestamp. The core `Page` stays timestamp-free (a wall-clock field would break
  the deterministic write-then-read round-trip; age is not staleness; and `meta`
  is the extension point for callers who want their own timestamp). Staleness
  asks: does this page conflict with or lag behind these current facts?
- **Contradiction pairs are caller-chosen.** `linkedPairs` (bounded: pages joined
  by a link) is the default; `allPairs` (O(n^2)) is available for a full sweep.
- **Output is `[Finding]`, not `Report`.** The `Report` type models a
  system-under-test over inputs; a static page set has no input/output/expectation
  per page, so findings are the natural shape. The judge reuse (the bead's
  substantive ask) is honored via `vote`. A `Report`/`renderReport` adapter is a
  non-goal unless a caller needs it.

## Design (`Crucible.Research.Lint`)

```haskell
data Finding
  = Orphan        Slug        -- ^ no inbound links from any page in the set
  | BrokenLink    Slug Link   -- ^ source slug; a link whose target is not in the set
  | SparsePage    Slug Int    -- ^ slug; body length, which is below the threshold
  | Contradiction Slug Slug Text  -- ^ the two page slugs that contradict; the judge's rationale
  | Stale         Slug Text   -- ^ a page that conflicts with the current facts; the judge's rationale
  deriving (Eq, Show)

-- Structural (pure).
orphans      :: [Page meta] -> [Finding]
brokenLinks  :: [Page meta] -> [Finding]
sparsePages  :: Int -> [Page meta] -> [Finding]   -- Int = min body length to not be sparse
lintStructural :: Int -> [Page meta] -> [Finding] -- orphans ++ brokenLinks ++ sparsePages threshold

-- Pair selectors for contradiction.
linkedPairs :: [Page meta] -> [(Page meta, Page meta)]  -- unique unordered pairs joined by a link
allPairs    :: [Page meta] -> [(Page meta, Page meta)]  -- every unique unordered pair (O(n^2))

-- Semantic (judge).
lintContradictions :: (LLM :> es) => Int -> [(Page meta, Page meta)] -> Eff es [Finding]
lintStale          :: (LLM :> es) => Int -> Text -> [Page meta] -> Eff es [Finding]

-- Combined.
data LintOpts meta = LintOpts
  { sparseThreshold :: Int
  , votes           :: Int
  , pairs           :: [Page meta] -> [(Page meta, Page meta)]
  , currentFacts    :: Maybe Text
  }
defaultLintOpts :: LintOpts meta   -- sparseThreshold 1, votes 1, pairs = linkedPairs, currentFacts = Nothing
lintWiki :: (LLM :> es) => LintOpts meta -> [Page meta] -> Eff es [Finding]
```

### Check semantics

- **orphans:** a page whose slug is the `target` of no `Link` on any page in the
  set. (A page is not its own inbound link.)
- **brokenLinks:** for each page, each `Link` whose `target` is not the slug of
  any page in the set, reported as `BrokenLink (page slug) link`.
- **sparsePages:** a page whose `T.length body` is `< threshold`, reported as
  `SparsePage slug (T.length body)`.
- **linkedPairs:** unique unordered pairs `(a, b)` where `a` links to `b` or `b`
  links to `a`; each pair once.
- **lintContradictions n pairs:** for each `(a, b)`, `vote True
  defaultJudgeOpts{votes=n}` with a rubric like "these two pages make
  contradictory claims" over both bodies rendered; a passing vote yields
  `Contradiction a.slug b.slug why`.
- **lintStale n facts pages:** for each page, `vote` with a rubric embedding the
  `facts` ("the page conflicts with or is out of date relative to these current
  facts") over the page body; a passing vote yields `Stale slug why`.
- **lintWiki opts pages:** `lintStructural opts.sparseThreshold pages` `++`
  `lintContradictions opts.votes (opts.pairs pages)` `++` (when
  `opts.currentFacts` is `Just facts`) `lintStale opts.votes facts pages`.

The contradiction/staleness rubrics decide "is there a problem"; a positive vote
is a finding. A judge error or abstain yields no finding (lint does not invent
problems on judge failure; this mirrors how a non-decisive vote is treated as
"not flagged").

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block: build a small page set with a deliberate orphan,
a broken link, and a sparse page, plus two pages that contradict each other; run
`lintWiki` (with `currentFacts` set to a short fact for one staleness check) under
the live `Chat`/`LLM`, and print the findings. Stack:
`runEff (Anthropic.run cfg (... lintWiki opts pages ...))` (lint needs only `LLM`,
not `Research`, since it takes the page list directly). Print each finding.

## Manual (`docs/research.md`)

A "Linting a store" section: the `Finding` type; the pure structural checks
(`orphans`/`brokenLinks`/`sparsePages`/`lintStructural`); the judge checks
(`lintContradictions` with `linkedPairs`/`allPairs`, `lintStale` against current
facts); `lintWiki`/`LintOpts`/`defaultLintOpts`; that structural lint is pure and
free while semantic lint costs judge calls; and that staleness is judged against
caller-supplied current facts rather than a timestamp (with `meta` as the place to
put a timestamp if you want age-based checks). Remove the last item from "planned
follow-on work" (the Research arc is then complete). House style: no
emdashes/endashes, no hype words, no manifest mentions.

## Testing (hermetic)

Structural (pure, deterministic):
- **orphans:** a set where page B has no inbound link returns `[Orphan "b"]`; a
  set where every page is linked returns `[]`.
- **brokenLinks:** a page linking to an absent slug returns
  `[BrokenLink src theLink]`; all-resolvable links return `[]`.
- **sparsePages:** a page with a short body under the threshold is flagged with
  its length; a long body is not.
- **lintStructural** combines the three.
- **linkedPairs/allPairs:** the expected pair counts/contents for a small set
  (each pair once, unordered).

Semantic (via `runLLMScripted`, canned verdicts in the `{"why":...,"pass":...}`
format the judge uses):
- **lintContradictions:** one pair, a `pass:true` verdict yields one
  `Contradiction` with the rationale; a `pass:false` verdict yields `[]`.
- **lintStale:** one page, `pass:true` against the facts yields one `Stale`;
  `pass:false` yields `[]`.
- **lintWiki:** a set with one structural issue and one scripted contradiction
  (and `currentFacts = Nothing` to keep the script small, or `Just` with a
  staleness verdict) returns the union of findings; the structural part needs no
  script.

Live: the demo lint pass before merge (gated on the Anthropic key).

## Non-goals

- A core-`Page` timestamp, age-based decay, or confidence scores (a wall-clock
  field breaks determinism; `meta` is the place for caller timestamps).
- A `Report`/`renderEval` adapter for findings (findings are the output; add an
  adapter later only if a caller needs `renderReport`).
- `allPairs` as the default contradiction sweep (opt-in; `linkedPairs` is the
  bounded default).
- Auto-fixing findings (lint reports; fixing is the caller's, e.g. via the
  Research tools).
- Supersedes-based staleness (this cycle judges against current facts instead;
  the typed `Supersedes` link remains available structurally to callers).
