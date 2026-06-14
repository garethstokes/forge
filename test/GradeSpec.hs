{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module GradeSpec (main) where

import Control.Monad (unless)
import Data.Aeson (Value (..), decode, object, toJSON, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as AT
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort, sortOn)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)

import qualified Crucible.Eval as Eval
import Manifest
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)

import Crucible.LLM.Anthropic (AnthropicConfig (..), defaultAnthropicConfig)
import Crucible.LLM.OpenAI (OpenAIConfig (..))
import Evals.Execute (ExecError (..))
import Evals.Execute.OpenAI (openaiCfgFromParams)
import Evals.Grade
import Evals.Grade.Live (gradeCfg)
import Evals.Ids
import Evals.Migrate (migrateAll)
import Evals.Schema

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

errContains :: Text -> Score -> Bool
errContains needle s = maybe False (needle `T.isInfixOf`) s.error

near :: Double -> Double -> Bool
near a b = abs (a - b) < 1e-9

main :: IO ()
main = do
  configSpec
  gradeCfgSpec
  exactSpec
  pointedPureSpec
  dimSpec
  withEphemeralDb $ \pool -> do
    _ <- withSession pool migrateAll
    now <- getCurrentTime
    engineSpec pool now
    errorRowSpec pool now
    checklistSpec pool now
    resumeSpec pool now
    metricSpec pool now
    unknownKindSpec pool now
    missingRunSpec pool now
    dedupeSpec pool now
    pointedSpec pool now
    dimEngineSpec pool now
  putStrLn "manifest-evals GradeSpec: config + exact + pointed + engine + checklist + resume + metrics + edge-cases OK"

configSpec :: IO ()
configSpec = do
  expect "votes default 1" (votesFrom (object []) == 1)
  expect "votes read" (votesFrom (object ["votes" .= (3 :: Int)]) == 3)
  expect "rubric read"
    (fmap (const ()) (rubricFrom (object ["rubric" .= ("be kind" :: Text)])) == Right ())
  expect "rubric missing is an error" (isLeft (rubricFrom (object [])))
  let cs = criteriaFrom (object ["criteria" .=
            [ object ["label" .= ("cites a URL" :: Text)]
            , object ["label" .= ("polite" :: Text), "weight" .= (2.5 :: Double)] ]])
  expect "criteria labels+weights (weight defaults 1)"
    (fmap (map (\c -> (c.label, c.weight))) cs
       == Right [("cites a URL", 1), ("polite", 2.5)])
  expect "criteria missing is an error" (isLeft (criteriaFrom (object [])))
  expect "criteria empty is an error" (isLeft (criteriaFrom (object ["criteria" .= ([] :: [Value])])))
  expect "provider default anthropic" (providerFrom (object []) == "anthropic")
  expect "provider reads openai" (providerFrom (object ["provider" .= ("openai" :: Text)]) == "openai")
  expect "provider non-object -> anthropic" (providerFrom (String "x") == "anthropic")
  let oc = openaiCfgFromParams "k" (Just "gpt-4.1")
            (object ["max_tokens" .= (50 :: Int), "timeout" .= (7 :: Int), "retries" .= (2 :: Int)])
  expect "openaiCfg model override" (oc.model == "gpt-4.1")
  expect "openaiCfg knobs" (oc.maxTokens == 50 && oc.timeoutSecs == 7 && oc.maxRetries == 2)
  expect "openaiCfg key" (oc.apiKey == "k")
  let od = openaiCfgFromParams "k" Nothing (object [])
  expect "openaiCfg default model" (od.model == "gpt-4o-mini")

gradeCfgSpec :: IO ()
gradeCfgSpec = do
  let dflt = defaultAnthropicConfig "k"
      full = gradeCfg "k" (object ["model" .= ("claude-j" :: Text), "max_tokens" .= (7 :: Int)])
      none = gradeCfg "k" (object [])
  expect "gradeCfg: model from config" (full.model == "claude-j" && full.maxTokens == 7)
  expect "gradeCfg: defaults without config keys"
    (none.model == dflt.model && none.maxTokens == dflt.maxTokens)

exactSpec :: IO ()
exactSpec = do
  let val = fmap (.value)
  expect "exact string pass"
    (val (gradeExact (Just (Aeson (toJSON ("4" :: Text)))) (Just " 4\n")) == Right 1.0)
  expect "exact string fail"
    (val (gradeExact (Just (Aeson (toJSON ("4" :: Text)))) (Just "5")) == Right 0.0)
  expect "exact structural pass"
    (val (gradeExact (Just (Aeson (object ["a" .= (1 :: Int)]))) (Just "{\"a\": 1}")) == Right 1.0)
  expect "exact unparseable output is a FAIL, not an error"
    (val (gradeExact (Just (Aeson (object []))) (Just "not json")) == Right 0.0)
  expect "missing expected is an error" (isLeft (gradeExact Nothing (Just "x")))
  expect "missing output text is an error" (isLeft (gradeExact (Just (Aeson (toJSON ("x" :: Text)))) Nothing))
  expect "judge-error score detected"
    (isJudgeError (Eval.score 0.0 "judge error: all samples failed"))
  expect "ordinary zero score is not a judge error"
    (isJudgeError (Eval.score 0.0 "mismatch") == False)

-- Pointed pure specs -------------------------------------------------------

pointedPureSpec :: IO ()
pointedPureSpec = do
  -- criteria parsing
  let twoItems = toJSON
        [ object ["criterion" .= ("c1" :: Text), "points" .= (7 :: Double)]
        , object ["criterion" .= ("c2" :: Text), "points" .= ((-6) :: Double), "tags" .= (["axis:accuracy"] :: [Text])]
        ]
  case criteriaFromExpected (Just (Aeson twoItems)) of
    Left e  -> ioError (userError ("criteria parsing failed: " <> show e))
    Right cs -> do
      expect "criteria: two items" (length cs == 2)
      expect "criteria: first has no tags"  (cs !! 0 == Criterion' { criterion = "c1", points = 7.0, tags = [] })
      expect "criteria: second has tags"    (cs !! 1 == Criterion' { criterion = "c2", points = -6.0, tags = ["axis:accuracy"] })
  expect "criteria: Nothing expected → Left"
    (isLeft (criteriaFromExpected Nothing))
  expect "criteria: non-array → Left"
    (isLeft (criteriaFromExpected (Just (Aeson (object ["criterion" .= ("x" :: Text), "points" .= (1 :: Double)])))))
  expect "criteria: empty array → Left"
    (isLeft (criteriaFromExpected (Just (Aeson (toJSON ([] :: [Value]))))))
  let allNeg = toJSON [object ["criterion" .= ("bad" :: Text), "points" .= ((-3) :: Double)]]
  expect "criteria: all-negative → Left"
    (isLeft (criteriaFromExpected (Just (Aeson allNeg))))

  -- renderCriterion
  let negCrit = Criterion' { criterion = "says something wrong", points = -6.0, tags = ["axis:accuracy"] }
      rendered = renderCriterion negCrit
  expect "renderCriterion: contains signed points [-6.0]" ("-6.0" `T.isInfixOf` rendered)
  expect "renderCriterion: contains 'whether the criterion is MET'"
    ("whether the criterion is MET" `T.isInfixOf` rendered)
  expect "renderCriterion: contains 'such as'"
    ("such as" `T.isInfixOf` rendered)

  -- transcript
  let sysPrompt = "SYS"
      inputMsgs = object ["messages" .= [object ["role" .= ("user" :: Text), "content" .= ("q1" :: Text)],
                                          object ["role" .= ("assistant" :: Text), "content" .= ("a1" :: Text)]]]
      finalAnswer = "final answer"
  case transcript sysPrompt inputMsgs finalAnswer of
    Left e  -> ioError (userError ("transcript failed: " <> show e))
    Right t ->
      expect "transcript: full conversation with system + messages + completion"
        (t == "system: SYS\n\nuser: q1\n\nassistant: a1\n\nassistant: final answer")
  case transcript sysPrompt (toJSON ("string input" :: Text)) "completion" of
    Left e  -> ioError (userError ("transcript string input failed: " <> show e))
    Right t -> expect "transcript: string input treated as user message"
      ("user: string input" `T.isInfixOf` t)
  expect "transcript: numeric input → Left"
    (isLeft (transcript sysPrompt (toJSON (42 :: Int)) "completion"))
  -- system-turn in input messages: the prepended "system: SYS" line comes
  -- first, then the conversation including any system turn from the input —
  -- pinning the current behaviour so we see exactly what the graded model saw.
  let sysInInput = object ["messages" .=
        [ object ["role" .= ("system" :: Text), "content" .= ("inner sys" :: Text)]
        , object ["role" .= ("user"   :: Text), "content" .= ("q"         :: Text)]
        ]]
  case transcript "SYS" sysInInput "ans" of
    Left e  -> ioError (userError ("transcript system-turn failed: " <> show e))
    Right t -> do
      expect "transcript: system-turn input renders as second system: block"
        (t == "system: SYS\n\nsystem: inner sys\n\nuser: q\n\nassistant: ans")

  -- renderCriterion: pinning the "final assistant message" framing sentence
  expect "renderCriterion: contains 'final assistant message'"
    ("final assistant message" `T.isInfixOf` renderCriterion negCrit)

  -- HealthBench vector: 7/5/10/-6 with verdicts T/F/T/T → 11/22
  let hbCriteria =
        [ (Criterion' "c1" 7.0  [], CriterionVerdict True  "e1")
        , (Criterion' "c2" 5.0  [], CriterionVerdict False "e2")
        , (Criterion' "c3" 10.0 [], CriterionVerdict True  "e3")
        , (Criterion' "c4" (-6.0) [], CriterionVerdict True  "e4")
        ]
      hbGraded = pointedGraded hbCriteria
  expect "pointedGraded: value == 11/22"
    (near hbGraded.value (11.0 / 22.0))
  expect "pointedGraded: passed == Nothing"
    (isNothing hbGraded.passed)

  -- Unmet-negative vector: 7/5/10/-6 with verdicts T/F/T/F → 17/22
  -- (the -6 criterion is unmet so it must NOT be subtracted — only met items
  -- contribute to achieved; achieved = 7+10 = 17, possible = 7+5+10 = 22)
  let unmetNegCriteria =
        [ (Criterion' "cites"    7.0  [], CriterionVerdict True  "e1")
        , (Criterion' "complete" 5.0  [], CriterionVerdict False "e2")
        , (Criterion' "thorough" 10.0 [], CriterionVerdict True  "e3")
        , (Criterion' "harmful"  (-6.0) [], CriterionVerdict False "e4")
        ]
      unmetNegGraded = pointedGraded unmetNegCriteria
  expect "pointedGraded: unmet-negative vector value == 17/22"
    (near unmetNegGraded.value (17.0 / 22.0))

  -- negative score possible
  let negPairs =
        [ (Criterion' "pos" 5.0   [], CriterionVerdict False "e1")
        , (Criterion' "neg" (-6.0) [], CriterionVerdict True  "e2")
        ]
  expect "pointedGraded: negative score possible"
    ((pointedGraded negPairs).value < 0)

  -- detail golden
  let singlePair = [(Criterion' "c" 7.0 [], CriterionVerdict True "e")]
      g = pointedGraded singlePair
      decoded = decode (Aeson.encode g.detail) :: Maybe Value
  case decoded of
    Nothing -> ioError (userError "detail round-trip failed to decode")
    Just v ->
      expect "pointedGraded: detail golden shape"
        (v == object
          [ "achieved" .= (7.0 :: Double)
          , "possible" .= (7.0 :: Double)
          , "criteria" .= [object
              [ "criterion"   .= ("c" :: Text)
              , "points"      .= (7.0 :: Double)
              , "tags"        .= ([] :: [Text])
              , "met"         .= True
              , "explanation" .= ("e" :: Text)
              ]]
          ])

-- Seeding -----------------------------------------------------------------

data SeededG = SeededG
  { runId :: RunId, gvId :: GraderVersionId }

-- One run with three GOOD outputs ("out-a" with expected "out-a", "out-b"
-- with expected "nope", "out-d" with NO expected value) + one ERRORED
-- output (no text), and one grader of the given kind. Per (output x grader)
-- pair that gives, for exact graders: pass, fail, missing-expected error,
-- output-error skip — and for LLM graders: three gradeable texts + one skip.
seedScoring :: Pool -> UTCTime -> Text -> Value -> IO SeededG
seedScoring pool now kind config = withSession pool $ do
  d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "g", slug = "g", createdAt = now } :: Dataset)
  v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  e1 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e1"
                     , input = Aeson (toJSON ("q1" :: Text)), expected = Just (Aeson (toJSON ("out-a" :: Text))), meta = Nothing } :: Example)
  e2 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e2"
                     , input = Aeson (toJSON ("q2" :: Text)), expected = Just (Aeson (toJSON ("nope" :: Text))), meta = Nothing } :: Example)
  e3 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e3"
                     , input = Aeson (toJSON ("q3" :: Text)), expected = Nothing, meta = Nothing } :: Example)
  e4 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e4"
                     , input = Aeson (toJSON ("q4" :: Text)), expected = Nothing, meta = Nothing } :: Example)
  t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
  tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "SYS"
                           , params = Aeson (object []), createdAt = now } :: TargetVersion)
  r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "succeeded"
                 , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
  _o1 <- add (Output { id = OutputId 0, run = r.id, example = e1.id, response = Nothing, text = Just "out-a"
                     , error = Nothing, latencyMs = Just 1, tokens = Nothing } :: Output)
  _o2 <- add (Output { id = OutputId 0, run = r.id, example = e2.id, response = Nothing, text = Just "out-b"
                     , error = Nothing, latencyMs = Just 1, tokens = Nothing } :: Output)
  _o3 <- add (Output { id = OutputId 0, run = r.id, example = e3.id, response = Nothing, text = Nothing
                     , error = Just "llm: boom", latencyMs = Just 1, tokens = Nothing } :: Output)
  _o4 <- add (Output { id = OutputId 0, run = r.id, example = e4.id, response = Nothing, text = Just "out-d"
                     , error = Nothing, latencyMs = Just 1, tokens = Nothing } :: Output)
  g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "g", kind = kind, createdAt = now } :: Grader)
  gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson config, createdAt = now } :: GraderVersion)
  pure SeededG { runId = r.id, gvId = gv.id }

scoresFor :: Pool -> GraderVersionId -> IO [Score]
scoresFor pool gv = withSession pool (selectWhere [ #graderVersion ==. gv ])

noRunner :: GradeRunner
noRunner _ _ _ = ioError (userError "runner must not be called")

noCriterionJudge :: CriterionJudge
noCriterionJudge _ _ _ = ioError (userError "criterion judge must not be called")

-- Scenarios ----------------------------------------------------------------

-- exact end-to-end: no runner call; pass + fail rows; errored output
-- skipped; missing-expected pair becomes an engine-level error row;
-- Run.status untouched.
engineSpec :: Pool -> UTCTime -> IO ()
engineSpec pool now = do
  sd <- seedScoring pool now "exact" (object [])
  outcome <- scoreRun pool 2 noRunner noCriterionJudge sd.runId [sd.gvId]
  expect "exact: outcome" (outcome == ScoreOutcome { total = 4, scored = 2, errored = 1, skipped = 1 })
  ss <- scoresFor pool sd.gvId
  expect "exact: one pass one fail (value paired with passed)"
    (sort [ (s.value, s.passed) | s <- ss, isNothing s.error ]
       == [(Just 0.0, Just False), (Just 1.0, Just True)])
  expect "exact: details carry rationales" (all (isJust . (.detail)) [ s | s <- ss, isNothing s.error ])
  expect "exact: missing expected became an error row"
    ([ () | s <- ss, errContains "no expected value" s, isNothing s.value, isNothing s.passed ] == [()])
  mr <- withSession pool (get @Run (Key sd.runId))
  expect "exact: Run.status untouched" (fmap (.status) mr == Just "succeeded")

-- rubric: recording runner sees the expectation+text; canned scores persist
-- with votes in detail; a runner EXCEPTION is captured as a per-pair error
-- row (try/SomeException -> LlmError -> renderExecError), not a batch kill.
errorRowSpec :: Pool -> UTCTime -> IO ()
errorRowSpec pool now = do
  sd <- seedScoring pool now "rubric" (object ["rubric" .= ("be right" :: Text), "votes" .= (3 :: Int)])
  ref <- newIORef ([] :: [Text])
  let runner _gv expn t = do
        case expn of
          Eval.Rubric r -> atomicModifyIORef' ref (\acc -> (acc ++ [r <> "|" <> t], ()))
          _ -> ioError (userError "expected a Rubric expectation")
        case t of
          "out-a" -> pure (Right (Eval.Score { value = 1.0, rationale = "good", votes = Just (2, 1), dissent = Nothing }))
          "out-b" -> ioError (userError "kaboom")
          _       -> pure (Right (Eval.score 1.0 "fine"))
  outcome <- scoreRun pool 1 runner noCriterionJudge sd.runId [sd.gvId]
  expect "rubric: outcome" (outcome == ScoreOutcome { total = 4, scored = 2, errored = 1, skipped = 1 })
  calls <- readIORef ref
  expect "rubric: runner saw config rubric + text for every gradeable output"
    (sort calls == ["be right|out-a", "be right|out-b", "be right|out-d"])
  ss <- scoresFor pool sd.gvId
  let good = [ s | s <- ss, isNothing s.error ]
      bad  = [ s | s <- ss, isJust s.error ]
  expect "rubric: two graded rows, votes preserved in detail"
    (sort [ (s.value, s.passed) | s <- good ] == [(Just 1.0, Just True), (Just 1.0, Just True)]
       && Just (Aeson (object ["rationale" .= ("good" :: Text), "votes" .= [2 :: Int, 1]]))
            `elem` map (.detail) good)
  expect "rubric: thrown exception became an error row carrying the message"
    (map (.value) bad == [Nothing] && all (isNothing . (.passed)) bad
       && all (errContains "kaboom") bad)

-- checklist: criteria (with default weight) threaded to the runner; a
-- non-voted score pins the votes-free detail json; a judge-error canned
-- score becomes an error row.
checklistSpec :: Pool -> UTCTime -> IO ()
checklistSpec pool now = do
  sd <- seedScoring pool now "checklist"
          (object ["criteria" .= [ object ["label" .= ("cites" :: Text), "weight" .= (2.0 :: Double)]
                                 , object ["label" .= ("polite" :: Text)] ]])
  ref <- newIORef ([] :: [[(Text, Double)]])
  let runner _gv expn t = do
        case expn of
          Eval.Checklist cs ->
            atomicModifyIORef' ref (\acc -> (acc ++ [map (\c -> (c.label, c.weight)) cs], ()))
          _ -> ioError (userError "expected a Checklist expectation")
        pure $ case t of
          "out-a" -> Right (Eval.score 0.5 "partial")
          "out-b" -> Right (Eval.score 0.0 "judge error: all samples failed")
          _       -> Right (Eval.score 1.0 "ok")
  outcome <- scoreRun pool 1 runner noCriterionJudge sd.runId [sd.gvId]
  expect "checklist: outcome" (outcome == ScoreOutcome { total = 4, scored = 2, errored = 1, skipped = 1 })
  calls <- readIORef ref
  expect "checklist: criteria threaded on every call (weight defaults 1)"
    (length calls == 3 && all (== [("cites", 2.0), ("polite", 1.0)]) calls)
  ss <- scoresFor pool sd.gvId
  let partial = [ s | s <- ss, s.value == Just 0.5 ]
      bad     = [ s | s <- ss, isJust s.error ]
  expect "checklist: partial score row (passed False, votes-free detail)"
    (map (.passed) partial == [Just False]
       && map (.detail) partial == [Just (Aeson (object ["rationale" .= ("partial" :: Text)]))])
  expect "checklist: judge-error score became an error row"
    (length bad == 1 && all (isNothing . (.value)) bad && all (errContains "judge error") bad)

-- resume: good rows skipped; errored rows deleted + re-graded each run
-- (still-failing pairs error again); hand-errored good rows re-grade clean.
resumeSpec :: Pool -> UTCTime -> IO ()
resumeSpec pool now = do
  sd <- seedScoring pool now "exact" (object [])
  outcome1 <- scoreRun pool 1 noRunner noCriterionJudge sd.runId [sd.gvId]
  expect "resume: first run grades 2, errors 1 (no expected), skips 1"
    (outcome1 == ScoreOutcome { total = 4, scored = 2, errored = 1, skipped = 1 })
  outcome2 <- scoreRun pool 1 noRunner noCriterionJudge sd.runId [sd.gvId]
  expect "resume: re-run skips good pairs, re-grades the still-failing pair"
    (outcome2 == ScoreOutcome { total = 4, scored = 0, errored = 1, skipped = 3 })
  ss <- scoresFor pool sd.gvId
  expect "resume: no duplicate rows" (length ss == 3)
  withSession pool $ update @Score (Key (head [ s.id | s <- ss, isNothing s.error ]))
    [ #value =. (Nothing :: Maybe Double), #passed =. (Nothing :: Maybe Bool)
    , #detail =. (Nothing :: Maybe (Aeson Value)), #error =. Just "llm: transient" ]
  outcome3 <- scoreRun pool 1 noRunner noCriterionJudge sd.runId [sd.gvId]
  expect "resume: hand-errored pair re-graded; still-failing pair errors again"
    (outcome3 == ScoreOutcome { total = 4, scored = 1, errored = 1, skipped = 2 })
  ss2 <- scoresFor pool sd.gvId
  expect "resume: still three rows, exactly the missing-expected one errored"
    (length ss2 == 3 && [ () | s <- ss2, errContains "no expected value" s ] == [()]
       && length [ s | s <- ss2, isJust s.error ] == 1)

-- metrics: AVG ignores error rows (a runner Left counts as errored in the
-- outcome); recompute replaces and folds re-graded pairs in.
metricSpec :: Pool -> UTCTime -> IO ()
metricSpec pool now = do
  sd <- seedScoring pool now "rubric" (object ["rubric" .= ("r" :: Text)])
  let runner _ _ t = pure $ case t of
        "out-a" -> Right (Eval.score 1.0 "good")
        "out-b" -> Left (LlmError "transient")
        _       -> Right (Eval.score 0.0 "bad")
  outcome1 <- scoreRun pool 1 runner noCriterionJudge sd.runId [sd.gvId]
  expect "metric: runner Left counts as errored in the outcome"
    (outcome1 == ScoreOutcome { total = 4, scored = 2, errored = 1, skipped = 1 })
  ms <- withSession pool (selectWhere [ #graderVersion ==. sd.gvId ]) :: IO [RunMetric]
  expect "metric: one row, mean over graded only, count 2"
    (map (\m -> (m.mean, m.passRate, m.count)) ms == [(0.5, Just 0.5, 2)])
  let runner2 _ _ _ = pure (Right (Eval.score 1.0 "good now"))
  _ <- scoreRun pool 1 runner2 noCriterionJudge sd.runId [sd.gvId]
  ms2 <- withSession pool (selectWhere [ #graderVersion ==. sd.gvId ]) :: IO [RunMetric]
  expect "metric: replaced, errored pair re-graded into the aggregate"
    (case ms2 of
       [m] -> m.count == 3 && near m.mean (2 / 3) && maybe False (\p -> near p (2 / 3)) m.passRate
       _   -> False)

-- unknown grader kind: every gradeable pair errors with a decode error; the
-- output-error skip still applies; the runner is never called.
unknownKindSpec :: Pool -> UTCTime -> IO ()
unknownKindSpec pool now = do
  sd <- seedScoring pool now "alien" (object [])
  outcome <- scoreRun pool 1 noRunner noCriterionJudge sd.runId [sd.gvId]
  expect "unknown kind: outcome" (outcome == ScoreOutcome { total = 4, scored = 0, errored = 3, skipped = 1 })
  ss <- scoresFor pool sd.gvId
  expect "unknown kind: every error row names the kind"
    (length ss == 3 && all (errContains "unknown grader kind") ss)

-- missing run: all-zero outcome, nothing written.
missingRunSpec :: Pool -> UTCTime -> IO ()
missingRunSpec pool now = do
  sd <- seedScoring pool now "exact" (object [])
  outcome <- scoreRun pool 1 noRunner noCriterionJudge (RunId 999999) [sd.gvId]
  expect "missing run: all-zero outcome"
    (outcome == ScoreOutcome { total = 0, scored = 0, errored = 0, skipped = 0 })
  ss <- scoresFor pool sd.gvId
  expect "missing run: no Score rows written" (null ss)
  ms <- withSession pool (selectWhere [ #graderVersion ==. sd.gvId ]) :: IO [RunMetric]
  expect "missing run: no RunMetric rows written" (null ms)

-- duplicate grader version ids are nubbed: same outcome and rows as one.
dedupeSpec :: Pool -> UTCTime -> IO ()
dedupeSpec pool now = do
  sd <- seedScoring pool now "exact" (object [])
  outcome <- scoreRun pool 1 noRunner noCriterionJudge sd.runId [sd.gvId, sd.gvId]
  expect "dedupe: duplicate gv ids grade once"
    (outcome == ScoreOutcome { total = 4, scored = 2, errored = 1, skipped = 1 })
  ss <- scoresFor pool sd.gvId
  expect "dedupe: no duplicate rows" (length ss == 3)

-- Pointed engine scenarios -------------------------------------------------

data SeededP = SeededP
  { runId :: RunId, gvId :: GraderVersionId }

-- Seed a "pointed" run: e1 carries 4 criteria in expected (cites/complete/
-- thorough/harmful), e2 has no expected; one output per example; the grader
-- version config is empty (the pointed kind reads criteria from the example,
-- not from the config).
seedPointed :: Pool -> UTCTime -> IO SeededP
seedPointed pool now = withSession pool $ do
  let crit c p ts = object (["criterion" .= (c :: Text), "points" .= (p :: Double)]
                              ++ if null ts then [] else ["tags" .= (ts :: [Text])])
  d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "p", slug = "p", createdAt = now } :: Dataset)
  v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  e1 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "pe1"
                     , input = Aeson (object ["messages" .= [object ["role" .= ("user" :: Text), "content" .= ("Q" :: Text)]]])
                     , expected = Just (Aeson (toJSON
                         [ crit "cites"    7.0  ([] :: [Text])
                         , crit "complete" 5.0  ([] :: [Text])
                         , crit "thorough" 10.0 ([] :: [Text])
                         , crit "harmful"  (-6.0) ["axis:accuracy"]
                         ]))
                     , meta = Nothing } :: Example)
  e2 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "pe2"
                     , input = Aeson (object ["messages" .= [object ["role" .= ("user" :: Text), "content" .= ("Q2" :: Text)]]])
                     , expected = Nothing, meta = Nothing } :: Example)
  t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "pt", createdAt = now } :: Target)
  tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "SYS"
                           , params = Aeson (object []), createdAt = now } :: TargetVersion)
  r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "succeeded"
                 , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
  _o1 <- add (Output { id = OutputId 0, run = r.id, example = e1.id, response = Nothing, text = Just "the answer"
                     , error = Nothing, latencyMs = Just 1, tokens = Nothing } :: Output)
  _o2 <- add (Output { id = OutputId 0, run = r.id, example = e2.id, response = Nothing, text = Just "x"
                     , error = Nothing, latencyMs = Just 1, tokens = Nothing } :: Output)
  g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "pg", kind = "pointed", createdAt = now } :: Grader)
  gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
  pure SeededP { runId = r.id, gvId = gv.id }

-- Four scenarios for the pointed engine: happy path, stop-at-first-error,
-- resume re-grades, and passRate == Nothing for pointed rows.
pointedSpec :: Pool -> UTCTime -> IO ()
pointedSpec pool now = do

  -- Scenario 1: happy path ---------------------------------------------------
  -- Judge: met=True except when "complete" is in the criterion text.
  -- Criteria: cites(7,T) + complete(5,F) + thorough(10,T) + harmful(-6,T)
  --   achieved = 7 + 10 + (-6) = 11, possible = 7+5+10 = 22 → 11/22
  sd1 <- seedPointed pool now
  callsRef1 <- newIORef ([] :: [(Text, Text)])  -- (transcript, criterionText) pairs
  let judge1 _gv tr c = do
        atomicModifyIORef' callsRef1 (\acc -> (acc ++ [(tr, renderCriterion c)], ()))
        let isComplete = "complete" `T.isInfixOf` c.criterion
        pure (Right (CriterionVerdict { met = not isComplete, explanation = "ok" }))
  outcome1 <- scoreRun pool 1 noRunner judge1 sd1.runId [sd1.gvId]
  expect "pointed/1: outcome {2,1,1,0}"
    (outcome1 == ScoreOutcome { total = 2, scored = 1, errored = 1, skipped = 0 })
  calls1 <- readIORef callsRef1
  expect "pointed/1: exactly 4 judge calls (all for o1)" (length calls1 == 4)
  expect "pointed/1: every transcript contains ordered system+user+assistant block"
    (all (("system: SYS\n\nuser: Q\n\nassistant: the answer" `T.isInfixOf`) . fst) calls1)
  expect "pointed/1: harmful criterion text contains '-6'"
    (any (("-6" `T.isInfixOf`) . snd) calls1)
  ss1 <- scoresFor pool sd1.gvId
  let scored1 = [ s | s <- ss1, isJust s.value ]
      errored1 = [ s | s <- ss1, isJust s.error ]
  expect "pointed/1: one scored row, value ≈ 11/22"
    (case scored1 of
       [s] -> maybe False (\v -> near v (11.0 / 22.0)) s.value
       _   -> False)
  expect "pointed/1: scored row passed == Nothing" (all (isNothing . (.passed)) scored1)
  -- detail must decode and contain 4 criteria entries; check via AT.parseMaybe
  expect "pointed/1: detail has 4 criteria, complete has met=False"
    (case scored1 of
       [s] -> case s.detail of
         Just (Aeson dv) ->
           -- parse the criteria array out of the detail object
           let parseCriteria = AT.withObject "detail" $ \o -> do
                 arr <- o AT..: "criteria"
                 mapM (AT.withObject "crit" $ \c ->
                         (,) <$> c AT..: "criterion" <*> c AT..: "met") arr
               mKvs = AT.parseMaybe parseCriteria dv :: Maybe [(Text, Bool)]
           in case mKvs of
                Just kvs -> length kvs == 4 && lookup "complete" kvs == Just False
                Nothing  -> False
         _ -> False
       _ -> False)
  expect "pointed/1: e2 error row mentions 'criteria'"
    (case errored1 of
       [s] -> errContains "criteria" s
       _   -> False)

  -- Scenario 2: stop at first error ------------------------------------------
  -- Judge errors on the 2nd call; counting via IORef.
  -- o1 has 4 criteria so judge: call1 ok, call2 → Left → sequentialJudge stops.
  -- Expected: o1 → error (judge down); o2 → error (no criteria).
  -- Outcome: {total=2, scored=0, errored=2, skipped=0}
  sd2 <- seedPointed pool now
  callCount2 <- newIORef (0 :: Int)
  let judge2 _gv _tr _c = do
        n <- atomicModifyIORef' callCount2 (\x -> (x + 1, x + 1))
        if n == 2
          then pure (Left (LlmError "judge down"))
          else pure (Right (CriterionVerdict { met = True, explanation = "ok" }))
  outcome2 <- scoreRun pool 1 noRunner judge2 sd2.runId [sd2.gvId]
  expect "pointed/2: outcome {2,0,2,0}"
    (outcome2 == ScoreOutcome { total = 2, scored = 0, errored = 2, skipped = 0 })
  n2 <- readIORef callCount2
  expect "pointed/2: exactly 2 judge calls (sequential stop)" (n2 == 2)
  ss2 <- scoresFor pool sd2.gvId
  let o1Err2 = [ s | s <- ss2, errContains "judge down" s ]
  expect "pointed/2: error row with 'judge down'" (length o1Err2 == 1)
  expect "pointed/2: judge-down row has value=Nothing"
    (all (isNothing . (.value)) o1Err2)
  expect "pointed/2: two rows" (length ss2 == 2)
  let o2Err2 = [ s | s <- ss2, errContains "criteria" s ]
  expect "pointed/2: other error row mentions 'criteria' (o2 parse error)"
    (length o2Err2 == 1)

  -- Scenario 3: resume re-grades ---------------------------------------------
  -- After scenario 2: o1 has error("judge down"), o2 has error("no criteria").
  -- Both are error rows → both re-grade.
  -- o1: re-grades with all-True judge → scores (achieved=7+5+10+(-6)=16, possible=22)
  -- o2: re-grades but criteriaFromExpected Nothing → errors again.
  -- Outcome: {total=2, scored=1, errored=1, skipped=0}
  -- (no rows skip because both prior rows were errors)
  let judge3 _gv _tr _c = pure (Right (CriterionVerdict { met = True, explanation = "ok" }))
  outcome3 <- scoreRun pool 1 noRunner judge3 sd2.runId [sd2.gvId]
  expect "pointed/3: outcome {2,1,1,0} — both error rows re-grade; o2 errors again"
    (outcome3 == ScoreOutcome { total = 2, scored = 1, errored = 1, skipped = 0 })
  ss3 <- scoresFor pool sd2.gvId
  expect "pointed/3: two rows total (old errors replaced)" (length ss3 == 2)
  let scored3 = [ s | s <- ss3, isJust s.value ]
  -- all-True: achieved = 7+5+10+(-6) = 16, possible = 22 → 16/22
  expect "pointed/3: re-graded o1 value ≈ 16/22"
    (case scored3 of
       [s] -> maybe False (\v -> near v (16.0 / 22.0)) s.value
       _   -> False)

  -- Scenario 4: passRate == Nothing for pointed rows -------------------------
  -- After scenario 1: the scored row has passed=Nothing.
  -- recompute should see no judged rows → passRate=Nothing (not Just 0).
  ms4 <- withSession pool (selectWhere [ #graderVersion ==. sd1.gvId ]) :: IO [RunMetric]
  expect "pointed/4: RunMetric count=1"
    (case ms4 of [m] -> m.count == 1; _ -> False)
  expect "pointed/4: mean ≈ 11/22"
    (case ms4 of [m] -> near m.mean (11.0 / 22.0); _ -> False)
  expect "pointed/4: passRate == Nothing (no verdict-bearing rows)"
    (case ms4 of [m] -> isNothing m.passRate; _ -> False)

dimSpec :: IO ()
dimSpec = do
  expect "clip01 below" (clip01 (-0.5) == 0)
  expect "clip01 above" (clip01 1.5 == 1)
  expect "clip01 in-range" (clip01 0.4 == 0.4)
  let detail = object
        [ "achieved" .= (4 :: Double), "possible" .= (10 :: Double)
        , "criteria" .=
          [ object ["criterion" .= ("A"::Text), "points" .= (4::Double)
                   , "tags" .= (["axis:accuracy"]::[Text]), "met" .= True, "explanation" .= (""::Text)]
          , object ["criterion" .= ("B"::Text), "points" .= (6::Double)
                   , "tags" .= (["axis:completeness"]::[Text]), "met" .= False, "explanation" .= (""::Text)]
          ] ]
  expect "axisScores per-tag"
    (sortOn fst (axisScoresFromDetail detail) == [("axis:accuracy", 1.0), ("axis:completeness", 0.0)])
  let negOnly = object ["criteria" .=
        [ object ["criterion" .= ("X"::Text), "points" .= ((-3)::Double)
                 , "tags" .= (["axis:safety"]::[Text]), "met" .= True, "explanation" .= (""::Text)] ]]
  expect "axisScores skips no-positive tag" (axisScoresFromDetail negOnly == [])
  let multi = object ["criteria" .=
        [ object ["criterion" .= ("M"::Text), "points" .= (5::Double)
                 , "tags" .= (["axis:accuracy","cluster:c1"]::[Text]), "met" .= True, "explanation" .= (""::Text)] ]]
  expect "axisScores multi-tag"
    (sortOn fst (axisScoresFromDetail multi) == [("axis:accuracy", 1.0), ("cluster:c1", 1.0)])
  expect "axisScores malformed -> []" (axisScoresFromDetail (object ["rationale" .= ("x"::Text)]) == [])
  expect "exampleThemes present"
    (exampleThemes (object ["example_tags" .= (["theme:x","theme:y"]::[Text])]) == ["theme:x","theme:y"])
  expect "exampleThemes absent -> []" (exampleThemes (object ["other" .= (1::Int)]) == [])
  let row1 = (Just 0.4, Nothing, Just detail, Just (object ["example_tags" .= (["theme:x"]::[Text])]))
      row2 = (Just 0.8, Nothing, Just multi,  Just (object ["example_tags" .= (["theme:x"]::[Text])]))
      ms = dimensionalMetrics 0 [row1, row2]
  expect "dim overall mean = clip01 avg(0.4,0.8) = 0.6"
    (case [ m | m <- ms, m.tag == Nothing ] of [m] -> abs (m.mean - 0.6) < 1e-9 && m.count == 2 && m.passRate == Nothing; _ -> False)
  expect "dim theme:x mean = 0.6, count 2"
    (case [ m | m <- ms, m.tag == Just "theme:x" ] of [m] -> abs (m.mean - 0.6) < 1e-9 && m.count == 2; _ -> False)
  expect "dim axis:accuracy mean = 1.0, count 2"
    (case [ m | m <- ms, m.tag == Just "axis:accuracy" ] of [m] -> abs (m.mean - 1.0) < 1e-9 && m.count == 2; _ -> False)
  expect "dim axis:completeness only row1, count 1, mean 0.0"
    (case [ m | m <- ms, m.tag == Just "axis:completeness" ] of [m] -> m.mean == 0.0 && m.count == 1; _ -> False)
  let neg = (Just (-0.5), Nothing, Nothing, Nothing)
  expect "dim overall clips negative to 0"
    (case [ m | m <- dimensionalMetrics 0 [neg], m.tag == Nothing ] of [m] -> m.mean == 0 && m.count == 1; _ -> False)
  let same = [ (Just 0.5, Nothing, Nothing, Nothing), (Just 0.5, Nothing, Nothing, Nothing) ]
  expect "dim overall stderr 0 on identical values"
    (case [ m | m <- dimensionalMetrics 0 same, m.tag == Nothing ] of [m] -> m.stderr == 0; _ -> False)
  let spread = [ (Just 0.0, Nothing, Nothing, Nothing), (Just 1.0, Nothing, Nothing, Nothing), (Just 0.5, Nothing, Nothing, Nothing) ]
  expect "dim overall stderr > 0 on spread"
    (case [ m | m <- dimensionalMetrics 0 spread, m.tag == Nothing ] of [m] -> m.stderr > 0; _ -> False)

-- Dimensional engine: one tagged example with two axes + one theme drives
-- recompute to emit overall + per-axis + per-theme RunMetric rows.
dimEngineSpec :: Pool -> UTCTime -> IO ()
dimEngineSpec pool now = do
  sd <- withSession pool $ do
    d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "dim", slug = "dim", createdAt = now } :: Dataset)
    v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    e1 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "e1"
                       , input = Aeson (toJSON ("q" :: Text))
                       , expected = Just (Aeson (toJSON
                           [ object ["criterion" .= ("A"::Text), "points" .= (4::Double), "tags" .= (["axis:accuracy"]::[Text])]
                           , object ["criterion" .= ("B"::Text), "points" .= (6::Double), "tags" .= (["axis:completeness"]::[Text])] ]))
                       , meta = Just (Aeson (object ["example_tags" .= (["theme:x"]::[Text])])) } :: Example)
    t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
    tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "SYS"
                             , params = Aeson (object []), createdAt = now } :: TargetVersion)
    r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "succeeded"
                   , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
    _  <- add (Output { id = OutputId 0, run = r.id, example = e1.id, response = Nothing, text = Just "ans"
                      , error = Nothing, latencyMs = Just 1, tokens = Nothing } :: Output)
    g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "pg", kind = "pointed", createdAt = now } :: Grader)
    gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
    pure (r.id, gv.id)
  let (rid, gvid) = sd
      judge _ _ c = pure (Right (CriterionVerdict { met = c.criterion == "A", explanation = "" }))
  _ <- scoreRun pool 1 noRunner judge rid [gvid]
  ms <- withSession pool (selectWhere [ #run ==. rid, #graderVersion ==. gvid ]) :: IO [RunMetric]
  let row t = [ (m.mean, m.count) | m <- ms, m.tag == t ]
  expect "dim engine: overall 0.4 count 1"
    (case row Nothing of [(mn, c)] -> near mn 0.4 && c == 1; _ -> False)
  expect "dim engine: axis:accuracy 1.0 count 1"
    (case row (Just "axis:accuracy") of [(mn, c)] -> near mn 1.0 && c == 1; _ -> False)
  expect "dim engine: axis:completeness 0.0 count 1"
    (case row (Just "axis:completeness") of [(mn, c)] -> near mn 0.0 && c == 1; _ -> False)
  expect "dim engine: theme:x 0.4 count 1"
    (case row (Just "theme:x") of [(mn, c)] -> near mn 0.4 && c == 1; _ -> False)
  expect "dim engine: exactly 4 metric rows" (length ms == 4)
  expect "dim engine: overall stderr persisted (single output -> 0)"
    (case [ m.stderr | m <- ms, m.tag == Nothing ] of [s] -> s == Just 0.0; _ -> False)
