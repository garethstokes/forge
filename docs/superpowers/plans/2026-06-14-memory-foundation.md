# Memory Effect Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `Crucible.Memory` (Remember/Recall/Forget effect, MemoryItem/Provenance/Query types, scripted/pure/file interpreters, `recallAs` typed recall) plus `encodeText` in `Crucible.Codec`.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-14-memory-foundation-design.md` (tracker `crucible-l9d`, sub-project 1). Linear append-log substrate (`MemoryEntry = Remembered MemoryItem | Forgot MemoryId`); liveness folded from the log; interpreter-assigned id/createdAt; typed `Provenance`; typed recall via Codec with free staleness.

**Refinement from the spec (deliberate):** `createdAt` is a uniform monotonic counter (the entry's Remembered index) in ALL interpreters, not POSIX seconds in the file one. This drops the `time` dependency, makes the file interpreter deterministic (file tests assert exact values), and still gives correct most-recent-first recency ordering. Wall-clock bi-temporal validity was already a deferred non-goal.

**Tech Stack:** Haskell GHC 9.12.2, effectful, autodocodec, text. No -Werror. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). Exit 137 = retry once. Judge by exit status or the pass line, never a pipeline tail.

---

## Background

- Branch `feat/memory-foundation` from master. House style: DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot, prefix-free fields. `(.field)` getter sections may need a type annotation under DuplicateRecordFields; annotate and report if ambiguous. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- READ `src/Crucible/Emit.hs` and `src/Crucible/LLM.hs` (effect + scripted-interpreter idiom: `reinterpret (evalState ...)`, `send`), `src/Crucible/Rows.hs` (`reinterpret (runState ...)` accumulation, `inject`), `src/Crucible/Codec.hs` (combinators; it imports `Data.Aeson as A`, `Data.ByteString.Lazy as LB`, `Data.Text.Encoding as TE`), `src/Crucible/Decode.hs` (`decodeLLM`, `DecodeError`).
- The suite passes (verify the live count; report before/after).
- API keys in `.env` (gitignored). NEVER print/echo/cat them.

---

### Task 1: `encodeText` + `Crucible.Memory` (types, kernel, scripted/pure, recallAs) + tests

**Files:** Modify `src/Crucible/Codec.hs`; create `src/Crucible/Memory.hs`; modify `test/Spec.hs`.

- [ ] **Step 1: `encodeText` in `Crucible.Codec`.** Add `toJSONVia` to the `import Autodocodec (...)` list. Add `encodeText` to the export list. Define (near `schemaText`):

```haskell
-- | Encode a value to compact JSON text through its codec (the encode
-- companion to 'schemaText' / 'Crucible.Decode.decodeLLM').
encodeText :: JSONCodec a -> a -> Text
encodeText c = TE.decodeUtf8 . LB.toStrict . A.encode . toJSONVia c
```

- [ ] **Step 2: create `src/Crucible/Memory.hs`** (types, effect, kernel, scripted + pure interpreters, recallAs; NO file interpreter or codecs yet, those are Task 2):

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
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | A small memory effect in the house style: a linear append-only log of
-- 'Remember'/'Forget' entries with provenance, recalled under a budget.
-- 'Forget' supersedes (an appended tombstone), it never erases, so history
-- survives for audit. Interpreters: 'runMemoryScripted' (tests),
-- 'runMemoryPure' (property tests), 'runMemoryFile' (a git-diffable JSONL
-- store). 'recallAs' decodes recalled content through a codec, so a memory
-- that no longer fits today's schema comes back as a 'DecodeError' (stale).
module Crucible.Memory
  ( MemoryKind (..)
  , MemoryId (..)
  , Provenance (..)
  , MemoryDraft (..)
  , MemoryItem (..)
  , Query (..)
  , Memory (..)
  , remember, recall, forget
  , recallAs
  , runMemoryScripted
  , runMemoryPure
  -- runMemoryFile is added in Task 2
  ) where

import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret, send)
import Effectful.State.Static.Local (evalState, get, modify, put, runState)

import Crucible.Codec (JSONCodec)
import Crucible.Decode (DecodeError, decodeLLM)

data MemoryKind = Episodic | Semantic | Procedural
  deriving (Eq, Show)

newtype MemoryId = MemoryId Int deriving (Eq, Show)

idInt :: MemoryId -> Int
idInt (MemoryId i) = i

-- | Who/what wrote a memory. Mandatory; enables trust-aware retrieval,
-- bulk revocation, and a raw-vs-derived distinction.
data Provenance
  = BySkill Text
  | BySession Text
  | ByConsolidation
  | Curated
  deriving (Eq, Show)

data MemoryDraft = MemoryDraft
  { kind    :: MemoryKind
  , content :: Text
  , tags    :: [Text]
  , source  :: Provenance
  }
  deriving (Eq, Show)

data MemoryItem = MemoryItem
  { memId     :: MemoryId
  , kind      :: MemoryKind
  , content   :: Text
  , tags      :: [Text]
  , source    :: Provenance
  , createdAt :: Int
  }
  deriving (Eq, Show)

data Query = Query
  { needle   :: Text
  , anyTags  :: [Text]
  , maxItems :: Int
  }
  deriving (Eq, Show)

-- | The internal append-log entry. Not exported in Task 1; Task 2's file
-- interpreter and codecs use it.
data MemoryEntry = Remembered MemoryItem | Forgot MemoryId
  deriving (Eq, Show)

data Memory :: Effect where
  Remember :: MemoryDraft -> Memory m MemoryId
  Recall   :: Query -> Memory m [MemoryItem]
  Forget   :: MemoryId -> Memory m ()
type instance DispatchOf Memory = Dynamic

remember :: (Memory :> es) => MemoryDraft -> Eff es MemoryId
remember = send . Remember

recall :: (Memory :> es) => Query -> Eff es [MemoryItem]
recall = send . Recall

forget :: (Memory :> es) => MemoryId -> Eff es ()
forget = send . Forget

-- | The live (non-forgotten) items of a log, in append order.
liveItems :: [MemoryEntry] -> [MemoryItem]
liveItems es = [it | Remembered it <- es, idInt it.memId `notElem` forgotten]
  where forgotten = [idInt i | Forgot i <- es]

-- | Does an item satisfy a query (tag overlap and case-folded needle infix)?
matchQuery :: Query -> MemoryItem -> Bool
matchQuery q it =
  (null q.anyTags || any (`elem` it.tags) q.anyTags)
    && (T.null q.needle || T.toCaseFold q.needle `T.isInfixOf` T.toCaseFold it.content)

-- | The shared recall kernel: live items matching the query, most-recent
-- first (descending createdAt, ties by descending id), capped at maxItems.
queryLive :: Query -> [MemoryEntry] -> [MemoryItem]
queryLive q =
  take (max 0 q.maxItems)
    . sortOn (\it -> Down (it.createdAt, idInt it.memId))
    . filter (matchQuery q)
    . liveItems

-- | Build a stored item from a draft, an id, and a createdAt ordinal.
itemOf :: MemoryDraft -> Int -> MemoryItem
itemOf d n = MemoryItem (MemoryId n) d.kind d.content d.tags d.source n

-- | Canned recalls popped per 'Recall' (mirrors 'runLLMScripted'). Remember
-- returns sequential ids; Forget is a no-op. State: (next id, remaining batches).
runMemoryScripted :: [[MemoryItem]] -> Eff (Memory : es) a -> Eff es a
runMemoryScripted batches = reinterpret (evalState (0 :: Int, batches)) $ \_ -> \case
  Remember _ -> do
    (n, bs) <- get
    put (n + 1, bs)
    pure (MemoryId n)
  Recall _ -> do
    (n, bs) <- get
    case bs of
      (x : xs) -> put (n, xs) >> pure x
      []       -> pure []
  Forget _ -> pure ()

-- | An in-memory append log in local State. Returns the result plus the
-- final live items (query-all order, no budget), for property tests.
runMemoryPure :: Eff (Memory : es) a -> Eff es (a, [MemoryItem])
runMemoryPure action = do
  (a, es) <- reinterpret (runState []) (\_ -> \case
    Remember d -> do
      es <- get
      let n = length [() | Remembered _ <- es]
      put (es ++ [Remembered (itemOf d n)])
      pure (MemoryId n)
    Recall q -> queryLive q <$> get
    Forget i -> modify (++ [Forgot i])) action
  pure (a, queryLive (Query "" [] maxBound) es)

-- | Recall, then decode each item's content through the codec. The item is
-- always present; only the content decode can fail, so a 'Left' is a stale
-- memory (it no longer fits today's schema) with its 'MemoryItem' intact.
recallAs :: (Memory :> es) => JSONCodec a -> Query -> Eff es [(MemoryItem, Either DecodeError a)]
recallAs c q = map (\m -> (m, decodeLLM c m.content)) <$> recall q
```

Notes: `MemoryEntry` stays unexported here (Task 2 exports nothing new of it either; it is internal). If `(.field)` getters are ambiguous under DuplicateRecordFields (MemoryDraft and MemoryItem share `kind`/`content`/`tags`/`source`), annotate the getter and report. The pure interpreter's `es ++ [..]` is O(n); fine for tests.

- [ ] **Step 3: tests in `test/Spec.hs`.** Import `import Crucible.Memory (...)` (the exported names) and `import Crucible.Codec (encodeText)` (add to the existing Codec import or a new line). Add (near the end of the check list); these run under `runPureEff`:

```haskell
  -- crucible-l9d: Memory foundation (pure + scripted + typed recall)
  , check "memory: remember then recall-all returns the item with assigned id"
      (MemoryId 0, "hello", 0 :: Int)
      (let (_, items) = runPureEff (runMemoryPure
              (remember (MemoryDraft Episodic "hello" ["greet"] (BySkill "s"))
               >> recall (Query "" [] 10)))
           it = head items
       in (it.memId, it.content, it.createdAt))
  , check "memory: tag filter and case-folded needle"
      (["a"], ["b"])
      (let prog = do _ <- remember (MemoryDraft Semantic "Alpha" ["a"] Curated)
                     _ <- remember (MemoryDraft Semantic "Beta" ["b"] Curated)
                     byTag <- recall (Query "" ["a"] 10)
                     byNeedle <- recall (Query "bet" [] 10)
                     pure (map (.content) byTag, map (.content) byNeedle)
           ((tg, nd), _) = runPureEff (runMemoryPure prog)
       in (map T.toLower tg, map T.toLower nd))
  , check "memory: maxItems caps and ordering is most-recent-first"
      (["c", "b"])
      (let prog = do mapM_ (\t -> remember (MemoryDraft Episodic t [] Curated)) ["a","b","c"]
                     recall (Query "" [] 2)
           (out, _) = runPureEff (runMemoryPure prog)
       in map (.content) out)
  , check "memory: forget removes from live recall but keeps the others"
      ["a", "c"]
      (let prog = do i0 <- remember (MemoryDraft Episodic "a" [] Curated)
                     _  <- remember (MemoryDraft Episodic "b" [] Curated)
                     i2 <- remember (MemoryDraft Episodic "c" [] Curated)
                     _  <- pure (i0, i2)
                     forget (MemoryId 1)
                     recall (Query "" [] 10)
           (out, _) = runPureEff (runMemoryPure prog)
       in reverse (map (.content) out))  -- recall is most-recent-first; reverse for append order
  , check "memory: all four provenance arms round-trip and are matchable"
      (True, True, True, True)
      (let (_, items) = runPureEff (runMemoryPure (do
              mapM_ remember
                [ MemoryDraft Episodic "p" [] (BySkill "k")
                , MemoryDraft Episodic "q" [] (BySession "run1")
                , MemoryDraft Episodic "r" [] ByConsolidation
                , MemoryDraft Episodic "s" [] Curated ]
              recall (Query "" [] 10)))
           has p = any (\it -> it.source == p) items
       in (has (BySkill "k"), has (BySession "run1"), has ByConsolidation, has Curated))
  , check "memory scripted: canned recalls pop in order; remember ids increment"
      ([["x"]], [], MemoryId 0)
      (let canned = [[MemoryItem (MemoryId 9) Episodic "x" [] Curated 9]]
           prog = do i <- remember (MemoryDraft Episodic "ignored" [] Curated)
                     r1 <- recall (Query "" [] 10)
                     r2 <- recall (Query "" [] 10)
                     pure (map (map (.content)) [r1], map (.content) r2, i)
           (a, b, c) = runPureEff (runMemoryScripted canned prog)
       in (a, b, c))
  , check "memory recallAs: typed round-trip and staleness on schema drift"
      (Right (42 :: Int), True)
      (let prog = do _ <- remember (MemoryDraft Semantic (encodeText C.int 42) ["n"] Curated)
                     _ <- remember (MemoryDraft Semantic "not a number" ["n"] Curated)
                     recallAs C.int (Query "" ["n"] 10)
           (out, _) = runPureEff (runMemoryPure prog)
           rs = map snd out  -- most-recent-first: the "not a number" item then the 42 item
       in ( case [v | Right v <- rs] of (v : _) -> Right v; [] -> Left ()
          , any (\e -> case e of Left _ -> True; Right _ -> False) rs ))
```

`C.int`/`C.str` come from the qualified `Crucible.Codec as C` import (already in Spec.hs). If `(.content)` / `(.source)` getter sections are ambiguous, annotate. Pin any value that differs from these against the ACTUAL deterministic output and report; do not weaken a checkable value to a property.

- [ ] **Step 4: build + suite.** Build exit 0; `1 test suite(s) passed`, +7. Report the count.

- [ ] **Step 5: commit.**

```bash
git add src/Crucible/Codec.hs src/Crucible/Memory.hs test/Spec.hs
git commit -m "$(printf 'feat(memory): Memory effect, pure/scripted interpreters, recallAs; encodeText\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: `runMemoryFile` (JSONL) + codecs + file tests

**Files:** Modify `src/Crucible/Memory.hs`, `test/Spec.hs`, `zinc.toml` (test deps).

- [ ] **Step 1: codecs + file interpreter in `Crucible.Memory`.** Add `runMemoryFile` to the export list. Add imports: `import Control.Exception (IOException, try)`, `import qualified Data.Text.IO as TIO`, and from `Crucible.Codec` add `(JSONCodec, object, field, optField, enum, str, int, list', bimapCodec, dimapCodec, encodeText)`. Add the codecs and interpreter:

```haskell
kindCodec :: JSONCodec MemoryKind
kindCodec = enum [("episodic", Episodic), ("semantic", Semantic), ("procedural", Procedural)]

memoryIdCodec :: JSONCodec MemoryId
memoryIdCodec = dimapCodec MemoryId idInt int

-- Provenance as a tagged object: {"by":"skill","name":...} etc.
data RawProv = RawProv { by :: Text, name :: Maybe Text }
provenanceCodec :: JSONCodec Provenance
provenanceCodec = bimapCodec toP fromP
  (object (RawProv <$> field "by" (.by) str <*> optField "name" (.name) str))
  where
    toP r = case r.by of
      "skill"         -> maybe (Left "skill provenance needs a name") (Right . BySkill) r.name
      "session"       -> maybe (Left "session provenance needs a name") (Right . BySession) r.name
      "consolidation" -> Right ByConsolidation
      "curated"       -> Right Curated
      other           -> Left ("unknown provenance: " <> T.unpack other)
    fromP (BySkill n)     = RawProv "skill" (Just n)
    fromP (BySession n)   = RawProv "session" (Just n)
    fromP ByConsolidation = RawProv "consolidation" Nothing
    fromP Curated         = RawProv "curated" Nothing

memoryItemCodec :: JSONCodec MemoryItem
memoryItemCodec = object (MemoryItem
  <$> field "id"        (.memId)     memoryIdCodec
  <*> field "kind"      (.kind)      kindCodec
  <*> field "content"   (.content)   str
  <*> field "tags"      (.tags)      (list' str)
  <*> field "source"    (.source)    provenanceCodec
  <*> field "createdAt" (.createdAt) int)

-- MemoryEntry as a tagged object: {"entry":"remembered","item":{...}} / {"entry":"forgot","id":n}
data RawEntry = RawEntry { entry :: Text, item :: Maybe MemoryItem, fid :: Maybe MemoryId }
entryCodec :: JSONCodec MemoryEntry
entryCodec = bimapCodec toE fromE
  (object (RawEntry <$> field "entry" (.entry) str
                    <*> optField "item" (.item) memoryItemCodec
                    <*> optField "id"   (.fid)  memoryIdCodec))
  where
    toE r = case r.entry of
      "remembered" -> maybe (Left "remembered entry needs an item") (Right . Remembered) r.item
      "forgot"     -> maybe (Left "forgot entry needs an id") (Right . Forgot) r.fid
      other        -> Left ("unknown entry: " <> T.unpack other)
    fromE (Remembered it) = RawEntry "remembered" (Just it) Nothing
    fromE (Forgot i)      = RawEntry "forgot" Nothing (Just i)

-- | Read the entry log, tolerant of blank/garbled lines (skipped).
readLog :: FilePath -> IO [MemoryEntry]
readLog path = do
  r <- try (TIO.readFile path) :: IO (Either IOException Text)
  let contents = either (const "") Prelude.id r
  pure [e | ln <- T.lines contents, not (T.null (T.strip ln))
          , Right e <- [decodeLLM entryCodec ln]]

appendEntry :: FilePath -> MemoryEntry -> IO ()
appendEntry path e = TIO.appendFile path (encodeText entryCodec e <> "\n")

-- | A JSONL log at the path. Remember/Forget append one line; Recall reads,
-- folds, filters, budgets. id = count of prior Remembered entries;
-- createdAt = the same ordinal (a uniform counter, not wall-clock).
-- git-diffable, lexical + tag matching.
runMemoryFile :: (IOE :> es) => FilePath -> Eff (Memory : es) a -> Eff es a
runMemoryFile path = interpret $ \_ -> \case
  Remember d -> liftIO $ do
    es <- readLog path
    let n = length [() | Remembered _ <- es]
    appendEntry path (Remembered (itemOf d n))
    pure (MemoryId n)
  Recall q -> liftIO (queryLive q <$> readLog path)
  Forget i -> liftIO (appendEntry path (Forgot i))
```

Add `interpret` to the `Effectful.Dispatch.Dynamic` import. `decodeLLM` is already imported. If a `(.by)`/`(.item)`/`(.fid)` getter clashes (RawProv/RawEntry share no labels with the domain types except via DuplicateRecordFields), annotate and report.

- [ ] **Step 2: test deps.** In `zinc.toml`, add `"directory"` to the `[build.test.spec]` `depends` list (for `removeFile` cleanup of temp files). Do NOT add it to the lib stanza (the lib uses only `Control.Exception.try` for missing files).

- [ ] **Step 3: file tests in `test/Spec.hs`.** Add `runMemoryFile` to the `Crucible.Memory` import, `import System.IO (openTempFile, hClose)`, `import System.Directory (removeFile)`. Add IO-form `do` checks (like the fallback/calllog tests):

```haskell
  , do (path, h) <- openTempFile "/tmp" "crucible-mem-test.jsonl"
       hClose h
       items <- runEff (runMemoryFile path (do
                  _ <- remember (MemoryDraft Episodic "alpha" ["x"] (BySkill "k"))
                  _ <- remember (MemoryDraft Semantic "beta" ["y"] Curated)
                  forget (MemoryId 0)
                  recall (Query "" [] 10)))
       raw <- TIO.readFile path
       removeFile path
       check "memory file: recall folds tombstones; history stays in the file"
         (["beta"], True, True)
         ( map (.content) items
         , T.isInfixOf "alpha" raw          -- the forgotten item's line is still there
         , T.isInfixOf "\"forgot\"" raw )   -- and the tombstone
  , do (path, h) <- openTempFile "/tmp" "crucible-mem-prov.jsonl"
       hClose h
       items <- runEff (runMemoryFile path (do
                  mapM_ remember
                    [ MemoryDraft Episodic   "a" [] (BySkill "k")
                    , MemoryDraft Semantic   "b" [] (BySession "run1")
                    , MemoryDraft Procedural "c" [] ByConsolidation
                    , MemoryDraft Episodic   "d" [] Curated ]
                  recall (Query "" [] 10)))
       removeFile path
       check "memory file: all provenance arms and kinds round-trip through JSONL"
         (4, True)
         ( length items
         , all (\(it, p) -> any (\j -> j.content == it && j.source == p) items)
               [ ("a", BySkill "k"), ("b", BySession "run1")
               , ("c", ByConsolidation), ("d", Curated) ] )
```

(The second check's lambda names are a little dense; if clearer, assert each arm individually. Keep the round-trip-through-file intent.)

- [ ] **Step 4: build + suite.** Build exit 0; `1 test suite(s) passed`, +2. Report the count.

- [ ] **Step 5: commit.**

```bash
git add src/Crucible/Memory.hs test/Spec.hs zinc.toml
git commit -m "$(printf 'feat(memory): runMemoryFile JSONL store with provenance codecs\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: demo + docs

**Files:** Modify `app/Main.hs`, create `docs/memory.md`, modify the docs nav (check `mkdocs.yml` or the equivalent under `docs/`).

- [ ] **Step 1: demo.** In `app/Main.hs` Anthropic-key-gated block, after the classify demo: write the classified `Sentiment` into a temp memory file, recall it typed, print. Add imports `import Crucible.Memory (...)` and reuse `encodeText`. Sketch (adapt to the actual `Sentiment`/`codec` names in Main, and to whether `classify` returns `Either DecodeError Sentiment`):

```haskell
      let memPath = "/tmp/crucible-memory-demo.jsonl"
      _ <- runEff (runMemoryFile memPath (case typed of
             Right s  -> remember (MemoryDraft Episodic (encodeText codec s) ["sentiment"] (BySkill "classify"))
             Left _   -> remember (MemoryDraft Episodic "decode failed" ["sentiment"] (BySkill "classify"))))
      recalled <- runEff (runMemoryFile memPath (recallAs codec (Query "" ["sentiment"] 5)))
      TIO.putStrLn ("memory: recalled " <> T.pack (show (length recalled)) <> " item(s); "
                    <> T.pack (show [either (const "stale") sentLabel v | (_, v) <- recalled]))
```

(`typed`, `codec`, `sentLabel` are the existing classify-demo bindings; adapt. Use the same `Sentiment` codec for encode and recall so the round-trip succeeds.)

- [ ] **Step 2: build + live smoke.**

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: a `memory: recalled 1 item(s); ["positive"]` style line; exit 0. REPORT the exact line.

- [ ] **Step 3: docs.** Create `docs/memory.md`: the `Memory` effect (Remember/Recall/Forget, supersede-not-erase), `MemoryItem` and the typed `Provenance` (the four arms and why provenance is mandatory), the three interpreters (scripted/pure/file, JSONL git-diffable), typed memory via `encodeText` + `recallAs` and the free-staleness property, the linear+star shape framing (linear log substrate, typed profile as the star view, tree/graph as future interpreters), and the disciplines (a `maxItems` budget on every recall; provenance for trust and bulk revocation). Note consolidation and `memoryLift` as follow-on sub-projects. Add the page to the docs nav (find the nav file: `mkdocs.yml`, `_config.yml`, or an index/sidebar under `docs/`; mirror how `evals.md`/`streaming.md`/`live-interpreter.md` are listed). House style STRICT: `grep -n $'—\|–' docs/memory.md` empty; no hype; no "manifest".

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/memory.md <nav-file>
git commit -m "$(printf 'docs(site)+demo: Memory effect, typed memory round-trip live\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: merge + publish + close + file follow-on beads

- [ ] **Step 1:** full suite `1 test suite(s) passed`.
- [ ] **Step 2:** merge via `superpowers:finishing-a-development-branch` (the user picks "merge to master locally"); `git pull` first (master may have moved); suite on master; push; Pages `built`.
- [ ] **Step 3: file the two follow-on sub-project beads** (so they are not lost):

```bash
bd create --title="Memory consolidation: offline Skill + apply function (sub-project 2 of l9d)" --description="Skill [MemoryItem] ConsolidationPlan (keep/merge/supersede/drop per item) + a pure apply over the entry log. Sleep-time-compute shape; crucible ships the skill + apply, not a scheduler. Reads linear, writes star (the linear->star pump). See docs/superpowers/research/2026-06-11-agentic-memory.md point 4; builds on Crucible.Memory." --type=feature --priority=3
bd create --title="memoryLift ablation eval hook (sub-project 3 of l9d)" --description="memoryLift :: Skill i o -> [MemoryItem] -> Eff es (Report, Report): run a skill's attached cases with and without candidate memories rendered into the preamble, compare pass rates. Makes 'does this memory pay rent' a number; a principled write gate for procedural memories. See research point 5; builds on Crucible.Memory + Crucible.Eval." --type=feature --priority=3
```

- [ ] **Step 4:** `bd close crucible-l9d --reason="Shipped sub-project 1 (foundation): Crucible.Memory (Remember/Recall/Forget, typed Provenance, MemoryItem/Query), scripted/pure/file interpreters (JSONL, supersede-not-erase, folded liveness), recallAs typed recall with free staleness, encodeText in Codec. ~9 tests, live typed round-trip demo, docs/memory.md. Consolidation Skill (sub-project 2) and memoryLift eval hook (sub-project 3) filed as follow-on beads."`

---

## Self-Review

**1. Spec coverage:** effect + 3 ops + smart ctors -> Task 1. Types (MemoryKind/MemoryId/Provenance sum/MemoryDraft/MemoryItem/Query) -> Task 1. Entry-log model + folded liveness + kernel (liveItems/matchQuery/queryLive, recency+budget) -> Task 1. Scripted + pure interpreters -> Task 1; file interpreter + codecs -> Task 2. recallAs returning [(MemoryItem, Either DecodeError a)] -> Task 1. encodeText -> Task 1. Provenance mandatory + matchable -> tests. supersede-not-erase + history-preserved -> Task 2 file test. Demo + docs/memory.md + nav -> Task 3. Non-goals (consolidation, memoryLift, embeddings, tree/graph, wall-clock, hash ids) absent; consolidation + memoryLift filed as beads -> Task 4. createdAt-as-counter refinement documented. ✅

**2. Placeholder scan:** the demo step adapts to existing classify bindings (named) and the docs nav file is "find and mirror" (concrete instruction); the dense round-trip lambda has a stated simplification. No silent gaps. ✅

**3. Type consistency:** `Memory` ops match the smart constructors; `queryLive :: Query -> [MemoryEntry] -> [MemoryItem]` used by pure and file; `itemOf d n` builds with createdAt=n=id ordinal; `recallAs :: JSONCodec a -> Query -> Eff es [(MemoryItem, Either DecodeError a)]` = map decode over recall; codecs (kind/provenance/item/entry) cover every constructor; `runMemoryFile :: (IOE :> es) => FilePath -> ...`. Check counts: +7 (Task 1) +2 (Task 2). ✅
