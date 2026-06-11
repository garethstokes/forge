{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}

-- | The dashboard SPA's pure core: the hash 'Route', 'RemoteData' wrappers
-- for each fetched resource, the 'Model' + lenses, the 'Action' sum, and the
-- hash parse/render helpers. No IO here — fetches live in "Evals.Ui.Fetch",
-- wiring in @Main@.
module Evals.Ui.Model
  ( Route (..)
  , RemoteData (..)
  , LiveStatus (..)
  , Model (..)
  , Action (..)
  , emptyModel
    -- * Lenses
  , routeL
  , runsL
  , detailL
  , compareL
  , selectedL
  , expandedL
  , liveL
  , refetchQueuedL
    -- * Live updates (pure)
  , relevantTo
    -- * Hash routing (pure)
  , parseHash
  , runsHash
  , runHash
  , compareHash
    -- * Small helpers
  , fromEither
  , keepStale
  , toggleSelect
  , toggleElem
  , pruneSelection
  , msShow
  ) where

import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Miso.Lens (Lens, lens)
import Miso.String (MisoString, fromMisoString, ms)

import Evals.Api

-- | Views, driven by the location hash: @#/runs@, @#/runs/<id>@,
-- @#/compare/<a>/<b>@.
data Route
  = RunsR
  | RunR Int
  | CompareR Int Int
  deriving (Show, Eq)

-- | Lifecycle of a fetched resource.
data RemoteData a
  = NotAsked
  | Loading
  | Failed MisoString
  | Got a
  deriving (Show, Eq)

-- | Status of the @/api/events@ SSE feed (the EventSource auto-reconnects on
-- its own; we only reflect what it last told us).
data LiveStatus
  = LiveConnected
  | LiveReconnecting
  deriving (Show, Eq)

data Model = Model
  { _routeM :: Route
  , _runsM :: RemoteData [RunSummaryDto]
  , _detailM :: RemoteData RunDetailDto
  , _compareM :: RemoteData CompareDto
  , _selectedM :: [Int]
    -- ^ run ids ticked for comparison on the runs view (at most two)
  , _expandedM :: [MisoString]
    -- ^ output cells toggled to full text (keys are view-local)
  , _liveM :: LiveStatus
  , _refetchQueuedM :: Bool
    -- ^ a debounced 'DoRefetch' is already scheduled; coalesce further changes
  } deriving (Show, Eq)

emptyModel :: Model
emptyModel = Model RunsR NotAsked NotAsked NotAsked [] [] LiveReconnecting False

data Action
  = Startup
  -- ^ mounted: connect the SSE change feed, then route the initial hash
  | HashChanged
  -- ^ the location hash changed (popstate/hashchange or initial mount)
  | SetRoute Route
  | Navigate MisoString
  -- ^ in-app navigation: set the location hash (the hashchange sub drives
  -- the actual route switch, so back/forward and manual edits behave the same)
  | ToggleSelect Int
  | ToggleExpand MisoString
  | GotRuns (Either MisoString [RunSummaryDto])
  | GotDetail Int (Either MisoString RunDetailDto)
  -- ^ carries the requested run id so stale responses for a different run can
  --   be dropped before touching the model
  | GotCompare Int Int (Either MisoString CompareDto)
  -- ^ carries the requested (a, b) ids for the same stale-response guard
  | SseOpen
  -- ^ the EventSource (re)connected
  | SseError
  -- ^ the EventSource dropped; it reconnects on its own, we just show status
  | SseMessage MisoString
  -- ^ a raw @/api/events@ line; aeson-decoded in update — decodable lines
  --   become 'GotChange', anything else is ignored silently
  | GotChange ChangeDto
  -- ^ a decoded change-feed hint: something in @table@ moved
  | DoRefetch
  -- ^ the 300ms debounce fired: refetch whatever the current route shows
  deriving (Show, Eq)

-- Lenses --------------------------------------------------------------------

routeL :: Lens Model Route
routeL = lens _routeM $ \r x -> r { _routeM = x }

runsL :: Lens Model (RemoteData [RunSummaryDto])
runsL = lens _runsM $ \r x -> r { _runsM = x }

detailL :: Lens Model (RemoteData RunDetailDto)
detailL = lens _detailM $ \r x -> r { _detailM = x }

compareL :: Lens Model (RemoteData CompareDto)
compareL = lens _compareM $ \r x -> r { _compareM = x }

selectedL :: Lens Model [Int]
selectedL = lens _selectedM $ \r x -> r { _selectedM = x }

expandedL :: Lens Model [MisoString]
expandedL = lens _expandedM $ \r x -> r { _expandedM = x }

liveL :: Lens Model LiveStatus
liveL = lens _liveM $ \r x -> r { _liveM = x }

refetchQueuedL :: Lens Model Bool
refetchQueuedL = lens _refetchQueuedM $ \r x -> r { _refetchQueuedM = x }

-- Live updates ----------------------------------------------------------------

-- | Does a change in @table@ affect what the given route is showing?
-- NOTE: deleting a run only emits @runs@ — the cascade-deleted children
-- (outputs, scores, …) are silent — hence @runs@ is relevant everywhere.
relevantTo :: Route -> MisoString -> Bool
relevantTo route table =
  case route of
    RunsR -> table `elem` ["runs", "run_metrics"]
    RunR _ -> table `elem` detailTables
    CompareR _ _ -> table `elem` detailTables
  where
    detailTables = ["runs", "outputs", "scores", "run_metrics"]

-- Hash routing --------------------------------------------------------------

-- | @#/runs@ (also empty/unknown), @#/runs/<id>@, @#/compare/<a>/<b>@.
parseHash :: MisoString -> Route
parseHash h =
  case T.splitOn "/" (T.dropWhile (== '#') (fromMisoString h :: T.Text)) of
    ["", "runs"] -> RunsR
    ["", "runs", n] | Just i <- readInt n -> RunR i
    ["", "compare", a, b] | Just x <- readInt a, Just y <- readInt b -> CompareR x y
    _ -> RunsR
  where
    readInt t = case TR.decimal t of
      Right (i, rest) | T.null rest -> Just i
      _ -> Nothing

runsHash :: MisoString
runsHash = "#/runs"

runHash :: Int -> MisoString
runHash i = "#/runs/" <> msShow i

compareHash :: Int -> Int -> MisoString
compareHash a b = "#/compare/" <> msShow a <> "/" <> msShow b

-- Helpers ---------------------------------------------------------------------

fromEither :: Either MisoString a -> RemoteData a
fromEither = either Failed Got

-- | A background refresh must not replace good data with an error box; manual
-- navigation resets to Loading first, so user-initiated errors still surface.
keepStale :: RemoteData a -> RemoteData a -> RemoteData a
keepStale old@(Got _) (Failed _) = old
keepStale _           new        = new

-- | Tick/untick a run for comparison; a third tick is ignored.
toggleSelect :: Int -> [Int] -> [Int]
toggleSelect i xs
  | i `elem` xs = filter (/= i) xs
  | length xs >= 2 = xs
  | otherwise = xs ++ [i]

toggleElem :: MisoString -> [MisoString] -> [MisoString]
toggleElem k xs
  | k `elem` xs = filter (/= k) xs
  | otherwise = k : xs

-- | Drop selected run ids that are no longer present in the fetched run list.
pruneSelection :: [RunSummaryDto] -> [Int] -> [Int]
pruneSelection rs = filter (\i -> any (\r -> r.runId == i) rs)

msShow :: Show a => a -> MisoString
msShow = ms . show
