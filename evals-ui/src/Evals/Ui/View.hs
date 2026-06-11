{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Plain @Model -> View Action@ functions for the three routes. DTO fields
-- are accessed with record-dot syntax ("Evals.Api" uses DuplicateRecordFields).
module Evals.Ui.View (viewModel) where

import Data.List (nub)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Numeric (showFFloat)

import Miso (View, text)
import Miso.Event.Types (Options (..))
import Miso.Html
import qualified Miso.Html.Property as P
import Miso.String (MisoString, ms)

import Evals.Api
import Evals.Ui.Model

viewModel :: props -> Model -> View Model Action
viewModel _ m =
  div_
    [ P.class_ "app" ]
    [ header_
        [ P.class_ "topbar" ]
        [ h1_ [] [ a_ [ P.href_ runsHash ] [ text "manifest evals" ] ] ]
    , main_ [ P.class_ "content" ] [ body ]
    ]
  where
    body = case _routeM m of
      RunsR -> runsView m
      RunR i -> detailView m i
      CompareR a b -> compareView m a b

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

-- Runs list -------------------------------------------------------------------

runsView :: Model -> View Model Action
runsView m =
  remoteView (_runsM m) $ \rs ->
    div_ [] (compareBar m rs : map (runGroup m) (groupRuns rs))

-- | Group runs under (datasetName, datasetVersion) headings, first-seen
-- order (the API returns newest first).
groupRuns :: [RunSummaryDto] -> [((Text, Int), [RunSummaryDto])]
groupRuns rs = [ (k, [ r | r <- rs, key r == k ]) | k <- nub (map key rs) ]
  where
    key r = (r.datasetName, r.datasetVersion)

runGroup :: Model -> ((Text, Int), [RunSummaryDto]) -> View Model Action
runGroup m ((dn, dv), rs) =
  section_
    [ P.class_ "run-group" ]
    [ h2_ [] [ text (ms dn <> " · v" <> msShow dv) ]
    , table_
        []
        [ thead_ [] [ tr_ [] (map thTxt [ "run", "target", "status", "started", "metrics", "compare" ]) ]
        , tbody_ [] (map (runRow m) rs)
        ]
    ]

runRow :: Model -> RunSummaryDto -> View Model Action
runRow m r =
  tr_
    [ P.class_ "clickable", onClick (Navigate (runHash r.runId)) ]
    [ td_ [ P.class_ "key" ] [ text ("#" <> msShow r.runId) ]
    , td_ [] [ text (targetLabel r) ]
    , td_ [] [ statusChip r.status ]
    , td_ [] [ text (fmtMaybeTime r.startedAt) ]
    , td_ [ P.class_ "metrics" ] (map metricChip r.metrics)
    , td_ [ P.class_ "pick" ]
        [ input_
            [ P.type_ "checkbox"
            , P.checked_ (r.runId `elem` _selectedM m)
              -- fully controlled checkbox: prevent the native toggle (the
              -- model decides, e.g. a third tick is ignored) and stop the
              -- click from bubbling into the row's navigate handler
            , onClickWithOptions
                (Options { _preventDefault = True, _stopPropagation = True })
                (ToggleSelect r.runId)
            ]
        ]
    ]

compareBar :: Model -> [RunSummaryDto] -> View Model Action
compareBar m rs =
  div_ [ P.class_ "comparebar" ] $
    -- filter to ids that are actually present in the current run list; a
    -- ghost id (not in rs) is treated as not-selected rather than showing a
    -- misleading version-mismatch hint
    case filter (\i -> any (\r -> r.runId == i) rs) (_selectedM m) of
      [a, b]
        | sameVersion a b ->
            [ hint "2 runs selected"
            , button_
                [ P.class_ "compare-btn", onClick (Navigate (compareHash a b)) ]
                [ text "Compare" ]
            ]
        | otherwise ->
            [ hint "selected runs are from different dataset versions — pick two from the same group"
            , button_ [ P.class_ "compare-btn", P.disabled_ ] [ text "Compare" ]
            ]
      [_] -> [ hint "tick one more run (same dataset version) to compare" ]
      _ -> [ hint "tick two runs to compare them" ]
  where
    hint t = span_ [ P.class_ "hint" ] [ text t ]
    dvOf i = [ r.datasetVersionId | r <- rs, r.runId == i ]
    sameVersion a b = case (dvOf a, dvOf b) of
      ([x], [y]) -> x == y
      _ -> False

-- Run detail ------------------------------------------------------------------

detailView :: Model -> Int -> View Model Action
detailView m _ =
  remoteView (_detailM m) $ \d ->
    div_
      [ P.class_ "detail" ]
      [ backLink
      , runHeader d.run
      , outputsTable (_expandedM m) d.outputs
      ]

runHeader :: RunSummaryDto -> View Model Action
runHeader r =
  div_
    [ P.class_ "run-header" ]
    [ h2_ [] [ text ("run #" <> msShow r.runId <> " — " <> ms r.datasetName <> " · v" <> msShow r.datasetVersion) ]
    , div_
        [ P.class_ "meta" ]
        [ span_ [] [ text (targetLabel r) ]
        , statusChip r.status
        , span_ [] [ text ("started " <> fmtMaybeTime r.startedAt <> " · finished " <> fmtMaybeTime r.finishedAt) ]
        ]
    , div_ [ P.class_ "metrics" ] (map metricChip r.metrics)
    ]

outputsTable :: [MisoString] -> [OutputRowDto] -> View Model Action
outputsTable expandedKeys outputs =
  table_
    [ P.class_ "outputs" ]
    [ thead_ [] [ tr_ [] (map thTxt ([ "example", "output", "latency ms" ] <> map graderHeading gs)) ]
    , tbody_ [] (map row outputs)
    ]
  where
    gs = nub [ (s.graderName, s.graderVersion) | o <- outputs, s <- o.scores ]
    graderHeading (g, v) = ms g <> " v" <> msShow v
    row o =
      tr_
        [ P.class_ (if isJust o.outputError then "error-row" else "") ]
        ( td_ [ P.class_ "key" ] [ text (ms o.exampleKey) ]
        : outputCell expandedKeys ("d:" <> ms o.exampleKey) o.outputText o.outputError
        : td_ [] [ text (maybe "–" msShow o.latencyMs) ]
        : [ scoreCell (lookupScore g o.scores) | g <- gs ]
        )
    lookupScore (g, v) ss =
      case [ s | s <- ss, s.graderName == g, s.graderVersion == v ] of
        (s : _) -> Just s
        [] -> Nothing

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

-- Compare -----------------------------------------------------------------------

compareView :: Model -> Int -> Int -> View Model Action
compareView m _ _ =
  remoteView (_compareM m) $ \c ->
    div_
      [ P.class_ "compare" ]
      [ backLink
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

backLink :: View Model Action
backLink = a_ [ P.href_ runsHash, P.class_ "back" ] [ text "← runs" ]

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
metricChip mc =
  span_
    [ P.class_ "chip metric" ]
    [ text (ms mc.graderName <> " v" <> msShow mc.graderVersion <> " · μ " <> fmtD mc.mean <> passTxt) ]
  where
    passTxt = maybe "" (\p -> " · pass " <> msShow (round (p * 100) :: Int) <> "%") mc.passRate

thTxt :: MisoString -> View Model Action
thTxt s = th_ [] [ text s ]

fmtD :: Double -> MisoString
fmtD d = ms (showFFloat (Just 3) d "")

fmtMaybeTime :: Maybe UTCTime -> MisoString
fmtMaybeTime = maybe "–" (ms . formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S")
