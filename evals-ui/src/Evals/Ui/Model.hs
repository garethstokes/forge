{-# LANGUAGE OverloadedStrings #-}

-- | The dashboard SPA's pure core: the hash 'Route', 'RemoteData' wrappers
-- for each fetched resource, the 'Model' + lenses, the 'Action' sum, and the
-- hash parse/render helpers. No IO here — fetches live in "Evals.Ui.Fetch",
-- wiring in @Main@.
module Evals.Ui.Model
  ( Route (..)
  , RemoteData (..)
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
    -- * Hash routing (pure)
  , parseHash
  , runsHash
  , runHash
  , compareHash
    -- * Small helpers
  , fromEither
  , toggleSelect
  , toggleElem
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

data Model = Model
  { _routeM :: Route
  , _runsM :: RemoteData [RunSummaryDto]
  , _detailM :: RemoteData RunDetailDto
  , _compareM :: RemoteData CompareDto
  , _selectedM :: [Int]
    -- ^ run ids ticked for comparison on the runs view (at most two)
  , _expandedM :: [MisoString]
    -- ^ output cells toggled to full text (keys are view-local)
  } deriving (Show, Eq)

emptyModel :: Model
emptyModel = Model RunsR NotAsked NotAsked NotAsked [] []

data Action
  = HashChanged
  -- ^ the location hash changed (popstate/hashchange or initial mount)
  | SetRoute Route
  | Navigate MisoString
  -- ^ in-app navigation: set the location hash (the hashchange sub drives
  -- the actual route switch, so back/forward and manual edits behave the same)
  | ToggleSelect Int
  | ToggleExpand MisoString
  | GotRuns (Either MisoString [RunSummaryDto])
  | GotDetail (Either MisoString RunDetailDto)
  | GotCompare (Either MisoString CompareDto)
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

msShow :: Show a => a -> MisoString
msShow = ms . show
