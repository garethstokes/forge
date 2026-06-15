{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
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
import Data.Aeson (Value)
import qualified Data.Aeson.Types as AT
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Foldable (toList)
import Data.List (maximumBy, minimumBy, nub, sort, sortBy, sortOn)
import Data.Maybe (catMaybes, isNothing)
import Data.Ord (comparing)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Network.HTTP.Types (Status, status200, status400, status404, status500)
import Network.Wai (Application, Request, Response, pathInfo, queryString, responseLBS, responseFile)
import System.Directory (doesFileExist)
import System.FilePath ((</>), takeExtension)
import Text.Read (readMaybe)

import Manifest (Aeson (..), Cond, Db, get, selectWhere, withSession, Key (..), (==.))
import Manifest.Postgres (Pool)

import Crucible.LLM (Message (..), Role (..))
import Evals.Api
import Evals.Calibration (bandOf, trustedBy)
import Evals.Dashboard.Events (EventHub, sseResponse)
import Evals.Execute (assembleMessages)
import Evals.Ids
import Evals.Schema
import Evals.Tenant (withTenant)

-- | Escape the five HTML-significant characters; org name/slug are interpolated
-- into the picker page, so escape them even though slugs are URL-constrained.
htmlEscape :: T.Text -> T.Text
htmlEscape = T.concatMap $ \c -> case c of
  '&' -> "&amp;"; '<' -> "&lt;"; '>' -> "&gt;"; '"' -> "&quot;"; '\'' -> "&#39;"
  _   -> T.singleton c

-- | Root page: a minimal standalone HTML table of orgs (links to /<slug>/).
-- Unscoped — the registry has no RLS policy.
orgPickerHandler :: Pool -> (Response -> IO a) -> IO a
orgPickerHandler pool respond = do
  orgs <- withSession pool (selectWhere ([] :: [Cond Org]))
  let row o = "<tr onclick=\"location='/" <> htmlEscape o.slug <> "/'\">"
           <> "<td class=\"k\">" <> htmlEscape o.slug <> "</td><td>" <> htmlEscape o.name <> "</td></tr>"
      body  = "<!doctype html><meta charset=utf-8><title>evals — orgs</title>"
           <> "<style>body{font:14px system-ui;margin:0;background:#f7f8fa;color:#1c2330}"
           <> ".topbar{display:flex;align-items:center;gap:10px;background:#fff;border-bottom:1px solid #e3e7ee;padding:10px 24px}"
           <> ".topbar h1{margin:0;font-size:16px}.topbar a{color:#1c2330;text-decoration:none}"
           <> ".wrap{max-width:1200px;margin:0 auto;padding:16px 24px 48px}h2{font-size:15px;margin:24px 0 8px}"
           <> "table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #e3e7ee;font-size:14px}"
           <> "th,td{border:1px solid #e3e7ee;padding:6px 10px;text-align:left}"
           <> "th{background:#eef0f4;color:#6b7280;text-transform:uppercase;font-size:12px;letter-spacing:.03em}"
           <> "tr{cursor:pointer}tbody tr:hover{background:#f2f6ff}td.k{font-family:ui-monospace,Menlo,monospace;color:#2456c8}</style>"
           <> "<header class=\"topbar\"><h1><a href=\"/\">manifest evals</a></h1></header>"
           <> "<div class=\"wrap\"><h2>organisations</h2>"
           <> "<table><thead><tr><th>org</th><th>name</th></tr></thead><tbody>"
           <> T.concat (map row orgs) <> "</tbody></table></div>"
  respond (responseLBS status200 [("Content-Type", "text/html; charset=utf-8")]
             (LBS.fromStrict (TE.encodeUtf8 body)))

-- | The WAI application: routes API calls and serves static files.
dashboardApp :: Pool -> FilePath -> EventHub -> Application
dashboardApp pool staticDir hub req respond =
  case pathInfo req of
    []            -> apiWith (orgPickerHandler pool respond)
    (slug : rest) -> do
      orgs <- withSession pool (selectWhere ([ #slug ==. slug ] :: [Cond Org]))
      case orgs of
        []      -> respond notFound
        (o : _) -> dispatch o.id rest
  where
    apiWith action = handle
      (\(e :: SomeException) ->
        respond (json status500 (ApiError { error = "internal error: " <> T.pack (show e) })))
      action
    dispatch orgId rest = case rest of
      ["api", "datasets"]     -> apiWith (datasetsHandler pool orgId respond)
      ["api", "runs"]         -> apiWith (runsHandler pool orgId (queryParam "datasetVersion" req) respond)
      ["api", "runs", nTxt]   ->
        case readMaybe (T.unpack nTxt) :: Maybe Int of
          Nothing -> respond (badRequest "invalid run id")
          Just n  -> apiWith (runDetailHandler pool orgId (RunId n) req respond)
      ["api", "runs", nTxt, "ex", key] ->
        case readMaybe (T.unpack nTxt) :: Maybe Int of
          Nothing -> respond (badRequest "invalid run id")
          Just n  -> apiWith (exampleDetailHandler pool orgId (RunId n) key respond)
      ["api", "compare"]      -> apiWith (compareHandler pool orgId req respond)
      ["api", "calibration"]  -> apiWith (calibrationHandler pool orgId respond)
      ["api", "events"]       -> respond (sseResponse hub)
      ("api" : _)             -> respond notFound
      segments                -> staticHandler staticDir (normalise segments) respond

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

-- | Drop empty path segments (a trailing slash like @/acme/@ yields @[""]@),
-- then default an empty path to the SPA index.
normalise :: [T.Text] -> [T.Text]
normalise ps = case filter (not . T.null) ps of
  [] -> ["index.html"]
  xs -> xs

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

datasetsHandler :: Pool -> OrgId -> (Response -> IO a) -> IO a
datasetsHandler pool orgId respond = do
  dtos <- withSession pool $ withTenant orgId $ do
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

runsHandler :: Pool -> OrgId -> Maybe T.Text -> (Response -> IO a) -> IO a
runsHandler pool orgId mFilterTxt respond =
  case mFilterTxt of
    Just txt ->
      case readMaybe (T.unpack txt) :: Maybe Int of
        Nothing  -> respond (badRequest "invalid datasetVersion id")
        Just n   -> do
          dtos <- withSession pool $ withTenant orgId $ do
            runs <- selectWhere [ #datasetVersion ==. DatasetVersionId n ] :: Db [Run]
            let runIdInt (RunId n) = n
                sorted = sortBy (flip (comparing (\r -> runIdInt r.id))) runs
            mapM (runSummary False) sorted
          respond (json status200 dtos)
    Nothing  -> do
      dtos <- withSession pool $ withTenant orgId $ do
        runs <- selectWhere ([] :: [Cond Run])
        let runIdInt (RunId n) = n
            sorted = sortBy (flip (comparing (\r -> runIdInt r.id))) runs
        mapM (runSummary False) sorted
      respond (json status200 dtos)

-- | Build a RunSummaryDto for a Run. Missing FK rows fall back to "?" names.
runSummary :: Bool -> Run -> Db RunSummaryDto
runSummary detail r = do
  mtv <- get @TargetVersion (Key r.targetVersion)
  mt  <- maybe (pure Nothing) (\tv -> get @Target (Key tv.target)) mtv
  mdv <- get @DatasetVersion (Key r.datasetVersion)
  md  <- maybe (pure Nothing) (\dv -> get @Dataset (Key dv.dataset)) mdv
  allMetrics <- selectWhere [ #run ==. r.id ] :: Db [RunMetric]
  metricDtos <- groupedMetricDtos detail r.id allMetrics
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
groupedMetricDtos :: Bool -> RunId -> [RunMetric] -> Db [MetricDto]
groupedMetricDtos detail runId rms =
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
              gKind    = maybe "?" (.kind) mg
              brks = sortOn (.tag)
                       [ TagMetricDto { tag = t, mean = rm.mean, stderr = rm.stderr, count = rm.count }
                       | rm <- rows, Just t <- [rm.tag] ]
          crits <- if detail && gKind == "pointed"
                     then rubricCriteriaFor runId gvId
                     else pure []
          pure (Just MetricDto
            { graderName = gName, graderVersion = gVersion, graderKind = gKind
            , mean = overall.mean, passRate = overall.passRate, count = overall.count
            , stderr = overall.stderr, breakdowns = brks, criteria = crits })

-- | The distinct rubric criteria across all of a grader version's scores in a
-- run — the union, deduped by criterion text. Detail-view only (the runs list
-- never calls this).
rubricCriteriaFor :: RunId -> GraderVersionId -> Db [RubricCriterionDto]
rubricCriteriaFor runId gvId = do
  outs   <- selectWhere [ #run ==. runId ] :: Db [Output]
  perOut <- mapM (\o -> selectWhere [ #output ==. o.id, #graderVersion ==. gvId ] :: Db [Score]) outs
  pure (dedupCriteria (concatMap (rubricCriteriaFromDetail . (.detail)) (concat perOut)))

rubricCriteriaFromDetail :: Maybe (Aeson Value) -> [RubricCriterionDto]
rubricCriteriaFromDetail Nothing = []
rubricCriteriaFromDetail (Just (Aeson v)) = maybe [] id (AT.parseMaybe p v)
  where p = AT.withObject "detail" $ \o -> do
              arr <- o AT..: "criteria"
              mapM (AT.withObject "criterion" $ \c ->
                      RubricCriterionDto <$> c AT..: "criterion" <*> c AT..: "points" <*> c AT..: "tags")
                   (arr :: [Value])

dedupCriteria :: [RubricCriterionDto] -> [RubricCriterionDto]
dedupCriteria = Map.elems . Map.fromListWith (\_new old -> old) . map (\c -> (c.criterion, c))

-- ---------------------------------------------------------------------------
-- Calibration (meta-eval) surfacing

-- | Resolve a MetaEval row into its wire DTO: grader identity, judge-error
-- count, and the server-computed trust verdict + Landis-Koch band.
metaEvalDto :: MetaEval -> Db MetaEvalDto
metaEvalDto me = do
  mgv <- get @GraderVersion (Key me.graderVersion)
  mg  <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv
  pure MetaEvalDto
    { graderName    = maybe "?" (.name) mg
    , graderVersion = maybe 0 (.version) mgv
    , graderKind    = maybe "?" (.kind) mg
    , mode          = me.mode
    , agreement     = me.agreement
    , kappa         = me.kappa
    , kappaLow      = me.kappaLow
    , kappaHigh     = me.kappaHigh
    , failPrecision = me.failPrecision
    , failRecall    = me.failRecall
    , passF1        = me.passF1
    , failF1        = me.failF1
    , balancedF1    = me.balancedF1
    , measured      = me.measured
    , judgeErrors   = judgeErrorCount me.judgeErrors
    , computedAt    = isoTime me.computedAt
    , trusted       = trustedBy me.kappaLow
    , band          = bandOf me.kappa
    }

-- | A trend point. 'isCurrent' is True when this report belongs to the run
-- being viewed (Nothing -> cross-run view, never current).
trendPoint :: Maybe RunId -> MetaEval -> TrendPointDto
trendPoint mrid me =
  let RunId rid = me.run
  in TrendPointDto
       { runId      = rid
       , kappa      = me.kappa
       , kappaLow   = me.kappaLow
       , kappaHigh  = me.kappaHigh
       , computedAt = isoTime me.computedAt
       , isCurrent  = maybe False (== me.run) mrid
       }

judgeErrorCount :: Aeson Value -> Int
judgeErrorCount = length . judgeErrorList

-- | The judge-error caseKeys stored on a MetaEval row (each "exampleKey:criterion").
judgeErrorList :: Aeson Value -> [T.Text]
judgeErrorList (Aeson v) = case v of
  Aeson.Array a -> [ t | Aeson.String t <- toList a ]
  _             -> []

isoTime :: UTCTime -> T.Text
isoTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | Build one CalibrationSeriesDto from a chosen "latest" row and a chronological
-- history (already filtered to one (graderVersion, mode) group).
buildSeries :: Maybe RunId -> MetaEval -> [MetaEval] -> Db CalibrationSeriesDto
buildSeries mrid latestRow history = do
  latestDto <- metaEvalDto latestRow
  pure CalibrationSeriesDto
    { graderName    = latestDto.graderName
    , graderVersion = latestDto.graderVersion
    , graderKind    = latestDto.graderKind
    , mode          = latestDto.mode
    , latest        = latestDto
    , trend         = map (trendPoint mrid) (sortOn (.computedAt) history)
    }

-- | Calibration series for a single run: latest report per (graderVersion,
-- mode) seen on THIS run, each with that grader version's kappa trend across ALL
-- runs (so the sparkline shows whether this run's kappa is typical).
runCalibration :: RunId -> Db [CalibrationSeriesDto]
runCalibration rid = do
  thisRun <- selectWhere [ #run ==. rid ] :: Db [MetaEval]
  let byGroup = Map.fromListWith (++) [ ((me.graderVersion, me.mode), [me]) | me <- thisRun ]
  mapM buildGroup (Map.toList byGroup)
  where
    buildGroup ((gvId, md), rows) = do
      let latestRow = maximumBy (comparing (.computedAt)) rows
      allForGv <- selectWhere [ #graderVersion ==. gvId ] :: Db [MetaEval]
      let history = [ h | h <- allForGv, h.mode == md ]
      buildSeries (Just rid) latestRow history

-- | GET /api/calibration — every (graderVersion, mode) group that has any
-- MetaEval row: the overall latest report + the full κ trend (no current marker).
calibrationHandler :: Pool -> OrgId -> (Response -> IO a) -> IO a
calibrationHandler pool orgId respond = do
  series <- withSession pool $ withTenant orgId $ do
    allMetas <- selectWhere ([] :: [Cond MetaEval])
    let byGroup = Map.fromListWith (++) [ ((me.graderVersion, me.mode), [me]) | me <- allMetas ]
        build (_grp, rows) =
          buildSeries Nothing (maximumBy (comparing (.computedAt)) rows) rows
    mapM build (Map.toList byGroup)
  let sorted = sortBy (comparing (\s -> (s.graderName, s.graderVersion, s.mode))) series
  respond (json status200 sorted)

-- ---------------------------------------------------------------------------
-- /api/runs/:id

runDetailHandler :: Pool -> OrgId -> RunId -> Request -> (Response -> IO a) -> IO a
runDetailHandler pool orgId rid req respond = do
  let parseInt t = readMaybe (T.unpack t) :: Maybe Int
      off = max 0 (maybe 0 id (queryParam "offset" req >>= parseInt))
      lim = clampLimit (maybe 50 id (queryParam "limit" req >>= parseInt))
      clampLimit n = max 1 (min 200 n)
  mDto <- withSession pool $ withTenant orgId $ do
    mRun <- get @Run (Key rid)
    case mRun of
      Nothing  -> pure Nothing
      Just run -> do
        summary <- runSummary True run
        outputs <- selectWhere [ #run ==. rid ] :: Db [Output]
        -- build OutputRowDto per output, ordering by example key
        rows <- mapM (outputRowDto rid) outputs
        let sortedRows = sortOn (\r -> r.exampleKey) rows
            page = take lim (drop off sortedRows)
        cal <- runCalibration rid
        pure (Just RunDetailDto
          { run = summary, outputs = page
          , totalOutputs = length sortedRows, calibration = cal })
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
-- /api/runs/:id/ex/:key

exampleDetailHandler :: Pool -> OrgId -> RunId -> T.Text -> (Response -> IO a) -> IO a
exampleDetailHandler pool orgId rid key respond = do
  mDto <- withSession pool $ withTenant orgId $ do
    mRun <- get @Run (Key rid)
    case mRun of
      Nothing  -> pure Nothing
      Just run -> do
        mtv    <- get @TargetVersion (Key run.targetVersion)
        outs   <- selectWhere [ #run ==. rid ] :: Db [Output]
        paired <- mapM (\o -> do { me <- get @Example (Key o.example); pure (o, me) }) outs
        case sortOn (\(o, _) -> outIdInt o.id) [ (o, e) | (o, Just e) <- paired, e.key == key ] of
          []           -> pure Nothing
          ((o, e) : _) -> do
            scores <- selectWhere [ #output ==. o.id ] :: Db [Score]
            grades <- mapM gradeDto scores
            lbls   <- selectWhere [ #output ==. o.id ] :: Db [CriterionLabel]
            jerrs  <- judgeErrorsFor rid e.key
            let labelDtos = sortOn (.criterion)
                  [ CriterionLabelDto { criterion = l.criterion, human = l.human, source = l.source }
                  | l <- lbls ]
                Aeson inputV = e.input
                prompt = case mtv of
                  Just tv -> either (const []) (map msgDto) (assembleMessages tv e)
                  Nothing -> []
                RunId rn = rid
                keys = sort (nub [ ek.key | (_, Just ek) <- paired ])
                (prevK, nextK) = case break (== key) keys of
                                   (before, _ : after) -> (lastMay before, headMay after)
                                   _                    -> (Nothing, Nothing)
            pure (Just ExampleDetailDto
              { runId = rn, exampleKey = key, input = inputV, prompt = prompt
              , responseText = o.text, responseError = o.error
              , grades = sortOn (\g -> g.graderName) grades
              , labels = labelDtos, judgeErrors = jerrs
              , prevKey = prevK, nextKey = nextK })
  case mDto of
    Nothing  -> respond notFound
    Just dto -> respond (json status200 dto)
  where
    outIdInt (OutputId n) = n
    headMay (x:_) = Just x
    headMay []    = Nothing
    lastMay []    = Nothing
    lastMay xs    = Just (last xs)

-- | Judges (grader versions) that errored on this example, from the run's
-- meta-evals (latest per grader version). A judge_errors caseKey is
-- "exampleKey:criterion"; we match this example's by the "exampleKey:" prefix
-- and report the grader identity + the criterion it failed to judge.
judgeErrorsFor :: RunId -> T.Text -> Db [JudgeErrorDto]
judgeErrorsFor rid exKey = do
  metas <- selectWhere [ #run ==. rid ] :: Db [MetaEval]
  let byGv     = Map.fromListWith (++) [ (me.graderVersion, [me]) | me <- metas ]
      latest   = [ maximumBy (comparing (.computedAt)) rows | rows <- Map.elems byGv ]
      prefix   = exKey <> ":"
  fmap (sortOn (\j -> (j.graderName, j.graderVersion)) . concat) $
    mapM (\me -> do
      mgv <- get @GraderVersion (Key me.graderVersion)
      mg  <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv
      let gName = maybe "?" (.name) mg
          gVersion = maybe 0 (.version) mgv
      pure [ JudgeErrorDto { graderName = gName, graderVersion = gVersion
                           , criterion = T.drop (T.length prefix) ck }
           | ck <- judgeErrorList me.judgeErrors, prefix `T.isPrefixOf` ck ])
      latest

msgDto :: Message -> PromptMsgDto
msgDto (Message r c) = PromptMsgDto { role = renderRole r, content = c }
  where renderRole = \case
          System -> "system"; User -> "user"; Assistant -> "assistant"; Tool -> "tool"

gradeDto :: Score -> Db GradeDto
gradeDto s = do
  mgv <- get @GraderVersion (Key s.graderVersion)
  mg  <- maybe (pure Nothing) (\gv -> get @Grader (Key gv.grader)) mgv
  let gName = maybe "?" (.name) mg
      gVersion = maybe 0 (.version) mgv
      gKind = maybe "?" (.kind) mg
      rationale = s.detail >>= \(Aeson v) -> AT.parseMaybe (AT.withObject "d" (AT..: "rationale")) v
  pure GradeDto
    { graderName = gName, graderVersion = gVersion, graderKind = gKind
    , value = s.value, passed = s.passed, rationale = rationale
    , gradeError = s.error, criteria = verdictsFromDetail s.detail }

verdictsFromDetail :: Maybe (Aeson Value) -> [CriterionVerdictDto]
verdictsFromDetail Nothing = []
verdictsFromDetail (Just (Aeson v)) = maybe [] id (AT.parseMaybe p v)
  where p = AT.withObject "detail" $ \o -> do
              arr <- o AT..: "criteria"
              mapM (AT.withObject "criterion" $ \c ->
                      CriterionVerdictDto <$> c AT..: "criterion" <*> c AT..: "points"
                                          <*> c AT..: "tags" <*> c AT..: "met" <*> c AT..: "explanation")
                   (arr :: [Value])

-- ---------------------------------------------------------------------------
-- /api/compare

-- | Compare two runs side-by-side, aligned by example key.
-- Both runs must share the same dataset version (else 400).
-- The grader compared is the lexicographically-first (name, version) among
-- graders that scored BOTH runs, falling back to either run's graders when
-- none scored both.
compareHandler :: Pool -> OrgId -> Request -> (Response -> IO a) -> IO a
compareHandler pool orgId req respond =
  case (queryParam "a" req >>= readMaybeInt, queryParam "b" req >>= readMaybeInt) of
    (Nothing, _) -> respond (badRequest "a and b run ids required")
    (_, Nothing) -> respond (badRequest "a and b run ids required")
    (Just aInt, Just bInt) -> do
      result <- withSession pool $ withTenant orgId $ do
        mRunA <- get @Run (Key (RunId aInt))
        mRunB <- get @Run (Key (RunId bInt))
        case (mRunA, mRunB) of
          (Nothing, _) -> pure (Left (404 :: Int, "not found"))
          (_, Nothing) -> pure (Left (404, "not found"))
          (Just runA, Just runB) ->
            if runA.datasetVersion /= runB.datasetVersion
              then pure (Left (400, "runs are over different dataset versions"))
              else do
                summA <- runSummary False runA
                summB <- runSummary False runB
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
