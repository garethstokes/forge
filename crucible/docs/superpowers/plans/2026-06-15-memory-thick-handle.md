# Memory Thick Backend Handle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add `MemoryStore` + `runMemoryWith` for the `Memory` effect, reframe `runMemoryFile` over a `memoryStoreFile` handle, add an IORef-backed `memoryStorePure`/`newMemoryStorePure`, keep `runMemoryPure`/`runMemoryScripted`. No public signature changes.

**Architecture:** Identical to the shipped Research/Ledger thick handles. A `MemoryStore` record holds one `IO` action per effect op; `runMemoryWith` is a near-passthrough `interpret`. `runMemoryFile` becomes a one-liner over the handle, reusing the existing `readLog`/`appendEntry`/`queryLive`/`itemOf` helpers verbatim.

**Tech Stack:** GHC 9.12.2, effectful; build/test via `nix develop . --command timeout -s KILL 300 zinc build|test`.

---

### Task 1: Memory thick handle (code + tests + docs)

**Files:**
- Modify: `src/Crucible/Memory.hs`
- Test: `test/Spec.hs`
- Docs: `docs/memory.md`

- [ ] **Step 1: Edit `src/Crucible/Memory.hs`.**

Add `import Data.IORef (IORef, newIORef, readIORef, atomicModifyIORef')`.

Add to the export list: `MemoryStore (..)`, `runMemoryWith`, `memoryStoreFile`, `memoryStorePure`, `newMemoryStorePure`.

Add near `runMemoryFile` (place type + interpreter + handles BEFORE the reframed `runMemoryFile`). Reuse the existing `readLog`, `appendEntry`, `queryLive`, `itemOf`, constructors `Remembered`/`Forgot`, type `MemoryEntry` — all already defined in the module:

```haskell
-- | A thick backend handle: one 'IO' action per 'Memory' operation. The seam
-- that lets a backend (file, in-memory, or a future Postgres satellite) be a
-- parameter of the interpreter rather than a fresh interpreter per backend.
data MemoryStore = MemoryStore
  { doRemember :: MemoryDraft -> IO MemoryId
  , doRecall   :: Query       -> IO [MemoryItem]
  , doForget   :: MemoryId    -> IO ()
  }

-- | Run 'Memory' against a thick handle (near-passthrough).
runMemoryWith :: (IOE :> es) => MemoryStore -> Eff (Memory : es) a -> Eff es a
runMemoryWith s = interpret $ \_ -> \case
  Remember d -> liftIO (s.doRemember d)
  Recall q   -> liftIO (s.doRecall q)
  Forget i   -> liftIO (s.doForget i)

-- | JSONL-file backend as a handle. id = createdAt = count of prior Remembered
-- entries. Single-writer; the read-count-append in doRemember is not atomic
-- (same caveat as the original interpreter).
memoryStoreFile :: FilePath -> MemoryStore
memoryStoreFile path = MemoryStore
  { doRemember = \d -> do
      es <- readLog path
      let n = length [() | Remembered _ <- es]
      appendEntry path (Remembered (itemOf d n))
      pure (MemoryId n)
  , doRecall = \q -> queryLive q <$> readLog path
  , doForget = \i -> appendEntry path (Forgot i)
  }

-- | In-memory backend as a handle over an 'IORef' of the entry log. The IO
-- analogue of 'runMemoryPure'. 'atomicModifyIORef'' makes remember/forget atomic
-- within a single process.
memoryStorePure :: IORef [MemoryEntry] -> MemoryStore
memoryStorePure ref = MemoryStore
  { doRemember = \d -> atomicModifyIORef' ref $ \es ->
      let n = length [() | Remembered _ <- es]
      in (es ++ [Remembered (itemOf d n)], MemoryId n)
  , doRecall = \q -> queryLive q <$> readIORef ref
  , doForget = \i -> atomicModifyIORef' ref (\es -> (es ++ [Forgot i], ()))
  }

-- | Allocate a fresh in-memory memory handle (its own empty 'IORef' entry log).
newMemoryStorePure :: IO MemoryStore
newMemoryStorePure = memoryStorePure <$> newIORef []
```

Then REPLACE the body of `runMemoryFile` (KEEP its existing haddock comment unchanged):

```haskell
runMemoryFile :: (IOE :> es) => FilePath -> Eff (Memory : es) a -> Eff es a
runMemoryFile path = runMemoryWith (memoryStoreFile path)
```

- [ ] **Step 2: Build.** `nix develop . --command timeout -s KILL 300 zinc build` → exit 0 (137 = iserv flake, retry once).

- [ ] **Step 3: Add tests to `test/Spec.hs`.**

Context:
- `Data.IORef` already imported in Spec.hs (`newIORef` etc.).
- Memory import is around line 80-ish: it imports from `Crucible.Memory`. ADD `runMemoryWith, newMemoryStorePure, memoryStoreFile` to that import list. (Check the existing Memory import line for what symbols/constructors are already in scope — `MemoryDraft (..)`, `MemoryKind (..)`, `Provenance (..)`, `Query (..)`, `MemoryItem (..)`, `MemoryId (..)`, `remember`, `recall`, `forget`, `runMemoryFile`, `runMemoryPure` are likely already imported; reuse them.)
- `openTempFile`/`hClose` from System.IO; `removeFile`, `catch`, `SomeException` imported. Temp-file pattern: `(path, h) <- openTempFile "/tmp" "crucible-memory-XXX.jsonl"; hClose h; ...; removeFile path \`catch\` \(_ :: SomeException) -> pure ()`.
- Tests are entries in the comma-separated `runChecks` list at the END of the file. Find the existing Memory test block and add after it.

Add TWO entries:

```haskell
  , do store <- newMemoryStorePure
       got <- runEff $ runMemoryWith store $ do
                i1 <- remember (MemoryDraft Semantic "alpha fact" ["t"] Curated)
                _  <- remember (MemoryDraft Semantic "beta fact" ["t"] Curated)
                forget i1
                rs <- recall (Query "" ["t"] 10)
                pure (map ((.content) :: MemoryItem -> Text) rs)
       check "memory: runMemoryWith pure handle remembers/forgets/recalls" ["beta fact"] got
  , do (path, h) <- openTempFile "/tmp" "crucible-memory-parity.jsonl"
       hClose h
       let prog = do _  <- remember (MemoryDraft Semantic "a" ["x"] Curated)
                     i2 <- remember (MemoryDraft Episodic "b" ["x"] Curated)
                     _  <- remember (MemoryDraft Semantic "c" ["x"] Curated)
                     forget i2
                     map ((.content) :: MemoryItem -> Text) <$> recall (Query "" ["x"] 10)
       fromFile <- runEff (runMemoryWith (memoryStoreFile path) prog)
       removeFile path `catch` \(_ :: SomeException) -> pure ()
       store <- newMemoryStorePure
       fromPure <- runEff (runMemoryWith store prog)
       check "memory: file and pure handles agree (remember/forget/recall)" fromFile fromPure
```

If a `(.content)` section needs a different annotation or the `prog` signature is needed, follow the compiler (a local `prog :: (Crucible.Memory.Memory :> es) => Eff es [Text]` may require importing `Memory`; prefer inference, fall back to inlining the program twice).

- [ ] **Step 4: Test.** `nix develop . --command timeout -s KILL 300 zinc test` → all checks pass.

- [ ] **Step 5: Docs.** In `docs/memory.md`, after the `## Interpreters` section (around line 99-120), add a short "### The backend handle" subsection mirroring the ones added to `docs/research.md`/`docs/ledger.md`:

> Both interpreters are thin wrappers over a thick backend handle — a `MemoryStore`
> record holding one `IO` action per operation (`doRemember`/`doRecall`/`doForget`)
> — run by `runMemoryWith`. `runMemoryFile path = runMemoryWith (memoryStoreFile path)`;
> `newMemoryStorePure` gives an in-memory handle over an `IORef`. The handle is the
> seam where persistence becomes a parameter: a Postgres backend in the
> `crucible-manifest` workspace package supplies its own `MemoryStore` and plugs
> into the same `runMemoryWith`. The pure `runMemoryPure` is kept for property tests.

Match the page's existing prose/format (it uses a table + code block; keep the addition short).

- [ ] **Step 6: Commit.**

```bash
git add src/Crucible/Memory.hs test/Spec.hs docs/memory.md
git commit -m "feat(memory): thick backend handle (MemoryStore + runMemoryWith)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** the single task covers MemoryStore/runMemoryWith/memoryStoreFile/memoryStorePure/newMemoryStorePure (spec §Shape), reframed runMemoryFile, kept runMemoryPure/runMemoryScripted, tests (§Testing), docs (§Docs). Non-breaking.
- **Type consistency:** names match the spec exactly; `newMemoryStorePure` resolves the `MemoryEntry`-not-exported issue for tests.
- **Placeholder scan:** none.
