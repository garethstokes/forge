{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Gating spike: a miso hello-world counter compiled as a wasm32-wasi
-- browser reactor (see evals-ui/zinc.toml wasm-exports).
module Main where

-- Instances-only import: makes the depends edge on evals-api honest. The UI
-- does not consume the DTOs yet; the edge proves the evals-api + aeson closure
-- cross-compiles to wasm alongside the UI.
import Evals.Api ()
import Miso
import qualified Miso.Html as H
import Miso.Lens (Lens, lens, (+=), (-=))
import Miso.String (ms)

-- | Component model state
newtype Model = Model
  { _counter :: Int
  } deriving (Show, Eq)

counter :: Lens Model Int
counter = lens _counter $ \record field -> record {_counter = field}

-- | Sum type for application events
data Action
  = AddOne
  | SubtractOne
  deriving (Show, Eq)

-- | Entry point for the miso application
main :: IO ()
main = startApp defaultEvents app

-- | WASM export, required when compiling with the GHC WASM backend.
#ifdef wasm32_HOST_ARCH
foreign export javascript "hs_start" main :: IO ()
#endif

app :: App Model Action
app = component (Model 0) updateModel viewModel

updateModel :: Action -> Effect parent props Model Action
updateModel = \case
  AddOne -> counter += 1
  SubtractOne -> counter -= 1

viewModel :: props -> Model -> View Model Action
viewModel _ m =
  H.div_
    []
    [ H.h1_ [] [text "evals-ui: hello, miso"]
    , H.button_ [H.onClick SubtractOne] [text "-"]
    , text (ms (_counter m))
    , H.button_ [H.onClick AddOne] [text "+"]
    ]
