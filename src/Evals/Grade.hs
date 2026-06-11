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
-- grading is pure and local; the LLM-judge mechanics are crucible's. Failure
-- is per-pair: any grading error becomes a 'Score' row with @error@ set and
-- @value = NULL@ (excluded from aggregates, re-graded on the next
-- invocation).
module Evals.Grade
  ( GradeRunner
  , votesFrom
  , rubricFrom
  , criteriaFrom
  , gradeExact
  , isJudgeError
  , ScoreOutcome (..)
  , scoreRun
  ) where

import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (SomeException, bracket_, try)
import Control.Monad (when)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import qualified Data.Aeson.Types as AT
import Data.Either (partitionEithers)
import Data.List (find, nub)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (getCurrentTime)

import qualified Crucible.Eval as Eval
import Manifest
import Manifest.Postgres (Pool)

import Evals.Execute (ExecError (..), renderExecError)
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
scoreRun :: Pool -> Int -> GradeRunner -> RunId -> [GraderVersionId] -> IO ScoreOutcome
scoreRun pool concurrency runner runId gvIds = do
  setup <- withSession pool $
    get @Run (Key runId) >>= \case
      Nothing -> pure Nothing
      Just _run -> do
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
                pure (Just (zip gs gvs, outputs :: [Output], existing))
  case setup of
    Nothing -> pure ScoreOutcome { total = 0, scored = 0, errored = 0, skipped = 0 }
    Just (graders, outputs, existing) -> do
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
        bracket_ (waitQSem sem) (signalQSem sem) (gradeOne g gv out regrade)
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
    gradeOne :: Grader -> GraderVersion -> Output -> Bool -> IO Bool
    gradeOne g gv out regrade = do
      result <- gradePair g gv out
      now <- getCurrentTime
      withSession pool $ do
        when regrade $
          deleteWhere ([ #output ==. out.id, #graderVersion ==. gv.id ] :: [Cond Score])
        case result of
          Right s -> do
            _ <- add (Score
              { id = ScoreId 0, output = out.id, graderVersion = gv.id
              , value = Just s.value, passed = Just (s.value >= 1.0)
              , detail = Just (Aeson (detailJson s)), error = Nothing
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
    -- the injected runner. An exception from the runner is captured as an
    -- LlmError rather than killing the batch; a judge-error score is folded
    -- into the error path.
    gradePair :: Grader -> GraderVersion -> Output -> IO (Either ExecError Eval.Score)
    gradePair g gv out = case g.kind of
        "exact" -> do
          ex <- withSession pool (get @Example (Key out.example))
          pure (gradeExact (ex >>= (.expected)) out.text)
        "rubric"    -> llmKind (Eval.Rubric <$> rubricFrom cfgV)
        "checklist" -> llmKind (Eval.Checklist <$> criteriaFrom cfgV)
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
                | otherwise      -> pure (Right s)

    -- One grader version's RunMetric over this run, from scratch: errored
    -- rows (value NULL) are excluded; no graded rows means mean 0 and no
    -- pass rate.
    recompute :: GraderVersion -> IO ()
    recompute gv = do
      now <- getCurrentTime
      withSession pool $ do
        rows <- runQuery $ do
          s <- from @Score
          o <- innerJoin @Output (\o -> o ?. #id .== s ?. #output)
          where_ (o ?. #run .== val runId .&& s ?. #graderVersion .== val gv.id)
          pure (s ?. #value, s ?. #passed)
        let rows' = rows :: [(Maybe Double, Maybe Bool)]
            graded = [ (v, p) | (Just v, p) <- rows' ]
            n = length graded
            mean = if n == 0 then 0 else sum (map fst graded) / fromIntegral n
            pr = if n == 0
                   then Nothing
                   else Just (fromIntegral (length [ () | (_, Just True) <- graded ]) / fromIntegral n)
        deleteWhere ([ #run ==. runId, #graderVersion ==. gv.id ] :: [Cond RunMetric])
        _ <- add (RunMetric
          { id = RunMetricId 0, run = runId, graderVersion = gv.id
          , mean = mean, passRate = pr, count = n, computedAt = now } :: RunMetric)
        pure ()

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
