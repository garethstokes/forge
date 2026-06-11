{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The evals dashboard SPA: a miso 1.11 component compiled as a wasm32-wasi
-- browser reactor (see evals-ui/zinc.toml wasm-exports). Routes live in the
-- location hash; each route entry kicks a same-origin JSON fetch.
module Main where

import Miso
import Miso.Lens ((%=), (.=))

import Evals.Ui.Fetch (fetchJson, getHash, setHash)
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
      -- parse the initial hash (and load its data) once mounted
    , mount = Just HashChanged
    }

updateModel :: Action -> Effect parent props Model Action
updateModel = \case
  HashChanged ->
    io (SetRoute . parseHash <$> getHash)
  SetRoute r -> do
    routeL .= r
    case r of
      RunsR -> do
        runsL .= Loading
        fetchJson "/api/runs" GotRuns
      RunR i -> do
        detailL .= Loading
        expandedL .= []
        fetchJson ("/api/runs/" <> msShow i) GotDetail
      CompareR a b -> do
        compareL .= Loading
        expandedL .= []
        fetchJson ("/api/compare?a=" <> msShow a <> "&b=" <> msShow b) GotCompare
  Navigate h ->
    io_ (setHash h)
  ToggleSelect i ->
    selectedL %= toggleSelect i
  ToggleExpand k ->
    expandedL %= toggleElem k
  GotRuns e ->
    runsL .= fromEither e
  GotDetail e ->
    detailL .= fromEither e
  GotCompare e ->
    compareL .= fromEither e
