{-# LANGUAGE CPP                 #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}

-- | The evals dashboard SPA: a miso 1.11 component compiled as a wasm32-wasi
-- browser reactor (see evals-ui/zinc.toml wasm-exports). Routes live in the
-- location hash; each route entry kicks a same-origin JSON fetch. An SSE
-- change feed (@/api/events@) triggers debounced refetches of the current
-- route, so the dashboard tracks the database live.
module Main where

import Control.Monad (when)
import Data.Aeson (eitherDecodeStrictText)
import Data.Text (Text)

import Miso
import Miso.Lens ((%=), (.=), use)
import qualified Miso.EventSource as SSE
import Miso.String (fromMisoString, ms)

import Evals.Api (ChangeDto (..))
import Evals.Ui.Fetch (fetchJson, getHash, getOrgPrefix, setHash, setTimeout)
import Evals.Ui.Model
import Evals.Ui.View (viewModel)

-- | Entry point for the miso application
main :: IO ()
main = startApp defaultEvents app

-- | WASM export, required when compiling with the GHC WASM backend.
#ifdef wasm32_HOST_ARCH
foreign export javascript "hs_start" main :: IO ()
#endif

app :: App Model Action
app =
  (component emptyModel updateModel viewModel)
    { subs = [ windowSub "hashchange" emptyDecoder (\() -> HashChanged) ]
      -- connect the SSE feed and parse the initial hash once mounted
    , mount = Just Startup
    }

updateModel :: Action -> Effect parent props Model Action
updateModel = \case
  Startup -> do
    -- Read the org prefix in IO, then dispatch ConnectSse to wire up the SSE
    -- feed at the correct prefixed URL (Effect cannot sequence IO results, so
    -- we use 'io' to lift the prefix read into an action).
    io (ConnectSse <$> getOrgPrefix)
    io (SetOrgSlug <$> getOrgPrefix)
    updateModel HashChanged
  ConnectSse prefix -> do
    -- connect once; the browser EventSource auto-reconnects on failure, so
    -- SseOpen/SseError only reflect status (no reconnect logic of our own)
    SSE.connectText (prefix <> "/api/events") (const SseOpen) SseMessage (const SseError)
  HashChanged ->
    io (SetRoute . parseHash <$> getHash)
  SetRoute r -> do
    routeL .= r
    compareMenuL .= Nothing
    case r of
      RunsR ->
        runsL .= Loading
      RunR _ -> do
        detailL .= Loading
        expandedL .= []
        runTabL .= "examples"
        outputsOffsetL .= 0  -- start each run at the first Examples page
      CompareR _ _ -> do
        compareL .= Loading
        expandedL .= []
      ExampleR _ _ -> do
        exampleL .= Loading
        expandedL .= []
      CalibrationR ->
        calibrationL .= Loading
    fetchRoute r
  Navigate h ->
    io_ (setHash h)
  SetOrgSlug s ->
    orgSlugL .= s
  SetRunTab t ->
    runTabL .= t
  SetOutputsOffset n -> do
    outputsOffsetL .= n
    -- silent refetch of the current run detail at the new page offset
    fetchRoute =<< use routeL
  SetGradeVersion name ver ->
    gradeVerL %= \xs -> (name, ver) : filter ((/= name) . fst) xs
  ToggleCompareMenu mi ->
    compareMenuL .= mi
  ToggleExpand k ->
    expandedL %= toggleElem k
  GotRuns e ->
    runsL %= \old -> keepStale old (fromEither e)
  GotDetail rid e -> do
    -- stale-response guard: commit only when the response matches the current route
    route <- use routeL
    case route of
      RunR i | i == rid -> detailL %= \old -> keepStale old (fromEither e)
      _ -> pure ()  -- response arrived after navigation away; drop it
  GotCompare ra rb e -> do
    -- stale-response guard: commit only when both ids match the current route
    route <- use routeL
    case route of
      CompareR a b | a == ra, b == rb -> compareL %= \old -> keepStale old (fromEither e)
      _ -> pure ()  -- response arrived after navigation away; drop it
  GotExample rid k e -> do
    route <- use routeL
    case route of
      ExampleR i kk | i == rid, kk == k -> exampleL %= \old -> keepStale old (fromEither e)
      _ -> pure ()
  GotCalibration e ->
    calibrationL %= \old -> keepStale old (fromEither e)
  SseOpen -> do
    -- Track whether this is the very first connect or a genuine reconnect.
    -- On the first connect SetRoute has already issued a fetch, so we must NOT
    -- refetch (duplicate). On every subsequent connect (browser EventSource
    -- auto-reconnect after a drop) we MAY have missed change events, so we DO
    -- refetch regardless of the current RemoteData state — including deep-linked
    -- detail routes where _runsM stays NotAsked.
    firstTime <- not <$> use sseConnectedOnceL
    sseConnectedOnceL .= True
    liveL .= LiveConnected
    when (not firstTime) (issue DoRefetch)
  SseError ->
    liveL .= LiveReconnecting
  SseMessage raw ->
    -- aeson-decode the change-feed line; anything undecodable is ignored
    case eitherDecodeStrictText (fromMisoString raw :: Text) of
      Right c -> issue (GotChange c)
      Left _ -> pure ()
  GotChange c -> do
    -- debounce: first relevant change schedules a refetch 300ms out; further
    -- changes coalesce into it. Route changes do NOT clear the queue — an
    -- in-flight debounce simply refetches the new route, which is harmless.
    route <- use routeL
    queued <- use refetchQueuedL
    when (relevantTo route (ms c.table) && not queued) $ do
      refetchQueuedL .= True
      withSink $ \sink -> setTimeout 300 (sink DoRefetch)
  DoRefetch -> do
    refetchQueuedL .= False
    -- silent background refresh: no Loading flash, no expanded reset; the
    -- stale-response guards on GotDetail/GotCompare make races safe
    fetchRoute =<< use routeL

-- | The fetch a route's entry kicks — shared by 'SetRoute' (which also resets
-- to Loading) and 'DoRefetch' (which refreshes silently in the background).
fetchRoute :: Route -> Effect parent props Model Action
fetchRoute = \case
  RunsR ->
    fetchJson "/api/runs" GotRuns
  RunR i -> do
    off <- use outputsOffsetL
    fetchJson ("/api/runs/" <> msShow i
               <> "?offset=" <> msShow off
               <> "&limit=" <> msShow outputsPageSize) (GotDetail i)
  CompareR a b ->
    fetchJson ("/api/compare?a=" <> msShow a <> "&b=" <> msShow b) (GotCompare a b)
  ExampleR i k ->
    fetchJson ("/api/runs/" <> msShow i <> "/ex/" <> ms (encodeSegment k)) (GotExample i k)
  CalibrationR ->
    fetchJson "/api/calibration" GotCalibration
