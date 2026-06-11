{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The eval CLI: @manifest-evals migrate@ reconciles the schema;
-- @manifest-evals run \<runId\> [--concurrency N]@ executes a queued run with
-- the live Anthropic backend; @manifest-evals score \<runId\>
-- \<graderVersionId\>... [--concurrency N]@ scores its outputs with the live
-- crucible judge. Config from env: @MANIFEST_DATABASE_URL@,
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
import Evals.Grade.Anthropic (liveGradeRunner)
import Evals.Ids (GraderVersionId (..), RunId (..))
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
          o <- scoreRun pool conc (liveGradeRunner (T.pack key)) (RunId rid) gvs
          putStrLn $ "score " <> ridStr <> ": "
            <> show o.total <> " pairs, "
            <> show o.scored <> " scored, "
            <> show o.errored <> " errored, "
            <> show o.skipped <> " skipped"
  _ -> die usage

usage :: String
usage = "usage: manifest-evals migrate | manifest-evals run <runId> [--concurrency N] | manifest-evals score <runId> <graderVersionId>... [--concurrency N]"

requireEnv :: String -> IO String
requireEnv name =
  lookupEnv name >>= maybe (die (name <> " is not set")) pure

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
