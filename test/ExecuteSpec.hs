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
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)

import Crucible.LLM (Message (..), Role (..))
import Crucible.LLM.Anthropic (AnthropicConfig (..), defaultAnthropicConfig)
import Crucible.Usage (Usage (..))
import Manifest hiding (Target)
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)

import Evals.Execute
import Evals.Execute.Anthropic (cfgFrom)
import Evals.Ids
import Evals.Migrate (migrateAll)
import Evals.Schema

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = do
  assemblySpec
  cfgFromSpec
  withEphemeralDb $ \pool -> do
    _ <- withSession pool migrateAll
    now <- getCurrentTime
    happyPathSpec pool now
    perExampleErrorSpec pool now
    resumeSpec pool now
    recordingSpec pool now
  putStrLn "manifest-evals ExecuteSpec: assembly + execute + resume + recording OK"

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

-- Seeding -----------------------------------------------------------------

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

outputsFor :: Pool -> RunId -> IO [Output]
outputsFor pool rid = withSession pool (selectWhere [ #run ==. rid ])

runStatus :: Pool -> RunId -> IO (Maybe Text)
runStatus pool rid = withSession pool (fmap (fmap (.status)) (get @Run (Key rid)))

-- Scenarios ----------------------------------------------------------------

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
  _ <- withSession pool $ add (Output
    { id = OutputId 0, run = sd.runId, example = preDone, response = Nothing
    , text = Just "already", error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
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
