{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module GradeSpec (main) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import qualified Crucible.Eval as Eval
import Manifest (Aeson (..))
import Evals.Grade

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = do
  configSpec
  exactSpec
  putStrLn "manifest-evals GradeSpec: config + exact OK"

configSpec :: IO ()
configSpec = do
  expect "votes default 1" (votesFrom (object []) == 1)
  expect "votes read" (votesFrom (object ["votes" .= (3 :: Int)]) == 3)
  expect "rubric read"
    (fmap (const ()) (rubricFrom (object ["rubric" .= ("be kind" :: Text)])) == Right ())
  expect "rubric missing is an error" (isLeft (rubricFrom (object [])))
  let cs = criteriaFrom (object ["criteria" .=
            [ object ["label" .= ("cites a URL" :: Text)]
            , object ["label" .= ("polite" :: Text), "weight" .= (2.5 :: Double)] ]])
  expect "criteria labels+weights (weight defaults 1)"
    (fmap (map (\c -> (c.label, c.weight))) cs
       == Right [("cites a URL", 1), ("polite", 2.5)])
  expect "criteria missing is an error" (isLeft (criteriaFrom (object [])))
  expect "criteria empty is an error" (isLeft (criteriaFrom (object ["criteria" .= ([] :: [Value])])))

exactSpec :: IO ()
exactSpec = do
  let val = fmap (.value)
  expect "exact string pass"
    (val (gradeExact (Just (Aeson (toJSON ("4" :: Text)))) (Just " 4\n")) == Right 1.0)
  expect "exact string fail"
    (val (gradeExact (Just (Aeson (toJSON ("4" :: Text)))) (Just "5")) == Right 0.0)
  expect "exact structural pass"
    (val (gradeExact (Just (Aeson (object ["a" .= (1 :: Int)]))) (Just "{\"a\": 1}")) == Right 1.0)
  expect "exact unparseable output is a FAIL, not an error"
    (val (gradeExact (Just (Aeson (object []))) (Just "not json")) == Right 0.0)
  expect "missing expected is an error" (isLeft (gradeExact Nothing (Just "x")))
  expect "missing output text is an error" (isLeft (gradeExact (Just (Aeson (toJSON ("x" :: Text)))) Nothing))
  expect "judge-error score detected"
    (isJudgeError (Eval.score 0.0 "judge error: all samples failed"))
  expect "ordinary zero score is not a judge error"
    (isJudgeError (Eval.score 0.0 "mismatch") == False)
