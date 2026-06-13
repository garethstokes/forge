{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module MetaEvalSpec (main) where

import Control.Monad (unless)
import Data.Text (Text)
import Data.Time (getCurrentTime)

import Manifest
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)

import Evals.Ids
import Evals.Migrate (migrateAll)
import Evals.Schema
import Evals.MetaEval.Ingest

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = withEphemeralDb $ \pool -> do
  _ <- withSession pool migrateAll
  ingestSpec pool
  putStrLn "manifest-evals MetaEvalSpec: ingest OK"

opts :: Bool -> MetaLoadOpts
opts skip = MetaLoadOpts
  { file = "test/fixtures/metaeval.jsonl", name = "Meta", slug = "meta"
  , version = 1, skipBad = skip, force = False }

ingestSpec :: Pool -> IO ()
ingestSpec pool = do
  bad <- metaLoad pool (opts False)
  expect "metaLoad refuses unknown-criterion row"
    (case bad of Left (NoSuchCriterion 3 _) -> True; _ -> False)
  good <- metaLoad pool (opts True)
  case good of
    Left e -> expect ("metaLoad --skip-bad should succeed: " <> show e) False
    Right r -> do
      expect "metaLoad seeded 2 examples"  (r.examples == 2)
      expect "metaLoad seeded 3 labels"    (r.labels == 3)
      expect "metaLoad skipped 1 bad row"  (r.skipped == 1)
      outs <- withSession pool (selectWhere [ #run ==. r.runId ]) :: IO [Output]
      expect "metaLoad seeded 2 outputs under the run" (length outs == 2)
      lbls <- withSession pool (selectWhere ([] :: [Cond CriterionLabel])) :: IO [CriterionLabel]
      expect "metaLoad seeded 3 labels total" (length lbls == 3)
      expect "metaLoad output carries the completion text"
        (any (\o -> o.text == Just "4") outs)
      -- re-loading the same slug+version is refused; --force is still refused
      -- because metaLoad always seeds a synthetic Run (DatasetVersion->Run is Restrict).
      again <- metaLoad pool (opts True)
      expect "metaLoad refuses an existing version"
        (case again of Left (AlreadyExists "meta" 1) -> True; _ -> False)
      forced <- metaLoad pool (MetaLoadOpts
        { file = "test/fixtures/metaeval.jsonl", name = "Meta", slug = "meta"
        , version = 1, skipBad = True, force = True })
      expect "metaLoad --force is blocked by the synthetic run (HasRuns)"
        (case forced of Left (HasRuns "meta" 1) -> True; _ -> False)
