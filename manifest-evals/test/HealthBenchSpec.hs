{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure tests for the HealthBench reproduction slice: the grader-response
-- parser and the consensus ingest adapter. Uses the suite's expect harness.
module HealthBenchSpec (main) where

import Control.Monad (unless)
import Data.Text (Text)
import Data.Aeson (Value, eitherDecodeStrict)
import qualified Data.ByteString.Char8 as BC
import Evals.Grade.Live (parseVerdict)
import Evals.Grade (CriterionVerdict (..))
import Evals.MetaEval.Ingest (metaFormatFor, MetaRow (..))

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

  -- consensus adapter: each row -> single-criterion rubric + majority label
  let hb = maybe (error "no healthbench format") id (metaFormatFor "healthbench")
  case hb 0 (rowVal "{\"prompt\":[{\"role\":\"user\",\"content\":\"Q1\"}],\"completion\":\"A1\",\"rubric\":\"states X\",\"binary_labels\":[true,true,true],\"category\":\"theme_a\"}") of
    Right r -> do expect "hb key"   (r.key == "hb-0000")
                  expect "hb comp"  (r.completion == "A1")
                  expect "hb label" (r.labels == [("states X", True)])
    Left e  -> expect ("hb row0: " <> show e) False
  case hb 1 (rowVal "{\"prompt\":[{\"role\":\"user\",\"content\":\"Q2\"}],\"completion\":\"A2\",\"rubric\":\"states Y\",\"binary_labels\":[false,false],\"category\":\"theme_b\"}") of
    Right r -> expect "hb false" (r.labels == [("states Y", False)])
    Left e  -> expect ("hb row1: " <> show e) False
  case hb 2 (rowVal "{\"prompt\":[{\"role\":\"user\",\"content\":\"Q3\"}],\"completion\":\"A3\",\"rubric\":\"states Z\",\"binary_labels\":[true,false],\"category\":\"\"}") of
    Right r -> expect "hb tie->met" (r.labels == [("states Z", True)])
    Left e  -> expect ("hb row2: " <> show e) False

  putStrLn "manifest-evals HealthBenchSpec: parseVerdict + consensus adapter OK"

rowVal :: String -> Value
rowVal s = either (error . ("rowVal: " <>)) id (eitherDecodeStrict (BC.pack s))
