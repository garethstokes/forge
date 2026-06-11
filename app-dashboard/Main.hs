-- | Stub static file server for the evals dashboard (gating spike).
-- Serves EVALS_STATIC_DIR (default "static") on EVALS_HTTP_PORT (default 8787).
module Main (main) where

import qualified Data.ByteString.Char8 as BS8
import qualified Data.Text as T
import Network.HTTP.Types (status200, status404)
import Network.Wai (Application, pathInfo, responseFile, responseLBS)
import qualified Network.Wai.Handler.Warp as Warp
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeExtension)

main :: IO ()
main = do
  port <- maybe 8787 read <$> lookupEnv "EVALS_HTTP_PORT"
  staticDir <- maybe "static" id <$> lookupEnv "EVALS_STATIC_DIR"
  putStrLn ("evals-dashboard: serving " <> staticDir <> " on http://localhost:" <> show port)
  Warp.run port (app staticDir)

app :: FilePath -> Application
app staticDir req respond = do
  let segments = case pathInfo req of
        [] -> ["index.html"]
        ps -> ps
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
    notFound = responseLBS status404 [("Content-Type", "text/plain")] "not found"

contentType :: FilePath -> BS8.ByteString
contentType path = case takeExtension path of
  ".html" -> "text/html; charset=utf-8"
  ".js"   -> "text/javascript"
  ".mjs"  -> "text/javascript"
  ".css"  -> "text/css"
  ".wasm" -> "application/wasm" -- required for WebAssembly.instantiateStreaming
  ".json" -> "application/json"
  ".svg"  -> "image/svg+xml"
  _       -> "application/octet-stream"
