# Research Lint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Crucible.Research.Lint`: pure structural lint (orphans, broken links, sparse pages) and judge-based semantic lint (contradiction, staleness vs current facts) over a Research page set, returning `[Finding]`.

**Architecture:** Structural checks are pure functions over `[Page meta]`. Semantic checks reuse `Crucible.Eval.Judge.vote`. `lintWiki` combines them under a `LintOpts` config. The `Research` effect and `Eval` are unchanged.

**Tech Stack:** GHC 9.12.2, effectful, `Crucible.Eval.Judge`; zinc build.

**Spec:** `docs/superpowers/specs/2026-06-15-research-lint-design.md`

## Conventions (every task)
- Build/test: `nix develop . --command timeout -s KILL 300 zinc build|test`. Judge success by exit status or "test suite(s) passed", never a pipeline tail. 137 = GHC flake, retry once; second 137 = BLOCKED. Ignore "Git tree is dirty".
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot. `(.field)` getter sections often need an inline annotation under DuplicateRecordFields. Annotate and report.
- Tests: custom harness `check "label" expected actual`; comma entries in `runChecks` at END of `test/Spec.hs`. No hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit per task; do not push.

## Confirmed facts
- `Crucible.Research` exports `Page (..)` (`slug`/`title`/`links`/`body`/`meta`), `Slug (..)`, `Link (..)` (`target`/`linkType`), `LinkType (..)`.
- `Crucible.Eval.Judge` exports `vote :: (LLM :> es) => Bool -> JudgeOpts -> Text -> Text -> Eff es VoteOutcome`, `defaultJudgeOpts`, `JudgeOpts (..)` (field `votes :: Int`), `VoteOutcome (..)` with `Decided {pass :: Bool, why :: Text, dissent, yes, no}`, `AllErrored Text`, `AllAbstained Text`.
- Scripted verdict reply format (the judge's): `"{\"why\":\"...\",\"pass\":true}"` (or `false`). `runLLMScripted` / `runPureEff` are imported in `test/Spec.hs`.
- A record update `defaultJudgeOpts { votes = n }` may be ambiguous under DuplicateRecordFields because `JudgeOpts` and `LintOpts` both have a `votes` field; annotate the record as `(defaultJudgeOpts :: JudgeOpts) { votes = n }` if so (the grounding-gate module needed this).

## File Structure
- Create `src/Crucible/Research/Lint.hs` — Finding, structural, pair helpers, semantic, lintWiki (Task 1).
- Modify `test/Spec.hs` — pure + scripted tests (Task 1).
- Modify `app/Main.hs` — live demo (Task 2).
- Modify `docs/research.md` — lint section; finish the Research arc (Task 3).

---

### Task 1: `Crucible.Research.Lint` + tests

**Files:**
- Create: `src/Crucible/Research/Lint.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Create `src/Crucible/Research/Lint.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- | Lint a 'Crucible.Research' page set. Structural checks (orphans, broken
-- links, sparse pages) are pure over the page set; semantic checks
-- (contradiction between pages, staleness against caller-supplied current facts)
-- reuse the judge vote ('Crucible.Eval.Judge.vote'). Returns typed 'Finding's.
-- Lives apart from 'Crucible.Research' so that module keeps no dependency on the
-- eval machinery.
module Crucible.Research.Lint
  ( Finding (..)
  , orphans, brokenLinks, sparsePages, lintStructural
  , linkedPairs, allPairs
  , lintContradictions, lintStale
  , LintOpts (..), defaultLintOpts, lintWiki
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Effectful

import Crucible.Eval.Judge (JudgeOpts (..), VoteOutcome (..), defaultJudgeOpts, vote)
import Crucible.LLM (LLM)
import Crucible.Research (Page (..), Slug (..), Link (..))

data Finding
  = Orphan        Slug
  | BrokenLink    Slug Link
  | SparsePage    Slug Int
  | Contradiction Slug Slug Text
  | Stale         Slug Text
  deriving (Eq, Show)

slugText :: Slug -> Text
slugText (Slug s) = s

-- Structural (pure).

-- | Pages with no inbound link from any other page (self-links do not count).
orphans :: [Page meta] -> [Finding]
orphans pages = [Orphan p.slug | p <- pages, p.slug `notElem` inbound]
  where inbound = [l.target | q <- pages, l <- q.links, l.target /= q.slug]

-- | Links whose target is not the slug of any page in the set.
brokenLinks :: [Page meta] -> [Finding]
brokenLinks pages = [BrokenLink p.slug l | p <- pages, l <- p.links, l.target `notElem` slugs]
  where slugs = map (.slug) pages

-- | Pages whose body is shorter than the threshold.
sparsePages :: Int -> [Page meta] -> [Finding]
sparsePages threshold pages =
  [SparsePage p.slug (T.length p.body) | p <- pages, T.length p.body < threshold]

-- | orphans ++ brokenLinks ++ sparsePages.
lintStructural :: Int -> [Page meta] -> [Finding]
lintStructural threshold pages =
  orphans pages ++ brokenLinks pages ++ sparsePages threshold pages

-- Pair selectors.

-- | Every unique unordered pair (O(n^2)).
allPairs :: [Page meta] -> [(Page meta, Page meta)]
allPairs (x : xs) = map ((,) x) xs ++ allPairs xs
allPairs []       = []

-- | Unique unordered pairs joined by a link in either direction.
linkedPairs :: [Page meta] -> [(Page meta, Page meta)]
linkedPairs pages = filter joined (allPairs pages)
  where joined (a, b) = any ((== b.slug) . target') a.links || any ((== a.slug) . target') b.links
        target' l = l.target

-- Semantic (judge).

-- | Judge each pair for a contradiction; a passing vote is a 'Contradiction'.
lintContradictions :: forall meta es. (LLM :> es) => Int -> [(Page meta, Page meta)] -> Eff es [Finding]
lintContradictions n prs = concat <$> mapM check prs
  where
    check :: (Page meta, Page meta) -> Eff es [Finding]
    check (a, b) = do
      out <- vote True (defaultJudgeOpts :: JudgeOpts) { votes = n }
               "These two pages make claims that contradict each other."
               (rendered a b)
      pure $ case out of
        Decided True why _ _ _ -> [Contradiction a.slug b.slug why]
        _                      -> []
    rendered a b =
      "Page 1 (" <> slugText a.slug <> "):\n" <> a.body
        <> "\n\nPage 2 (" <> slugText b.slug <> "):\n" <> b.body

-- | Judge each page against the current facts; a passing vote is 'Stale'.
lintStale :: forall meta es. (LLM :> es) => Int -> Text -> [Page meta] -> Eff es [Finding]
lintStale n facts pages = concat <$> mapM check pages
  where
    check :: Page meta -> Eff es [Finding]
    check p = do
      out <- vote True (defaultJudgeOpts :: JudgeOpts) { votes = n }
               ("The page conflicts with or is out of date relative to these current facts:\n" <> facts)
               p.body
      pure $ case out of
        Decided True why _ _ _ -> [Stale p.slug why]
        _                      -> []

-- Combined.

data LintOpts meta = LintOpts
  { sparseThreshold :: Int
  , votes           :: Int
  , pairs           :: [Page meta] -> [(Page meta, Page meta)]
  , currentFacts    :: Maybe Text
  }

-- | sparseThreshold 1, votes 1, pairs = linkedPairs, currentFacts = Nothing.
defaultLintOpts :: LintOpts meta
defaultLintOpts = LintOpts 1 1 linkedPairs Nothing

-- | Structural ++ contradictions (over @pairs@) ++ staleness (when @currentFacts@).
lintWiki :: forall meta es. (LLM :> es) => LintOpts meta -> [Page meta] -> Eff es [Finding]
lintWiki opts pages = do
  cs <- lintContradictions opts.votes (opts.pairs pages)
  ss <- maybe (pure []) (\facts -> lintStale opts.votes facts pages) opts.currentFacts
  pure (lintStructural opts.sparseThreshold pages ++ cs ++ ss)
```
Notes:
- `(.slug)`/`(.links)`/`(.body)`/`(.target)` getter sections may need inline annotations under DuplicateRecordFields (e.g. `((.slug) :: Page meta -> Slug)`); add them where GHC complains and report. The `target'`/`slugText` helpers keep some of them local.
- The `(defaultJudgeOpts :: JudgeOpts) { votes = n }` annotation resolves the `votes` field ambiguity between `JudgeOpts` and `LintOpts`.
- `Decided True why _ _ _` extracts the rationale; non-decisive outcomes (`Decided False`, `AllErrored`, `AllAbstained`) yield no finding.
- `lintWiki`/`lintContradictions`/`lintStale` use `forall meta es.` (ScopedTypeVariables) for the inner `check` signatures.

- [ ] **Step 2: Add tests to `test/Spec.hs`**

Add `import Crucible.Research.Lint (Finding (..), orphans, brokenLinks, sparsePages, lintStructural, linkedPairs, allPairs, lintContradictions, lintStale, LintOpts (..), defaultLintOpts, lintWiki)`. `Page`/`Slug`/`Link`/`LinkType` are imported from `Crucible.Research`; `runPureEff`/`runLLMScripted` are in scope. `meta = ()` for structural, `Text` is fine too. Structural functions are pure (call directly, no interpreter). Add to `runChecks`:

```haskell
  , let pA = Page (Slug "a") "A" [Link (Slug "b") Relates] "body of a" ()
        pB = Page (Slug "b") "B" [] "body of b" ()
    in check "lint: orphan is a page with no inbound link" [Orphan (Slug "a")] (orphans [pA, pB])
  , let pC = Page (Slug "c") "C" [Link (Slug "ghost") Relates] "body of c" ()
    in check "lint: broken link to an absent target"
         [BrokenLink (Slug "c") (Link (Slug "ghost") Relates)] (brokenLinks [pC])
  , let pS = Page (Slug "s") "S" [] "hi" ()
        pL = Page (Slug "l") "L" [] "a sufficiently long body" ()
    in check "lint: sparse page under the threshold" [SparsePage (Slug "s") 2] (sparsePages 5 [pS, pL])
  , let pA = Page (Slug "a") "A" [Link (Slug "b") Relates] "aaaaa" ()
        pB = Page (Slug "b") "B" [] "bbbbb" ()
        pC = Page (Slug "c") "C" [] "ccccc" ()
    in check "lint: linkedPairs only joined pairs; allPairs all"
         (1, 3)
         (length (linkedPairs [pA, pB, pC]), length (allPairs [pA, pB, pC]))
  , let pA = Page (Slug "a") "A" [] "x" ()
        pB = Page (Slug "b") "B" [] "y" ()
    in check "lint: contradiction on a passing vote"
         [Contradiction (Slug "a") (Slug "b") "they disagree"]
         (runPureEff (runLLMScripted ["{\"why\":\"they disagree\",\"pass\":true}"]
            (lintContradictions 1 [(pA, pB)])))
  , let pA = Page (Slug "a") "A" [] "x" ()
        pB = Page (Slug "b") "B" [] "y" ()
    in check "lint: no contradiction on a failing vote"
         ([] :: [Finding])
         (runPureEff (runLLMScripted ["{\"why\":\"unrelated\",\"pass\":false}"]
            (lintContradictions 1 [(pA, pB)])))
  , let p = Page (Slug "a") "A" [] "the moon is made of cheese" ()
    in check "lint: stale on a passing vote against current facts"
         [Stale (Slug "a") "contradicts the facts"]
         (runPureEff (runLLMScripted ["{\"why\":\"contradicts the facts\",\"pass\":true}"]
            (lintStale 1 "the moon is made of rock" [p])))
  , let pA = Page (Slug "a") "A" [Link (Slug "b") Relates] "aaaaa" ()  -- a links b; a has no inbound -> orphan
        pB = Page (Slug "b") "B" [] "bbbbb" ()
        (res) = runPureEff (runLLMScripted ["{\"why\":\"clash\",\"pass\":true}"]
                  (lintWiki defaultLintOpts { sparseThreshold = 1 } [pA, pB]))
    in check "lint: lintWiki combines structural and contradiction"
         [Orphan (Slug "a"), Contradiction (Slug "a") (Slug "b") "clash"]
         res
```
Notes:
- `meta = ()` everywhere here; `Page`/`Finding` derive `Eq`/`Show`. If `Page ()` is ambiguous, annotate one binding.
- The `lintWiki` test: `defaultLintOpts` has `currentFacts = Nothing` (so no staleness, no extra verdict needed), `pairs = linkedPairs` ([(pA,pB)] since a links b), `sparseThreshold = 1` (bodies length 5, not sparse). Structural finds `Orphan a` (a has no inbound; b is linked by a). The single scripted `pass:true` verdict makes the one contradiction. Expected order: structural (`Orphan a`) then contradictions (`Contradiction a b`), matching `lintWiki`'s `structural ++ cs ++ ss`.
- If the record-update `defaultLintOpts { sparseThreshold = 1 }` is ambiguous, it should resolve via `defaultLintOpts :: LintOpts meta`; annotate if needed.

- [ ] **Step 3: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the eight new lint checks pass; full suite green. If a verdict format mismatches, copy the exact `{"why","pass"}` shape from the existing judge tests and pin. Retry once on 137.

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/Research/Lint.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(research): lint (structural + judge contradiction/staleness)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Live demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a lint demo**

Read `app/Main.hs`. It imports `qualified Crucible.Research as Research`, `Anthropic.run`, `runEff`, `cfg`, `TIO`, `T`. Add `import Crucible.Research.Lint (lintWiki, LintOpts (..), defaultLintOpts, Finding)`. Inside the `Just key -> do` block, after an existing Research demo, add:
```haskell
      -- Lint: structural issues (pure) plus a judged contradiction, over a small set.
      let lintPages =
            [ Research.Page (Research.Slug "earth") "Earth" [Research.Link (Research.Slug "moon") Research.Relates]
                "Earth is the third planet." ("" :: T.Text)
            , Research.Page (Research.Slug "moon") "Moon" []
                "The Moon orbits Earth." ("" :: T.Text)
            , Research.Page (Research.Slug "stub") "Stub" [] "x" ("" :: T.Text)   -- sparse + orphan
            , Research.Page (Research.Slug "hot") "Climate" [] "The planet is cooling rapidly." ("" :: T.Text)
            , Research.Page (Research.Slug "cold") "Climate2" [] "The planet is warming rapidly." ("" :: T.Text)
            ]
          lintOpts = defaultLintOpts { sparseThreshold = 5, pairs = Research.Lint.allPairs }
      findings <- runEff (Anthropic.run cfg (lintWiki lintOpts lintPages))
      TIO.putStrLn ("lint: " <> T.pack (show (length findings)) <> " finding(s):")
      mapM_ (\f -> TIO.putStrLn ("  " <> T.pack (show f))) findings
```
Notes:
- `meta = T.Text`. `lintWiki` needs only `LLM` (via `Anthropic.run`), not `Research`, since it takes the page list directly. Stack: `runEff (Anthropic.run cfg (lintWiki lintOpts lintPages))`.
- This uses `allPairs` to give the contradiction judge a chance to see the two climate pages; import `allPairs` too: add it to the `Crucible.Research.Lint` import (and drop the `Research.Lint.` qualifier in the code, using the imported `allPairs` directly). Set `pairs = allPairs`.
- `sparseThreshold = 5` flags the "stub" page (body "x", length 1) which is also an orphan. `defaultLintOpts` has `currentFacts = Nothing` (no staleness in the demo to avoid a long run; the structural + contradiction findings are the point).
- If a row/annotation issue arises, resolve and report.

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. Retry once on 137. (Do not run the binary.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "$(cat <<'EOF'
demo(research): lint a small store (structural + judged contradiction)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: "Linting a store" section in `docs/research.md`; finish the arc

**Files:**
- Modify: `docs/research.md`

- [ ] **Step 1: Add the section and remove the last follow-on**

Read `docs/research.md`. Insert a `## Linting a store` section after "Maintaining a store with an agent" and before "Planned follow-on work". Content (real triple-backtick fences):

```markdown
## Linting a store

A knowledge base decays as it grows. Lint surfaces the rot.

```haskell
data Finding = Orphan Slug | BrokenLink Slug Link | SparsePage Slug Int
             | Contradiction Slug Slug Text | Stale Slug Text

lintStructural :: Int -> [Page meta] -> [Finding]
lintContradictions :: (LLM :> es) => Int -> [(Page meta, Page meta)] -> Eff es [Finding]
lintStale :: (LLM :> es) => Int -> Text -> [Page meta] -> Eff es [Finding]
lintWiki :: (LLM :> es) => LintOpts meta -> [Page meta] -> Eff es [Finding]
```

The structural checks are pure and free: `orphans` (no inbound link),
`brokenLinks` (a link whose target is absent), `sparsePages` (a body under the
threshold). The semantic checks reuse the judge: `lintContradictions` flags pages
that make contradictory claims (over `linkedPairs` by default, or `allPairs` for a
full O(n^2) sweep), and `lintStale` flags pages that conflict with a current-facts
trace you supply. `lintWiki` runs the lot under `LintOpts`
(`sparseThreshold`, `votes`, `pairs`, `currentFacts`); `defaultLintOpts` is
structural plus contradiction over linked pairs, no staleness.

Staleness is judged against current facts you pass in, not a page timestamp: the
page type stays timestamp-free for a deterministic round-trip, and a timestamp,
if you want age-based checks, belongs in your `meta`.
```
(The outer ```markdown fence delimits this block in the plan only; write real markdown.)

Then in "Planned follow-on work", remove the lint item. The Research foundation, grounding-gated writes, tools, and lint are all shipped now; if nothing remains in the section, replace it with a short closing line, e.g. "The Research effect, grounded writes, agent tools, and lint are all available." or remove the empty section heading.

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/research.md` (expect no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/research.md` (expect no output).

- [ ] **Step 3: Commit**

```bash
git add docs/research.md
git commit -m "$(cat <<'EOF'
docs(research): Linting a store section; Research arc complete

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** `Finding` (T1), structural pure (T1), `linkedPairs`/`allPairs` (T1), `lintContradictions`/`lintStale` (T1), `LintOpts`/`defaultLintOpts`/`lintWiki` (T1), 8 tests incl. scripted semantic + lintWiki integration (T1 S2), demo (T2), docs + remove last follow-on (T3). Non-goals (Page timestamps/decay, Report adapter, allPairs default) are "do not build".
- **Type consistency:** `lintStructural :: Int -> [Page meta] -> [Finding]`, `lintContradictions :: (LLM :> es) => Int -> [(Page meta, Page meta)] -> Eff es [Finding]`, `lintStale :: (LLM :> es) => Int -> Text -> [Page meta] -> Eff es [Finding]`, `LintOpts meta {sparseThreshold, votes, pairs, currentFacts}`, `lintWiki :: (LLM :> es) => LintOpts meta -> [Page meta] -> Eff es [Finding]`. Consistent across module, tests, demo, docs.
- **Placeholder scan:** no placeholder code. Judgement points flagged: getter annotations under DuplicateRecordFields, the `(defaultJudgeOpts :: JudgeOpts){votes=n}` ambiguity, the verdict format (with a pin instruction), and the demo's `allPairs` import. No vague steps.
