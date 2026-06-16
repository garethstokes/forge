# Eval Run Orchestrator (sub-project C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute an eval run — load a queued `Run`, call the model for each example through crucible, persist one `Output` row per example, and update the run status. Scoring is out of scope.

**Architecture:** An injected `LlmRunner` (live Anthropic via crucible / scripted for tests) decouples the executor from the network. `executeRun` loads the run graph in one Manifest session, fans out bounded-concurrent per-example work (`async` + `QSem`), writes one `Output` per example in its own session, and finishes the run `succeeded` (per-example failures are recorded on the `Output`, not the run). The two effect worlds meet at IO: Manifest `Db` via `withSession`, crucible `Eff` via `runEff` inside the runner.

**Tech Stack:** GHC 9.12.2, zinc, Manifest (Db/schema from sub-project A), crucible @ 0cb8c17 (post-DevEx API: `Crucible.LLM`, qualified `Crucible.LLM.Anthropic`, `Crucible.Usage`), `effectful`, `async`, aeson.

**Spec:** manifest repo `docs/superpowers/specs/2026-06-10-eval-run-orchestrator-design.md`. The spec predates crucible's DevEx pass; this plan uses the NEW names:

| Spec (old) | Now |
|---|---|
| `AnthropicConfig { acApiKey, acModel, acMaxTokens, acTimeoutSecs, acMaxRetries, acBaseDelayMicros, acStreamIdleSecs }` | `AnthropicConfig { apiKey, model, maxTokens, timeoutSecs, maxRetries, baseDelayMicros, streamIdleSecs }` (`NoFieldSelectors`, record-dot) |
| `runLLMAnthropic` / usage variant | `Anthropic.run` / `Anthropic.usage :: AnthropicConfig -> Eff (LLM : es) a -> Eff es (a, Usage)` (import qualified) |
| `Usage`, `usTotalTokens` | unchanged module `Crucible.Usage`; fields are `inputTokens`/`outputTokens`. **No ToJSON instance** — the executor builds the tokens JSON itself. |
| `tv.params` keys `max_tokens, temperature, timeout, retries` | `AnthropicConfig` has **no temperature knob**; map only `max_tokens`→`maxTokens`, `timeout`→`timeoutSecs`, `retries`→`maxRetries`. |

## File structure

- Create `src/Evals/Execute.hs` — the engine: `ExecError`, `renderExecError`, `LlmRunner`, `scriptedRunner`, `decodeInput`, `assembleMessages`, `usageJson`, `RunOutcome`, `executeRun`.
- Create `src/Evals/Execute/Anthropic.hs` — the live edge: `cfgFrom`, `liveAnthropicRunner`.
- Create `app/Main.hs` — the `manifest-evals` CLI (`migrate`, `run <runId>`).
- Create `test/ExecuteSpec.hs`; Modify `test/Spec.hs` (run both specs).
- Modify `zinc.toml` — lib gains `effectful`, `effectful-core`, `async`; new `[build.exe.manifest-evals]`.

---

### Task 1: `Evals.Execute` types + prompt assembly (pure, TDD)

**Files:**
- Create: `src/Evals/Execute.hs`
- Create: `test/ExecuteSpec.hs`
- Modify: `test/Spec.hs`
- Modify: `zinc.toml` (lib depends)

- [ ] **Step 1: Write the failing tests.** Create `test/ExecuteSpec.hs`:

```haskell
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module ExecuteSpec (main) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import Crucible.LLM (Message (..), Role (..))
import Evals.Execute

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = do
  assemblySpec
  putStrLn "manifest-evals ExecuteSpec: assembly OK"

-- decodeInput / assembleMessages are pure; no DB, no network.
assemblySpec :: IO ()
assemblySpec = do
  -- a JSON string input becomes a single User message
  expect "string input -> [User]"
    (decodeInput (toJSON ("2+2?" :: Text)) == Right [Message User "2+2?"])
  -- {"messages": [...]} round-trips roles
  let multi = object
        [ "messages" .=
            [ object ["role" .= ("user" :: Text),      "content" .= ("q1" :: Text)]
            , object ["role" .= ("assistant" :: Text), "content" .= ("a1" :: Text)]
            , object ["role" .= ("user" :: Text),      "content" .= ("q2" :: Text)]
            ]
        ]
  expect "messages input -> turns"
    (decodeInput multi == Right [Message User "q1", Message Assistant "a1", Message User "q2"])
  -- an unknown role and a non-string/object input are decode errors
  let badRole = object ["messages" .= [object ["role" .= ("robot" :: Text), "content" .= ("x" :: Text)]]]
  expect "unknown role is an error" (isLeft (decodeInput badRole))
  expect "number input is an error" (isLeft (decodeInput (toJSON (42 :: Int))))
```

Modify `test/Spec.hs` to:

```haskell
module Main where
import qualified ExecuteSpec
import qualified SchemaSpec
main :: IO ()
main = SchemaSpec.main >> ExecuteSpec.main
```

- [ ] **Step 2: Run to verify failure.** Run: `nix develop -c zinc test 2>&1 | tail -5`. Expected: compile FAILURE — `Evals.Execute` does not exist.

- [ ] **Step 3: Implement `src/Evals/Execute.hs`** (everything except `executeRun`, which is Task 2 — include its exported types now so the module compiles whole; the `executeRun` definition itself also lands now but is exercised by Task 2's tests):

```haskell
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Run execution (sub-project C): assemble prompts, call the injected LLM
-- backend, persist one 'Output' per 'Example', and finish the run. Failure is
-- per-example: a model or decode error is recorded on that 'Output' and the
-- run still finishes @succeeded@. The run only goes @failed@ when the run or
-- its target version cannot be loaded.
module Evals.Execute
  ( ExecError (..)
  , renderExecError
  , LlmRunner
  , scriptedRunner
  , decodeInput
  , assembleMessages
  , usageJson
  , RunOutcome (..)
  , executeRun
  ) where

import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (SomeException, bracket_, try)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Types as AT
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (diffUTCTime, getCurrentTime)

import Crucible.LLM (Message (..), Role (..))
import Crucible.Usage (Usage (..))
import Manifest hiding (Target)
import Manifest.Postgres (Pool)

import Evals.Ids
import Evals.Schema

-- | A per-example failure: the model call failed, or the example's @input@
-- jsonb is not in a shape we can turn into messages.
data ExecError = LlmError Text | InputDecodeError Text
  deriving (Eq, Show)

renderExecError :: ExecError -> Text
renderExecError (LlmError t)         = "llm: " <> t
renderExecError (InputDecodeError t) = "input: " <> t

-- | The injected model backend: a target version + assembled messages in, a
-- reply (with token usage) or an error out. Live = crucible's Anthropic
-- interpreter ("Evals.Execute.Anthropic"); tests inject their own.
type LlmRunner = TargetVersion -> [Message] -> IO (Either ExecError (Text, Usage))

-- | A no-network backend that ignores the target and pops replies from the
-- scripted list, cycling when exhausted. (An 'Data.IORef.IORef' pops across
-- calls — crucible's @runLLMScripted@ scopes its script to one @runEff@, i.e.
-- one call, so the cross-call cursor has to live out here.)
scriptedRunner :: [Text] -> IO LlmRunner
scriptedRunner replies
  | null replies = pure (\_ _ -> pure (Right ("", mempty)))
  | otherwise = do
      ref <- newIORef (cycle replies)
      pure $ \_ _ -> do
        t <- atomicModifyIORef' ref (\case (x : xs) -> (xs, x); [] -> ([], ""))
        pure (Right (t, mempty))

-- | An 'Example'\'s @input@ jsonb as conversation messages:
-- a JSON string is one user turn; @{"messages":[{role,content},…]}@ is a
-- multi-turn conversation (roles: system\/user\/assistant); anything else is
-- an 'InputDecodeError'.
decodeInput :: Value -> Either ExecError [Message]
decodeInput (String s) = Right [Message User s]
decodeInput v@(Object _) =
  either (Left . InputDecodeError . T.pack) Right (AT.parseEither parser v)
  where
    parser = AT.withObject "input" $ \o -> do
      items <- o AT..: "messages"
      mapM one items
    one = AT.withObject "message" $ \m -> do
      r <- m AT..: "role"
      c <- m AT..: "content"
      role <- case (r :: Text) of
        "system"    -> pure System
        "user"      -> pure User
        "assistant" -> pure Assistant
        _           -> fail ("unknown role: " <> T.unpack r)
      pure (Message role c)
decodeInput _ = Left (InputDecodeError "input must be a JSON string or {\"messages\": [...]}")

-- | The target's prompt as the system turn, then the example's conversation.
assembleMessages :: TargetVersion -> Example -> Either ExecError [Message]
assembleMessages tv ex = (Message System tv.prompt :) <$> decodeInput inputVal
  where Aeson inputVal = ex.input

-- | 'Usage' as the @Output.tokens@ jsonb. ('Usage' has no ToJSON upstream.)
usageJson :: Usage -> Value
usageJson u = object ["input_tokens" .= u.inputTokens, "output_tokens" .= u.outputTokens]

-- | What 'executeRun' did: example counts by fate.
data RunOutcome = RunOutcome
  { total     :: Int
  , succeeded :: Int
  , errored   :: Int
  , skipped   :: Int
  }
  deriving (Eq, Show)

-- | Execute a run: load the 'Run', its 'TargetVersion', its dataset version's
-- 'Example's and the already-output example ids (resume); mark @running@; for
-- each remaining example (bounded-concurrent) assemble + call the runner and
-- write one 'Output'; mark @succeeded@. A missing run\/target marks the run
-- @failed@ and returns an all-zero outcome.
executeRun :: Pool -> Int -> LlmRunner -> RunId -> IO RunOutcome
executeRun pool concurrency runner runId = do
  setup <- withSession pool $
    get @Run (Key runId) >>= \case
      Nothing -> pure Nothing
      Just run ->
        get @TargetVersion (Key run.targetVersion) >>= \case
          Nothing -> pure Nothing
          Just tv -> do
            examples <- selectWhere [ #datasetVersion ==. run.datasetVersion ]
            done     <- selectWhere [ #run ==. runId ]
            pure (Just (tv, examples :: [Example], map (.example) (done :: [Output])))
  case setup of
    Nothing -> do
      withSession pool $ update @Run (Key runId) [ #status =. "failed" ]
      pure RunOutcome { total = 0, succeeded = 0, errored = 0, skipped = 0 }
    Just (tv, examples, doneIds) -> do
      startedAt <- getCurrentTime
      withSession pool $
        update @Run (Key runId) [ #status =. "running", #startedAt =. Just startedAt ]
      sem <- newQSem (max 1 concurrency)
      let todo = [ ex | ex <- examples, ex.id `notElem` doneIds ]
      oks <- forConcurrently todo $ \ex ->
        bracket_ (waitQSem sem) (signalQSem sem) (runOne tv ex)
      finishedAt <- getCurrentTime
      withSession pool $
        update @Run (Key runId) [ #status =. "succeeded", #finishedAt =. Just finishedAt ]
      pure RunOutcome
        { total     = length examples
        , succeeded = length (filter id oks)
        , errored   = length (filter not oks)
        , skipped   = length examples - length todo
        }
  where
    -- One example: assemble, time the call, write the Output. Both error
    -- branches (assembly, model) record on the row; an unexpected exception
    -- from the runner is captured as an LlmError rather than killing the run.
    runOne :: TargetVersion -> Example -> IO Bool
    runOne tv ex = do
      t0 <- getCurrentTime
      result <- case assembleMessages tv ex of
        Left err   -> pure (Left err)
        Right msgs ->
          try (runner tv msgs) >>= \case
            Left (e :: SomeException) -> pure (Left (LlmError (T.pack (show e))))
            Right r                   -> pure r
      t1 <- getCurrentTime
      let ms = round (realToFrac (diffUTCTime t1 t0) * 1000 :: Double) :: Int
      case result of
        Right (txt, u) -> do
          _ <- withSession pool $ add Output
            { id = OutputId 0, run = runId, example = ex.id
            , response = Nothing, text = Just txt, error = Nothing
            , latencyMs = Just ms, tokens = Just (Aeson (usageJson u)) }
          pure True
        Left err -> do
          _ <- withSession pool $ add Output
            { id = OutputId 0, run = runId, example = ex.id
            , response = Nothing, text = Nothing
            , error = Just (renderExecError err)
            , latencyMs = Just ms, tokens = Nothing }
          pure False
```

In `zinc.toml`, extend the lib depends line to:

```toml
depends = ["base", "text", "time", "bytestring", "aeson", "manifest", "crucible", "effectful", "effectful-core", "async"]
```

- [ ] **Step 4: Run to verify pass.** Run: `nix develop -c zinc test 2>&1 | tail -5`. Expected: `manifest-evals SchemaSpec: … OK`, `manifest-evals ExecuteSpec: assembly OK`, `1 test suite(s) passed`.

- [ ] **Step 5: Commit.**

```bash
git add src/Evals/Execute.hs test/ExecuteSpec.hs test/Spec.hs zinc.toml
git commit -m "feat(execute): prompt assembly + injected LlmRunner + executeRun engine"
```

---

### Task 2: `executeRun` behaviour (ephemeral-Postgres TDD)

**Files:**
- Modify: `test/ExecuteSpec.hs`
- Modify (only if a test exposes a bug): `src/Evals/Execute.hs`

- [ ] **Step 1: Add the executor tests.** In `test/ExecuteSpec.hs`, add the imports:

```haskell
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Maybe (isJust)
import Data.Time (UTCTime, getCurrentTime)
import Crucible.Usage (Usage (..))
import Manifest hiding (Target)
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)
import Evals.Ids
import Evals.Migrate (migrateAll)
import Evals.Schema
```

a seed helper (the `Run` starts @queued@; one target version with a known prompt):

```haskell
data Seeded = Seeded { runId :: RunId, exampleIds :: [ExampleId] }

-- One dataset version with the given example inputs (keys "e1", "e2", …), one
-- target version (prompt "SYS", model "m", empty params), one queued Run.
seedRun :: Pool -> UTCTime -> [Value] -> IO Seeded
seedRun pool now inputs = withSession pool $ do
  d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "x", slug = "x", createdAt = now } :: Dataset)
  v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  exs <- mapM (\(i, inp) -> add (Example { id = ExampleId 0, datasetVersion = v.id, key = T.pack ("e" <> show (i :: Int))
                                         , input = Aeson inp, expected = Nothing, meta = Nothing } :: Example))
              (zip [1 ..] inputs)
  t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
  tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "SYS"
                           , params = Aeson (object []), createdAt = now } :: TargetVersion)
  r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "queued"
                 , startedAt = Nothing, finishedAt = Nothing, meta = Nothing, createdAt = now } :: Run)
  pure Seeded { runId = r.id, exampleIds = map (.id) exs }
```

(also add `import qualified Data.Text as T`), and four scenarios, called from `main` after `assemblySpec` (note: each `Dataset.slug` above is fixed `"x"` — if the schema ever uniques on slug, suffix per scenario; today it does not):

```haskell
main :: IO ()
main = do
  assemblySpec
  withEphemeralDb $ \pool -> do
    _ <- withSession pool migrateAll
    now <- getCurrentTime
    happyPathSpec pool now
    perExampleErrorSpec pool now
    resumeSpec pool now
    recordingSpec pool now
  putStrLn "manifest-evals ExecuteSpec: assembly + execute + resume + recording OK"

outputsFor :: Pool -> RunId -> IO [Output]
outputsFor pool rid = withSession pool (selectWhere [ #run ==. rid ])

runStatus :: Pool -> RunId -> IO (Maybe Text)
runStatus pool rid = withSession pool (fmap (fmap (.status)) (get @Run (Key rid)))

-- N examples -> N outputs with the scripted text; queued -> running -> succeeded.
happyPathSpec :: Pool -> UTCTime -> IO ()
happyPathSpec pool now = do
  sd <- seedRun pool now [toJSON ("q1" :: Text), toJSON ("q2" :: Text)]
  -- observe the mid-flight status from inside the runner
  seen <- newIORef (Nothing :: Maybe Text)
  base <- scriptedRunner ["out"]
  let runner tv msgs = do
        st <- runStatus pool sd.runId
        atomicModifyIORef' seen (\_ -> (st, ()))
        base tv msgs
  outcome <- executeRun pool 2 runner sd.runId
  expect "happy: outcome" (outcome == RunOutcome { total = 2, succeeded = 2, errored = 0, skipped = 0 })
  expect "happy: status running mid-flight" . (== Just "running") =<< readIORef seen
  expect "happy: status succeeded after" . (== Just "succeeded") =<< runStatus pool sd.runId
  outs <- outputsFor pool sd.runId
  expect "happy: two outputs, scripted text" (map (.text) outs == [Just "out", Just "out"])
  expect "happy: latency recorded" (all (isJust . (.latencyMs)) outs)
  expect "happy: usage json persisted"
    (all ((== Just (Aeson (usageJson mempty))) . (.tokens)) outs)
  r <- withSession pool (get @Run (Key sd.runId))
  expect "happy: startedAt/finishedAt set" (maybe False (\x -> isJust x.startedAt && isJust x.finishedAt) r)

-- one undecodable input -> that Output carries the error; the run still succeeds.
perExampleErrorSpec :: Pool -> UTCTime -> IO ()
perExampleErrorSpec pool now = do
  sd <- seedRun pool now [toJSON ("ok" :: Text), toJSON (42 :: Int)]
  runner <- scriptedRunner ["fine"]
  outcome <- executeRun pool 1 runner sd.runId
  expect "error: outcome" (outcome == RunOutcome { total = 2, succeeded = 1, errored = 1, skipped = 0 })
  expect "error: run still succeeded" . (== Just "succeeded") =<< runStatus pool sd.runId
  outs <- outputsFor pool sd.runId
  expect "error: one error row, one text row"
    (sort (map (\o -> (isJust o.text, isJust o.error)) outs) == [(False, True), (True, False)])

-- a pre-existing Output means that example is skipped, not duplicated.
resumeSpec :: Pool -> UTCTime -> IO ()
resumeSpec pool now = do
  sd <- seedRun pool now [toJSON ("a" :: Text), toJSON ("b" :: Text), toJSON ("c" :: Text)]
  let preDone = head sd.exampleIds
  _ <- withSession pool $ add Output
    { id = OutputId 0, run = sd.runId, example = preDone, response = Nothing
    , text = Just "already", error = Nothing, latencyMs = Nothing, tokens = Nothing }
  runner <- scriptedRunner ["new"]
  outcome <- executeRun pool 2 runner sd.runId
  expect "resume: outcome" (outcome == RunOutcome { total = 3, succeeded = 2, errored = 0, skipped = 1 })
  outs <- outputsFor pool sd.runId
  expect "resume: three outputs total, no duplicate"
    (length outs == 3 && length (filter ((== preDone) . (.example)) outs) == 1)
  expect "resume: the pre-done text is untouched"
    (map (.text) (filter ((== preDone) . (.example)) outs) == [Just "already"])

-- multi-turn input assembles in order, with the system prompt first.
recordingSpec :: Pool -> UTCTime -> IO ()
recordingSpec pool now = do
  let multi = object
        [ "messages" .=
            [ object ["role" .= ("user" :: Text),      "content" .= ("q1" :: Text)]
            , object ["role" .= ("assistant" :: Text), "content" .= ("a1" :: Text)]
            , object ["role" .= ("user" :: Text),      "content" .= ("q2" :: Text)]
            ]
        ]
  sd <- seedRun pool now [multi]
  ref <- newIORef ([] :: [[Message]])
  let runner _ msgs = do
        atomicModifyIORef' ref (\acc -> (acc ++ [msgs], ()))
        pure (Right ("r", Usage 3 4))
  outcome <- executeRun pool 1 runner sd.runId
  expect "recording: outcome" (outcome == RunOutcome { total = 1, succeeded = 1, errored = 0, skipped = 0 })
  calls <- readIORef ref
  expect "recording: system prompt first, turns in order"
    (calls == [[Message System "SYS", Message User "q1", Message Assistant "a1", Message User "q2"]])
  outs <- outputsFor pool sd.runId
  expect "recording: real usage persisted"
    (map (.tokens) outs == [Just (Aeson (usageJson (Usage 3 4)))])
```

- [ ] **Step 2: Run to verify the new tests run (and pass or fail honestly).** Run: `nix develop -c zinc test 2>&1 | tail -6`. `executeRun` already landed in Task 1, so expected: PASS (`assembly + execute + resume + recording OK`). Any failure here is a real engine bug — debug the engine, not the test, and fix `src/Evals/Execute.hs`.

- [ ] **Step 3: Commit.**

```bash
git add test/ExecuteSpec.hs
git commit -m "test(execute): executeRun happy path, per-example error, resume, multi-turn recording"
```

---

### Task 3: the live Anthropic edge (`cfgFrom` TDD; runner by inspection)

**Files:**
- Create: `src/Evals/Execute/Anthropic.hs`
- Modify: `test/ExecuteSpec.hs`

- [ ] **Step 1: Write the failing `cfgFrom` test.** In `test/ExecuteSpec.hs` add:

```haskell
import Crucible.LLM.Anthropic (AnthropicConfig (..), defaultAnthropicConfig)
import Evals.Execute.Anthropic (cfgFrom)
```

and a pure spec (call it from `main` right after `assemblySpec`):

```haskell
-- cfgFrom maps tv.model and the known params keys; everything else defaults.
cfgFromSpec :: IO ()
cfgFromSpec = do
  now <- getCurrentTime
  let tv ps = TargetVersion { id = TargetVersionId 0, target = TargetId 0, version = 1
                            , model = "claude-x", prompt = "SYS", params = Aeson ps
                            , createdAt = now } :: TargetVersion
      dflt = defaultAnthropicConfig "k"
      full = cfgFrom "k" (tv (object ["max_tokens" .= (9 :: Int), "timeout" .= (5 :: Int), "retries" .= (1 :: Int)]))
      none = cfgFrom "k" (tv (object []))
  expect "cfgFrom: model + key" (full.model == "claude-x" && full.apiKey == "k")
  expect "cfgFrom: params mapped"
    (full.maxTokens == 9 && full.timeoutSecs == 5 && full.maxRetries == 1)
  expect "cfgFrom: unknown knobs untouched"
    (full.baseDelayMicros == dflt.baseDelayMicros && full.streamIdleSecs == dflt.streamIdleSecs)
  expect "cfgFrom: empty params -> defaults (except model)"
    (none.maxTokens == dflt.maxTokens && none.timeoutSecs == dflt.timeoutSecs && none.maxRetries == dflt.maxRetries)
```

- [ ] **Step 2: Run to verify failure.** Run: `nix develop -c zinc test 2>&1 | tail -5`. Expected: compile FAILURE — `Evals.Execute.Anthropic` does not exist.

- [ ] **Step 3: Implement `src/Evals/Execute/Anthropic.hs`.** The live runner cannot be unit-tested without network; it is a thin, reviewable shim over crucible (which already has its own live-path tests):

```haskell
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The live model edge: build an 'AnthropicConfig' from a 'TargetVersion'
-- and run crucible's Anthropic interpreter. Retries\/backoff\/timeouts are
-- crucible's; this module only maps configuration and catches the typed error.
module Evals.Execute.Anthropic
  ( cfgFrom
  , liveAnthropicRunner
  ) where

import Control.Exception (try)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Types as AT
import Data.Text (Text)
import qualified Data.Text as T
import Effectful (runEff)

import Crucible.LLM (complete)
import Crucible.LLM.Anthropic (AnthropicConfig (..), AnthropicError, defaultAnthropicConfig)
import qualified Crucible.LLM.Anthropic as Anthropic
import Manifest (Aeson (..))

import Evals.Execute (ExecError (..), LlmRunner)
import Evals.Schema (TargetVersion)

-- | 'defaultAnthropicConfig' + the target's @model@, with the known
-- @params@ jsonb knobs mapped on top: @max_tokens@ → 'maxTokens', @timeout@ →
-- 'timeoutSecs', @retries@ → 'maxRetries'. Unknown keys (e.g. @temperature@ —
-- crucible has no such knob) are ignored.
cfgFrom :: Text -> TargetVersion -> AnthropicConfig
cfgFrom key tv = base
  { maxTokens   = intParam "max_tokens" base.maxTokens
  , timeoutSecs = intParam "timeout"    base.timeoutSecs
  , maxRetries  = intParam "retries"    base.maxRetries
  }
  where
    base = (defaultAnthropicConfig key) { model = tv.model }
    Aeson paramsVal = tv.params
    intParam :: AT.Key -> Int -> Int
    intParam k dflt = case paramsVal of
      Object o -> maybe dflt id (AT.parseMaybe (AT..: k) o)
      _        -> dflt

-- | The live backend: one @Anthropic.usage@-interpreted 'complete' per call;
-- a thrown 'AnthropicError' (after crucible's own retries) becomes 'LlmError'.
liveAnthropicRunner :: Text -> LlmRunner
liveAnthropicRunner key tv msgs =
  try (runEff (Anthropic.usage (cfgFrom key tv) (complete msgs))) >>= \case
    Right (t, u)                 -> pure (Right (t, u))
    Left (e :: AnthropicError)   -> pure (Left (LlmError (T.pack (show e))))
```

- [ ] **Step 4: Run to verify pass.** Run: `nix develop -c zinc test 2>&1 | tail -5`. Expected: PASS including `cfgFrom` expectations.

- [ ] **Step 5: Commit.**

```bash
git add src/Evals/Execute/Anthropic.hs test/ExecuteSpec.hs
git commit -m "feat(execute): live Anthropic runner via crucible (cfgFrom params mapping)"
```

---

### Task 4: the `manifest-evals` CLI

**Files:**
- Create: `app/Main.hs`
- Modify: `zinc.toml` (exe target)

- [ ] **Step 1: Add the exe target to `zinc.toml`** (after `[build.test.spec]`; `-lpq` because manifest links libpq):

```toml
[build.exe.manifest-evals]
source-dirs = ["app"]
main = "Main.hs"
ghc-options = ["-Wall", "-XOverloadedStrings", "-lpq"]
depends = ["base", "text", "bytestring", "manifest", "manifest-evals"]
```

- [ ] **Step 2: Write `app/Main.hs`:**

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The eval CLI: @manifest-evals migrate@ reconciles the schema;
-- @manifest-evals run \<runId\> [--concurrency N]@ executes a queued run with
-- the live Anthropic backend. Config from env: @MANIFEST_DATABASE_URL@,
-- @ANTHROPIC_API_KEY@, @EVALS_CONCURRENCY@ (flag wins over env; default 4).
module Main (main) where

import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import Text.Read (readMaybe)

import Manifest (withSession)
import Manifest.Postgres (Pool, closePool, newPool)

import Evals.Execute (RunOutcome (..), executeRun)
import Evals.Execute.Anthropic (liveAnthropicRunner)
import Evals.Ids (RunId (..))
import Evals.Migrate (migrateAll)

main :: IO ()
main = getArgs >>= \case
  ["migrate"] -> withEnvPool $ \pool -> do
    _ <- withSession pool migrateAll
    putStrLn "schema migrated"
  ("run" : ridStr : rest) -> do
    rid <- maybe (die ("not a run id: " <> ridStr)) pure (readMaybe ridStr)
    key <- requireEnv "ANTHROPIC_API_KEY"
    conc <- concurrencyFrom rest
    withEnvPool $ \pool -> do
      o <- executeRun pool conc (liveAnthropicRunner (T.pack key)) (RunId rid)
      putStrLn $ "run " <> ridStr <> ": "
        <> show o.total <> " examples, "
        <> show o.succeeded <> " succeeded, "
        <> show o.errored <> " errored, "
        <> show o.skipped <> " skipped (resume)"
  _ -> die "usage: manifest-evals migrate | manifest-evals run <runId> [--concurrency N]"

requireEnv :: String -> IO String
requireEnv name =
  lookupEnv name >>= maybe (die (name <> " is not set")) pure

-- --concurrency N beats EVALS_CONCURRENCY beats 4.
concurrencyFrom :: [String] -> IO Int
concurrencyFrom = \case
  ["--concurrency", n] -> maybe (die ("not a number: " <> n)) pure (readMaybe n)
  [] -> maybe 4 id . (>>= readMaybe) <$> lookupEnv "EVALS_CONCURRENCY"
  rest -> die ("unrecognised arguments: " <> unwords rest)

withEnvPool :: (Pool -> IO a) -> IO a
withEnvPool act = do
  url <- requireEnv "MANIFEST_DATABASE_URL"
  pool <- newPool (TE.encodeUtf8 (T.pack url)) 8
  r <- act pool
  closePool pool
  pure r
```

- [ ] **Step 3: Build + smoke the usage path.** Run:

```bash
nix develop -c zinc build 2>&1 | tail -3
nix develop -c zinc run manifest-evals 2>&1 | tail -2 ; echo "exit: $?"
```

Expected: build green; the bare invocation prints the `usage: …` line and exits non-zero. (If `zinc run` passes no extra args differently, invoke the built binary directly — its path appears in the build output, e.g. `.zinc/build/manifest-evals`.)

- [ ] **Step 4: Commit.**

```bash
git add app/Main.hs zinc.toml
git commit -m "feat(cli): manifest-evals migrate / run <runId> (env-configured, live backend)"
```

---

### Task 5: full verification + docs + push

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Full suite.** Run: `nix develop -c zinc test 2>&1 | tail -6`. Expected: SchemaSpec line, ExecuteSpec line, `1 test suite(s) passed`.

- [ ] **Step 2: README.** Update the Layout section to:

```markdown
## Layout

- `src/Evals/` — the eval data model (sub-project A): ids, schema types,
  schema, migrations — plus the run executor (sub-project C):
  `Evals.Execute` (prompt assembly, injected `LlmRunner`, `executeRun`) and
  `Evals.Execute.Anthropic` (the live crucible-backed runner).
- `app/` — the `manifest-evals` CLI: `migrate`, and `run <runId>` (env:
  `MANIFEST_DATABASE_URL`, `ANTHROPIC_API_KEY`, `EVALS_CONCURRENCY`).
- `test/` — `SchemaSpec` (schema scenarios) and `ExecuteSpec` (assembly,
  executeRun happy path / per-example error / resume / multi-turn recording)
  against an ephemeral Postgres.
```

- [ ] **Step 3: Commit + push.**

```bash
git add README.md docs/
git commit -m "docs: README layout for sub-project C; implementation plan"
git push 2>&1 | tail -1
```

---

## Self-Review

**1. Spec coverage:** §2 `LlmRunner` live+scripted → Tasks 1 & 3; §3 assembly (string / messages / error) → Task 1; §4 executor (load → assemble → call → write → status, bounded-async via QSem, per-example failure, resume, run-level failed) → Tasks 1–2; §5 CLI (migrate / run, env config) → Task 4; §6 gating dependency → already proven by the rehome (crucible @ 0cb8c17 in the lock); §7's five test scenarios → Task 2's four specs (the system-prompt-first assertion lives inside `recordingSpec`) + Task 1's pure assembly spec. Out-of-scope items (scoring, streaming, raw response capture, claim-locking) are not implemented anywhere.

**2. Placeholder scan:** all steps carry complete code/commands; no TBDs. The one judgment call is documented inline: assembly failures get `latencyMs = Just ms` (the spec times the whole per-example action; ms≈0 for assembly failures).

**3. Type consistency:** `LlmRunner = TargetVersion -> [Message] -> IO (Either ExecError (Text, Usage))` is used identically in Tasks 1, 2, 3; `scriptedRunner :: [Text] -> IO LlmRunner` (IORef cursor — deliberate deviation from the spec sketch, which would replay only the first reply; noted in the haddock); `RunOutcome {total, succeeded, errored, skipped}` (record-dot style, not the spec's `roTotal` prefixes — matches the post-DevEx codebase convention) is constructed in Task 1 and asserted in Task 2 and printed field-by-field in Task 4; `cfgFrom :: Text -> TargetVersion -> AnthropicConfig` matches its test and `liveAnthropicRunner` use. `usageJson` keys (`input_tokens`/`output_tokens`) match the Anthropic wire names crucible parses.
