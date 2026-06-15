# Thick Backend Handles (Research + Ledger) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a thick backend handle (`ResearchStore`/`LedgerStore`) + passthrough interpreter (`runResearchWith`/`runLedgerWith`) for the two non-breaking persistent effects, reframing the existing file/state interpreters as handles, with no public signature changes.

**Architecture:** A `*Store` record holds one `IO` action per effect operation. `run*With` is a near-passthrough `interpret` that lifts each handle field. The existing on-disk interpreters become `run*With (*StoreFile/Dir …)`, reusing the current helper functions verbatim. The pure tuple-returning interpreters (`runResearchState`, `runLedgerState`) are kept unchanged for property tests; an IORef-backed handle (`researchStoreState`, `ledgerStorePure`) is the IO analogue.

**Tech Stack:** GHC 9.12.2, effectful, Crucible.Codec; build/test via `nix develop . --command timeout -s KILL 300 zinc build|test`.

---

### Task 1: Research thick handle

**Files:**
- Modify: `src/Crucible/Research.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Add `ResearchStore` + `runResearchWith` + handles, reframe `runResearchDir`.**

Add `Data.IORef` import (`import Data.IORef (IORef, readIORef, modifyIORef')`).

Add to the export list: `ResearchStore (..)`, `runResearchWith`, `researchStoreDir`, `researchStoreState`.

Add the type and interpreter (place near `runResearchDir`):

```haskell
-- | A thick backend handle: one 'IO' action per 'Research' operation. The seam
-- that lets a backend (directory, in-memory, or a future Postgres satellite) be
-- a parameter of the interpreter rather than a fresh interpreter per backend.
data ResearchStore meta = ResearchStore
  { doRead   :: Slug -> IO (Maybe (Page meta))
  , doWrite  :: Page meta -> IO ()
  , doIndex  :: IO [Slug]
  , doSearch :: Text -> IO [Slug]
  , doLog    :: Text -> IO ()
  }

-- | Run 'Research' against a thick handle (near-passthrough).
runResearchWith :: (IOE :> es) => ResearchStore meta -> Eff (Research meta : es) a -> Eff es a
runResearchWith s = interpret $ \_ -> \case
  ReadPage sl  -> liftIO (s.doRead sl)
  WritePage p  -> liftIO (s.doWrite p)
  Index        -> liftIO s.doIndex
  Search q     -> liftIO (s.doSearch q)
  AppendLog ln -> liftIO (s.doLog ln)

-- | Directory backend as a handle: one @\<slug\>.md@ per page, AppendLog to
-- @activity.log@. Path-unsafe slugs are refused (read 'Nothing', write no-op).
researchStoreDir :: JSONCodec meta -> FilePath -> ResearchStore meta
researchStoreDir mc dir = ResearchStore
  { doRead   = readPageFile mc dir
  , doWrite  = writePageFile mc dir
  , doIndex  = indexDir dir
  , doSearch = searchDir mc dir
  , doLog    = \ln -> createDirectoryIfMissing True dir >> TIO.appendFile (logFile dir) (ln <> "\n")
  }

-- | In-memory backend as a handle, over two 'IORef's (pages, log lines newest
-- first). The IO analogue of 'runResearchState'; use when a program needs the
-- 'Research' effect in 'IO' without touching disk.
researchStoreState :: forall meta. IORef [Page meta] -> IORef [Text] -> ResearchStore meta
researchStoreState pagesRef logRef = ResearchStore
  { doRead   = \s -> find (\p -> p.slug == s) <$> readIORef pagesRef
  , doWrite  = \p -> modifyIORef' pagesRef (\ps -> p : filter (\q -> q.slug /= p.slug) ps)
  , doIndex  = sort . map ((.slug) :: Page meta -> Slug) <$> readIORef pagesRef
  , doSearch = \q -> sort . map ((.slug) :: Page meta -> Slug) . filter (matchesQuery q) <$> readIORef pagesRef
  , doLog    = \ln -> modifyIORef' logRef (ln :)
  }
```

Reframe the existing interpreter (replace the current `runResearchDir` body):

```haskell
runResearchDir :: (IOE :> es) => JSONCodec meta -> FilePath -> Eff (Research meta : es) a -> Eff es a
runResearchDir mc dir = runResearchWith (researchStoreDir mc dir)
```

Keep the existing `runResearchDir` haddock comment above it unchanged.

- [ ] **Step 2: Build.**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: exit 0. (If exit 137 — GHC iserv flake — retry once.)

- [ ] **Step 3: Add direct-handle + parity tests in `test/Spec.hs`.**

Find the `runChecks` list at the end of `test/Spec.hs` and the Research test block. Add a test action and `check` entries. Example test bodies (adapt to the file's existing seeding/helpers and `meta = ()` convention used by other Research tests):

```haskell
-- runResearchWith over IORef state round-trips a write then read, and indexes.
researchWithState :: IO (Maybe Text, [Slug])
researchWithState = do
  pagesRef <- newIORef ([] :: [Page ()])
  logRef   <- newIORef ([] :: [Text])
  runEff $ runResearchWith (researchStoreState pagesRef logRef) $ do
    writePage (Page (Slug "a") "A" [] "body-a" ())
    mp <- readPage (Slug "a")
    ix <- index @()
    pure (fmap (.body) mp, ix)
-- expected: (Just "body-a", [Slug "a"])
```

Add a parity check: run the same program through `runResearchDir mc <tempdir>` and through `runResearchWith (researchStoreState …)`, assert equal observable results. Use the temp-dir pattern already used by existing `runResearchDir` tests in the file (reuse whatever `withSystemTempDirectory`/helper they use).

Add to the `runChecks` list (comma-separated), e.g.:
```haskell
, check "research runResearchWith state round-trips" (Just "body-a", [Slug "a"]) =<< researchWithState
```

- [ ] **Step 4: Test.**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: all checks pass ("1 test suite(s) passed" / exit 0).

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/Research.hs test/Spec.hs
git commit -m "feat(research): thick backend handle (ResearchStore + runResearchWith)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Ledger thick handle

**Files:**
- Modify: `src/Crucible/Ledger.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Add `LedgerStore` + `runLedgerWith` + handles, reframe `runLedgerFile`.**

Add `import Data.IORef (IORef, readIORef, atomicModifyIORef')`.

Add to the export list: `LedgerStore (..)`, `runLedgerWith`, `ledgerStoreFile`, `ledgerStorePure`.

Add the type and interpreter near `runLedgerFile`:

```haskell
-- | A thick backend handle: one 'IO' action per 'Ledger' operation.
data LedgerStore = LedgerStore
  { doRecord    :: Text -> IO WorkId
  , doClaim     :: WorkId -> Text -> IO Bool
  , doComplete  :: WorkId -> IO ()
  , doListReady :: IO [WorkItem]
  }

-- | Run 'Ledger' against a thick handle (near-passthrough).
runLedgerWith :: (IOE :> es) => LedgerStore -> Eff (Ledger : es) a -> Eff es a
runLedgerWith s = interpret $ \_ -> \case
  Record p    -> liftIO (s.doRecord p)
  Claim w who -> liftIO (s.doClaim w who)
  Complete w  -> liftIO (s.doComplete w)
  ListReady   -> liftIO s.doListReady

-- | JSONL-file backend as a handle. Single-writer; the read-then-append in
-- doRecord/doClaim is not atomic (same caveat as before).
ledgerStoreFile :: FilePath -> LedgerStore
ledgerStoreFile path = LedgerStore
  { doRecord = \p -> do
      evs <- readLog path
      let n = length [() | EvRecorded _ _ <- evs]
      appendEvent path (EvRecorded (WorkId n) p)
      pure (WorkId n)
  , doClaim = \w who -> do
      evs <- readLog path
      case stateOf w evs of
        Just Ready -> appendEvent path (EvClaimed w who) >> pure True
        _          -> pure False
  , doComplete  = \w -> appendEvent path (EvCompleted w)
  , doListReady = readyOf <$> readLog path
  }

-- | In-memory backend as a handle, over an 'IORef' of the event log. The IO
-- analogue of 'runLedgerState'. 'atomicModifyIORef'' makes record/claim atomic
-- within a process (stronger than the file handle).
ledgerStorePure :: IORef [LedgerEvent] -> LedgerStore
ledgerStorePure ref = LedgerStore
  { doRecord = \p -> atomicModifyIORef' ref $ \evs ->
      let n = length [() | EvRecorded _ _ <- evs]
      in (evs ++ [EvRecorded (WorkId n) p], WorkId n)
  , doClaim = \w who -> atomicModifyIORef' ref $ \evs ->
      case stateOf w evs of
        Just Ready -> (evs ++ [EvClaimed w who], True)
        _          -> (evs, False)
  , doComplete  = \w -> atomicModifyIORef' ref (\evs -> (evs ++ [EvCompleted w], ()))
  , doListReady = readyOf <$> readIORef ref
  }
```

Reframe the existing interpreter (replace the current `runLedgerFile` body, keep its haddock):

```haskell
runLedgerFile :: (IOE :> es) => FilePath -> Eff (Ledger : es) a -> Eff es a
runLedgerFile path = runLedgerWith (ledgerStoreFile path)
```

- [ ] **Step 2: Build.**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: exit 0. (exit 137 → retry once.)

- [ ] **Step 3: Add direct-handle + parity tests in `test/Spec.hs`.**

Add to the Ledger test block:

```haskell
-- runLedgerWith over an IORef event log: record, claim, second claim fails.
ledgerWithPure :: IO (WorkId, Bool, Bool, [Text])
ledgerWithPure = do
  ref <- newIORef ([] :: [LedgerEvent])  -- NOTE: LedgerEvent is not exported
  ...
```

`LedgerEvent` is **not exported** from `Crucible.Ledger`. Two options — choose the first:
1. Have `ledgerStorePure` take an `IORef [LedgerEvent]` but provide a constructor `emptyLedgerStorePure :: IO LedgerStore` that allocates the ref internally and returns the handle; OR test `ledgerStorePure` indirectly through `runLedgerWith` by exporting a tiny helper `newLedgerStorePure :: IO LedgerStore`.

Add `newLedgerStorePure :: IO LedgerStore` to `Crucible.Ledger` (and its export) so tests need no access to `LedgerEvent`:

```haskell
-- | Allocate a fresh in-memory ledger handle (its own 'IORef' event log).
newLedgerStorePure :: IO LedgerStore
newLedgerStorePure = ledgerStorePure <$> newIORef []
```

Then the test:

```haskell
ledgerWithPure :: IO (Bool, Bool, Int)
ledgerWithPure = do
  store <- newLedgerStorePure
  runEff $ runLedgerWith store $ do
    w  <- record "task-1"
    c1 <- claim w "alice"
    c2 <- claim w "bob"    -- already claimed → False
    rs <- listReady
    pure (c1, c2, length rs)
-- expected: (True, False, 0)
```

Add a parity check against `runLedgerFile <tempfile>` running the same program.

Add the `check` entries to `runChecks`.

- [ ] **Step 4: Test.**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: all checks pass.

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/Ledger.hs test/Spec.hs
git commit -m "feat(ledger): thick backend handle (LedgerStore + runLedgerWith)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Docs

**Files:**
- Modify: `docs/research.md`, `docs/ledger.md`

- [ ] **Step 1: Add a short "backend handle" paragraph to each interpreters section.**

In `docs/research.md`, in the interpreters section, add one paragraph: the on-disk
and in-memory backends are now `ResearchStore` handles run by `runResearchWith`;
`runResearchDir` is `runResearchWith (researchStoreDir …)`. This is the seam a
future Postgres backend plugs into without crucible-core gaining a DB dependency.

Mirror in `docs/ledger.md` for `LedgerStore`/`runLedgerWith`/`ledgerStoreFile`.

Keep each addition to a short paragraph; match the page's existing prose style.

- [ ] **Step 2: Commit.**

```bash
git add docs/research.md docs/ledger.md
git commit -m "docs: thick backend handles for Research and Ledger

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** Task 1 = Research handle (spec §Research); Task 2 = Ledger
  handle (spec §Ledger); Task 3 = docs (spec §Docs). Tests in steps cover the
  spec's testing section (direct-handle + parity). No breaking change introduced.
- **Type consistency:** `ResearchStore`/`runResearchWith`/`researchStoreDir`/
  `researchStoreState`; `LedgerStore`/`runLedgerWith`/`ledgerStoreFile`/
  `ledgerStorePure`/`newLedgerStorePure` used consistently across tasks. The
  `newLedgerStorePure` helper resolves the `LedgerEvent`-not-exported issue so
  tests need no internal access.
- **Placeholder scan:** none.
