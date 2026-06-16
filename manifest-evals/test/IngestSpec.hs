{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module IngestSpec (main) where

import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, decode, encode, object, toJSON, (.=))
import Data.Either (isLeft)
import Data.List (sort)
import Data.Text (Text)
import Data.Time (getCurrentTime)

import Manifest hiding (decode, encode, key)
import Manifest.Postgres (Pool)
import Manifest.Testing (withEphemeralDb)

import Evals.Ids
import Evals.Ingest
import Evals.Migrate (migrateAll)
import Evals.Schema

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = do
  adapterSpec
  driverSpec
  putStrLn "manifest-evals IngestSpec: adapters + driver OK"

adapterSpec :: IO ()
adapterSpec = do
  expect "formatFor generic" (maybe False (const True) (formatFor "generic"))
  expect "formatFor healthbench" (maybe False (const True) (formatFor "healthbench"))
  expect "formatFor unknown -> Nothing" (maybe True (const False) (formatFor "xml"))
  let gOk = generic (object
        [ "key" .= ("c1" :: Text), "input" .= toJSON ("hello" :: Text)
        , "expected" .= object ["a" .= (1 :: Int)], "meta" .= object ["src" .= ("x" :: Text)] ])
  expect "generic maps all four fields"
    (case gOk of
       Right r -> r.key == "c1" && r.input == toJSON ("hello" :: Text)
                    && r.expected == Just (object ["a" .= (1 :: Int)])
                    && r.meta == Just (object ["src" .= ("x" :: Text)])
       Left _  -> False)
  expect "generic without expected/meta -> Nothings"
    (case generic (object ["key" .= ("k" :: Text), "input" .= toJSON ("i" :: Text)]) of
       Right r -> r.expected == Nothing && r.meta == Nothing
       Left _  -> False)
  expect "generic missing key -> Left" (isLeft (generic (object ["input" .= toJSON ("i" :: Text)])))
  expect "generic missing input -> Left" (isLeft (generic (object ["key" .= ("k" :: Text)])))
  let promptArr = [ object ["role" .= ("user" :: Text), "content" .= ("q1" :: Text)] ]
      rubricsArr = [ object ["criterion" .= ("cites" :: Text), "points" .= (7 :: Double)
                            , "tags" .= (["axis:accuracy"] :: [Text])] ]
      hbRow = object
        [ "prompt_id" .= ("hb-1" :: Text), "prompt" .= promptArr, "rubrics" .= rubricsArr
        , "example_tags" .= (["theme:hedging"] :: [Text]), "canary" .= ("healthbench:abc" :: Text) ]
      hb = healthbench hbRow
  expect "healthbench key <- prompt_id" (either (const False) (\r -> r.key == "hb-1") hb)
  expect "healthbench input <- {messages: prompt}"
    (either (const False) (\r -> r.input == object ["messages" .= promptArr]) hb)
  expect "healthbench expected <- rubrics verbatim"
    (either (const False) (\r -> r.expected == Just (toJSON rubricsArr)) hb)
  expect "healthbench meta carries tags + canary"
    (either (const False)
       (\r -> r.meta == Just (object [ "example_tags" .= (["theme:hedging"] :: [Text])
                                     , "canary" .= ("healthbench:abc" :: Text) ])) hb)
  expect "healthbench missing prompt_id -> Left"
    (isLeft (healthbench (object ["prompt" .= promptArr, "rubrics" .= rubricsArr])))
  expect "healthbench missing prompt -> Left"
    (isLeft (healthbench (object ["prompt_id" .= ("x" :: Text), "rubrics" .= rubricsArr])))
  expect "healthbench missing rubrics -> Left"
    (isLeft (healthbench (object ["prompt_id" .= ("x" :: Text), "prompt" .= promptArr])))
  expect "generic empty key -> Left"
    (isLeft (generic (object ["key" .= ("" :: Text), "input" .= toJSON ("i" :: Text)])))
  expect "generic whitespace key -> Left"
    (isLeft (generic (object ["key" .= ("  " :: Text), "input" .= toJSON ("i" :: Text)])))
  expect "healthbench empty prompt_id -> Left"
    (isLeft (healthbench (object [ "prompt_id" .= ("" :: Text)
                                 , "prompt" .= ([object ["role" .= ("user"::Text), "content" .= ("q"::Text)]] :: [Value])
                                 , "rubrics" .= ([] :: [Value])])))

-- Driver helpers ----------------------------------------------------------

examplesOf :: Pool -> Text -> IO [Example]
examplesOf pool slug = withSession pool $ do
  ds <- selectWhere [ #slug ==. slug ]
  case (ds :: [Dataset]) of
    (d : _) -> do
      vs <- selectWhere [ #dataset ==. d.id ]
      concat <$> mapM (\v -> selectWhere [ #datasetVersion ==. v.id ]) (vs :: [DatasetVersion])
    [] -> pure []

optsFor :: Format -> FilePath -> Text -> Bool -> Maybe Int -> Bool -> IngestOpts
optsFor fmt fp slug force lim skip = IngestOpts
  { file = fp, name = slug, slug = slug, version = 1, format = fmt
  , limit = lim, skipBad = skip, force = force }

gen :: Format
gen = maybe (error "no generic format") id (formatFor "generic")

hb :: Format
hb = maybe (error "no healthbench format") id (formatFor "healthbench")

-- Driver scenarios --------------------------------------------------------

driverSpec :: IO ()
driverSpec = withEphemeralDb $ \pool -> do
  _ <- withSession pool migrateAll
  let org1 = OrgId 1

  -- 1. generic happy
  r1 <- ingestFile pool org1 (optsFor gen "test/fixtures/generic.jsonl" "ds1" False Nothing False)
  expect "driver/1: generic happy result" (r1 == Right (IngestResult 2 0))
  exs1 <- examplesOf pool "ds1"
  expect "driver/1: two examples" (length exs1 == 2)
  expect "driver/1: keys a,b" (sort (map (.key) exs1) == ["a", "b"])
  case [ e | e <- exs1, e.key == "a" ] of
    (ea : _) -> do
      let Aeson iv = ea.input
      expect "driver/1: a.input == \"first\"" (iv == toJSON ("first" :: Text))
      expect "driver/1: a.expected == {v:1}"
        (fmap (\(Aeson v) -> v) ea.expected == Just (object ["v" .= (1 :: Int)]))
      expect "driver/1: a.meta == {src:t}"
        (fmap (\(Aeson v) -> v) ea.meta == Just (object ["src" .= ("t" :: Text)]))
    [] -> expect "driver/1: example a present" False

  -- 2. healthbench happy
  r2 <- ingestFile pool org1 (optsFor hb "test/fixtures/healthbench.jsonl" "hb" False Nothing False)
  expect "driver/2: healthbench happy result" (r2 == Right (IngestResult 1 0))
  exs2 <- examplesOf pool "hb"
  expect "driver/2: one example" (length exs2 == 1)
  case exs2 of
    (e : _) -> do
      let Aeson iv = e.input
          promptArr = [ object ["role" .= ("user" :: Text), "content" .= ("q" :: Text)] ] :: [Value]
          rubricsArr = [ object [ "criterion" .= ("cites" :: Text), "points" .= (7 :: Int)
                                , "tags" .= (["axis:accuracy"] :: [Text]) ] ] :: [Value]
      expect "driver/2: key hb-1" (e.key == "hb-1")
      expect "driver/2: input == {messages: prompt}"
        (iv == object ["messages" .= promptArr])
      expect "driver/2: expected == rubrics array"
        (case e.expected of
           Just (Aeson v) -> decode (encode v) == (Just (toJSON rubricsArr) :: Maybe Value)
           Nothing        -> False)
      expect "driver/2: meta carries example_tags + canary"
        (case e.meta of
           Just (Aeson v) -> decode (encode v)
             == (Just (object [ "example_tags" .= (["theme:hedging"] :: [Text])
                              , "canary" .= ("healthbench:abc" :: Text) ]) :: Maybe Value)
           Nothing        -> False)
    [] -> expect "driver/2: example present" False

  -- 3. refuse existing
  r3a <- ingestFile pool org1 (optsFor gen "test/fixtures/generic.jsonl" "ds2" False Nothing False)
  expect "driver/3: first ingest ok" (r3a == Right (IngestResult 2 0))
  r3b <- ingestFile pool org1 (optsFor gen "test/fixtures/generic.jsonl" "ds2" False Nothing False)
  expect "driver/3: re-ingest refused" (r3b == Left (AlreadyExists "ds2" 1))
  exs3 <- examplesOf pool "ds2"
  expect "driver/3: still exactly 2 (no dup)" (length exs3 == 2)

  -- 4. --force replaces (proves the Task-1 flush fix)
  r4a <- ingestFile pool org1 (optsFor gen "test/fixtures/generic.jsonl" "ds3" False Nothing False)
  expect "driver/4: seed generic ok" (r4a == Right (IngestResult 2 0))
  r4b <- ingestFile pool org1 (optsFor hb "test/fixtures/healthbench.jsonl" "ds3" True Nothing False)
  expect "driver/4: force replace ok (flush fix)" (r4b == Right (IngestResult 1 0))
  exs4 <- examplesOf pool "ds3"
  expect "driver/4: exactly one example after force"
    (map (.key) exs4 == ["hb-1"])

  -- 5. --force blocked by a Run
  r5a <- ingestFile pool org1 (optsFor gen "test/fixtures/generic.jsonl" "ds4" False Nothing False)
  expect "driver/5: seed generic ok" (r5a == Right (IngestResult 2 0))
  now <- getCurrentTime
  dvId <- withSession pool $ do
    ds <- selectWhere [ #slug ==. ("ds4" :: Text) ]
    case (ds :: [Dataset]) of
      (d : _) -> do
        vs <- selectWhere [ #dataset ==. d.id ]
        case (vs :: [DatasetVersion]) of
          (v : _) -> pure v.id
          []      -> liftIO (ioError (userError "scenario 5 seed missing"))
      [] -> liftIO (ioError (userError "scenario 5 seed missing"))
  _ <- withSession pool $ do
    t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "t", createdAt = now } :: Target)
    tv <- add (TargetVersion { id = TargetVersionId 0, org = OrgId 1, target = t.id, version = 1, model = "m"
                             , prompt = "SYS", params = Aeson (object []), createdAt = now } :: TargetVersion)
    _r <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = dvId, targetVersion = tv.id
                   , status = "succeeded", startedAt = Just now, finishedAt = Just now
                   , meta = Nothing, createdAt = now } :: Run)
    pure ()
  r5b <- ingestFile pool org1 (optsFor gen "test/fixtures/generic.jsonl" "ds4" True Nothing False)
  expect "driver/5: force blocked by run" (r5b == Left (HasRuns "ds4" 1))
  exs5 <- examplesOf pool "ds4"
  expect "driver/5: version kept, still 2 examples" (length exs5 == 2)

  -- 6. --limit
  r6 <- ingestFile pool org1 (optsFor gen "test/fixtures/generic.jsonl" "ds5" False (Just 1) False)
  expect "driver/6: limit result" (r6 == Right (IngestResult 1 0))
  exs6 <- examplesOf pool "ds5"
  expect "driver/6: exactly 1 example, key a" (map (.key) exs6 == ["a"])

  -- 7. skip-bad off
  r7 <- ingestFile pool org1 (optsFor gen "test/fixtures/skip-bad.jsonl" "ds6" False Nothing False)
  expect "driver/7: bad line at 2"
    (case r7 of Left (BadLine n _) -> n == 2; _ -> False)
  exs7 <- examplesOf pool "ds6"
  expect "driver/7: nothing ingested" (null exs7)

  -- 8. skip-bad on
  r8 <- ingestFile pool org1 (optsFor gen "test/fixtures/skip-bad.jsonl" "ds7" False Nothing True)
  expect "driver/8: skip-bad result" (r8 == Right (IngestResult 2 1))
  exs8 <- examplesOf pool "ds7"
  expect "driver/8: exactly 2 examples, keys g1,g2"
    (sort (map (.key) exs8) == ["g1", "g2"])
