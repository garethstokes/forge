{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module SchemaSpec (main) where

import Control.Exception (SomeException, try)
import Control.Monad (join, unless)
import Data.Aeson (Value, object, (.=))
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Manifest
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)
import Evals.Schema
import Evals.Ids
import Evals.Migrate (migrateAll)

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = withEphemeralDb $ \pool -> do
  -- migrate twice; the second run is a no-op (empty additive plan)
  _  <- withSession pool migrateAll
  p2 <- withSession pool migrateAll
  expect "second migrate is a no-op (empty additive plan)" (null (planAdditive p2))
  now <- getCurrentTime

  -- Org round-trip
  orgResult <- withSession pool $ do
    o  <- add (Org { id = OrgId 0, slug = "acme", name = "Acme Corp", createdAt = now } :: Org)
    got <- get @Org (Key o.id)
    pure (fmap (.slug) got, fmap (.name) got)
  expect "org round-trips: slug" (fst orgResult == Just "acme")
  expect "org round-trips: name" (snd orgResult == Just "Acme Corp")

  result <- withSession pool $ do
    d <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "demo", slug = "demo", createdAt = now } :: Dataset)
    v <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    _ <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c1"
                      , input = Aeson (object ["q" .= ("2+2" :: Text)])
                      , expected = Just (Aeson (object ["a" .= (4 :: Int)])), meta = Nothing } :: Example)
    got <- get @Dataset (Key d.id)
    pure (fmap (.name) got, v.version)
  expect "dataset round-trips by typed Key" (fst result == Just "demo")
  expect "dataset version is 1" (snd result == 1)

  -- Scenario A: cascade deletes. Manifest cascades walk the whole rule tree
  -- (since manifest-va2), so ONE Run delete removes its Outputs (Run->Output
  -- Cascade) AND, transitively, the Scores under them (Output->Score Cascade).
  -- Rows not owned by the deleted Run (Example, DatasetVersion) survive.
  cascade' <- expectCascade pool now
  expect "cascade: run's outputs are gone"                 (cOutputsGone cascade')
  expect "cascade: scores are gone transitively"           (cScoresGone cascade')
  expect "cascade: example survives the run delete"  (cExampleKept cascade')
  expect "cascade: dataset version survives"         (cVersionKept cascade')

  -- Scenario B: deleting a DatasetVersion that a Run references is Restricted.
  restrict' <- expectRestrict pool now
  expect "restrict: delete of referenced version was rejected" (rRejected restrict')
  expect "restrict: referenced dataset version still exists"   (rVersionKept restrict')

  -- Scenario C: aggregate (mean + count of scores per grader version, for a run).
  agg <- expectAggregate pool now
  expect "aggregate: exactly one grader-version group" (aGroups agg == 1)
  expect "aggregate: count of scores in the group is 2" (aCount agg == 2)
  expect "aggregate: mean of {0.0, 1.0} is 0.5"
    (maybe False (\m -> abs (m - 0.5) < 1e-9) (aMean agg))
  expect "aggregate: grouped grader version matches the seeded one"
    (aGroupGv agg == Just (aSeededGv agg))

  -- Scenario D: compare two runs over the same dataset version, by example key.
  cmp <- expectCompareRuns pool now
  expect "compare: run A scored c1=1.0, c2=0.0" (cRunA cmp == [("c1", Just 1.0), ("c2", Just 0.0)])
  expect "compare: run B scored c1=0.0, c2=1.0" (cRunB cmp == [("c1", Just 0.0), ("c2", Just 1.0)])

  -- Scenario E: a human gold verdict (CriterionLabel) round-trips against an Output.
  lab <- expectCriterionLabel pool now
  expect "label: exactly one row for the output" (lRows lab == 1)
  expect "label: human verdict is True"          (lHuman lab == Just True)
  expect "label: criterion is \"is accurate\""    (lCriterion lab == Just "is accurate")
  expect "label: source is Just \"physician\""    (lSource lab == Just (Just "physician"))

  putStrLn "manifest-evals SchemaSpec: migrate + org + round-trip + cascade + restrict + aggregate + compare-runs + criterion-label OK"

-- Scenario A ------------------------------------------------------------------

data CascadeResult = CascadeResult
  { cOutputsGone :: Bool
  , cScoresGone  :: Bool
  , cExampleKept :: Bool
  , cVersionKept :: Bool
  }

expectCascade :: Pool -> UTCTime -> IO CascadeResult
expectCascade pool now = withSession pool $ do
  d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "casc", slug = "casc", createdAt = now } :: Dataset)
  v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  ex <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "k1"
                     , input = Aeson (object ["q" .= ("hi" :: Text)]), expected = Nothing, meta = Nothing } :: Example)
  t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
  tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "p"
                           , params = Aeson (object []), createdAt = now } :: TargetVersion)
  g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "g", kind = "exact", createdAt = now } :: Grader)
  gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
  r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "done"
                 , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
  -- Output o1 carries a Score; o2 doesn't. ONE Run delete must remove both
  -- outputs (Run->Output Cascade) and o1's score transitively (Output->Score).
  o1 <- add (Output { id = OutputId 0, run = r.id, example = ex.id, response = Nothing, text = Just "scored"
                    , error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
  _  <- add (Score { id = ScoreId 0, output = o1.id, graderVersion = gv.id, value = Just 1.0, passed = Just True
                   , detail = Nothing, error = Nothing, createdAt = now } :: Score)
  _  <- add (Output { id = OutputId 0, run = r.id, example = ex.id, response = Nothing, text = Just "byrun"
                    , error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
  withTransaction $ delete r
  scores <- selectWhere [ #output ==. o1.id ]
  outs   <- selectWhere [ #run ==. r.id ]
  exs    <- selectWhere [ #datasetVersion ==. v.id ]
  vers   <- get @DatasetVersion (Key v.id)
  pure CascadeResult
    { cOutputsGone = null (outs :: [Output])
    , cScoresGone  = null (scores :: [Score])
    , cExampleKept = length (exs :: [Example]) == 1
    , cVersionKept = maybe False (const True) vers
    }

-- Scenario B ------------------------------------------------------------------

data RestrictResult = RestrictResult
  { rRejected    :: Bool
  , rVersionKept :: Bool
  }

expectRestrict :: Pool -> UTCTime -> IO RestrictResult
expectRestrict pool now = do
  -- Create the dataset version and a Run referencing it.
  vid <- withSession pool $ do
    d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "restr", slug = "restr", createdAt = now } :: Dataset)
    v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t2", createdAt = now } :: Target)
    tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "p"
                             , params = Aeson (object []), createdAt = now } :: TargetVersion)
    _  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "done"
                   , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
    pure v.id
  -- Attempt to delete the referenced version; Restrict must reject it.
  res <- (try :: IO a -> IO (Either SomeException a)) $ withSession pool $ do
    v <- get @DatasetVersion (Key vid)
    maybe (pure ()) (withTransaction . delete) v
  -- The version row must survive.
  kept <- withSession pool $ get @DatasetVersion (Key vid)
  pure RestrictResult
    { rRejected    = either (const True) (const False) res
    , rVersionKept = maybe False (const True) kept
    }

-- Scenario C ------------------------------------------------------------------

data AggregateResult = AggregateResult
  { aGroups   :: Int                  -- number of grouped rows
  , aCount    :: Int                  -- COUNT(*) within the (single) group
  , aMean     :: Maybe Double         -- AVG(value) within the group
  , aGroupGv  :: Maybe GraderVersionId-- grader version key of the group
  , aSeededGv :: GraderVersionId      -- the grader version we seeded scores from
  }

-- Seed a run with two scored outputs (values 0.0 and 1.0) from one grader
-- version, then aggregate mean+count per grader version for that run. The
-- typed projection '(?.)' recovers each column's Haskell type, so the join,
-- filter, and grouped tuple need no annotations. Tuple selections are pairs, so
-- the (gv, mean, count) triple is left-nested as (gv, (mean, count)).
expectAggregate :: Pool -> UTCTime -> IO AggregateResult
expectAggregate pool now = withSession pool $ do
  d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "agg", slug = "agg", createdAt = now } :: Dataset)
  v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  e1 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c1"
                     , input = Aeson (object []), expected = Nothing, meta = Nothing } :: Example)
  e2 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c2"
                     , input = Aeson (object []), expected = Nothing, meta = Nothing } :: Example)
  t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
  tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "p"
                           , params = Aeson (object []), createdAt = now } :: TargetVersion)
  g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "g", kind = "exact", createdAt = now } :: Grader)
  gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
  r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "done"
                 , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
  o1 <- add (Output { id = OutputId 0, run = r.id, example = e1.id, response = Nothing, text = Just "a"
                    , error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
  o2 <- add (Output { id = OutputId 0, run = r.id, example = e2.id, response = Nothing, text = Just "b"
                    , error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
  _  <- add (Score { id = ScoreId 0, output = o1.id, graderVersion = gv.id, value = Just 0.0, passed = Just False
                   , detail = Nothing, error = Nothing, createdAt = now } :: Score)
  _  <- add (Score { id = ScoreId 0, output = o2.id, graderVersion = gv.id, value = Just 1.0, passed = Just True
                   , detail = Nothing, error = Nothing, createdAt = now } :: Score)
  rows <- runQuery $ do
    o <- from @Output
    s <- innerJoin @Score (\s -> s ?. #output .== o ?. #id)
    where_ (o ?. #run .== val r.id)
    groupBy (s ?. #graderVersion)
    pure (s ?. #graderVersion, (avg_ (s ?. #value), countRows))
  -- rows :: [(GraderVersionId, (Maybe (Maybe Double), Int))]
  let pick = case rows of
        [(k, (m, c))] -> Just (k, m, c)
        _             -> Nothing
  pure AggregateResult
    { aGroups   = length rows
    , aCount    = maybe 0 (\(_, _, c) -> c) pick
    , aMean     = pick >>= \(_, m, _) -> join m
    , aGroupGv  = fmap (\(k, _, _) -> k) pick
    , aSeededGv = gv.id
    }

-- Scenario D ------------------------------------------------------------------

data CompareResult = CompareResult
  { cRunA :: [(Text, Maybe Double)]   -- (example key, score value) for run A
  , cRunB :: [(Text, Maybe Double)]   -- (example key, score value) for run B
  }

-- Two runs over the SAME dataset version, scoring the same two examples with
-- opposite values. We query each run's scores joined back to the example, return
-- (key, value), and line the two runs up by the stable example key. This proves
-- the schema supports comparing runs by example key.
expectCompareRuns :: Pool -> UTCTime -> IO CompareResult
expectCompareRuns pool now = withSession pool $ do
  d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "cmp", slug = "cmp", createdAt = now } :: Dataset)
  v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  e1 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c1"
                     , input = Aeson (object []), expected = Nothing, meta = Nothing } :: Example)
  e2 <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c2"
                     , input = Aeson (object []), expected = Nothing, meta = Nothing } :: Example)
  t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
  tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "p"
                           , params = Aeson (object []), createdAt = now } :: TargetVersion)
  g  <- add (Grader { id = GraderId 0, org = OrgId 1, name = "g", kind = "exact", createdAt = now } :: Grader)
  gv <- add (GraderVersion { id = GraderVersionId 0, grader = g.id, version = 1, config = Aeson (object []), createdAt = now } :: GraderVersion)
  -- Run A: c1 -> 1.0, c2 -> 0.0
  rA <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "done"
                 , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
  aO1 <- add (Output { id = OutputId 0, run = rA.id, example = e1.id, response = Nothing, text = Nothing
                     , error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
  aO2 <- add (Output { id = OutputId 0, run = rA.id, example = e2.id, response = Nothing, text = Nothing
                     , error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
  _ <- add (Score { id = ScoreId 0, output = aO1.id, graderVersion = gv.id, value = Just 1.0, passed = Just True
                  , detail = Nothing, error = Nothing, createdAt = now } :: Score)
  _ <- add (Score { id = ScoreId 0, output = aO2.id, graderVersion = gv.id, value = Just 0.0, passed = Just False
                  , detail = Nothing, error = Nothing, createdAt = now } :: Score)
  -- Run B: c1 -> 0.0, c2 -> 1.0
  rB <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "done"
                 , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
  bO1 <- add (Output { id = OutputId 0, run = rB.id, example = e1.id, response = Nothing, text = Nothing
                     , error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
  bO2 <- add (Output { id = OutputId 0, run = rB.id, example = e2.id, response = Nothing, text = Nothing
                     , error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
  _ <- add (Score { id = ScoreId 0, output = bO1.id, graderVersion = gv.id, value = Just 0.0, passed = Just False
                  , detail = Nothing, error = Nothing, createdAt = now } :: Score)
  _ <- add (Score { id = ScoreId 0, output = bO2.id, graderVersion = gv.id, value = Just 1.0, passed = Just True
                  , detail = Nothing, error = Nothing, createdAt = now } :: Score)
  let scoresFor rid = do
        rows <- runQuery $ do
          o <- from @Output
          s <- innerJoin @Score (\s -> s ?. #output .== o ?. #id)
          e <- innerJoin @Example (\e -> e ?. #id .== o ?. #example)
          where_ (o ?. #run .== val rid)
          orderBy [asc (e ?. #key)]
          pure (e ?. #key, s ?. #value)
        pure (rows :: [(Text, Maybe Double)])
  rowsA <- scoresFor rA.id
  rowsB <- scoresFor rB.id
  pure CompareResult { cRunA = rowsA, cRunB = rowsB }

-- Scenario E ------------------------------------------------------------------

data CriterionLabelResult = CriterionLabelResult
  { lRows      :: Int
  , lHuman     :: Maybe Bool
  , lCriterion :: Maybe Text
  , lSource    :: Maybe (Maybe Text)
  }

-- Seed the minimal graph for an Output, attach a human gold verdict
-- (CriterionLabel) against it, then read it back by output.
expectCriterionLabel :: Pool -> UTCTime -> IO CriterionLabelResult
expectCriterionLabel pool now = withSession pool $ do
  d  <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "lbl", slug = "lbl", createdAt = now } :: Dataset)
  v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  ex <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "k1"
                     , input = Aeson (object []), expected = Nothing, meta = Nothing } :: Example)
  t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
  tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "m", prompt = "p"
                           , params = Aeson (object []), createdAt = now } :: TargetVersion)
  r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id, status = "done"
                 , startedAt = Just now, finishedAt = Just now, meta = Nothing, createdAt = now } :: Run)
  o  <- add (Output { id = OutputId 0, run = r.id, example = ex.id, response = Nothing, text = Just "candidate"
                    , error = Nothing, latencyMs = Nothing, tokens = Nothing } :: Output)
  _  <- add (CriterionLabel { id = CriterionLabelId 0, output = o.id
                            , criterion = "is accurate", human = True
                            , source = Just "physician", createdAt = now } :: CriterionLabel)
  got <- selectWhere [ #output ==. o.id ]
  let labels = got :: [CriterionLabel]
  pure CriterionLabelResult
    { lRows      = length labels
    , lHuman     = fmap (.human) (listToMaybe labels)
    , lCriterion = fmap (.criterion) (listToMaybe labels)
    , lSource    = fmap (.source) (listToMaybe labels)
    }
