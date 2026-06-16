# Research Effect (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Crucible.Research`: a typed, persistent agent knowledge base. Typed pages with typed links, a `Research` effect (`readPage`/`writePage`/`index`/`search`/`appendLog`), a pure interpreter for tests, and a directory-of-markdown interpreter for apps.

**Architecture:** A dynamic effect parameterized by the frontmatter type `meta`. The pure interpreter keeps pages in `State` (an assoc list, no `containers` dep). The directory interpreter stores one `<slug>.md` per page (a `---`-delimited JSON frontmatter `{title,links,meta}` plus a markdown body), reusing the `Crucible.Codec` facade for the frontmatter. Mirrors `Crucible.Memory`/`Crucible.Ledger`.

**Tech Stack:** GHC 9.12.2, effectful, autodocodec via `Crucible.Codec`, `filepath` (already a lib dep), `directory` (added this cycle); zinc build.

**Spec:** `docs/superpowers/specs/2026-06-14-research-effect-design.md`

## Conventions (every task)
- Build/test: `nix develop . --command timeout -s KILL 300 zinc build|test`. Judge success by exit status or "test suite(s) passed", never a pipeline tail. 137 = GHC flake, retry once; second 137 = BLOCKED. Ignore "Git tree is dirty".
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot. `(.field)` getter sections often need an inline annotation under DuplicateRecordFields (e.g. `((.slug) :: Page meta -> Slug)`); effectful dynamic State needs `get @T`/`modify @T` annotations. Annotate and report.
- Tests: custom harness `check "label" expected actual`; comma entries in `runChecks` at END of `test/Spec.hs`; `do` blocks allowed. No hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit per task; do not push.
- Modules auto-discovered; only the dependency list needs editing (Task 1 adds `directory` to the library).

## Reference
This mirrors `Crucible.Memory` / `Crucible.Ledger`: a dynamic effect, a pure State interpreter, and an on-disk interpreter tolerant of unparseable input (`try` + skip). `Crucible.Codec` exports `JSONCodec, object, field, list', enum, str, dimapCodec, encodeText`; `Crucible.Decode` exports `decodeLLM`. `System.FilePath` (`</>`, `<.>`, `takeBaseName`, `takeExtension`) is available (lib dep `filepath`). `System.Directory` (`listDirectory`, `createDirectoryIfMissing`, `doesFileExist`) needs `directory` added to the library deps (Task 1 Step 1).

## File Structure
- Modify `zinc.toml` — add `directory` to `[build.lib]` (Task 1).
- Create `src/Crucible/Research.hs` — types, codecs, effect, both interpreters (Tasks 1-2).
- Modify `test/Spec.hs` — pure + codec tests (Task 1), directory tests (Task 2).
- Modify `app/Main.hs` — demo (Task 3).
- Create `docs/research.md` — manual (Task 4).

---

### Task 1: Types, codecs, effect, pure interpreter + tests

**Files:**
- Modify: `zinc.toml`
- Create: `src/Crucible/Research.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Add `directory` to the library deps in `zinc.toml`**

In `[build.lib]` `depends` (line 15), add `"directory"` (keep all existing entries). (`filepath` and `base64-bytestring` are already present.)

- [ ] **Step 2: Create `src/Crucible/Research.hs` (types, codecs, effect, pure interpreter)**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | A typed, persistent knowledge base the agent maintains: typed 'Page's with
-- typed 'Link's, read/written/listed/searched through the 'Research' effect.
-- 'runResearchState' is the pure test interpreter; 'runResearchDir' stores one
-- markdown file per page in a directory (git-diffable, outlives sessions).
-- Sibling of 'Crucible.Memory' and 'Crucible.Ledger'. (The research notes call
-- this a "Wiki"; it ships as "Research".)
module Crucible.Research
  ( Slug (..)
  , LinkType (..)
  , Link (..)
  , Page (..)
  , Research (..)
  , readPage, writePage, index, search, appendLog
  , runResearchState
  , runResearchDir
  , slugCodec, linkTypeCodec, linkCodec
  ) where

import Control.Exception (IOException, try)
import Data.List (find, sort, sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (runState, get, modify)

import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.FilePath ((</>), (<.>), takeBaseName, takeExtension)

import Crucible.Codec (JSONCodec, object, field, list', enum, str, dimapCodec, encodeText)
import Crucible.Decode (decodeLLM)

newtype Slug = Slug Text deriving (Eq, Ord, Show)

unSlug :: Slug -> Text
unSlug (Slug s) = s

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

readPage :: (Research meta :> es) => Slug -> Eff es (Maybe (Page meta))
readPage = send . ReadPage

writePage :: (Research meta :> es) => Page meta -> Eff es ()
writePage = send . WritePage

index :: (Research meta :> es) => Eff es [Slug]
index = send Index

search :: (Research meta :> es) => Text -> Eff es [Slug]
search = send . Search

appendLog :: (Research meta :> es) => Text -> Eff es ()
appendLog = send . AppendLog

-- | Does a page match a query (case-insensitive substring in title or body)?
matchesQuery :: Text -> Page meta -> Bool
matchesQuery q p =
  let q' = T.toCaseFold q
  in T.isInfixOf q' (T.toCaseFold p.title) || T.isInfixOf q' (T.toCaseFold p.body)

-- | Pure interpreter (tests): seed pages, return the result, the final pages in
-- slug order, and the appended log lines in order.
runResearchState :: forall meta es a. [Page meta]
                 -> Eff (Research meta : es) a -> Eff es (a, [Page meta], [Text])
runResearchState seed action = do
  (a, (pages, logRev)) <- reinterpret (runState (seed, [] :: [Text])) (\_ -> \case
    ReadPage s   -> do (ps, _) <- get @([Page meta], [Text]); pure (find (\p -> p.slug == s) ps)
    WritePage p  -> modify @([Page meta], [Text]) (\(ps, l) -> (p : filter (\q -> q.slug /= p.slug) ps, l))
    Index        -> do (ps, _) <- get @([Page meta], [Text]); pure (sort (map (.slug) ps))
    Search q     -> do (ps, _) <- get @([Page meta], [Text]); pure (sort [p.slug | p <- ps, matchesQuery q p])
    AppendLog ln -> modify @([Page meta], [Text]) (\(ps, l) -> (ps, ln : l))) action
  pure (a, sortOn (.slug) pages, reverse logRev)
```
Notes:
- The assoc-list state avoids a `containers` dependency. `WritePage` replaces any existing page with the same slug (filter-then-prepend); final order is normalized by `sortOn (.slug)`.
- `(.slug)`/`(.title)`/`(.body)` getter sections may need annotation under DuplicateRecordFields (e.g. `((.slug) :: Page meta -> Slug)`); annotate and report. The State `get @([Page meta], [Text])` annotations are required.
- `Slug` derives `Ord` (for `sort`/`sortOn`).
- The directory interpreter (`runResearchDir`) and the directory imports are added in Task 2; if GHC warns about unused imports (`createDirectoryIfMissing`, etc.) after Task 1, that is expected and resolved in Task 2 (warnings do not fail the build). If you prefer a clean Task 1 build, add the directory imports in Task 2 instead of now; either is fine.

Add the codecs (used by the directory interpreter and exported):
```haskell
slugCodec :: JSONCodec Slug
slugCodec = dimapCodec Slug unSlug str

linkTypeCodec :: JSONCodec LinkType
linkTypeCodec = enum
  [ ("relates", Relates), ("contradicts", Contradicts)
  , ("extends", Extends), ("supersedes", Supersedes) ]

linkCodec :: JSONCodec Link
linkCodec = object (Link <$> field "target" (.target) slugCodec
                         <*> field "linkType" (.linkType) linkTypeCodec)
```

- [ ] **Step 3: Add pure + codec tests to `test/Spec.hs`**

Add imports near the other crucible imports:
```haskell
import Crucible.Research (Slug (..), LinkType (..), Link (..), Page (..), readPage, writePage, index, search, appendLog, runResearchState, runResearchDir, linkCodec)
```
`runPureEff` is imported; `C` = `Crucible.Codec` (`C.encodeText`); `decodeLLM` from `Crucible.Decode` (imported). Use a simple `meta` for tests: `()` with the unit codec? The page `meta` needs a codec only for the directory tests (Task 2); the pure interpreter holds `Page meta` values directly, so the pure tests can use `meta = ()` with no codec. Build pages directly. Add to `runChecks`:

```haskell
  , let p = Page (Slug "a") "Alpha" [] "the body of alpha" ()
        prog = do writePage p; readPage (Slug "a")
        (r, _, _) = runPureEff (runResearchState [] prog)
    in check "research: write then read" (Just p) r
  , let (r, _, _) = runPureEff (runResearchState ([] :: [Page ()]) (readPage (Slug "missing")))
    in check "research: read absent page is Nothing" (Nothing :: Maybe (Page ())) r
  , let p1 = Page (Slug "a") "Alpha" [] "first" ()
        p2 = Page (Slug "a") "Alpha v2" [] "second" ()
        (r, _, _) = runPureEff (runResearchState [] (do writePage p1; writePage p2; readPage (Slug "a")))
    in check "research: write overwrites by slug" (Just p2) r
  , let ps = [Page (Slug "b") "B" [] "x" (), Page (Slug "a") "A" [] "y" ()]
        (r, _, _) = runPureEff (runResearchState ps index)
    in check "research: index lists slugs in slug order" [Slug "a", Slug "b"] r
  , let ps = [Page (Slug "a") "Alpha note" [] "mentions Haskell" (), Page (Slug "b") "Beta" [] "nothing here" ()]
        (rt, _, _) = runPureEff (runResearchState ps (search "haskell"))   -- body, case-insensitive
        (rti, _, _) = runPureEff (runResearchState ps (search "ALPHA"))    -- title, case-insensitive
        (rn, _, _) = runPureEff (runResearchState ps (search "zzz"))
    in check "research: search matches body/title case-insensitively, else []"
         ([Slug "a"], [Slug "a"], ([] :: [Slug])) (rt, rti, rn)
  , let (_, _, logs) = runPureEff (runResearchState ([] :: [Page ()]) (do appendLog "one"; appendLog "two"))
    in check "research: appendLog accumulates in order" ["one", "two"] logs
  , check "research: linkCodec round-trips each link type"
      (Right (Link (Slug "t") Supersedes))
      (decodeLLM linkCodec (C.encodeText linkCodec (Link (Slug "t") Supersedes)))
```
Notes:
- `meta = ()` needs `Page ()`; `Page` derives `Eq`/`Show`, and `()` has both, so `check` works. The pure interpreter needs no `meta` codec.
- If a `(.slug)` getter or a `Page ()` ambiguity bites, annotate. The `runResearchState` result is a 3-tuple `(a, [Page meta], [Text])`; bind the parts you assert.

- [ ] **Step 4: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the new research checks pass; full suite green. Retry once on 137.

- [ ] **Step 5: Commit**

```bash
git add zinc.toml src/Crucible/Research.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(research): typed pages + Research effect + pure interpreter

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Directory interpreter `runResearchDir` + tests

**Files:**
- Modify: `src/Crucible/Research.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Add the directory interpreter to `src/Crucible/Research.hs`**

Add a private page-head record + codec and the file helpers, then the interpreter. (Ensure the `System.Directory`/`System.FilePath` imports from Task 1 Step 2 are present.)

```haskell
-- The serialized page head (everything but the slug, which is the filename).
data PageHead meta = PageHead { title :: Text, links :: [Link], meta :: meta }

pageHeadCodec :: JSONCodec meta -> JSONCodec (PageHead meta)
pageHeadCodec mc = object (PageHead <$> field "title" (.title) str
                                    <*> field "links" (.links) (list' linkCodec)
                                    <*> field "meta"  (.meta)  mc)

pagePath :: FilePath -> Slug -> FilePath
pagePath dir s = dir </> T.unpack (unSlug s) <.> "md"

-- Serialize a page: --- <json head> --- then the markdown body.
renderPage :: JSONCodec meta -> Page meta -> Text
renderPage mc p =
  "---\n" <> encodeText (pageHeadCodec mc) (PageHead p.title p.links p.meta)
    <> "\n---\n" <> p.body

-- Parse a page file back into a Page (Nothing if the head does not decode).
parsePage :: JSONCodec meta -> Slug -> Text -> Maybe (Page meta)
parsePage mc s contents = case T.lines contents of
  ("---" : rest) ->
    let (headLines, afterHead) = break (== "---") rest
        bodyText = T.intercalate "\n" (drop 1 afterHead)
        headJson = T.intercalate "\n" headLines
    in case decodeLLM (pageHeadCodec mc) headJson of
         Right h -> Just (Page s h.title h.links bodyText h.meta)
         Left _  -> Nothing
  _ -> Nothing

readPageFile :: JSONCodec meta -> FilePath -> Slug -> IO (Maybe (Page meta))
readPageFile mc dir s = do
  let path = pagePath dir s
  exists <- doesFileExist path
  if not exists then pure Nothing
  else do
    r <- try (TIO.readFile path) :: IO (Either IOException Text)
    pure (either (const Nothing) (parsePage mc s) r)

writePageFile :: JSONCodec meta -> FilePath -> Page meta -> IO ()
writePageFile mc dir p = do
  createDirectoryIfMissing True dir
  TIO.writeFile (pagePath dir p.slug) (renderPage mc p)

-- All page slugs (".md" files, excluding the activity log), sorted.
indexDir :: FilePath -> IO [Slug]
indexDir dir = do
  createDirectoryIfMissing True dir
  fs <- listDirectory dir
  pure (sort [ Slug (T.pack (takeBaseName f)) | f <- fs, takeExtension f == ".md", f /= "log.md" ])

searchDir :: JSONCodec meta -> FilePath -> Text -> IO [Slug]
searchDir mc dir q = do
  slugs <- indexDir dir
  matched <- mapM (\s -> maybe False (matchesQuery q) <$> readPageFile mc dir s) slugs
  pure [ s | (s, True) <- zip slugs matched ]

-- | Directory interpreter: one <slug>.md per page (--- JSON head --- + body),
-- AppendLog -> log.md. Outlives sessions; git-diffable. Tolerant: a page file
-- whose head does not decode reads as absent.
runResearchDir :: (IOE :> es) => JSONCodec meta -> FilePath -> Eff (Research meta : es) a -> Eff es a
runResearchDir mc dir = interpret $ \_ -> \case
  ReadPage s   -> liftIO (readPageFile mc dir s)
  WritePage p  -> liftIO (writePageFile mc dir p)
  Index        -> liftIO (indexDir dir)
  Search q     -> liftIO (searchDir mc dir q)
  AppendLog ln -> liftIO (createDirectoryIfMissing True dir >> TIO.appendFile (dir </> "log.md") (ln <> "\n"))
```
Notes:
- `PageHead` reuses field names `title`/`links`/`meta` (DuplicateRecordFields makes this fine; the `(.title)` getters in `pageHeadCodec` resolve via the `PageHead` argument). If a getter is ambiguous, annotate.
- `parsePage` body is everything after the second `---`; the head is the lines between the two `---` markers (one line, since `encodeText` is compact).
- `runResearchDir` is already in the export list (Task 1 Step 2). Add `PageHead`-related helpers as NON-exported (do not add to the module export list).

- [ ] **Step 2: Add directory tests to `test/Spec.hs`**

`runResearchDir` was imported in Task 1. Use a real `meta` codec for these tests; reuse `C.str` (so `meta = Text`) for simplicity. Create a temp directory under `/tmp` (use `System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)`; add these to the existing `System.Directory` import in Spec.hs). Add:

```haskell
  , do let dir = "/tmp/crucible-research-test"
       removeDirectoryRecursive dir `catchAny` \_ -> pure ()   -- clean slate
       let p = Page (Slug "alpha") "Alpha" [Link (Slug "beta") Extends] "body text here" ("m" :: Text)
       _ <- runEff (runResearchDir C.str dir (writePage p))
       got <- runEff (runResearchDir C.str dir (readPage (Slug "alpha")))   -- separate session
       removeDirectoryRecursive dir `catchAny` \_ -> pure ()
       check "research dir: a written page reads back across sessions (title/links/meta)"
         (Just p) got
  , do let dir = "/tmp/crucible-research-idx"
       removeDirectoryRecursive dir `catchAny` \_ -> pure ()
       (idx, hits) <- runEff (runResearchDir C.str dir (do
                        writePage (Page (Slug "a") "Apple" [] "red fruit" ("" :: Text))
                        writePage (Page (Slug "b") "Boat" [] "floats" "")
                        i <- index
                        h <- search "fruit"
                        pure (i, h)))
       removeDirectoryRecursive dir `catchAny` \_ -> pure ()
       check "research dir: index lists slugs, search greps body" ([Slug "a", Slug "b"], [Slug "a"]) (idx, hits)
```
Notes:
- `catchAny` is a small helper to ignore "directory does not exist" on the pre-clean; if the file already imports a catch-all, reuse it, otherwise define inline: `let catchAny io h = io \`Control.Exception.catch\` (\(e :: Control.Exception.SomeException) -> h e)` (import `Control.Exception` if needed), OR simply call `createDirectoryIfMissing True dir` first and skip the pre-clean, relying on the post-test `removeDirectoryRecursive`. Prefer whichever is simplest and report what you used.
- The first test writes in one `runResearchDir` call and reads in a SEPARATE call on the same dir (outlives sessions). `meta = Text` via `C.str`.
- These tests do disk IO under `/tmp`; clean up the directory after.

- [ ] **Step 3: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the directory checks pass; full suite green. If the frontmatter round-trip mismatches, print the actual file contents to debug the parse/serialize and fix; do not weaken the assertion. Retry once on 137.

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/Research.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(research): directory interpreter (markdown pages, outlives sessions)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a Research demo**

Read `app/Main.hs`. Add imports: `import qualified Crucible.Research as Research` (use qualified to avoid clashes with `index`/`search`/`links`/`title` etc.), and ensure `str` is in scope (it is). Inside the `Just key -> do` block, after an existing demo (it needs no API key), add:
```haskell
      -- Research: a typed, persistent knowledge base (markdown files on disk).
      let researchDir = "/tmp/crucible-research-demo"
          alpha = Research.Page (Research.Slug "alpha") "Alpha" [] "Alpha is the first letter." ("" :: T.Text)
          beta  = Research.Page (Research.Slug "beta") "Beta"
                    [Research.Link (Research.Slug "alpha") Research.Extends]
                    "Beta extends alpha." ("" :: T.Text)
      (researchIdx, researchHits) <- runEff (Research.runResearchDir str researchDir (do
        Research.writePage alpha
        Research.writePage beta
        Research.appendLog "wrote alpha and beta"
        i <- Research.index
        h <- Research.search "extends"
        pure (i, h)))
      TIO.putStrLn ("research: index = " <> T.pack (show (map (\(Research.Slug s) -> s) researchIdx))
                    <> ", search 'extends' = " <> T.pack (show (map (\(Research.Slug s) -> s) researchHits)))
```
Notes:
- Use `meta = T.Text` via `str`. The `Research.Slug` pattern unwraps for printing.
- `runEff (Research.runResearchDir str researchDir prog)` returns the program result directly. The demo prints the index and search hits.

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. Retry once on 137. (Do not run the binary.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "$(cat <<'EOF'
demo(research): write/read/search/index a directory knowledge base

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Manual page `docs/research.md`

**Files:**
- Create: `docs/research.md`

- [ ] **Step 1: Write the page**

Check nav orders: `grep -rn "nav_order:" docs/*.md`. Use `14` if free; otherwise the next free integer. Match the voice of `docs/memory.md`. Content (use REAL triple-backtick fences):

```markdown
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
```
(The outer ```markdown fence delimits this block in the plan only; write real markdown.)

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/research.md` (expect no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/research.md` (expect no output).
Confirm the chosen `nav_order` does not collide.

- [ ] **Step 3: Commit**

```bash
git add docs/research.md
git commit -m "$(cat <<'EOF'
docs(research): knowledge-base effect manual page

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- **Spec coverage:** `Slug`/`LinkType`/`Link`/`Page` (T1), `Research` effect + smart ctors (T1), `runResearchState` (T1), codecs (T1), `runResearchDir` + file format (T2), demo (T3), `docs/research.md` (T4). Non-goals (tools, grounding-gate, lint, BM25/embeddings, revisions, scheduler) are "do not build".
- **Type consistency:** `Page meta {slug,title,links,body,meta}`, `Research meta` ops and smart ctors, `runResearchState :: [Page meta] -> Eff (Research meta : es) a -> Eff es (a, [Page meta], [Text])`, `runResearchDir :: (IOE :> es) => JSONCodec meta -> FilePath -> ...` are consistent across module, tests, demo, docs. `slugCodec`/`linkTypeCodec`/`linkCodec` exported; `PageHead`/`pageHeadCodec` internal.
- **Placeholder scan:** no placeholder code. Judgement points flagged: `(.field)` getter annotations under DuplicateRecordFields, the State `get @(...)` annotations, the temp-dir cleanup helper choice (T2), and the directory-import timing (T1 vs T2). No vague steps.
- **Dependency:** `directory` added to `[build.lib]` (T1 S1); `filepath` already present; no `containers` (assoc-list state).
