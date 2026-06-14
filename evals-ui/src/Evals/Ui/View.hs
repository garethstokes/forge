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
import Data.List (nub)
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
import Miso.String (MisoString, ms)

import Evals.Api
import Evals.Ui.Model

viewModel :: props -> Model -> View Model Action
viewModel _ m =
  div_
    [ P.class_ "app" ]
    [ header_
        [ P.class_ "topbar" ]
        [ h1_ [] [ a_ [ P.href_ runsHash ] [ text "manifest evals" ] ]
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
      , runHeader (_expandedM m) d.run
      , outputsTable d.run.runId (_expandedM m) d.run.metrics d.outputs
      ]

runHeader :: [MisoString] -> RunSummaryDto -> View Model Action
runHeader _ r =
  div_
    [ P.class_ "run-header" ]
    [ h2_ [] [ text ("run #" <> msShow r.runId <> " — " <> ms r.datasetName <> " · v" <> msShow r.datasetVersion) ]
    , div_
        [ P.class_ "meta" ]
        [ span_ [] [ text (targetLabel r) ]
        , statusChip r.status
        , span_ [] [ text ("started " <> fmtMaybeTime r.startedAt <> " · finished " <> fmtMaybeTime r.finishedAt) ]
        ]
    , div_ [ P.class_ "grader-details" ] (map graderDetailSection r.metrics)
    ]

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
    gs = nub [ (s.graderName, s.graderVersion) | o <- outputs, s <- o.scores ]
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
    div_ [ P.class_ "example" ]
      [ a_ [ P.href_ (runHash d.runId), P.class_ "back" ] [ text "← run" ]
      , div_ [ P.class_ "ex-card" ]
          [ h2_ [] [ text ("example " <> ms d.exampleKey) ]
          , div_ [ P.class_ "ex-cols" ]
              [ div_ [ P.class_ "ex-main" ]
                  [ exSection "Input" [ pre_ [ P.class_ "io" ] [ text (renderJson d.input) ] ]
                  , exSection "Generated prompt" (map promptMsg d.prompt)
                  , exSection "Response" [ responseBlock d.responseText d.responseError ]
                  ]
              , div_ [ P.class_ "ex-side" ]
                  [ exSection "Grades" (map gradeBlock d.grades) ]
              ]
          ]
      ]
  where
    exSection title kids = div_ [ P.class_ "ex-section" ] (h3_ [] [ text title ] : kids)

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

gradeBlock :: GradeDto -> View Model Action
gradeBlock g =
  div_ [ P.class_ "grade" ]
    ( div_ [ P.class_ "grade-head" ]
        [ strong_ [] [ text (ms g.graderName) ], text (" v" <> msShow g.graderVersion)
        , span_ [ P.class_ "kind" ] [ text (ms g.graderKind) ]
        , span_ [ P.class_ "gval" ] [ text (maybe "–" fmtD g.value), passMark g.passed ] ]
      : [ verdictRow c | c <- g.criteria ]
      ++ [ div_ [ P.class_ "cell-error" ] [ text ("⚠ " <> ms e) ] | Just e <- [g.gradeError] ]
      ++ [ div_ [ P.class_ "muted" ] [ text (ms r) ] | Just r <- [g.rationale] ] )
  where
    verdictRow c =
      div_ [ P.class_ "cr" ]
        [ span_ [ P.class_ (if c.met then "m ok" else "m fail") ] [ text (if c.met then "✓" else "✗") ]
        , span_ [ P.class_ "ctxt" ] [ text (ms c.criterion), span_ [ P.class_ "why" ] [ text (ms c.explanation) ] ]
        , span_ [ P.class_ "crit-tags" ] [ span_ [ P.class_ "tag" ] [ text (ms t) ] | t <- c.tags ]
        , span_ [ P.class_ "earn" ] [ text (if c.met then "+" <> fmtD c.points else "0 / " <> fmtD c.points) ] ]

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
