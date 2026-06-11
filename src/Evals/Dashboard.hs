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
import Data.List (sortBy, sortOn)
import Data.Ord (comparing)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types (Status, status200, status400, status404, status500)
import Network.Wai (Application, Request, Response, pathInfo, queryString, responseLBS, responseFile)
import System.Directory (doesFileExist)
import System.FilePath ((</>), takeExtension)
import Text.Read (readMaybe)

import Manifest (Aeson (..), Cond, Db, get, selectWhere, withSession, Key (..), (==.))
import Manifest.Postgres (Pool)

import Evals.Api
import Evals.Ids
import Evals.Schema

-- | The WAI application: routes API calls and serves static files.
dashboardApp :: Pool -> FilePath -> Application
dashboardApp pool staticDir req respond =
  case pathInfo req of
    ["api", "datasets"]     -> apiWith (datasetsHandler pool respond)
    ["api", "runs"]         -> apiWith (runsHandler pool (queryParam "datasetVersion" req) respond)
    ["api", "runs", nTxt]   ->
      case readMaybe (T.unpack nTxt) :: Maybe Int of
        Nothing  -> respond (badRequest "invalid run id")
        Just n   -> apiWith (runDetailHandler pool (RunId n) respond)
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
  metrics <- selectWhere [ #run ==. r.id ] :: Db [RunMetric]
  metricDtos <- mapM metricDto metrics
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

metricDto :: RunMetric -> Db MetricDto
metricDto rm = do
  mgv <- get @GraderVersion (Key rm.graderVersion)
  mg  <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv
  let gName    = maybe "?" (.name) mg
      gVersion = maybe 0 (.version) mgv
  pure MetricDto
    { graderName    = gName
    , graderVersion = gVersion
    , mean          = rm.mean
    , passRate      = rm.passRate
    , count         = rm.count
    }

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
