{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The evals dashboard WAI application: JSON API routes for datasets, runs,
-- and run detail, plus a static file fallback for the WASM UI.
module Evals.Dashboard (dashboardApp) where

import Control.Exception (SomeException, handle)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as AT
import qualified Data.ByteString.Char8 as BS8
import Data.List (minimumBy, nub, sortBy, sortOn)
import Data.Maybe (catMaybes, isNothing)
import Data.Ord (comparing)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Map.Strict as Map
import Network.HTTP.Types (Status, status200, status400, status404, status500)
import Network.Wai (Application, Request, Response, pathInfo, queryString, responseLBS, responseFile)
import System.Directory (doesFileExist)
import System.FilePath ((</>), takeExtension)
import Text.Read (readMaybe)

import Manifest (Aeson (..), Cond, Db, get, selectWhere, withSession, Key (..), (==.))
import Manifest.Postgres (Pool)

import Evals.Api
import Evals.Dashboard.Events (EventHub, sseResponse)
import Evals.Ids
import Evals.Schema

-- | The WAI application: routes API calls and serves static files.
dashboardApp :: Pool -> FilePath -> EventHub -> Application
dashboardApp pool staticDir hub req respond =
  case pathInfo req of
    ["api", "datasets"]     -> apiWith (datasetsHandler pool respond)
    ["api", "runs"]         -> apiWith (runsHandler pool (queryParam "datasetVersion" req) respond)
    ["api", "runs", nTxt]   ->
      case readMaybe (T.unpack nTxt) :: Maybe Int of
        Nothing  -> respond (badRequest "invalid run id")
        Just n   -> apiWith (runDetailHandler pool (RunId n) respond)
    ["api", "compare"]      -> apiWith (compareHandler pool req respond)
    ["api", "events"]       -> respond (sseResponse hub)
    ("api" : _)             -> respond notFound
    segments                -> staticHandler staticDir (normalise segments) respond
  where
    apiWith action = handle
      (\(e :: SomeException) ->
        respond (json status500 (ApiError { error = "internal error: " <> T.pack (show e) })))
      action

-- | Serve a static file.
staticHandler :: FilePath -> [T.Text] -> (Response -> IO a) -> IO a
staticHandler staticDir segments respond = do
  if any unsafe segments
    then respond notFound
    else do
      let path = staticDir </> foldr1 (</>) (map T.unpack segments)
      exists <- doesFileExist path
      if exists
        then respond (responseFile status200 [("Content-Type", contentType path)] path Nothing)
        else respond notFound
  where
    unsafe s = s == ".." || T.isInfixOf ".." s || s == ""

normalise :: [T.Text] -> [T.Text]
normalise [] = ["index.html"]
normalise ps = ps

contentType :: FilePath -> BS8.ByteString
contentType path = case takeExtension path of
  ".html" -> "text/html; charset=utf-8"
  ".js"   -> "text/javascript"
  ".mjs"  -> "text/javascript"
  ".css"  -> "text/css"
  ".wasm" -> "application/wasm"
  ".json" -> "application/json"
  ".svg"  -> "image/svg+xml"
  _       -> "application/octet-stream"

-- | Extract a named query string parameter.
queryParam :: BS8.ByteString -> Request -> Maybe T.Text
queryParam key req =
  case lookup key (queryString req) of
    Just (Just v) -> Just (TE.decodeUtf8Lenient v)
    _             -> Nothing

-- ---------------------------------------------------------------------------
-- JSON helpers

json :: Aeson.ToJSON a => Status -> a -> Response
json st val =
  responseLBS st [("Content-Type", "application/json")] (Aeson.encode val)

notFound :: Response
notFound = json status404 (ApiError { error = "not found" })

badRequest :: T.Text -> Response
badRequest msg = json status400 (ApiError { error = msg })

-- ---------------------------------------------------------------------------
-- /api/datasets

datasetsHandler :: Pool -> (Response -> IO a) -> IO a
datasetsHandler pool respond = do
  dtos <- withSession pool $ do
    datasets <- selectWhere ([] :: [Cond Dataset])
    let sorted = sortOn (\d -> d.name) datasets
    mapM datasetDto sorted
  respond (json status200 dtos)

datasetDto :: Dataset -> Db DatasetDto
datasetDto d = do
  versions <- selectWhere [ #dataset ==. d.id ] :: Db [DatasetVersion]
  let sortedVs = sortOn (\v -> v.version) versions
  vDtos <- mapM versionDto sortedVs
  let DatasetId did = d.id
  pure DatasetDto
    { datasetId = did
    , name      = d.name
    , slug      = d.slug
    , versions  = vDtos
    }

versionDto :: DatasetVersion -> Db DatasetVersionDto
versionDto v = do
  -- TODO: project a COUNT when datasets grow (this pulls full jsonb rows)
  examples <- selectWhere [ #datasetVersion ==. v.id ] :: Db [Example]
  let DatasetVersionId vid = v.id
  pure DatasetVersionDto
    { datasetVersionId = vid
    , version          = v.version
    , finalizedAt      = v.finalizedAt
    , exampleCount     = length examples
    }

-- ---------------------------------------------------------------------------
-- /api/runs

runsHandler :: Pool -> Maybe T.Text -> (Response -> IO a) -> IO a
runsHandler pool mFilterTxt respond =
  case mFilterTxt of
    Just txt ->
      case readMaybe (T.unpack txt) :: Maybe Int of
        Nothing  -> respond (badRequest "invalid datasetVersion id")
        Just n   -> do
          dtos <- withSession pool $ do
            runs <- selectWhere [ #datasetVersion ==. DatasetVersionId n ] :: Db [Run]
            let runIdInt (RunId n) = n
                sorted = sortBy (flip (comparing (\r -> runIdInt r.id))) runs
            mapM runSummary sorted
          respond (json status200 dtos)
    Nothing  -> do
      dtos <- withSession pool $ do
        runs <- selectWhere ([] :: [Cond Run])
        let runIdInt (RunId n) = n
            sorted = sortBy (flip (comparing (\r -> runIdInt r.id))) runs
        mapM runSummary sorted
      respond (json status200 dtos)

-- | Build a RunSummaryDto for a Run. Missing FK rows fall back to "?" names.
runSummary :: Run -> Db RunSummaryDto
runSummary r = do
  mtv <- get @TargetVersion (Key r.targetVersion)
  mt  <- maybe (pure Nothing) (\tv -> get @Target (Key tv.target)) mtv
  mdv <- get @DatasetVersion (Key r.datasetVersion)
  md  <- maybe (pure Nothing) (\dv -> get @Dataset (Key dv.dataset)) mdv
  allMetrics <- selectWhere [ #run ==. r.id ] :: Db [RunMetric]
  metricDtos <- groupedMetricDtos allMetrics
  let sortedMetrics = sortOn (\m -> m.graderName) metricDtos
      RunId rid = r.id
      tvVersion  = maybe 0 (.version) mtv
      tvModel    = maybe "?" (.model) mtv
      tName      = maybe "?" (.name) mt
      dvVersion  = maybe 0 (.version) mdv
      dName      = maybe "?" (.name) md
      DatasetVersionId dvid = r.datasetVersion
  pure RunSummaryDto
    { runId           = rid
    , datasetVersionId = dvid
    , datasetName     = dName
    , datasetVersion  = dvVersion
    , targetName      = tName
    , targetVersion   = tvVersion
    , model           = tvModel
    , status          = r.status
    , startedAt       = r.startedAt
    , finishedAt      = r.finishedAt
    , metrics         = sortedMetrics
    }

-- | One MetricDto per grader version: the overall (tag Nothing) row supplies
-- mean/passRate/stderr/count; the tagged rows become sorted breakdowns. A group
-- with no overall row is dropped (recompute always writes one).
groupedMetricDtos :: [RunMetric] -> Db [MetricDto]
groupedMetricDtos rms =
  fmap catMaybes (mapM buildOne (Map.toList byGrader))
  where
    byGrader = Map.fromListWith (++) [ (rm.graderVersion, [rm]) | rm <- rms ]
    buildOne (gvId, rows) =
      case [ rm | rm <- rows, isNothing rm.tag ] of
        []          -> pure Nothing
        (overall:_) -> do
          mgv <- get @GraderVersion (Key gvId)
          mg  <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv
          let gName    = maybe "?" (.name) mg
              gVersion = maybe 0 (.version) mgv
              brks = sortOn (.tag)
                       [ TagMetricDto { tag = t, mean = rm.mean, stderr = rm.stderr, count = rm.count }
                       | rm <- rows, Just t <- [rm.tag] ]
          pure (Just MetricDto
            { graderName = gName, graderVersion = gVersion
            , mean = overall.mean, passRate = overall.passRate, count = overall.count
            , stderr = overall.stderr, breakdowns = brks })

-- ---------------------------------------------------------------------------
-- /api/runs/:id

runDetailHandler :: Pool -> RunId -> (Response -> IO a) -> IO a
runDetailHandler pool rid respond = do
  mDto <- withSession pool $ do
    mRun <- get @Run (Key rid)
    case mRun of
      Nothing  -> pure Nothing
      Just run -> do
        summary <- runSummary run
        outputs <- selectWhere [ #run ==. rid ] :: Db [Output]
        -- build OutputRowDto per output, ordering by example key
        rows <- mapM (outputRowDto rid) outputs
        let sortedRows = sortOn (\r -> r.exampleKey) rows
        pure (Just RunDetailDto { run = summary, outputs = sortedRows })
  case mDto of
    Nothing  -> respond notFound
    Just dto -> respond (json status200 dto)

outputRowDto :: RunId -> Output -> Db OutputRowDto
outputRowDto _rid o = do
  mEx <- get @Example (Key o.example)
  let exKey = maybe "?" (.key) mEx
  scores <- selectWhere [ #output ==. o.id ] :: Db [Score]
  scoreDtos <- mapM scoreDto scores
  let sortedScores = sortOn (\s -> s.graderName) scoreDtos
      tokensVal = (\(Aeson v) -> v) <$> o.tokens
  pure OutputRowDto
    { exampleKey  = exKey
    , outputText  = o.text
    , outputError = o.error
    , latencyMs   = o.latencyMs
    , tokens      = tokensVal
    , scores      = sortedScores
    }

scoreDto :: Score -> Db ScoreDto
scoreDto s = do
  mgv <- get @GraderVersion (Key s.graderVersion)
  mg  <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv
  let gName    = maybe "?" (.name) mg
      gVersion = maybe 0 (.version) mgv
      rationale = s.detail >>= \(Aeson v) ->
        AT.parseMaybe (Aeson.withObject "d" (Aeson..: "rationale")) v
  pure ScoreDto
    { graderName    = gName
    , graderVersion = gVersion
    , value         = s.value
    , passed        = s.passed
    , scoreError    = s.error
    , rationale     = rationale
    }

-- ---------------------------------------------------------------------------
-- /api/compare

-- | Compare two runs side-by-side, aligned by example key.
-- Both runs must share the same dataset version (else 400).
-- The grader compared is the lexicographically-first (name, version) among
-- graders that scored BOTH runs, falling back to either run's graders when
-- none scored both.
compareHandler :: Pool -> Request -> (Response -> IO a) -> IO a
compareHandler pool req respond =
  case (queryParam "a" req >>= readMaybeInt, queryParam "b" req >>= readMaybeInt) of
    (Nothing, _) -> respond (badRequest "a and b run ids required")
    (_, Nothing) -> respond (badRequest "a and b run ids required")
    (Just aInt, Just bInt) -> do
      result <- withSession pool $ do
        mRunA <- get @Run (Key (RunId aInt))
        mRunB <- get @Run (Key (RunId bInt))
        case (mRunA, mRunB) of
          (Nothing, _) -> pure (Left (404 :: Int, "not found"))
          (_, Nothing) -> pure (Left (404, "not found"))
          (Just runA, Just runB) ->
            if runA.datasetVersion /= runB.datasetVersion
              then pure (Left (400, "runs are over different dataset versions"))
              else do
                summA <- runSummary runA
                summB <- runSummary runB
                -- Examples of the shared dataset version, sorted by key.
                examples <- selectWhere [ #datasetVersion ==. runA.datasetVersion ] :: Db [Example]
                let sortedExamples = sortOn (.key) examples
                -- Outputs keyed by (runId, exampleId).
                outsA <- selectWhere [ #run ==. runA.id ] :: Db [Output]
                outsB <- selectWhere [ #run ==. runB.id ] :: Db [Output]
                let outputMapA = Map.fromList [ (o.example, o) | o <- outsA ]
                    outputMapB = Map.fromList [ (o.example, o) | o <- outsB ]
                -- Collect all scores for both runs; resolve grader identities.
                allScoresA <- concat <$> mapM (\o -> selectWhere [ #output ==. o.id ] :: Db [Score]) outsA
                allScoresB <- concat <$> mapM (\o -> selectWhere [ #output ==. o.id ] :: Db [Score]) outsB
                -- For each score, resolve (graderName, graderVersion) pair.
                let resolveGrader s = do
                      mgv <- get @GraderVersion (Key s.graderVersion)
                      mg  <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv
                      let gName    = maybe "?" (.name) mg
                          gVersion = maybe 0 (.version) mgv
                      pure (gName, gVersion, s.graderVersion)
                graderKeysA <- mapM resolveGrader allScoresA
                graderKeysB <- mapM resolveGrader allScoresB
                let graderSetA    = nub [ (n, v, gvid) | (n, v, gvid) <- graderKeysA ]
                    graderSetB    = nub [ (n, v, gvid) | (n, v, gvid) <- graderKeysB ]
                    graderNamesA  = [ (n, v) | (n, v, _) <- graderSetA ]
                    graderNamesB  = [ (n, v) | (n, v, _) <- graderSetB ]
                    -- Graders that appear in BOTH runs (intersection by name+version).
                    bothNames     = [ nv | nv <- graderNamesA, nv `elem` graderNamesB ]
                    -- Candidate pool: intersection if non-empty, else union.
                    candidateKeys =
                      if null bothNames
                        then nub (graderSetA ++ graderSetB)
                        else [ (n, v, gvid) | (n, v, gvid) <- graderSetA, (n, v) `elem` bothNames ]
                -- Pick the first grader by (graderName, graderVersion) ordering.
                let mChosenGrader =
                      if null candidateKeys
                        then Nothing
                        else Just (minimumBy (comparing (\(n, v, _) -> (n, v))) candidateKeys)
                -- Build a score lookup map: outputId -> Score (for chosen grader only).
                -- NOTE: chosenGvId comes from run A's candidate set; this assumes one
                -- GraderVersion row per (grader name, version) — if B were scored by a
                -- DIFFERENT row sharing the same (name, version), B's scores would drop.
                let chosenGvId = fmap (\(_, _, gvid) -> gvid) mChosenGrader
                    scoresByOutput scores =
                      Map.fromList
                        [ (s.output, s)
                        | s <- scores
                        , Just s.graderVersion == chosenGvId
                        ]
                    scoreMapA = scoresByOutput allScoresA
                    scoreMapB = scoresByOutput allScoresB
                -- Build rows.
                let mkRow ex =
                      let mOutA  = Map.lookup ex.id outputMapA
                          mOutB  = Map.lookup ex.id outputMapB
                          mSA    = mOutA >>= \o -> Map.lookup o.id scoreMapA
                          mSB    = mOutB >>= \o -> Map.lookup o.id scoreMapB
                          sAval  = mSA >>= (.value)
                          sBval  = mSB >>= (.value)
                      in CompareRowDto
                           { exampleKey = ex.key
                           , outputA    = mOutA >>= (.text)
                           , outputB    = mOutB >>= (.text)
                           , errorA     = mOutA >>= (.error)
                           , errorB     = mOutB >>= (.error)
                           , scoreA     = sAval
                           , scoreB     = sBval
                           , passedA    = mSA >>= (.passed)
                           , passedB    = mSB >>= (.passed)
                           , delta      = (-) <$> sAval <*> sBval
                           }
                    rows = map mkRow sortedExamples
                    (mGraderName, mGraderVersion) =
                      case mChosenGrader of
                        Nothing          -> (Nothing, Nothing)
                        Just (n, v, _)   -> (Just n, Just v)
                pure (Right CompareDto
                  { runA         = summA
                  , runB         = summB
                  , graderName    = mGraderName
                  , graderVersion = mGraderVersion
                  , rows          = rows
                  })
      case result of
        Left (404, msg) -> respond (json status404 (ApiError { error = msg }))
        Left (_, msg)   -> respond (badRequest msg)
        Right dto       -> respond (json status200 dto)
  where
    readMaybeInt :: T.Text -> Maybe Int
    readMaybeInt t = readMaybe (T.unpack t)
