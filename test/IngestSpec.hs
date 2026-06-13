{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
module IngestSpec (main) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import Evals.Ingest

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = do
  adapterSpec
  putStrLn "manifest-evals IngestSpec: adapters OK"

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
