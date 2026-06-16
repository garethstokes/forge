# Ingestion CLI (HealthBench slice 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `manifest-evals ingest <file.jsonl> --name N --slug S [...]` turns a JSONL file into a Dataset / DatasetVersion / Examples graph — generic `{key, input, expected?, meta?}` rows plus a `healthbench` adapter — with refuse-or-`--force` re-ingest semantics, atomically.

**Architecture:** A new `Evals.Ingest` lib module holds the pure adapters (`IngestRow`, `Format`, `generic`, `healthbench`) and the IO driver (`ingestFile`); `app/Main.hs` parses flags and calls it. The whole import is one `withTransaction`. Re-ingest into an existing `(dataset, version)` refuses unless `--force`; `--force` is pre-checked against referencing Runs (clean error rather than relying on the cascade Restrict to throw).

**Tech Stack:** the existing lib closure (`aeson`, `bytestring`, `text`, `time`, `manifest`); committed JSONL fixtures under `test/fixtures/`; the in-repo Harness + `withEphemeralDb`.

**Spec:** `docs/superpowers/specs/2026-06-13-ingestion-cli-design.md`

**Repo facts (verified):** `Example {key :: Text, input :: Aeson Value, expected :: Maybe (Aeson Value), meta :: Maybe (Aeson Value)}` plus the FK `datasetVersion`; `Dataset {org, name, slug, ...}` (the CLI has no org concept → default `OrgId 1`, as the demo/tests do); `DatasetVersion {dataset, version, note, finalizedAt, ...}`. `add (X {...} :: X)` returns the row WITH its serial id. `DatasetVersion → Example` is `Cascade`, `DatasetVersion → Run` is `Restrict` (a force-delete of a version with Runs would be blocked — we pre-check instead). The lib already depends on `aeson`/`bytestring`/`time`; the `manifest-evals` exe depends on the lib, so it picks up `Evals.Ingest` with no new deps. `add`/`selectWhere`/`delete`/`withSession`/`withTransaction`/`Key`/`(==.)`/`Cond` come from `Manifest`. Tests use ephemeral Postgres via `Manifest.Testing.withEphemeralDb` and the `expect` helper (see `GradeSpec`/`SchemaSpec`). `test/Spec.hs` runs `ApiSpec >> SchemaSpec >> ExecuteSpec >> GradeSpec`.

## File structure

- Create `src/Evals/Ingest.hs` — `IngestRow`, `Format`, `generic`, `healthbench`, `formatFor`, `IngestOpts`, `IngestError`, `IngestResult`, `ingestFile`.
- Create `test/IngestSpec.hs`; `test/fixtures/{generic,healthbench,skip-bad}.jsonl`; modify `test/Spec.hs`.
- Modify `app/Main.hs` — the `ingest` subcommand + flag parsing + usage.
- Modify `README.md` — an Ingestion section.

---

### Task 1: pure adapters (TDD)

**Files:** Create `src/Evals/Ingest.hs`, `test/IngestSpec.hs`; Modify `test/Spec.hs`.

- [ ] **Step 1: failing tests.** Create `test/IngestSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module IngestSpec (main) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import Evals.Ingest

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = do
  adapterSpec
  putStrLn "manifest-evals IngestSpec: adapters OK"

adapterSpec :: IO ()
adapterSpec = do
  -- formatFor
  expect "formatFor generic" (maybe False (const True) (formatFor "generic"))
  expect "formatFor healthbench" (maybe False (const True) (formatFor "healthbench"))
  expect "formatFor unknown -> Nothing" (maybe True (const False) (formatFor "xml"))
  -- generic: 1:1
  let gOk = generic (object
        [ "key" .= ("c1" :: Text)
        , "input" .= toJSON ("hello" :: Text)
        , "expected" .= object ["a" .= (1 :: Int)]
        , "meta" .= object ["src" .= ("x" :: Text)] ])
  expect "generic maps all four fields"
    (case gOk of
       Right r -> r.key == "c1" && r.input == toJSON ("hello" :: Text)
                    && r.expected == Just (object ["a" .= (1 :: Int)])
                    && r.meta == Just (object ["src" .= ("x" :: Text)])
       Left _  -> False)
  expect "generic without expected/meta -> Nothings"
    (case generic (object ["key" .= ("k" :: Text), "input" .= toJSON ("i" :: Text)]) of
       Right r -> r.expected == Nothing && r.meta == Nothing
       Left _  -> False)
  expect "generic missing key -> Left"
    (isLeft (generic (object ["input" .= toJSON ("i" :: Text)])))
  expect "generic missing input -> Left"
    (isLeft (generic (object ["key" .= ("k" :: Text)])))
  -- healthbench: the three moves
  let promptArr = [ object ["role" .= ("user" :: Text), "content" .= ("q1" :: Text)] ]
      rubricsArr = [ object ["criterion" .= ("cites" :: Text), "points" .= (7 :: Double)
                            , "tags" .= (["axis:accuracy"] :: [Text])] ]
      hbRow = object
        [ "prompt_id" .= ("hb-1" :: Text)
        , "prompt" .= promptArr
        , "rubrics" .= rubricsArr
        , "example_tags" .= (["theme:hedging"] :: [Text])
        , "canary" .= ("healthbench:abc" :: Text) ]
      hb = healthbench hbRow
  expect "healthbench key <- prompt_id"
    (either (const False) (\r -> r.key == "hb-1") hb)
  expect "healthbench input <- {messages: prompt}"
    (either (const False) (\r -> r.input == object ["messages" .= promptArr]) hb)
  expect "healthbench expected <- rubrics verbatim"
    (either (const False) (\r -> r.expected == Just (toJSON rubricsArr)) hb)
  expect "healthbench meta carries tags + canary"
    (either (const False)
       (\r -> r.meta == Just (object [ "example_tags" .= (["theme:hedging"] :: [Text])
                                     , "canary" .= ("healthbench:abc" :: Text) ])) hb)
  expect "healthbench missing prompt_id -> Left"
    (isLeft (healthbench (object ["prompt" .= promptArr, "rubrics" .= rubricsArr])))
  expect "healthbench missing prompt -> Left"
    (isLeft (healthbench (object ["prompt_id" .= ("x" :: Text), "rubrics" .= rubricsArr])))
  expect "healthbench missing rubrics -> Left"
    (isLeft (healthbench (object ["prompt_id" .= ("x" :: Text), "prompt" .= promptArr])))
```

Wire into `test/Spec.hs`: `import qualified IngestSpec`, append `>> IngestSpec.main`.

- [ ] **Step 2:** `nix develop -c zinc test 2>&1 | tail -4` — compile FAILURE (`Evals.Ingest` missing).

- [ ] **Step 3: implement the pure layer** in `src/Evals/Ingest.hs` (the driver lands in Task 2 — but write the WHOLE module now including the Task-2 types/driver so it compiles once; the driver's TESTS are Task 2). The pure part:

```haskell
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Ingestion: turn a JSONL file into a Dataset / DatasetVersion / Examples
-- graph. A 'Format' adapts one parsed JSON object to an 'IngestRow' (the four
-- Example payload fields) or rejects it; 'ingestFile' streams the file and
-- writes the graph in one transaction.
module Evals.Ingest
  ( IngestRow (..)
  , Format
  , generic
  , healthbench
  , formatFor
  , IngestOpts (..)
  , IngestError (..)
  , IngestResult (..)
  , renderIngestError
  , ingestFile
  ) where

import Control.Monad (foldM)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Types as AT
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)

import Manifest
import Manifest.Postgres (Pool)

import Evals.Ids
import Evals.Schema

-- | The four Example payload fields parsed from one JSONL row. Ids are
-- assigned by 'add'.
data IngestRow = IngestRow
  { key      :: Text
  , input    :: Value
  , expected :: Maybe Value
  , meta     :: Maybe Value
  }
  deriving (Eq, Show)

-- | Adapt one parsed JSON object to a row, or reject it with a reason.
type Format = Value -> Either Text IngestRow

-- | Generic format: a top-level @{key, input, expected?, meta?}@ object.
generic :: Format
generic v = first T.pack $ AT.parseEither
  (AT.withObject "row" $ \o ->
     IngestRow <$> o AT..: "key"
               <*> o AT..: "input"
               <*> o AT..:? "expected"
               <*> o AT..:? "meta")
  v

-- | HealthBench format: wrap the bare @prompt@ array as @{messages: ...}@,
-- pass @rubrics@ through verbatim, fold @example_tags@/
-- @ideal_completions_data@/@canary@ into meta.
healthbench :: Format
healthbench v = first T.pack $ AT.parseEither
  (AT.withObject "hb" $ \o -> do
     k       <- o AT..: "prompt_id"
     prompt  <- o AT..: "prompt" :: AT.Parser Value
     rubrics <- o AT..: "rubrics" :: AT.Parser Value
     let metaKeys = ["example_tags", "ideal_completions_data", "canary"]
         present  = [ (K.fromText nm, val)
                    | nm <- metaKeys, Just val <- [KM.lookup (K.fromText nm) o] ]
     pure IngestRow
       { key      = k
       , input    = object ["messages" .= prompt]
       , expected = Just rubrics
       , meta     = if null present then Nothing else Just (Object (KM.fromList present))
       })
  v

-- | Resolve a @--format@ name.
formatFor :: Text -> Maybe Format
formatFor "generic"     = Just generic
formatFor "healthbench" = Just healthbench
formatFor _             = Nothing
```

(`prompt`/`rubrics` are pulled as `Value` so they pass through unparsed. `KM`/`K` are aeson 2.x KeyMap/Key — confirm the lib's aeson is 2.x; it is 2.3.) THEN append the driver from Task 2's Step 3 so the module compiles as a whole; the driver code is given there.

- [ ] **Step 4:** `nix develop -c zinc test 2>&1 | tail -4` — `IngestSpec: adapters OK` plus all existing green.
- [ ] **Step 5: commit** `feat(ingest): JSONL adapters — generic + healthbench`.

---

### Task 2: the import driver (TDD, ephemeral Postgres)

**Files:** Modify `src/Evals/Ingest.hs` (the driver — written in Task 1's Step 3 to compile; its tests land now); Create `test/fixtures/{generic,healthbench,skip-bad}.jsonl`; Modify `test/IngestSpec.hs`, `zinc.toml` (test deps += `directory`).

The driver (append to `src/Evals/Ingest.hs`):

```haskell
-- | Everything 'ingestFile' needs. @format@ is the resolved adapter.
data IngestOpts = IngestOpts
  { file    :: FilePath
  , name    :: Text
  , slug    :: Text
  , version :: Int
  , format  :: Format
  , limit   :: Maybe Int
  , skipBad :: Bool
  , force   :: Bool
  }

-- | Why an ingest aborted (no rows written).
data IngestError
  = BadLine Int Text          -- ^ line number (1-based) + the adapter/parse error
  | AlreadyExists Text Int    -- ^ slug + version already present (no --force)
  | HasRuns Text Int          -- ^ slug + version has Runs; --force refused
  deriving (Eq, Show)

data IngestResult = IngestResult { ingested :: Int, skipped :: Int }
  deriving (Eq, Show)

renderIngestError :: IngestError -> Text
renderIngestError = \case
  BadLine n e      -> "line " <> T.pack (show n) <> ": " <> e
  AlreadyExists s v -> "dataset " <> s <> " v" <> T.pack (show v)
                         <> " already exists (use --force to replace)"
  HasRuns s v       -> "dataset " <> s <> " v" <> T.pack (show v)
                         <> " has runs; delete them before --force"

-- | Read the file, adapt rows, and write the graph in one transaction.
-- Refuses an existing (slug, version) unless 'force'; 'force' is blocked when
-- Runs reference the version (a clean error, not a cascade-Restrict throw).
ingestFile :: Pool -> IngestOpts -> IO (Either IngestError IngestResult)
ingestFile pool opts = do
  contents <- BS.readFile opts.file
  let numbered = zip [1 :: Int ..] (BC.lines contents)
      nonBlank = [ (n, ln) | (n, ln) <- numbered, not (BC.all isSpace ln) ]
      limited  = maybe id take opts.limit nonBlank
  case adaptAll opts.format opts.skipBad limited of
    Left err            -> pure (Left err)
    Right (rows, nSkip) -> do
      now <- getCurrentTime
      withSession pool $ do
        existing <- selectWhere [ #slug ==. opts.slug ]
        case (existing :: [Dataset]) of
          (d : _) -> do
            vers <- selectWhere [ #dataset ==. d.id, #version ==. opts.version ]
            case (vers :: [DatasetVersion]) of
              (v : _)
                | not opts.force -> pure (Left (AlreadyExists opts.slug opts.version))
                | otherwise -> do
                    runs <- selectWhere [ #datasetVersion ==. v.id ]
                    if not (null (runs :: [Run]))
                      then pure (Left (HasRuns opts.slug opts.version))
                      else withTransaction $ do
                        delete v   -- cascade removes the version's Examples
                        writeVersion d.id opts rows now nSkip
              [] -> withTransaction (writeVersion d.id opts rows now nSkip)
          [] -> withTransaction $ do
            d <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = opts.name
                              , slug = opts.slug, createdAt = now } :: Dataset)
            writeVersion d.id opts rows now nSkip

-- | Add the DatasetVersion + one Example per row; return the tally.
writeVersion :: DatasetId -> IngestOpts -> [IngestRow] -> UTCTime -> Int -> Db (Either IngestError IngestResult)
writeVersion did opts rows now nSkip = do
  v <- add (DatasetVersion { id = DatasetVersionId 0, dataset = did, version = opts.version
                           , note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  mapM_ (\r -> add (Example { id = ExampleId 0, datasetVersion = v.id, key = r.key
                            , input = Aeson r.input, expected = fmap Aeson r.expected
                            , meta = fmap Aeson r.meta } :: Example)) rows
  pure (Right (IngestResult { ingested = length rows, skipped = nSkip }))

-- | Adapt every numbered line; on a bad line, abort (default) or skip+count.
adaptAll :: Format -> Bool -> [(Int, BS.ByteString)] -> Either IngestError ([IngestRow], Int)
adaptAll fmt skip = foldM step ([], 0)
  where
    step (acc, nSkip) (n, ln) =
      case eitherDecodeStrict ln >>= (first T.unpack . fmt) of
        Right r  -> Right (acc ++ [r], nSkip)
        Left err
          | skip      -> Right (acc, nSkip + 1)
          | otherwise -> Left (BadLine n (T.pack err))
```

(`UTCTime` needs `import Data.Time (UTCTime, getCurrentTime)`; `\case` needs `LambdaCase`. `eitherDecodeStrict ln :: Either String Value` then `fmt` returns `Either Text`; the `first T.unpack . fmt` unifies both error sides to `String` for the `>>=`, then `BadLine n (T.pack err)`. `acc ++ [r]` keeps order; fine at 5k rows.)

- [ ] **Step 1: fixtures.** Create `test/fixtures/generic.jsonl` (exactly two lines, no trailing logic needed):

```
{"key":"a","input":"first","expected":{"v":1},"meta":{"src":"t"}}
{"key":"b","input":{"messages":[{"role":"user","content":"hi"}]},"expected":["x"]}
```

`test/fixtures/healthbench.jsonl` (one line):

```
{"prompt_id":"hb-1","prompt":[{"role":"user","content":"q"}],"rubrics":[{"criterion":"cites","points":7,"tags":["axis:accuracy"]}],"example_tags":["theme:hedging"],"canary":"healthbench:abc"}
```

`test/fixtures/skip-bad.jsonl` (three lines, middle malformed):

```
{"key":"g1","input":"one"}
{ this is not json
{"key":"g2","input":"two"}
```

`zinc.toml`: add `"directory"` to the `[build.test.spec]` `depends` (boot lib; `removeFile`/`doesFileExist` aren't needed since we read committed fixtures, but the driver tests for `--force`-with-runs reuse fixtures — `directory` is only needed if a test writes a temp file; it does NOT here, so SKIP this dep change unless the compiler asks). [Plan note: no temp files — all driver tests read committed fixtures, so no `directory` dep is required. Leave `zinc.toml` unchanged.]

- [ ] **Step 2: driver tests.** Extend `test/IngestSpec.hs`: add imports

```haskell
import Data.Aeson (decode, encode)
import Manifest hiding (key)
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)
import Evals.Ids
import Evals.Migrate (migrateAll)
import Evals.Schema
```

and a `driverSpec` called from `main` after `adapterSpec` (and a `gen :: Format` / `hb :: Format` bound from `formatFor`). Use `withEphemeralDb` + `migrateAll`. Helper to fetch examples for a slug:

```haskell
examplesOf :: Pool -> Text -> IO [Example]
examplesOf pool slug = withSession pool $ do
  ds <- selectWhere [ #slug ==. slug ]
  case (ds :: [Dataset]) of
    (d : _) -> do
      vs <- selectWhere [ #dataset ==. d.id ]
      concat <$> mapM (\v -> selectWhere [ #datasetVersion ==. v.id ]) (vs :: [DatasetVersion])
    [] -> pure []

optsFor :: Format -> FilePath -> Text -> Bool -> Maybe Int -> Bool -> IngestOpts
optsFor fmt fp slug force lim skip = IngestOpts
  { file = fp, name = slug, slug = slug, version = 1, format = fmt
  , limit = lim, skipBad = skip, force = force }
```

Scenarios (each `withEphemeralDb $ \pool -> do _ <- withSession pool migrateAll; ...`; assert via the helpers; render expected JSON with `decode`/`encode`):

1. **generic happy**: `Just gen <- pure (formatFor "generic")`; `r <- ingestFile pool (optsFor gen "test/fixtures/generic.jsonl" "ds1" False Nothing False)`; expect `r == Right (IngestResult 2 0)`; `exs <- examplesOf pool "ds1"`; expect 2 examples; expect the keys sorted are `["a","b"]`; expect example "a" has `input == Aeson (String "first")`, `expected == Just (Aeson (object ["v" .= (1::Int)]))`, `meta == Just (Aeson (object ["src" .= ("t"::Text)]))`.
2. **healthbench happy**: ingest `healthbench.jsonl` as slug "hb" with the healthbench format; expect `Right (IngestResult 1 0)`; the one example's `input` is `Aeson (object ["messages" .= [...]])`, `expected` is `Just (Aeson <the rubrics array>)`, `meta` carries `example_tags`+`canary`.
3. **refuse existing**: ingest generic.jsonl into "ds2"; ingest AGAIN (force False) → `Left (AlreadyExists "ds2" 1)`; `examplesOf "ds2"` still exactly 2 (no duplicate).
4. **--force replaces**: ingest generic.jsonl into "ds3"; then ingest a DIFFERENT-content file into "ds3" with force True → `Right`; the examples now reflect the new file only. (Reuse `healthbench.jsonl` via the healthbench format under slug "ds3" force True → 1 example whose key is "hb-1"; assert `examplesOf "ds3"` has exactly one example, key "hb-1".)
5. **--force blocked by a Run**: ingest generic.jsonl into "ds4"; seed a Target/TargetVersion and a Run whose `datasetVersion` is ds4's v1 (fetch ds4's DatasetVersion id via `examplesOf`-style query or `selectWhere`); re-ingest with force True → `Left (HasRuns "ds4" 1)`; `examplesOf "ds4"` still 2 (version kept).
6. **--limit**: ingest generic.jsonl into "ds5" with `limit = Just 1` → `Right (IngestResult 1 0)`; 1 example (key "a").
7. **skip-bad off**: ingest `skip-bad.jsonl` into "ds6" (skipBad False) → `Left (BadLine 2 _)` (assert it's `BadLine` with line 2 — pattern-match); `examplesOf "ds6"` empty (nothing written).
8. **skip-bad on**: ingest `skip-bad.jsonl` into "ds7" (skipBad True) → `Right (IngestResult 2 1)`; 2 examples (keys "g1","g2").

Update the final `putStrLn` to `IngestSpec: adapters + driver OK`.

- [ ] **Step 3:** the driver code is already in `src/Evals/Ingest.hs` from Task 1's Step 3 — run `nix develop -c zinc test 2>&1 | tail -5` TWICE (DB scenarios). Expected: all green incl. `IngestSpec: adapters + driver OK`. If scenario 5's HasRuns or scenario 4's force-replace fails, debug the driver.
- [ ] **Step 4: commit** `feat(ingest): ingestFile driver — atomic import, refuse/--force, limit, skip-bad`.

---

### Task 3: the CLI subcommand + docs

**Files:** Modify `app/Main.hs`, `README.md`.

- [ ] **Step 1: the subcommand.** In `app/Main.hs` add imports `import Evals.Ingest (IngestOpts (..), IngestResult (..), formatFor, ingestFile, renderIngestError)` and (for `T.unpack`) the existing `Data.Text` qualified import suffices. Add the case before the `_ -> die usage` fallthrough:

```haskell
  ("ingest" : fileArg : flags) -> do
    name <- reqFlag "--name" flags
    slug <- reqFlag "--slug" flags
    ver  <- maybe (pure 1) parseIntFlag (lookupFlag "--version" flags)
    fmtN <- maybe (pure "generic") pure (lookupFlag "--format" flags)
    fmt  <- maybe (die ("unknown --format: " <> fmtN)) pure (formatFor (T.pack fmtN))
    lim  <- traverse parseIntFlag (lookupFlag "--limit" flags)
    let opts = IngestOpts
          { file = fileArg, name = T.pack name, slug = T.pack slug, version = ver
          , format = fmt, limit = lim
          , skipBad = "--skip-bad" `elem` flags, force = "--force" `elem` flags }
    withEnvPool $ \pool -> ingestFile pool opts >>= \case
      Left e  -> die (T.unpack (renderIngestError e))
      Right r -> putStrLn $ "ingested " <> slug <> " v" <> show ver <> ": "
                   <> show r.ingested <> " examples (" <> show r.skipped <> " skipped)"
```

with flag helpers near `requireEnv`:

```haskell
-- | The value following @name@ in the flag list (@--name foo@), if present.
lookupFlag :: String -> [String] -> Maybe String
lookupFlag name = \case
  (k : v : _) | k == name -> Just v
  (_ : rest)              -> lookupFlag name rest
  []                      -> Nothing

reqFlag :: String -> [String] -> IO String
reqFlag name = maybe (die (name <> " is required")) pure . lookupFlag name

parseIntFlag :: String -> IO Int
parseIntFlag s = maybe (die ("not a number: " <> s)) pure (readMaybe s)
```

Extend `usage`:

```haskell
usage = "usage: manifest-evals migrate | run <runId> [--concurrency N] | "
     <> "score <runId> <graderVersionId>... [--concurrency N] | "
     <> "ingest <file.jsonl> --name N --slug S [--version N] [--format generic|healthbench] [--limit N] [--skip-bad] [--force]"
```

(Update the module haddock's one-line command summary too.)

- [ ] **Step 2: build + smoke.** `nix develop -c zinc build 2>&1 | tail -2`. Then a real ingest against a throwaway DB (psql available in the devShell):

```bash
nix develop -c bash -c 'dropdb --if-exists --force ingest_smoke; createdb ingest_smoke; \
  MANIFEST_DATABASE_URL=postgresql:///ingest_smoke ./.zinc/build/manifest-evals migrate; \
  MANIFEST_DATABASE_URL=postgresql:///ingest_smoke ./.zinc/build/manifest-evals ingest test/fixtures/healthbench.jsonl --name HB --slug hb-smoke --format healthbench; \
  MANIFEST_DATABASE_URL=postgresql:///ingest_smoke ./.zinc/build/manifest-evals ingest test/fixtures/healthbench.jsonl --name HB --slug hb-smoke --format healthbench; \
  dropdb --if-exists --force ingest_smoke'
```

Expected: first ingest prints `ingested hb-smoke v1: 1 examples (0 skipped)`; the second prints the `already exists (use --force to replace)` error and a non-zero exit. (Report the actual lines.)

- [ ] **Step 3: README.** Add an "Ingesting datasets" subsection: the `ingest` usage line; the generic shape `{key, input, expected?, meta?}`; the `healthbench` format's three moves; the refuse/`--force` (and the runs-block) and `--limit`/`--skip-bad` semantics; a one-liner that `Example.input` must be the `{"messages":[...]}` conversation shape (which `healthbench` produces). Layout bullet: `src/Evals/Ingest.hs`.

- [ ] **Step 4:** full suite + `nix develop -c zinc build`; commit `feat(cli): manifest-evals ingest; docs` and push.

---

## Self-Review

**1. Spec coverage:** §1 CLI surface (subcommand, all flags, defaults, env, output line) → Task 3; §2 `Evals.Ingest` (IngestRow, Format, generic + healthbench's three moves, formatFor) → Task 1; §3 driver (one transaction, exists-refuse, --force delete with the Runs pre-check, add Dataset/Version/Examples, streaming via `BC.lines`, --limit truncation, per-line bad handling + --skip-bad) → Task 2; §4 testing (pure adapters incl. all Left cases; driver scenarios incl. refuse, force-replace, force-blocked-by-run, limit, skip-bad on/off; committed fixtures) → Tasks 1-2; §5 out-of-scope (no provider knob, no blob download, no seeded sampling, no glob) absent everywhere.

**2. Placeholder scan:** the one cross-task note — the whole `Evals.Ingest` module (pure + driver) is written in Task 1 Step 3 so it compiles, with the driver code given verbatim in Task 2; this is explicit instruction, not a TBD. The `directory` dep note resolves to "not needed" with a reason. No unmarked placeholders.

**3. Type consistency:** `IngestRow {key, input, expected, meta}`, `Format = Value -> Either Text IngestRow`, `generic`/`healthbench`/`formatFor`, `IngestOpts {file, name, slug, version, format, limit, skipBad, force}`, `IngestError {BadLine, AlreadyExists, HasRuns}`, `IngestResult {ingested, skipped}`, `ingestFile :: Pool -> IngestOpts -> IO (Either IngestError IngestResult)`, `renderIngestError` — names/shapes consistent across Tasks 1-3 and both test layers and Main.
