{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Plain @Model -> View Action@ functions for the three routes. DTO fields
-- are accessed with record-dot syntax ("Evals.Api" uses DuplicateRecordFields).
module Evals.Ui.View (viewModel) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Text (encodeToLazyText)
import Data.Foldable (toList)
import Data.List (intersperse, nub)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Numeric (showFFloat)

import Miso (Attribute, View, text)
import Miso.CSS (styleInline_)
import Miso.Event.Types (Options (..))
import Miso.Html
import qualified Miso.Html.Property as P
import Miso.String (MisoString, fromMisoString, ms)
import qualified Miso.Svg.Element as S
import qualified Miso.Svg.Property as SP

import Evals.Api
import Evals.Ui.Model

viewModel :: props -> Model -> View Model Action
viewModel _ m =
  div_
    [ P.class_ "app" ]
    [ header_
        [ P.class_ "topbar" ]
        [ h1_ [] [ a_ [ P.href_ "/" ] [ text "manifest evals" ] ]
        , liveDot (_liveM m)
        ]
    , main_ [ P.class_ "content" ] [ body ]
    ]
  where
    body = case _routeM m of
      RunsR -> runsView m
      RunR i -> detailView m i
      CompareR a b -> compareView m a b
      ExampleR i k -> exampleView m i k
      CalibrationR -> calibrationView m

-- | SSE connection status dot in the header: green while the change feed is
-- connected, gray while the EventSource is reconnecting.
liveDot :: LiveStatus -> View Model Action
liveDot st = span_ [ P.class_ ("live " <> cls), P.title_ ttl ] []
  where
    (cls, ttl) = case st of
      LiveConnected -> ("on", "live")
      LiveReconnecting -> ("off", "reconnecting…")

-- | Loading / Failed / Got dispatch ('NotAsked' renders as loading: every
-- route entry immediately kicks a fetch).
remoteView :: RemoteData a -> (a -> View Model Action) -> View Model Action
remoteView rd f =
  case rd of
    NotAsked -> loadingBox
    Loading -> loadingBox
    Failed e -> div_ [ P.class_ "error" ] [ text e ]
    Got a -> f a
  where
    loadingBox = div_ [ P.class_ "loading" ] [ text "loading…" ]

-- Shared navigation components -----------------------------------------------

breadcrumb :: [(MisoString, Maybe MisoString)] -> View Model Action
breadcrumb crumbs = nav_ [ P.class_ "breadcrumb" ] (intersperse sep (map crumb crumbs))
  where
    sep = span_ [ P.class_ "sep" ] [ text "/" ]
    crumb (label, Just href) = a_ [ P.href_ href ] [ text label ]
    crumb (label, Nothing)   = span_ [ P.class_ "here" ] [ text label ]

orgCrumb :: Model -> (MisoString, Maybe MisoString)
orgCrumb m = (ms (T.dropWhile (== '/') (fromMisoString (_orgSlugM m))), Just "/")

tabBar :: [(MisoString, MisoString, Bool)] -> View Model Action
tabBar tabs = div_ [ P.class_ "tabbar" ] (map one tabs)
  where one (label, href, active) =
          a_ [ P.class_ ("tab" <> if active then " active" else ""), P.href_ href ] [ text label ]

-- Runs list -------------------------------------------------------------------

runsView :: Model -> View Model Action
runsView m =
  remoteView (_runsM m) $ \rs ->
    div_ []
      ( breadcrumb [ orgCrumb m, ("runs", Nothing) ]
      : runsTabBar RunsR
      : map (runGroup m rs) (groupRuns rs) )

runsTabBar :: Route -> View Model Action
runsTabBar active = tabBar
  [ ("Runs", runsHash, active == RunsR)
  , ("Grader calibration", calibrationHash, active == CalibrationR) ]

-- | Group runs under (datasetName, datasetVersion) headings, first-seen
-- order (the API returns newest first).
groupRuns :: [RunSummaryDto] -> [((Text, Int), [RunSummaryDto])]
groupRuns rs = [ (k, [ r | r <- rs, key r == k ]) | k <- nub (map key rs) ]
  where
    key r = (r.datasetName, r.datasetVersion)

runGroup :: Model -> [RunSummaryDto] -> ((Text, Int), [RunSummaryDto]) -> View Model Action
runGroup m allRs ((dn, dv), rs) =
  section_ [ P.class_ "run-group" ]
    [ h2_ [] [ text (ms dn <> " · v" <> msShow dv) ]
    , table_ []
        [ thead_ [] [ tr_ [] (map thTxt [ "run", "target", "status", "started", "metrics", "" ]) ]
        , tbody_ [] (map (runRow m allRs) rs) ] ]

runRow :: Model -> [RunSummaryDto] -> RunSummaryDto -> View Model Action
runRow m allRs r =
  tr_ [ P.class_ "clickable", onClick (Navigate (runHash r.runId)) ]
    [ td_ [ P.class_ "key" ] [ text ("#" <> msShow r.runId) ]
    , td_ [] [ text (targetLabel r) ]
    , td_ [] [ statusChip r.status ]
    , td_ [] [ text (fmtMaybeTime r.startedAt) ]
    , td_ [ P.class_ "metrics" ] (map metricChip r.metrics)
    , td_ [ P.class_ "row-menu" ] [ compareMenu m allRs r ]
    ]

compareMenu :: Model -> [RunSummaryDto] -> RunSummaryDto -> View Model Action
compareMenu m allRs r =
  span_ [ P.class_ "menu-wrap" ]
    ( a_ [ P.class_ "kebab"
         , onClickWithOptions (Options { _preventDefault = True, _stopPropagation = True })
             (ToggleCompareMenu (if _compareMenuM m == Just r.runId then Nothing else Just r.runId)) ]
        [ text "\8942" ]   -- ⋮
    : [ dropdown | _compareMenuM m == Just r.runId ] )
  where
    sibs = [ o | o <- allRs, o.runId /= r.runId, o.datasetVersionId == r.datasetVersionId ]
    dropdown = div_ [ P.class_ "menu" ]
      ( div_ [ P.class_ "menu-head" ] [ text ("compare #" <> msShow r.runId <> " with") ]
      : if null sibs
          then [ div_ [ P.class_ "menu-empty" ] [ text "no comparable runs" ] ]
          else map item sibs )
    item o = a_ [ P.class_ "menu-item"
                , onClickWithOptions (Options { _preventDefault = True, _stopPropagation = True })
                    (Navigate (compareHash r.runId o.runId)) ]
               [ text ("#" <> msShow o.runId)
               , span_ [ P.class_ "muted" ] [ text (" · " <> fmtMaybeTime o.startedAt) ] ]

-- Run detail ------------------------------------------------------------------

detailView :: Model -> Int -> View Model Action
detailView m _ =
  remoteView (_detailM m) $ \d ->
    let graders = d.run.metrics
        tabKey mc = ms mc.graderName <> "v" <> msShow mc.graderVersion
        active = _runTabM m
        tabs = ("Examples", "examples", active == "examples")
             : [ (ms mc.graderName, tabKey mc, active == tabKey mc) | mc <- graders ]
        content
          | active == "examples" =
              div_ []
                ( outputsTable d.run.runId (_expandedM m) d.run.metrics d.outputs
                : [ pager (_outputsOffsetM m) d.totalOutputs | d.totalOutputs > outputsPageSize ] )
          | otherwise = case [ mc | mc <- graders, tabKey mc == active ] of
              (mc : _) -> graderTabPanel d mc
              []       -> outputsTable d.run.runId (_expandedM m) d.run.metrics d.outputs
    in div_ [ P.class_ "detail" ]
         [ breadcrumb [ orgCrumb m, ("runs", Just runsHash), ("run #" <> msShow d.run.runId, Nothing) ]
         , runHeader d.run
         , detailTabBar tabs
         , content ]

detailTabBar :: [(MisoString, MisoString, Bool)] -> View Model Action
detailTabBar tabs = div_ [ P.class_ "tabbar" ] (map one tabs)
  where one (label, key, active) =
          a_ [ P.class_ ("tab" <> if active then " active" else ""), onClick (SetRunTab key) ] [ text label ]

graderTabPanel :: RunDetailDto -> MetricDto -> View Model Action
graderTabPanel d mc =
  div_ [ P.class_ "grader-tab" ]
    ( graderDetailSection mc
    : [ calibCard s | s <- d.calibration, s.graderName == mc.graderName, s.graderVersion == mc.graderVersion ] )

runHeader :: RunSummaryDto -> View Model Action
runHeader r =
  div_ [ P.class_ "run-header" ]
    [ h2_ [] [ text ("run #" <> msShow r.runId <> " — " <> ms r.datasetName <> " · v" <> msShow r.datasetVersion) ]
    , div_ [ P.class_ "meta" ]
        [ span_ [] [ text (targetLabel r) ]
        , statusChip r.status
        , span_ [] [ text ("started " <> fmtMaybeTime r.startedAt <> " · finished " <> fmtMaybeTime r.finishedAt) ] ] ]

outputsTable :: Int -> [MisoString] -> [MetricDto] -> [OutputRowDto] -> View Model Action
outputsTable rid expandedKeys metrics outputs =
  table_
    [ P.class_ "outputs" ]
    [ thead_ [] [ tr_ [] (map thTxt ([ "example", "output", "latency ms" ] <> map graderHeading gs)) ]
    , tbody_ [] (map row outputs)
    , tfoot_ [] [ tr_ [ P.class_ "means" ]
        ( td_ [ P.class_ "mean-lab" ] [ text "mean" ] : td_ [] [] : td_ [] []
          : [ td_ [ P.class_ "score" ] [ text (meanFor g) ] | g <- gs ] ) ]
    ]
  where
    -- Columns come from the run's metrics, NOT the current page's scores, so
    -- they stay stable as the user pages through outputs.
    gs = nub [ (m.graderName, m.graderVersion) | m <- metrics ]
    graderHeading (g, v) = ms g <> " v" <> msShow v
    meanFor (g, v) = case [ m | m <- metrics, m.graderName == g, m.graderVersion == v ] of
      (m : _) -> fmtD m.mean
      []      -> "–"
    row o =
      tr_
        [ P.class_ (if isJust o.outputError then "error-row" else "") ]
        ( td_ [ P.class_ "key" ] [ a_ [ P.href_ (exampleHash rid o.exampleKey) ] [ text (ms o.exampleKey) ] ]
        : outputCell expandedKeys ("d:" <> ms o.exampleKey) o.outputText o.outputError
        : td_ [] [ text (maybe "–" msShow o.latencyMs) ]
        : [ scoreCell (lookupScore g o.scores) | g <- gs ]
        )
    lookupScore (g, v) ss =
      case [ s | s <- ss, s.graderName == g, s.graderVersion == v ] of
        (s : _) -> Just s
        [] -> Nothing

-- | Prev/next pager for the run-detail Examples table. @off@ is the current
-- page offset, @total@ the full output count. Buttons disable at the ends.
pager :: Int -> Int -> View Model Action
pager off total =
  div_ [ P.class_ "pager" ]
    [ pagerBtn "\8249 Prev" (off <= 0) (SetOutputsOffset (max 0 (off - outputsPageSize)))
    , span_ [ P.class_ "pager-label" ] [ text label ]
    , pagerBtn "Next \8250" (off + outputsPageSize >= total) (SetOutputsOffset (off + outputsPageSize))
    ]
  where
    lo = if total == 0 then 0 else off + 1
    hi = min (off + outputsPageSize) total
    label = "showing " <> msShow lo <> "–" <> msShow hi <> " of " <> msShow total
    pagerBtn lbl disabled act
      | disabled  = span_ [ P.class_ "pager-btn disabled" ] [ text lbl ]
      | otherwise = a_   [ P.class_ "pager-btn", onClick act ] [ text lbl ]

scoreCell :: Maybe ScoreDto -> View Model Action
scoreCell Nothing = td_ [] [ text "–" ]
scoreCell (Just s) =
  case s.scoreError of
    Just e -> td_ [ P.class_ "score-error" ] [ text ("⚠ " <> ms e) ]
    Nothing ->
      td_
        (P.class_ "score" : maybe [] (\rt -> [ P.title_ (ms rt) ]) s.rationale)
        [ text (maybe "–" fmtD s.value)
        , passMark s.passed
        ]

passMark :: Maybe Bool -> View Model Action
passMark (Just True) = span_ [ P.class_ "mark ok" ] [ text " ✓" ]
passMark (Just False) = span_ [ P.class_ "mark fail" ] [ text " ✗" ]
passMark Nothing = text ""

-- | An output cell: error variant (red), or full text CSS-truncated via
-- @.truncate@ — clicking toggles @.expanded@; the @title@ always carries the
-- full text.
outputCell :: [MisoString] -> MisoString -> Maybe Text -> Maybe Text -> View Model Action
outputCell expandedKeys k mtext merr =
  case merr of
    Just e -> td_ [ P.class_ "out cell-error" ] [ text (ms e) ]
    Nothing ->
      let full = ms (fromMaybe "" mtext)
          cls = if k `elem` expandedKeys then "out expanded" else "out truncate"
      in td_ [ P.class_ cls, P.title_ full, onClick (ToggleExpand k) ] [ text full ]

-- Example inspector -------------------------------------------------------------

exampleView :: Model -> Int -> Text -> View Model Action
exampleView m _ _ =
  remoteView (_exampleM m) $ \d ->
    let humanByCrit = [ (l.criterion, l.human) | l <- d.labels ] in
    div_ [ P.class_ "example" ]
      [ breadcrumb [ orgCrumb m, ("runs", Just runsHash)
                   , ("run #" <> msShow d.runId, Just (runHash d.runId))
                   , (ms d.exampleKey, Nothing) ]
      , div_ [ P.class_ "ex-card" ]
          [ div_ [ P.class_ "ex-head" ]
              [ h2_ [] [ text ("example " <> ms d.exampleKey) ]
              , div_ [ P.class_ "ex-nav" ]
                  [ navBtn "\8592 prev" (fmap (exampleHash d.runId) d.prevKey)
                  , navBtn "next \8594" (fmap (exampleHash d.runId) d.nextKey) ] ]
          , div_ [ P.class_ "ex-cols" ]
              [ div_ [ P.class_ "ex-main" ]
                  [ exSection "Input" [ pre_ [ P.class_ "io" ] [ text (renderJson d.input) ] ]
                  , exSection "Generated prompt" (map promptMsg d.prompt)
                  , exSection "Response" [ responseBlock d.responseText d.responseError ] ]
              , div_ [ P.class_ "ex-side" ]
                  [ exSection "Grades"
                      (  map (gradeBlock humanByCrit) d.grades
                      ++ map labelBlock d.labels
                      ++ map judgeErrorBlock d.judgeErrors ) ] ] ] ]
  where
    exSection title kids = div_ [ P.class_ "ex-section" ] (h3_ [] [ text title ] : kids)
    navBtn label Nothing     = span_ [ P.class_ "ex-navbtn disabled" ] [ text label ]
    navBtn label (Just href) = a_ [ P.class_ "ex-navbtn", P.href_ href ] [ text label ]

-- | Pretty-print a JSON value with 2-space indentation. Scalars are encoded
-- via aeson (correct escaping); objects/arrays are hand-indented.
renderJson :: Value -> MisoString
renderJson = ms . go 0
  where
    ind n = T.replicate n "  "
    enc   = LT.toStrict . encodeToLazyText
    go _ (Object o) | KM.null o = "{}"
    go n (Object o) =
      "{\n"
        <> T.intercalate ",\n"
             [ ind (n + 1) <> enc (String (AK.toText k)) <> ": " <> go (n + 1) v | (k, v) <- KM.toList o ]
        <> "\n" <> ind n <> "}"
    go _ (Array a) | null a = "[]"
    go n (Array a) =
      "[\n"
        <> T.intercalate ",\n" [ ind (n + 1) <> go (n + 1) v | v <- toList a ]
        <> "\n" <> ind n <> "]"
    go _ v = enc v

promptMsg :: PromptMsgDto -> View Model Action
promptMsg p =
  div_ [ P.class_ ("msg " <> ms p.role) ]
    [ span_ [ P.class_ "role" ] [ text (ms p.role) ]
    , pre_ [ P.class_ "content" ] [ text (ms p.content) ] ]

responseBlock :: Maybe Text -> Maybe Text -> View Model Action
responseBlock _ (Just e)       = div_ [ P.class_ "cell-error" ] [ text (ms e) ]
responseBlock (Just t) Nothing = pre_ [ P.class_ "io" ] [ text (ms t) ]
responseBlock Nothing Nothing  = div_ [ P.class_ "muted" ] [ text "–" ]

-- | A model grade. @humanByCrit@ maps a criterion to its human gold verdict
-- (from this example's consensus labels); when a criterion is labelled, the
-- judge's verdict gets an "agrees / disagrees" badge — the per-example
-- calibration signal.
gradeBlock :: [(Text, Bool)] -> GradeDto -> View Model Action
gradeBlock humanByCrit g =
  div_ [ P.class_ "grade" ]
    ( div_ [ P.class_ "grade-head" ]
        [ strong_ [] [ text (ms g.graderName) ], text (" v" <> msShow g.graderVersion)
        , span_ [ P.class_ "kind" ] [ text (ms g.graderKind) ]
        , span_ [ P.class_ "gval" ] [ text (maybe "–" fmtD g.value), passMark g.passed ] ]
      : [ verdictRow c | c <- g.criteria ]
      ++ [ div_ [ P.class_ "cell-error" ] [ text ("⚠ " <> ms e) ] | Just e <- [g.gradeError] ]
      ++ [ div_ [ P.class_ "muted" ] [ text (ms r) ] | Just r <- [g.rationale] ] )
  where
    -- Stacked layout: a wrapping pill row (verdict · agreement · tags · points)
    -- sits ABOVE the full-width criterion prose. The HealthBench category tags
    -- are long, so a grid column for them overflows the narrow side panel.
    verdictRow c =
      div_ [ P.class_ "vrow" ]
        ( div_ [ P.class_ "vrow-pills" ]
            ( span_ [ P.class_ (if c.met then "m ok" else "m fail") ] [ text (if c.met then "✓" else "✗") ]
            : agreeBadge c
            ++ [ span_ [ P.class_ "tag" ] [ text (ms t) ] | t <- c.tags ]
            ++ [ span_ [ P.class_ "earn" ] [ text (if c.met then "+" <> fmtD c.points else "0 / " <> fmtD c.points) ] ] )
        : div_ [ P.class_ "crit-text" ] [ text (ms c.criterion) ]
        : [ div_ [ P.class_ "why" ] [ text (ms c.explanation) ] | not (T.null c.explanation) ] )
    agreeBadge c = case lookup c.criterion humanByCrit of
      Nothing -> []
      Just h  -> let agrees = h == c.met
                 in [ span_ [ P.class_ ("agree " <> if agrees then "ok" else "fail") ]
                        [ text (if agrees then "agrees" else "disagrees") ] ]

-- | A human consensus label: a verdict-chip header tagged "human consensus"
-- (so it reads as ground truth, not a model grade) over the criterion text.
-- Same card/padding as 'gradeBlock'; the criterion is pre-wrapped so its
-- rubric bullets keep their line breaks.
labelBlock :: CriterionLabelDto -> View Model Action
labelBlock l =
  div_ [ P.class_ "grade label" ]
    [ div_ [ P.class_ "grade-head" ]
        ( span_ [ P.class_ (if l.human then "m ok" else "m fail") ] [ text (if l.human then "✓" else "✗") ]
        : strong_ [] [ text "human consensus" ]
        : [ span_ [ P.class_ "src" ] [ text (ms s) ] | Just s <- [l.source] ] )
    , div_ [ P.class_ "crit-text" ] [ text (ms l.criterion) ] ]

-- | A judge that errored on this example during meta-eval. Same card as a
-- grade so it lines up with the blocks above it.
judgeErrorBlock :: JudgeErrorDto -> View Model Action
judgeErrorBlock j =
  div_ [ P.class_ "grade judge-err" ]
    [ div_ [ P.class_ "grade-head" ]
        [ span_ [ P.class_ "m warn" ] [ text "\9888" ]
        , strong_ [] [ text (ms j.graderName <> " v" <> msShow j.graderVersion) ]
        , span_ [ P.class_ "src" ] [ text "couldn't judge" ] ]
    , div_ [ P.class_ "crit-text muted" ] [ text (ms j.criterion) ] ]

-- Compare -----------------------------------------------------------------------

compareView :: Model -> Int -> Int -> View Model Action
compareView m a b =
  remoteView (_compareM m) $ \c ->
    div_
      [ P.class_ "compare" ]
      [ breadcrumb [ orgCrumb m, ("runs", Just runsHash), ("compare #" <> msShow a <> " \215 #" <> msShow b, Nothing) ]
      , div_ [ P.class_ "cards" ] [ runCard "A" c.runA, runCard "B" c.runB ]
      , div_
          [ P.class_ "grader-line" ]
          [ text $ case (c.graderName, c.graderVersion) of
              (Just g, Just v) -> "compared grader: " <> ms g <> " v" <> msShow v
              _ -> "no scores"
          ]
      , compareTable (_expandedM m) c.rows
      ]

runCard :: MisoString -> RunSummaryDto -> View Model Action
runCard label r =
  div_
    [ P.class_ "card" ]
    [ h3_ [] [ text (label <> " · run #" <> msShow r.runId) ]
    , div_ [] [ text (targetLabel r) ]
    , div_ [ P.class_ "metrics" ] (map metricChip r.metrics)
    ]

compareTable :: [MisoString] -> [CompareRowDto] -> View Model Action
compareTable expandedKeys rows_ =
  table_
    [ P.class_ "compare-table" ]
    [ thead_ [] [ tr_ [] (map thTxt [ "example", "A output", "B output", "A score", "B score", "delta" ]) ]
    , tbody_ [] (map row rows_)
    ]
  where
    row cr =
      tr_
        [ P.class_ (if disagree cr then "disagree" else "") ]
        [ td_ [ P.class_ "key" ] [ text (ms cr.exampleKey) ]
        , outputCell expandedKeys ("A:" <> ms cr.exampleKey) cr.outputA cr.errorA
        , outputCell expandedKeys ("B:" <> ms cr.exampleKey) cr.outputB cr.errorB
        , scoreValueCell cr.scoreA cr.passedA
        , scoreValueCell cr.scoreB cr.passedB
        , deltaCell cr.delta
        ]
    disagree cr = case (cr.passedA, cr.passedB) of
      (Just x, Just y) -> x /= y
      _ -> False

scoreValueCell :: Maybe Double -> Maybe Bool -> View Model Action
scoreValueCell v p = td_ [ P.class_ "score" ] [ text (maybe "–" fmtD v), passMark p ]

deltaCell :: Maybe Double -> View Model Action
deltaCell Nothing = td_ [] [ text "–" ]
deltaCell (Just d) = td_ [ P.class_ cls ] [ text txt ]
  where
    cls
      | d > 0 = "delta pos"
      | d < 0 = "delta neg"
      | otherwise = "delta"
    txt = (if d > 0 then "+" else "") <> fmtD d

-- Shared bits ----------------------------------------------------------------------

targetLabel :: RunSummaryDto -> MisoString
targetLabel r = ms r.targetName <> " v" <> msShow r.targetVersion <> " · " <> ms r.model

statusChip :: Text -> View Model Action
statusChip s = span_ [ P.class_ ("chip " <> cls) ] [ text (ms s) ]
  where
    cls = case s of
      "succeeded" -> "ok"
      "failed" -> "fail"
      _ -> "muted"

metricChip :: MetricDto -> View Model Action
metricChip mc = span_ [ P.class_ "chip metric" ] [ text (chipText mc), kindTag mc.graderKind ]

kindTag :: Text -> View Model Action
kindTag k = span_ [ P.class_ "kind" ] [ text (ms k) ]

chipText :: MetricDto -> MisoString
chipText mc = ms mc.graderName <> " v" <> msShow mc.graderVersion
            <> " · μ " <> fmtD mc.mean <> ciTxt mc.stderr <> passTxt mc.passRate

-- | 95% CI half-width (1.96·stderr), blank when no stderr.
ciTxt :: Maybe Double -> MisoString
ciTxt = maybe "" (\s -> " ±" <> fmtD (1.96 * s))

passTxt :: Maybe Double -> MisoString
passTxt = maybe "" (\p -> " · pass " <> msShow (round (p * 100) :: Int) <> "%")

-- | Full-width run-level grader detail: a values sub-heading, the run's
-- distinct rubric criteria, and the charted breakdown.
graderDetailSection :: MetricDto -> View Model Action
graderDetailSection mc =
  div_ [ P.class_ "gdetail" ]
    ( div_ [ P.class_ "gdetail-head" ]
        [ strong_ [] [ text (ms mc.graderName) ], text (" v" <> msShow mc.graderVersion)
        , span_ [ P.class_ "kind big" ] [ text (ms mc.graderKind) ]
        , span_ [ P.class_ "gvals" ] [ text (valsLine mc) ]
        , span_ [ P.class_ "gdesc" ] [ text (methodLine mc.graderKind) ] ]
      : [ criteriaBlock mc.criteria | not (null mc.criteria) ]
      ++ [ breakdownChart mc | not (null mc.breakdowns) ]
      ++ [ span_ [ P.class_ "gnote" ] [ text "per-answer verdicts: open an example below" ]
         | mc.graderKind == "pointed" ] )

valsLine :: MetricDto -> MisoString
valsLine mc = "μ " <> fmtD mc.mean <> ciTxt mc.stderr <> passTxt mc.passRate

criteriaBlock :: [RubricCriterionDto] -> View Model Action
criteriaBlock cs =
  div_ [ P.class_ "criteria" ]
    ( div_ [ P.class_ "crit-cap" ] [ text ("what it checks · " <> msShow (length cs) <> " criteria") ]
      : map critRow cs )
  where
    critRow c =
      div_ [ P.class_ "crit" ]
        [ span_ [ P.class_ (if c.points < 0 then "pts neg" else "pts pos") ]
            [ text ((if c.points < 0 then "" else "+") <> fmtD c.points) ]
        , span_ [ P.class_ "crit-txt" ] [ text (ms c.criterion) ]
        , span_ [ P.class_ "crit-tags" ] (map tagChip c.tags) ]
    tagChip t = span_ [ P.class_ ("tag " <> ms (namespace t)) ] [ text (ms (labelOf t)) ]

methodLine :: Text -> MisoString
methodLine k = case k of
  "pointed"   -> "An LLM judges each criterion; score = points met ÷ points possible (partial credit, no pass/fail)."
  "exact"     -> "Compares the answer to the expected value — all-or-nothing."
  "rubric"    -> "An LLM judges the answer pass/fail against a rubric."
  "checklist" -> "A weighted yes/no checklist; score = the weighted fraction satisfied."
  _           -> "Scores each answer in this run."

-- | The tag breakdown as a labeled horizontal bar chart.
breakdownChart :: MetricDto -> View Model Action
breakdownChart mc =
  div_ [ P.class_ "chart" ]
    ( div_ [ P.class_ "chart-head" ]
        [ span_ [] [], span_ [] []
        , span_ [ P.class_ "r" ] [ text "score" ], span_ [ P.class_ "r" ] [ text "95% CI" ], span_ [ P.class_ "r" ] [ text "n" ] ]
      : concatMap grp nsOrder
      ++ [ div_ [ P.class_ "scale" ] [ span_ [] [], div_ [ P.class_ "ticks" ] [ span_ [] [text "0"], span_ [] [text "0.5"], span_ [] [text "1.0"] ], span_ [] [] ]
         , div_ [ P.class_ "legend" ] [ text "μ mean · ± 95% CI (bootstrap) · n = examples" ] ] )
  where
    nss     = nub (map (namespace . (.tag)) mc.breakdowns)
    known   = filter (`elem` nss) ["theme", "axis", "cluster"]
    nsOrder = known <> filter (`notElem` ["theme", "axis", "cluster"]) nss
    grp n   = div_ [ P.class_ "grp-label" ] [ text (ms n), span_ [ P.class_ "muted" ] [ text (nsHint n) ] ]
            : [ brow n b | b <- mc.breakdowns, namespace b.tag == n ]
    brow n b = div_ [ P.class_ ("brow " <> ms n) ]
      [ span_ [ P.class_ ("tag " <> ms n) ] [ text (ms (labelOf b.tag)) ]
      , div_ [ P.class_ "track" ] [ span_ [ widthStyle b.mean ] [] ]
      , span_ [ P.class_ "val" ] [ text (fmtD b.mean) ]
      , span_ [ P.class_ "ci" ]  [ text (ciCol b.stderr) ]
      , span_ [ P.class_ "n" ]   [ text (msShow b.count) ] ]

-- | One grader version's calibration: headline κ bar + verdict, sparkline,
-- and the secondary precision/recall/agreement line. Reused by the run-detail
-- section and (later) the cross-run view.
calibCard :: CalibrationSeriesDto -> View Model Action
calibCard s =
  div_ [ P.class_ "calib-card" ]
    [ div_ [ P.class_ "calib-head" ]
        [ span_ [ P.class_ "gname" ] [ text (ms s.graderName <> " v" <> msShow s.graderVersion) ]
        , span_ [ P.class_ ("kind " <> ms s.graderKind) ] [ text (ms s.graderKind) ]
        , span_ [ P.class_ "mode" ] [ text (ms s.mode) ]
        ]
    , kappaBar s.latest
    , div_ [ P.class_ "calib-f1" ]
        [ text ("balanced-F1 " <> fmtD s.latest.balancedF1
                <> " (met " <> fmtD s.latest.passF1
                <> " \183 not-met " <> fmtD s.latest.failF1 <> ")") ]
    , calibSpark s.trend
    , div_ [ P.class_ "calib-sub" ]
        [ text ("fail precision " <> fmtD s.latest.failPrecision
                <> " \183 fail recall " <> fmtD s.latest.failRecall
                <> " \183 agreement " <> pct s.latest.agreement
                <> " \183 n=" <> msShow s.latest.measured
                <> (if s.latest.judgeErrors > 0
                      then " \183 " <> msShow s.latest.judgeErrors <> " judge errors" else ""))
        ]
    , div_ [ P.class_ "calib-band" ]
        [ text ("\954 " <> fmtD s.latest.kappa <> " \8212 \8220" <> ms s.latest.band
                <> "\8221 on the Landis\8211Koch scale") ]
    ]

-- | κ value + 95% CI on a 0–1 track with a trust-threshold tick at 0.6 and a
-- verdict driven by the CI lower bound.
kappaBar :: MetaEvalDto -> View Model Action
kappaBar me =
  div_ [ P.class_ "calib-bar" ]
    [ div_ [ P.class_ "calib-track" ]
        [ span_ [ P.class_ "calib-ci", styleInline_ (ciStyle me.kappaLow me.kappaHigh) ] []
        , span_ [ P.class_ "calib-mark", styleInline_ ("left:" <> pct me.kappa) ] []
        , span_ [ P.class_ "calib-threshold", styleInline_ ("left:" <> pct 0.6) ] []
        ]
    , span_ [ P.class_ ("calib-verdict " <> if me.trusted then "trusted" else "untrusted") ]
        [ text ("\954 " <> fmtD me.kappa
                <> " (95% CI " <> fmtD me.kappaLow <> "\8211" <> fmtD me.kappaHigh <> ") \8212 "
                <> (if me.trusted then "trustworthy" else "below trust threshold")) ]
    ]

-- | Inline-SVG sparkline of κ over runs; current/latest point highlighted, a
-- faint line at the 0.6 threshold. Empty trend → nothing.
calibSpark :: [TrendPointDto] -> View Model Action
calibSpark [] = text ""
calibSpark pts =
  S.svg_ [ SP.viewBox_ "0 0 100 30", P.class_ "calib-spark" ]
    ( S.line_ [ SP.x1_ "0", SP.y1_ (ms (showD (yOf 0.6))), SP.x2_ "100", SP.y2_ (ms (showD (yOf 0.6))), P.class_ "thr" ]
    : S.polyline_ [ SP.points_ (ms polyPts), P.class_ "line" ]
    : [ S.circle_ [ SP.cx_ (ms (showD (xOf i))), SP.cy_ (ms (showD (yOf p.kappa)))
                  , SP.r_ (if p.isCurrent then "2.5" else "1.5")
                  , P.class_ (if p.isCurrent then "pt cur" else "pt") ]
      | (i, p) <- zip [0 :: Int ..] pts ] )
  where
    n      = length pts
    xOf i  = if n <= 1 then 50 else fromIntegral i / fromIntegral (n - 1) * 100 :: Double
    yOf k  = 30 - max 0 (min 1 k) * 30 :: Double   -- κ 0 at bottom, 1 at top
    polyPts = T.intercalate " " [ showD (xOf i) <> "," <> showD (yOf p.kappa) | (i, p) <- zip [0 ..] pts ]
    showD d = T.pack (showFFloat (Just 1) d "")

-- | Inline @left:..%;width:..%@ for the CI band span (clamped to [0,1]).
ciStyle :: Double -> Double -> MisoString
ciStyle lo hi =
  let l = max 0 (min 1 lo); h = max 0 (min 1 hi)
  in "left:" <> pct l <> ";width:" <> pct (max 0 (h - l))

-- | The #/calibration page: a teaching legend then one card per grader series.
calibrationView :: Model -> View Model Action
calibrationView m =
  remoteView (_calibrationM m) $ \ss ->
    div_ [ P.class_ "calib-page" ]
      ( breadcrumb [ orgCrumb m, ("runs", Just runsHash) ]
      : runsTabBar CalibrationR
      : div_ [ P.class_ "calib-legend" ] [ text "\954 measures judge\8211human agreement beyond chance; the 0.6 tick is the trust threshold." ]
      : if null ss then [ p_ [ P.class_ "empty" ] [ text "no calibration runs yet." ] ]
        else map calibCard ss )

nsHint :: Text -> MisoString
nsHint n = case n of
  "axis"  -> " — criteria, grouped by what they measure"
  "theme" -> " — each example's score, grouped by topic"
  _       -> ""

-- | CI column: "±X" (95% half-width) or an em-dash when no stderr.
ciCol :: Maybe Double -> MisoString
ciCol = maybe "—" (\s -> "±" <> fmtD (1.96 * s))

-- | "theme:cardiology" -> "theme"; no colon -> "".
namespace :: Text -> Text
namespace = T.takeWhile (/= ':')

-- | "theme:cardiology" -> "cardiology"; no colon -> the whole tag.
labelOf :: Text -> Text
labelOf t = case T.dropWhile (/= ':') t of
  "" -> t
  d  -> T.drop 1 d

-- | Inline @width:NN%@ style clamped to [0,100] for a bar fill.
widthStyle :: Double -> Attribute Action
widthStyle m = styleInline_ ("width:" <> pct m)

pct :: Double -> MisoString
pct m = msShow (max 0 (min 100 (round (m * 100) :: Int))) <> "%"

thTxt :: MisoString -> View Model Action
thTxt s = th_ [] [ text s ]

fmtD :: Double -> MisoString
fmtD d = ms (showFFloat (Just 3) d "")

fmtMaybeTime :: Maybe UTCTime -> MisoString
fmtMaybeTime = maybe "–" (ms . formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S")
