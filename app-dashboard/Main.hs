{-# LANGUAGE OverloadedStrings #-}

-- | The evals dashboard server: reads env, opens a DB pool, and runs the WAI
-- application from Evals.Dashboard.
module Main (main) where

import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Environment (lookupEnv)
import System.Exit (die)
import qualified Network.Wai.Handler.Warp as Warp

import Manifest.Postgres (newPool)

import Evals.Dashboard (dashboardApp)

main :: IO ()
main = do
  port      <- maybe 8787 read <$> lookupEnv "EVALS_HTTP_PORT"
  staticDir <- maybe "static" id <$> lookupEnv "EVALS_STATIC_DIR"
  dbUrl     <- requireEnv "MANIFEST_DATABASE_URL"
  pool      <- newPool (TE.encodeUtf8 (T.pack dbUrl)) 8
  putStrLn ("evals-dashboard: serving " <> staticDir <> " on http://localhost:" <> show port)
  Warp.run port (dashboardApp pool staticDir)

requireEnv :: String -> IO String
requireEnv name =
  lookupEnv name >>= maybe (die (name <> " is not set")) pure
