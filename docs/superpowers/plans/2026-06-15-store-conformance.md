# Store Conformance Suite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** A backend-parameterized conformance suite in `crucible-manifest/test` that runs the same observable-behaviour checks for each effect against all its backends (file/dir, pure/state, manifest-ephemeral), plus the `ledgerStoreManifest.doListReady` ordering fix it surfaces.

**Architecture:** A `Conformance.hs` module exposes `memoryConformance`/`ledgerConformance`/`researchConformance :: String -> WithStore X -> [Test]` (rank-2 `WithStore` bracket so each backend's lifetime works). `Spec.hs` supplies one bracket per backend and concatenates. Checks compare observable projections (content/payload/page), never raw serial ids.

**Tech Stack:** GHC 9.12.2, the existing tiny `Test`/`assertEq` harness, ephemeral Postgres.
**Build/test:** `nix develop . --command timeout -s KILL 600 zinc test` (137 → retry once).

---

### Task 1: Ledger backend ordering fix

**Files:** `crucible-manifest/src/Crucible/Manifest/Ledger.hs`

- [ ] **Step 1: make `doListReady` deterministic (record order).** Currently it is `selectWhere [#state ==. Ready]` (no ORDER BY → undefined Postgres order). Change it to sort by `wid` in Haskell so it matches the file/pure record order:
```haskell
  , doListReady = withSession pool (sortOn (.wid) <$> selectWhere [#state ==. Ready])
```
Add `import Data.List (sortOn)`. (`(.wid)` may need an annotation `((.wid) :: WorkItem -> WorkId)`; follow the compiler. `WorkId` derives `Ord` already.)

- [ ] **Step 2: build.** `nix develop . --command timeout -s KILL 300 zinc build` → exit 0.

(Tested via the conformance suite in Task 2.)

---

### Task 2: the conformance module + Spec refactor

**Files:** Create `crucible-manifest/test/Conformance.hs`; rewrite `crucible-manifest/test/Spec.hs`; ensure `crucible-manifest/zinc.toml` test deps cover the file/pure stores (they come from `crucible`, already a dep — likely no change; add `directory`/`filepath`/`temporary` only if a temp helper needs them; prefer `openTempFile`/`removeFile` from base+directory, and `getTemporaryDirectory`+`createDirectory`/`removeDirectoryRecursive` from `directory`).

- [ ] **Step 1: write `crucible-manifest/test/Conformance.hs`.**

Module header with `{-# LANGUAGE RankNTypes #-}`, `OverloadedStrings`, `OverloadedRecordDot`, `ScopedTypeVariables`. Export the harness types it needs and the three conformance functions. Reuse the `Test`/`assertEq` types — to avoid a cyclic import, DEFINE `Test`/`assertEq`/`WithStore` here and have `Spec.hs` import them from `Conformance` (move the harness here).

```haskell
module Conformance
  ( Test (..), runTests, assertEq, WithStore
  , memoryConformance, ledgerConformance, researchConformance
  ) where
```
Bring `Test`, `runTests`, `assertEq` over from the current `Spec.hs` verbatim. Add:
```haskell
type WithStore s = forall a. (s -> IO a) -> IO a
```

`memoryConformance :: String -> WithStore MemoryStore -> [Test]` — checks (prefix every label with `"memory[" <> be <> "]: "`):
```haskell
memoryConformance be withS =
  [ Test (lbl "recall is most-recent-first") $ withS $ \s -> do
      mapM_ s.doRemember [d "a", d "b", d "c"]
      r <- s.doRecall (Query "" [] 10)
      assertEq "content order" ["c","b","a"] (map ((.content) :: MemoryItem -> Text) r)
  , Test (lbl "forget removes from recall") $ withS $ \s -> do
      i <- s.doRemember (d "a"); _ <- s.doRemember (d "b")
      s.doForget i
      r <- s.doRecall (Query "" [] 10)
      assertEq "content" ["b"] (map ((.content) :: MemoryItem -> Text) r)
  , Test (lbl "budget caps recall") $ withS $ \s -> do
      mapM_ s.doRemember [d "a", d "b", d "c"]
      r <- s.doRecall (Query "" [] 1)
      assertEq "budget" ["c"] (map ((.content) :: MemoryItem -> Text) r)
  , Test (lbl "tag filter") $ withS $ \s -> do
      _ <- s.doRemember (MemoryDraft Semantic "x" ["red"] Curated)
      _ <- s.doRemember (MemoryDraft Semantic "y" ["blue"] Curated)
      r <- s.doRecall (Query "" ["red"] 10)
      assertEq "tagged" ["x"] (map ((.content) :: MemoryItem -> Text) r)
  , Test (lbl "empty recall") $ withS $ \s -> do
      r <- s.doRecall (Query "" [] 10)
      assertEq "empty" ([] :: [Text]) (map ((.content) :: MemoryItem -> Text) r)
  ]
  where lbl m = "memory[" <> be <> "]: " <> m
        d c = MemoryDraft Semantic c ["t"] Curated
```

`ledgerConformance :: String -> WithStore LedgerStore -> [Test]`:
```haskell
ledgerConformance be withS =
  [ Test (lbl "listReady is record order") $ withS $ \s -> do
      mapM_ s.doRecord ["A","B","C"]
      rs <- s.doListReady
      assertEq "payloads" ["A","B","C"] (map ((.payload) :: WorkItem -> Text) rs)
  , Test (lbl "claim drops from listReady; CAS rejects re-claim") $ withS $ \s -> do
      i <- s.doRecord "A"; _ <- s.doRecord "B"
      ok1 <- s.doClaim i "w"; ok2 <- s.doClaim i "w2"
      rs <- s.doListReady
      assertEq "first claim" True ok1
      assertEq "second claim (CAS)" False ok2
      assertEq "remaining" ["B"] (map ((.payload) :: WorkItem -> Text) rs)
  , Test (lbl "claim unknown id fails") $ withS $ \s -> do
      ok <- s.doClaim (WorkId 9999) "w"
      assertEq "unknown" False ok
  , Test (lbl "complete drops from listReady") $ withS $ \s -> do
      i <- s.doRecord "A"; _ <- s.doRecord "B"
      s.doComplete i
      rs <- s.doListReady
      assertEq "remaining" ["B"] (map ((.payload) :: WorkItem -> Text) rs)
  ]
  where lbl m = "ledger[" <> be <> "]: " <> m
```
(Note `claim unknown id`: `WorkId 9999` is safe across backends — no real row has it.)

`researchConformance :: String -> WithStore (ResearchStore Text) -> [Test]`:
```haskell
researchConformance be withS =
  [ Test (lbl "read round-trips a written page") $ withS $ \s -> do
      let p = Page (Slug "a") "Alpha" [Link (Slug "b") Extends] "alpha body" ("m"::Text)
      s.doWrite p
      mp <- s.doRead (Slug "a")
      assertEq "page" (Just p) mp
  , Test (lbl "read absent is Nothing") $ withS $ \s -> do
      mp <- s.doRead (Slug "missing")
      assertEq "absent" (Nothing :: Maybe (Page Text)) mp
  , Test (lbl "overwrite replaces") $ withS $ \s -> do
      s.doWrite (Page (Slug "a") "Alpha" [Link (Slug "b") Extends] "old" ("m"::Text))
      let p2 = Page (Slug "a") "Alpha2" [] "new" ("m2"::Text)
      s.doWrite p2
      mp <- s.doRead (Slug "a")
      assertEq "overwritten" (Just p2) mp
  , Test (lbl "index lists sorted slugs") $ withS $ \s -> do
      s.doWrite (Page (Slug "b") "B" [] "x" (""::Text))
      s.doWrite (Page (Slug "a") "A" [] "y" (""::Text))
      ix <- s.doIndex
      assertEq "index" [Slug "a", Slug "b"] ix
  , Test (lbl "search greps title/body") $ withS $ \s -> do
      s.doWrite (Page (Slug "a") "Apple" [] "red fruit" (""::Text))
      s.doWrite (Page (Slug "b") "Boat" [] "floats" (""::Text))
      hits <- s.doSearch "fruit"
      assertEq "search" [Slug "a"] hits
  ]
  where lbl m = "research[" <> be <> "]: " <> m
```
Imports for `Conformance.hs`: from `Crucible.Memory` (`MemoryStore (..)`, `MemoryDraft (..)`, `MemoryKind (..)`, `Provenance (..)`, `MemoryItem`, `MemoryItemT (..)`, `Query (..)`, `MemoryId (..)`); `Crucible.Ledger` (`LedgerStore (..)`, `WorkItem`, `WorkItemT (..)`, `WorkId (..)`); `Crucible.Research` (`ResearchStore (..)`, `Page (..)`, `Slug (..)`, `Link (..)`, `LinkType (..)`); `Data.Text (Text)`. (`(.content)`/`(.payload)` getter sections need the inline annotations shown.)

- [ ] **Step 2: rewrite `crucible-manifest/test/Spec.hs`.**

`Spec.hs` now: import `Conformance` (the harness + the three conformance fns), the manifest stores + migrations, the file/pure store constructors (`memoryStoreFile`/`newMemoryStorePure` from `Crucible.Memory`; `ledgerStoreFile`/`newLedgerStorePure` from `Crucible.Ledger`; `researchStoreDir`/`researchStoreState` from `Crucible.Research`), `qualified Crucible.Codec as C`, `Manifest (withEphemeralDb)`, `Data.IORef (newIORef)`, and temp-file/dir helpers.

Define the brackets and run:
```haskell
main :: IO ()
main = runTests $ concat
  [ memoryConformance   "file"     withMemFile
  , memoryConformance   "pure"     (\k -> newMemoryStorePure >>= k)
  , memoryConformance   "manifest" (\k -> withEphemeralDb (\p -> migrateMemory p >> k (memoryStoreManifest p)))
  , ledgerConformance   "file"     withLedgerFile
  , ledgerConformance   "pure"     (\k -> newLedgerStorePure >>= k)
  , ledgerConformance   "manifest" (\k -> withEphemeralDb (\p -> migrateLedger p >> k (ledgerStoreManifest p)))
  , researchConformance "dir"      withResearchDir
  , researchConformance "state"    (\k -> do { pr <- newIORef []; lr <- newIORef []; k (researchStoreState pr lr) })
  , researchConformance "manifest" (\k -> withEphemeralDb (\p -> migrateResearch p >> k (researchStoreManifest C.str p)))
  -- backend-specific assertions the conformance suite doesn't cover:
  , memorySpecific
  , ledgerSpecific
  ]
```
Temp brackets (use `bracket` from Control.Exception for cleanup):
```haskell
withMemFile k = withTempFile (\p -> k (memoryStoreFile p))
withLedgerFile k = withTempFile (\p -> k (ledgerStoreFile p))
withResearchDir k = withTempDir (\d -> k (researchStoreDir C.str d))

withTempFile :: (FilePath -> IO a) -> IO a
withTempFile act = do
  tmp <- getTemporaryDirectory
  bracket (do (p,h) <- openTempFile tmp "conf.jsonl"; hClose h; pure p) removeFile act

withTempDir :: (FilePath -> IO a) -> IO a
withTempDir act = do
  tmp <- getTemporaryDirectory
  bracket (do let d = tmp </> "conf-research"; removeDirectoryRecursive d `catch` \(_::SomeException) -> pure (); createDirectoryIfMissing True d; pure d)
          (\d -> removeDirectoryRecursive d `catch` \(_::SomeException) -> pure ()) act
```
Keep two backend-specific tests as `[Test]` (move from the old Spec.hs): the Memory `createdAt`-mirrors-id check (manifest only) and the Ledger distinct-increasing-ids check (manifest only). These wrap `withEphemeralDb`. Delete all the OTHER old ad-hoc per-backend tests (subsumed by conformance).

- [ ] **Step 3: zinc.toml.** Ensure `crucible-manifest`'s `[build.test.spec]` has `other-modules` discovery for `Conformance` (zinc auto-discovers modules in `source-dirs`; if it needs an explicit list, add it) and deps include `directory` (temp dir) — add `"directory"` to the test `depends` if not present.

- [ ] **Step 4: build + test.** `nix develop . --command timeout -s KILL 600 zinc test`. Expect every `effect[backend]: …` check to pass (3×~4-5 across 3 backends) plus the specifics, plus crucible's hermetic suite. If the Ledger `manifest` listReady-order check fails, the Task-1 sort fix wasn't applied/working — fix it. 137 → retry once.

- [ ] **Step 5: commit.**
```bash
cd /home/gareth/code/garethstokes/crucible
git add crucible-manifest/
git commit -m "test(crucible-manifest): cross-backend store conformance suite (crucible-m0b)

Shared observable-behaviour checks per effect run against file/pure/manifest
backends; surfaces+fixes ledgerStoreManifest.doListReady ordering.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review
- **Spec coverage:** Task 1 = the doListReady ordering fix; Task 2 = the conformance module (3 effects × 3 backends), the Spec refactor (replace ad-hoc tests, keep backend-specific ones). Projections avoid raw ids.
- **Type consistency:** `WithStore`, `memoryConformance`/`ledgerConformance`/`researchConformance`, harness moved to `Conformance`. Brackets match each backend's lifetime.
- **Placeholder scan:** none.
- **Risk:** `(.field)` getter sections need the inline annotations shown; temp helpers use `bracket` for cleanup; conformance is the gate that the Ledger sort fix works.
