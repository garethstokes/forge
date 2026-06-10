{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeApplications #-}
module SchemaSpec (main) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Manifest hiding (Target)
import Manifest.Testing (withEphemeralDb)
import Evals.Schema
import Evals.Ids
import Evals.Migrate (migrateAll)

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = withEphemeralDb $ \pool -> do
  -- migrate twice; the second run is a no-op (empty additive plan)
  _  <- withSession pool migrateAll
  p2 <- withSession pool migrateAll
  expect "second migrate is a no-op (empty additive plan)" (null (planAdditive p2))
  now <- getCurrentTime
  result <- withSession pool $ do
    d <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "demo", slug = "demo", createdAt = now } :: Dataset)
    v <- add (DatasetVersion { id = DatasetVersionId 0, dataset = d.id, version = 1, note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
    _ <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = "c1"
                      , input = Aeson (object ["q" .= ("2+2" :: Text)])
                      , expected = Just (Aeson (object ["a" .= (4 :: Int)])), meta = Nothing } :: Example)
    got <- get @Dataset (Key d.id)
    pure (fmap (.name) got, v.version)
  expect "dataset round-trips by typed Key" (fst result == Just "demo")
  expect "dataset version is 1" (snd result == 1)
  putStrLn "manifest-evals SchemaSpec: migrate + round-trip OK"
