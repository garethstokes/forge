{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure tests for the HealthBench reproduction slice: the grader-response
-- parser and the consensus ingest adapter. Uses the suite's expect harness.
module HealthBenchSpec (main) where

import Control.Monad (unless)
import Data.Text (Text)
import Evals.Grade.Live (parseVerdict)
import Evals.Grade (CriterionVerdict (..))

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = do
  -- bare JSON object
  case parseVerdict "{\"explanation\":\"ok\",\"criteria_met\":true}" of
    Right v -> do expect "bare met"  (v.met == True)
                  expect "bare expl" (v.explanation == "ok")
    Left e  -> expect ("bare json parsed: " <> show e) False

  -- fenced ```json block (HealthBench's grader returns markdown)
  case parseVerdict "```json\n{\"explanation\":\"no\",\"criteria_met\":false}\n```" of
    Right v -> expect "fenced not-met" (v.met == False)
    Left e  -> expect ("fenced json parsed: " <> show e) False

  -- explanation optional (defaults to "")
  case parseVerdict "{\"criteria_met\":true}" of
    Right v -> expect "expl defaults empty" (v.explanation == "")
    Left _  -> expect "criteria_met-only parsed" False

  -- malformed → Left
  case parseVerdict "not json at all" of
    Left _  -> pure ()
    Right _ -> expect "malformed rejected" False

  putStrLn "manifest-evals HealthBenchSpec: parseVerdict OK"
