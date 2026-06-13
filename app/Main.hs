{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The eval CLI: @manifest-evals migrate@ reconciles the schema;
-- @manifest-evals run \<runId\> [--concurrency N]@ executes a queued run with
-- the live Anthropic backend; @manifest-evals score \<runId\>
-- \<graderVersionId\>... [--concurrency N]@ scores its outputs with the live
-- crucible judge; @manifest-evals ingest \<file.jsonl\> --name N --slug S
-- [--version N] [--format generic|healthbench] [--limit N] [--skip-bad]
-- [--force]@ loads a JSONL dataset. Config from env: @MANIFEST_DATABASE_URL@,
-- @ANTHROPIC_API_KEY@, @EVALS_CONCURRENCY@ (flag wins over env; default 4).
module Main (main) where

import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import Text.Read (readMaybe)

import Manifest (withSession)
import Manifest.Postgres (Pool, closePool, newPool)

import Evals.Execute (RunOutcome (..), executeRun)
import Evals.Execute.Anthropic (liveAnthropicRunner)
import Evals.Grade (ScoreOutcome (..), scoreRun)
import Evals.Grade.Anthropic (liveCriterionJudge, liveGradeRunner)
import Evals.Ids (GraderVersionId (..), RunId (..))
import Evals.Ingest (IngestOpts (..), IngestResult (..), formatFor, ingestFile, renderIngestError)
import Evals.Migrate (migrateAll)

main :: IO ()
main = getArgs >>= \case
  ["migrate"] -> withEnvPool $ \pool -> do
    _ <- withSession pool migrateAll
    putStrLn "schema migrated"
  ("run" : ridStr : rest) -> do
    rid <- maybe (die ("not a run id: " <> ridStr)) pure (readMaybe ridStr)
    key <- requireEnv "ANTHROPIC_API_KEY"
    conc <- concurrencyFrom rest
    withEnvPool $ \pool -> do
      o <- executeRun pool conc (liveAnthropicRunner (T.pack key)) (RunId rid)
      putStrLn $ "run " <> ridStr <> ": "
        <> show o.total <> " examples, "
        <> show o.succeeded <> " succeeded, "
        <> show o.errored <> " errored, "
        <> show o.skipped <> " skipped (resume)"
  ("score" : ridStr : rest) -> do
    let (gvStrs, flags) = break (== "--concurrency") rest
    if null gvStrs
      then die usage
      else do
        rid  <- maybe (die ("not a run id: " <> ridStr)) pure (readMaybe ridStr)
        gvs  <- mapM (\s -> maybe (die ("not a grader version id: " <> s)) (pure . GraderVersionId) (readMaybe s)) gvStrs
        key  <- requireEnv "ANTHROPIC_API_KEY"
        conc <- concurrencyFrom flags
        withEnvPool $ \pool -> do
          o <- scoreRun pool conc (liveGradeRunner (T.pack key)) (liveCriterionJudge (T.pack key)) (RunId rid) gvs
          putStrLn $ "score " <> ridStr <> ": "
            <> show o.total <> " pairs, "
            <> show o.scored <> " scored, "
            <> show o.errored <> " errored, "
            <> show o.skipped <> " skipped"
  ("ingest" : fileArg : flags) -> do
    name <- reqFlag "--name" flags
    slug <- reqFlag "--slug" flags
    ver  <- maybe (pure 1) parseIntFlag (lookupFlag "--version" flags)
    fmtN <- pure (maybe "generic" id (lookupFlag "--format" flags))
    fmt  <- maybe (die ("unknown --format: " <> fmtN)) pure (formatFor (T.pack fmtN))
    lim  <- traverse parseIntFlag (lookupFlag "--limit" flags)
    let opts = IngestOpts
          { file = fileArg, name = T.pack name, slug = T.pack slug, version = ver
          , format = fmt, limit = lim
          , skipBad = "--skip-bad" `elem` flags, force = "--force" `elem` flags }
    withEnvPool $ \pool -> ingestFile pool opts >>= \case
      Left e  -> die (T.unpack (renderIngestError e))
      Right r -> putStrLn $ "ingested " <> slug <> " v" <> show ver <> ": "
                   <> show r.ingested <> " examples (" <> show r.skipped <> " skipped)"
  _ -> die usage

usage :: String
usage = "usage: manifest-evals migrate | run <runId> [--concurrency N] | "
     <> "score <runId> <graderVersionId>... [--concurrency N] | "
     <> "ingest <file.jsonl> --name N --slug S [--version N] [--format generic|healthbench] [--limit N] [--skip-bad] [--force]"

requireEnv :: String -> IO String
requireEnv name =
  lookupEnv name >>= maybe (die (name <> " is not set")) pure

-- | The value following @flag@ in the arg list (@--name foo@), if present.
lookupFlag :: String -> [String] -> Maybe String
lookupFlag flag = \case
  (k : v : _) | k == flag -> Just v
  (_ : rest)              -> lookupFlag flag rest
  []                      -> Nothing

reqFlag :: String -> [String] -> IO String
reqFlag flag = maybe (die (flag <> " is required")) pure . lookupFlag flag

parseIntFlag :: String -> IO Int
parseIntFlag s = maybe (die ("not a number: " <> s)) pure (readMaybe s)

-- --concurrency N beats EVALS_CONCURRENCY beats 4.
concurrencyFrom :: [String] -> IO Int
concurrencyFrom = \case
  ["--concurrency", n] -> maybe (die ("not a number: " <> n)) pure (readMaybe n)
  [] -> maybe 4 id . (>>= readMaybe) <$> lookupEnv "EVALS_CONCURRENCY"
  rest -> die ("unrecognised arguments: " <> unwords rest)

withEnvPool :: (Pool -> IO a) -> IO a
withEnvPool act = do
  url <- requireEnv "MANIFEST_DATABASE_URL"
  pool <- newPool (TE.encodeUtf8 (T.pack url)) 8
  r <- act pool
  closePool pool
  pure r
