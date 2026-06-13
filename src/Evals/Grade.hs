{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Scoring (the grading bridge): grade a run's Outputs with named grader
-- versions through crucible's eval machinery, one 'Score' row per
-- (output x grader version), then recompute per-grader 'RunMetric's. exact
-- grading is pure and local; the LLM-judge mechanics are crucible's; pointed
-- judges per-example signed criteria with conversation context. Failure
-- is per-pair: any grading error becomes a 'Score' row with @error@ set and
-- @value = NULL@ (excluded from aggregates, re-graded on the next
-- invocation).
module Evals.Grade
  ( GradeRunner
  , CriterionJudge
  , Criterion' (..)
  , CriterionVerdict (..)
  , Graded (..)
  , votesFrom
  , rubricFrom
  , criteriaFrom
  , gradeExact
  , isJudgeError
  , criteriaFromExpected
  , renderCriterion
  , transcript
  , pointedGraded
  , ScoreOutcome (..)
  , scoreRun
  , DimMetric (..)
  , clip01
  , axisScoresFromDetail
  , exampleThemes
  , dimensionalMetrics
  ) where

import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (SomeException, bracket_, try)
import Control.Monad (when)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import qualified Data.Aeson.Types as AT
import Data.Either (partitionEithers)
import Data.List (find, nub)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (getCurrentTime)

import qualified Crucible.Eval as Eval
import qualified Crucible.Eval.Calibrate as Cal
import Crucible.LLM (Message (..), Role (..))
import Manifest
import Manifest.Postgres (Pool)

import Evals.Execute (ExecError (..), decodeInput, renderExecError)
import Evals.Ids
import Evals.Schema

-- | The injected judge backend: a grader version + expectation + output text
-- in, a crucible score or an error out. Live = crucible's LLM judge; tests
-- inject their own.
type GradeRunner = GraderVersion -> Eval.Expectation Text -> Text -> IO (Either ExecError Eval.Score)

-- | The @votes@ key of a grader config object, defaulting to 1 (a non-object
-- config also yields 1).
votesFrom :: Value -> Int
votesFrom v = maybe 1 id (AT.parseMaybe parser v)
  where parser = AT.withObject "config" (\o -> o AT..:? "votes" AT..!= 1)

-- | The @rubric@ key of a grader config object.
rubricFrom :: Value -> Either ExecError Text
rubricFrom (Object o) = case AT.parseMaybe (AT..: "rubric") o of
  Just r  -> Right r
  Nothing -> Left (InputDecodeError "grader config has no \"rubric\"")
rubricFrom _ = Left (InputDecodeError "grader config is not an object")

-- | The @criteria@ key of a grader config object: an array of
-- @{label, weight?}@ objects (weight defaults to 1). An empty array is an
-- error — a checklist needs at least one criterion.
criteriaFrom :: Value -> Either ExecError [Eval.Criterion]
criteriaFrom (Object o) = case AT.parseMaybe parser o of
  Nothing -> Left (InputDecodeError "grader config has no \"criteria\"")
  Just [] -> Left (InputDecodeError "grader config \"criteria\" is empty")
  Just cs -> Right cs
  where
    parser obj = obj AT..: "criteria" >>= mapM one
    one = AT.withObject "criterion" $ \c ->
      Eval.Criterion <$> c AT..: "label" <*> (maybe 1 id <$> c AT..:? "weight")
criteriaFrom _ = Left (InputDecodeError "grader config is not an object")

-- | Pure exact grading: an expected JSON string is compared
-- whitespace-stripped against the output text; any other expected JSON value
-- is compared structurally against the output text parsed as JSON
-- (unparseable output is a fail, not an error). A missing expected value or
-- missing output text is an error.
gradeExact :: Maybe (Aeson Value) -> Maybe Text -> Either ExecError Eval.Score
gradeExact Nothing _ = Left (InputDecodeError "no expected value")
gradeExact _ Nothing = Left (InputDecodeError "output has no text")
gradeExact (Just (Aeson expected)) (Just txt) = Right $ case expected of
  String e
    | T.strip e == T.strip txt -> Eval.score 1.0 "exact match"
    | otherwise                -> Eval.score 0.0 "mismatch"
  otherJson -> case eitherDecodeStrict (TE.encodeUtf8 txt) of
    Left _ -> Eval.score 0.0 "output is not valid JSON"
    Right (v :: Value)
      | v == otherJson -> Eval.score 1.0 "exact match"
      | otherwise      -> Eval.score 0.0 "mismatch"

-- | Crucible folds all-samples-errored judging into a tagged zero score; we
-- persist those as error rows. The tag is produced only by the error path.
-- A checklist where every criterion's judge errored is NOT detected — crucible
-- folds per-criterion errors into criterion fails, so it persists as a
-- legitimate low score.
isJudgeError :: Eval.Score -> Bool
isJudgeError s = s.value == 0 && "judge error: " `T.isPrefixOf` s.rationale

-- ---------------------------------------------------------------------------
-- Pointed grader kind
-- ---------------------------------------------------------------------------

-- | One criterion in a pointed rubric: a natural-language statement, a
-- signed point value (negative = penalty), and optional classification tags.
data Criterion' = Criterion'
  { criterion :: Text, points :: Double, tags :: [Text] } deriving (Eq, Show)

-- | The per-criterion verdict from the injected judge.
data CriterionVerdict = CriterionVerdict
  { met :: Bool, explanation :: Text } deriving (Eq, Show)

-- | The injected per-criterion judge for the pointed kind. Live:
-- "Evals.Grade.Anthropic". NOTE the fidelity caveat: the live judge uses
-- crucible's hardened prompt + a Claude model, not HealthBench's published
-- GPT-4.1 grader — scores are directionally comparable, not benchmark-comparable.
type CriterionJudge =
  GraderVersion -> Text -> Criterion' -> IO (Either ExecError CriterionVerdict)

-- | A grading result that unifies the old Eval.Score path and the new
-- pointed path.
data Graded = Graded
  { value  :: Double
  , passed :: Maybe Bool
  , detail :: Value
  }

-- | Parse the pointed rubric criteria from an example's expected field.
-- Nothing → error; non-array → error; empty → error; no positive points → error.
criteriaFromExpected :: Maybe (Aeson Value) -> Either ExecError [Criterion']
criteriaFromExpected Nothing = Left (InputDecodeError "no expected criteria")
criteriaFromExpected (Just (Aeson v)) =
  case AT.parseEither parseArr v of
    Left msg -> Left (InputDecodeError (T.pack msg))
    Right [] -> Left (InputDecodeError "criteria are empty")
    Right cs
      | sum [p | Criterion' _ p _ <- cs, p > 0] <= 0
          -> Left (InputDecodeError "no positive points")
      | otherwise -> Right cs
  where
    parseArr = AT.withArray "criteria" $ \arr ->
      mapM parseCriterion (foldr (:) [] arr)
    parseCriterion = AT.withObject "criterion" $ \o -> do
      c <- o AT..: "criterion"
      p <- o AT..: "points"
      t <- maybe [] id <$> o AT..:? "tags"
      pure Criterion' { criterion = c, points = p, tags = t }

-- | Render a criterion as the rubric line shown to the judge.
renderCriterion :: Criterion' -> Text
renderCriterion c =
  "[" <> T.pack (show (c.points)) <> "] " <> c.criterion
  <> "\n\nNotes: a criterion that says \"such as\", \"for example\", or \"including\" does not require the response to include all of the examples. For a criterion with negative points, report whether the criterion is MET — not whether meeting it is good. Judge only the final assistant message; earlier turns are context."

-- | Build a transcript from a system prompt, a structured input value, and
-- the final assistant completion.
transcript :: Text -> Value -> Text -> Either ExecError Text
transcript sys inputVal completion = do
  msgs <- decodeInput inputVal
  let renderRole System    = "system"
      renderRole User      = "user"
      renderRole Assistant = "assistant"
      renderRole Tool      = "tool"
      renderMsg (Message r c) = renderRole r <> ": " <> c
      sysLine = "system: " <> sys
      convLines = map renderMsg msgs
      finalLine = "assistant: " <> completion
      allLines = sysLine : convLines ++ [finalLine]
  pure (T.intercalate "\n\n" allLines)

-- | Compute the pointed grading result from verdict pairs.
-- Precondition: @possible > 0@ is the caller's obligation (guaranteed via
-- 'criteriaFromExpected'; an all-negative list yields NaN). A second call
-- site (future tag-metrics slice) must also satisfy this invariant.
pointedGraded :: [(Criterion', CriterionVerdict)] -> Graded
pointedGraded pairs =
  Graded { value = achieved / possible, passed = Nothing, detail = detailVal }
  where
    achieved = sum [c.points | (c, v) <- pairs, v.met]
    possible = sum [c.points | (c, _) <- pairs, c.points > 0]
    detailVal = object
      [ "achieved" .= achieved
      , "possible" .= possible
      , "criteria"  .= map criterionDetail pairs
      ]
    criterionDetail (c, v) = object
      [ "criterion"   .= c.criterion
      , "points"      .= c.points
      , "tags"        .= c.tags
      , "met"         .= v.met
      , "explanation" .= v.explanation
      ]

-- | Wrap an old-style 'Eval.Score' as a 'Graded'.
fromEvalScore :: Eval.Score -> Graded
fromEvalScore s = Graded
  { value  = s.value
  , passed = Just (s.value >= 1.0)
  , detail = detailJson s
  }

-- ---------------------------------------------------------------------------

-- | What 'scoreRun' did: (output x grader version) pair counts by fate.
data ScoreOutcome = ScoreOutcome
  { total   :: Int
  , scored  :: Int
  , errored :: Int
  , skipped :: Int
  }
  deriving (Eq, Show)

-- | Grade a run's outputs with the named grader versions. A pair is skipped
-- when the output errored in execution or a non-errored 'Score' already
-- exists (resume); an errored 'Score' is deleted and re-graded. Afterwards
-- each grader version's 'RunMetric' is recomputed (delete+insert).
-- @Run.status@ is never touched. A missing run or grader version returns an
-- all-zero outcome with nothing written.
scoreRun :: Pool -> Int -> GradeRunner -> CriterionJudge -> RunId -> [GraderVersionId] -> IO ScoreOutcome
scoreRun pool concurrency runner criterionJudge runId gvIds = do
  setup <- withSession pool $
    get @Run (Key runId) >>= \case
      Nothing -> pure Nothing
      Just run -> do
        mtv <- get @TargetVersion (Key run.targetVersion)
        -- nub before the gets: duplicates would double-grade every pair
        mgvs <- mapM (\i -> get @GraderVersion (Key i)) (nub gvIds)
        case sequence mgvs of
          Nothing  -> pure Nothing
          Just gvs -> do
            mgs <- mapM (get @Grader . Key . (.grader)) gvs
            case sequence mgs of
              Nothing -> pure Nothing
              Just gs -> do
                outputs  <- selectWhere [ #run ==. runId ]
                existing <- concat <$> mapM (\gv -> existingFor gv.id) gvs
                pure (Just (mtv, zip gs gvs, outputs :: [Output], existing))
  case setup of
    Nothing -> pure ScoreOutcome { total = 0, scored = 0, errored = 0, skipped = 0 }
    Just (mtv, graders, outputs, existing) -> do
      let pairs = [ (g, gv, out) | (g, gv) <- graders, out <- outputs ]
          -- existing :: [(OutputId, (GraderVersionId, Maybe Text))]
          prior gv out = find (\(oid, (gvid, _)) -> oid == out.id && gvid == gv.id) existing
          classify (g, gv, out)
            | isJust out.error = Left ()
            | Just (_, (_, Nothing)) <- prior gv out = Left ()
            | otherwise = Right (g, gv, out, isJust (prior gv out))
          (skips, work) = partitionEithers (map classify pairs)
      sem <- newQSem (max 1 concurrency)
      oks <- forConcurrently work $ \(g, gv, out, regrade) ->
        bracket_ (waitQSem sem) (signalQSem sem) (gradeOne mtv g gv out regrade)
      mapM_ (recompute . snd) graders
      pure ScoreOutcome
        { total   = length pairs
        , scored  = length (filter id oks)
        , errored = length (filter not oks)
        , skipped = length skips
        }
  where
    -- One pair: grade, then write exactly one Score row — value + detail on
    -- success, error text (value NULL) on failure. A regrade first deletes
    -- the prior errored row.
    gradeOne :: Maybe TargetVersion -> Grader -> GraderVersion -> Output -> Bool -> IO Bool
    gradeOne mtv g gv out regrade = do
      -- The try covers gradePair WHOLE (including the exact kind's Example
      -- fetch), so even a transient DB error becomes this pair's error row
      -- rather than cancelling the concurrent batch.
      result <- try (gradePair mtv g gv out) >>= \case
        Left (e :: SomeException) -> pure (Left (LlmError (T.pack (show e))))
        Right r                   -> pure r
      now <- getCurrentTime
      withSession pool $ do
        when regrade $
          deleteWhere ([ #output ==. out.id, #graderVersion ==. gv.id ] :: [Cond Score])
        case result of
          Right graded -> do
            _ <- add (Score
              { id = ScoreId 0, output = out.id, graderVersion = gv.id
              , value = Just graded.value, passed = graded.passed
              , detail = Just (Aeson graded.detail), error = Nothing
              , createdAt = now } :: Score)
            pure True
          Left err -> do
            _ <- add (Score
              { id = ScoreId 0, output = out.id, graderVersion = gv.id
              , value = Nothing, passed = Nothing
              , detail = Nothing, error = Just (renderExecError err)
              , createdAt = now } :: Score)
            pure False

    -- Dispatch on the grader kind: exact is pure and local; rubric and
    -- checklist build a crucible expectation from the config and go through
    -- the injected runner; pointed judges the example's own criteria one by
    -- one through the injected CriterionJudge with the full transcript.
    -- An exception from the runner is captured as an
    -- LlmError rather than killing the batch; a judge-error score is folded
    -- into the error path.
    gradePair :: Maybe TargetVersion -> Grader -> GraderVersion -> Output -> IO (Either ExecError Graded)
    gradePair mtv g gv out = case g.kind of
        "exact" -> do
          ex <- withSession pool (get @Example (Key out.example))
          pure (fmap fromEvalScore (gradeExact (ex >>= (.expected)) out.text))
        "rubric"    -> llmKind (Eval.Rubric <$> rubricFrom cfgV)
        "checklist" -> llmKind (Eval.Checklist <$> criteriaFrom cfgV)
        "pointed" -> do
          mex <- withSession pool (get @Example (Key out.example))
          case mex of
            Nothing -> pure (Left (InputDecodeError "example missing"))
            Just ex ->
              case criteriaFromExpected ex.expected of
                Left e -> pure (Left e)
                Right cs ->
                  case mtv of
                    Nothing -> pure (Left (InputDecodeError "target version missing"))
                    Just tv ->
                      case out.text of
                        Nothing -> pure (Left (InputDecodeError "output has no text"))
                        Just txt ->
                          let Aeson inputVal = ex.input
                          in case transcript tv.prompt inputVal txt of
                            Left e -> pure (Left e)
                            Right transcriptTxt -> do
                              verdicts <- sequentialJudge gv transcriptTxt cs
                              case verdicts of
                                Left e  -> pure (Left e)
                                Right vs -> pure (Right (pointedGraded vs))
        k -> pure (Left (InputDecodeError ("unknown grader kind: " <> k)))
      where
        Aeson cfgV = gv.config
        llmKind builtExp = case (builtExp, out.text) of
          (Left e, _)  -> pure (Left e)
          (_, Nothing) -> pure (Left (InputDecodeError "output has no text"))
          (Right expn, Just t) ->
            try (runner gv expn t) >>= \case
              Left (e :: SomeException) -> pure (Left (LlmError (T.pack (show e))))
              Right (Left e)            -> pure (Left e)
              Right (Right s)
                | isJudgeError s -> pure (Left (LlmError s.rationale))
                | otherwise      -> pure (Right (fromEvalScore s))

    -- Judge criteria sequentially, stopping at the first error.
    sequentialJudge :: GraderVersion -> Text -> [Criterion'] -> IO (Either ExecError [(Criterion', CriterionVerdict)])
    sequentialJudge _  _            []     = pure (Right [])
    sequentialJudge gv transcriptTxt (c:cs) = do
      r <- try (criterionJudge gv transcriptTxt c) >>= \case
        Left (e :: SomeException) -> pure (Left (LlmError (T.pack (show e))))
        Right x                   -> pure x
      case r of
        Left e -> pure (Left e)
        Right v -> do
          rest <- sequentialJudge gv transcriptTxt cs
          case rest of
            Left e   -> pure (Left e)
            Right vs -> pure (Right ((c, v) : vs))

    -- One grader version's RunMetric over this run, from scratch: errored
    -- rows (value NULL) are excluded; no graded rows means mean 0 and no
    -- pass rate.
    recompute :: GraderVersion -> IO ()
    recompute gv = do
      now <- getCurrentTime
      withSession pool $ do
        rows <- runQuery $ do
          s <- from @Score
          o <- innerJoin @Output  (\o -> o ?. #id .== s ?. #output)
          e <- innerJoin @Example (\e -> e ?. #id .== o ?. #example)
          where_ (o ?. #run .== val runId .&& s ?. #graderVersion .== val gv.id)
          pure (s ?. #value, (s ?. #passed, (s ?. #detail, e ?. #meta)))
        -- runQuery encodes the projection as right-nested pairs; flatten to the aggregator's 4-tuple.
        let unwrap (mv, (mp, (md, mm))) =
              (mv, mp, fmap (\(Aeson x) -> x) md, fmap (\(Aeson x) -> x) mm)
            dms = dimensionalMetrics 0
              (map unwrap (rows :: [(Maybe Double, (Maybe Bool, (Maybe (Aeson Value), Maybe (Aeson Value))))]))
        deleteWhere ([ #run ==. runId, #graderVersion ==. gv.id ] :: [Cond RunMetric])
        mapM_ (\dm -> add (RunMetric
          { id = RunMetricId 0, run = runId, graderVersion = gv.id
          , mean = dm.mean, passRate = dm.passRate, count = dm.count
          , tag = dm.tag, stderr = Just dm.stderr, computedAt = now } :: RunMetric)) dms

    -- Scores for one grader version scoped to this run: join through Output
    -- so we only fetch rows belonging to this run, not all runs. Returns
    -- (output id, (grader version id, error)) — nested pair because
    -- runQuery's Selectable instances handle 3-tuples as (a, (b, c)).
    existingFor :: GraderVersionId -> Db [(OutputId, (GraderVersionId, Maybe Text))]
    existingFor gvId = runQuery $ do
      s <- from @Score
      o <- innerJoin @Output (\o -> o ?. #id .== s ?. #output)
      where_ (o ?. #run .== val runId .&& s ?. #graderVersion .== val gvId)
      pure (s ?. #output, (s ?. #graderVersion, s ?. #error))

-- | A crucible score as the @Score.detail@ jsonb.
detailJson :: Eval.Score -> Value
detailJson s = object (["rationale" .= s.rationale] ++ maybe [] (\(y, n) -> ["votes" .= [y, n]]) s.votes)

-- ---------------------------------------------------------------------------
-- Dimensional metrics (pure aggregator)
-- ---------------------------------------------------------------------------

-- | One emitted metric row: the overall (tag Nothing) or a per-tag breakdown.
data DimMetric = DimMetric
  { tag      :: Maybe Text
  , mean     :: Double
  , passRate :: Maybe Double
  , count    :: Int
  , stderr   :: Double
  } deriving (Eq, Show)

-- | Clip a mean to [0,1] (HealthBench's aggregate clip).
clip01 :: Double -> Double
clip01 = max 0 . min 1

-- | Per-tag @achieved / possible@ over one example's pointed 'Score.detail'.
-- A criterion with multiple tags contributes to each; a tag whose criteria
-- have no positive points is skipped (HealthBench's @None@). A non-pointed or
-- malformed detail yields @[]@.
axisScoresFromDetail :: Value -> [(Text, Double)]
axisScoresFromDetail v = case AT.parseMaybe parseCriteria v of
  Nothing  -> []
  Just its ->
    [ (t, achieved / possible)
    | t <- nub (concatMap (\(tags, _, _) -> tags) its)
    , let tagged   = [ (pts, m) | (tags, pts, m) <- its, t `elem` tags ]
          possible = sum [ pts | (pts, _) <- tagged, pts > 0 ]
          achieved = sum [ pts | (pts, m) <- tagged, m ]
    , possible > 0 ]
  where
    parseCriteria = AT.withObject "detail" $ \o -> do
      arr <- o AT..: "criteria"
      mapM (AT.withObject "criterion" $ \c ->
              (,,) <$> c AT..: "tags" <*> c AT..: "points" <*> c AT..: "met")
           (arr :: [Value])

-- | The @example_tags@ themes from an example's meta. Absent/malformed -> [].
exampleThemes :: Value -> [Text]
exampleThemes v = maybe [] id (AT.parseMaybe (AT.withObject "meta" (AT..: "example_tags")) v)

-- | All 'RunMetric' rows for one grader version's scored rows: the overall, a
-- per-theme breakdown (the example's value bucketed by @example_tags@), and a
-- per-axis breakdown (the pointed detail re-scored per criterion tag). Every
-- mean is clipped to [0,1]; tag-row passRate is Nothing (score-derived).
dimensionalMetrics :: Int -> [(Maybe Double, Maybe Bool, Maybe Value, Maybe Value)] -> [DimMetric]
dimensionalMetrics seed rows = overall : themeMetrics ++ axisMetrics
  where
    graded = [ (v, p, d, m) | (Just v, p, d, m) <- rows ]
    vals   = [ v | (v, _, _, _) <- graded ]
    judged = [ b | (_, Just b, _, _) <- graded ]
    stderrOf = Cal.bootstrapStdErr seed 1000
    overall = DimMetric
      { tag = Nothing
      , mean = clip01 (if null vals then 0 else avg vals)
      , passRate = if null judged then Nothing
                   else Just (fromIntegral (length (filter id judged)) / fromIntegral (length judged))
      , count = length graded
      , stderr = stderrOf vals }
    themePairs = [ (t, v)  | (v, _, _, Just m) <- graded, t <- exampleThemes m ]
    axisPairs  = [ (t, sc) | (_, _, Just d, _) <- graded, (t, sc) <- axisScoresFromDetail d ]
    themeMetrics = [ DimMetric (Just t) (clip01 (avg ss)) Nothing (length ss) (stderrOf ss) | (t, ss) <- grouped themePairs ]
    axisMetrics  = [ DimMetric (Just t) (clip01 (avg ss)) Nothing (length ss) (stderrOf ss) | (t, ss) <- grouped axisPairs ]
    avg xs = sum xs / fromIntegral (length xs)
    grouped = Map.toList . Map.fromListWith (++) . map (\(k, x) -> (k, [x]))
