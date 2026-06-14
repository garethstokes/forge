{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

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

import Control.Monad.IO.Class (liftIO)
import Data.Time (getCurrentTime)

import Manifest (Cond, Db, add, get, Key (..), selectWhere, withSession, (==.))
import Manifest.Postgres (Pool, closePool, newPool)

import Evals.Execute (RunOutcome (..), executeRun)
import Evals.Execute.Anthropic (liveAnthropicRunner)
import Evals.Grade (ScoreOutcome (..), scoreRun)
import Evals.Grade.Live (LiveKeys (..), liveCriterionJudge, liveGradeRunner)
import Evals.Ids (GraderVersionId (..), OrgId (..), RunId (..))
import Evals.Ingest (IngestOpts (..), IngestResult (..), formatFor, ingestFile, renderIngestError)
import Evals.MetaEval (metaReport, MetaMode (..), saveMetaEval)
import Evals.MetaEval.Ingest (MetaLoadOpts (..), MetaLoadResult (..), metaLoad, renderMetaLoadError)
import Evals.Migrate (migrateAll)
import Evals.Schema
import qualified Crucible.Eval.Calibrate as Cal

main :: IO ()
main = getArgs >>= \case
  ["migrate"] -> withEnvPool $ \pool -> do
    _ <- withSession pool migrateAll
    putStrLn "schema migrated"
  ("run" : ridStr : rest) -> do
    let (nonFlagArgs, flags) = break (== "--org") rest
    slug <- reqFlag "--org" flags
    rid  <- maybe (die ("not a run id: " <> ridStr)) pure (readMaybe ridStr)
    key  <- requireEnv "ANTHROPIC_API_KEY"
    conc <- concurrencyFrom nonFlagArgs
    withEnvPool $ \pool -> do
      org <- resolveOrg pool slug
      ensureRunOrg pool (RunId rid) org ridStr
      o <- executeRun pool conc (liveAnthropicRunner (T.pack key)) (RunId rid)
      putStrLn $ "run " <> ridStr <> ": "
        <> show o.total <> " examples, "
        <> show o.succeeded <> " succeeded, "
        <> show o.errored <> " errored, "
        <> show o.skipped <> " skipped (resume)"
  ("score" : ridStr : rest) -> do
    let (nonFlagArgs, afterOrg) = break (== "--org") rest
        (gvStrs, concFlags)     = break (== "--concurrency") nonFlagArgs
    if null gvStrs
      then die usage
      else do
        slug <- reqFlag "--org" afterOrg
        rid  <- maybe (die ("not a run id: " <> ridStr)) pure (readMaybe ridStr)
        gvs  <- mapM (\s -> maybe (die ("not a grader version id: " <> s)) (pure . GraderVersionId) (readMaybe s)) gvStrs
        ks   <- liveKeys
        conc <- concurrencyFrom concFlags
        withEnvPool $ \pool -> do
          org <- resolveOrg pool slug
          ensureRunOrg pool (RunId rid) org ridStr
          o <- scoreRun pool conc (liveGradeRunner ks) (liveCriterionJudge ks) (RunId rid) gvs
          putStrLn $ "score " <> ridStr <> ": "
            <> show o.total <> " pairs, "
            <> show o.scored <> " scored, "
            <> show o.errored <> " errored, "
            <> show o.skipped <> " skipped"
  ("ingest" : fileArg : flags) -> do
    slug <- reqFlag "--org" flags
    name <- reqFlag "--name" flags
    dslug <- reqFlag "--slug" flags
    ver  <- maybe (pure 1) parseIntFlag (lookupFlag "--version" flags)
    let fmtN = maybe "generic" id (lookupFlag "--format" flags)
    fmt  <- maybe (die ("unknown --format: " <> fmtN)) pure (formatFor (T.pack fmtN))
    lim  <- traverse parseIntFlag (lookupFlag "--limit" flags)
    case lim of
      Just n | n < 1 -> die "--limit must be at least 1"
      _              -> pure ()
    let opts = IngestOpts
          { file = fileArg, name = T.pack name, slug = T.pack dslug, version = ver
          , format = fmt, limit = lim
          , skipBad = "--skip-bad" `elem` flags, force = "--force" `elem` flags }
    withEnvPool $ \pool -> do
      org <- resolveOrg pool slug
      ingestFile pool org opts >>= \case
        Left e  -> die (T.unpack (renderIngestError e))
        Right r -> putStrLn $ "ingested " <> dslug <> " v" <> show ver <> ": "
                     <> show r.ingested <> " examples (" <> show r.skipped <> " skipped)"
  ("metaeval" : "load" : fileArg : flags) -> do
    slug <- reqFlag "--org" flags
    name <- reqFlag "--name" flags
    dslug <- reqFlag "--slug" flags
    ver  <- maybe (pure 1) parseIntFlag (lookupFlag "--version" flags)
    let opts = MetaLoadOpts
          { file = fileArg, name = T.pack name, slug = T.pack dslug, version = ver
          , format = maybe "generic" T.pack (lookupFlag "--format" flags)
          , skipBad = "--skip-bad" `elem` flags, force = "--force" `elem` flags }
    withEnvPool $ \pool -> do
      org <- resolveOrg pool slug
      metaLoad pool org opts >>= \case
        Left e  -> die (T.unpack (renderMetaLoadError e))
        Right r -> let RunId rid = r.runId in
          putStrLn $ "loaded " <> dslug <> " v" <> show ver <> ": run " <> show rid
            <> ", " <> show r.examples <> " examples, " <> show r.labels <> " labels ("
            <> show r.skipped <> " skipped)"
  ("metaeval" : "report" : ridStr : gvStr : flags) -> do
    slug <- reqFlag "--org" flags
    rid  <- maybe (die ("not a run id: " <> ridStr)) (pure . RunId) (readMaybe ridStr)
    gvid <- maybe (die ("not a grader version id: " <> gvStr)) (pure . GraderVersionId) (readMaybe gvStr)
    seed <- maybe (pure 0) parseIntFlag (lookupFlag "--seed" flags)
    let modeName = maybe "live" id (lookupFlag "--mode" flags)
    mode <- case modeName of
      "stored" -> pure Stored
      "live"   -> Live . liveCriterionJudge <$> liveKeys
      other    -> die ("unknown --mode: " <> other)
    withEnvPool $ \pool -> do
      org <- resolveOrg pool slug
      metaReport pool seed mode rid gvid >>= \case
        Left e  -> die (T.unpack e)
        Right r -> do
          _ <- saveMetaEval pool org rid gvid (T.pack modeName) seed r
          putStrLn (T.unpack (Cal.renderCalibration r))
  ("org" : "create" : flags) -> do
    slug <- reqFlag "--slug" flags
    name <- reqFlag "--name" flags
    now  <- getCurrentTime
    withEnvPool $ \pool -> withSession pool $ do
      o <- add (Org { id = OrgId 0, slug = T.pack slug, name = T.pack name, createdAt = now } :: Org)
      let OrgId n = o.id in liftIO (putStrLn ("created org " <> show n <> " (" <> slug <> ")"))
  ("org" : "list" : _) -> do
    withEnvPool $ \pool -> withSession pool $ do
      os <- selectWhere ([] :: [Cond Org])
      liftIO (mapM_ (\o -> let OrgId n = o.id
                           in putStrLn (show n <> "  " <> T.unpack o.slug <> "  " <> T.unpack o.name)) os)
  _ -> die usage

usage :: String
usage = "usage: manifest-evals migrate | run <runId> --org <slug> [--concurrency N] | "
     <> "score <runId> <graderVersionId>... --org <slug> [--concurrency N] | "
     <> "ingest <file.jsonl> --org <slug> --name N --slug S [--version N] [--format generic|healthbench] [--limit N] [--skip-bad] [--force]"
     <> " | metaeval load <file.jsonl> --org <slug> --name N --slug S [--version N] [--format generic|healthbench] [--skip-bad] [--force]"
     <> " | metaeval report <runId> <graderVersionId> --org <slug> [--mode live|stored] [--seed N]"
     <> " | org create --slug S --name N | org list"

-- | Resolve an org slug to its OrgId. Dies if no such org exists.
resolveOrg :: Pool -> String -> IO OrgId
resolveOrg pool slug = withSession pool $ do
  os <- selectWhere ([ #slug ==. T.pack slug ] :: [Cond Org])
  case os of
    (o : _) -> pure o.id
    []      -> liftIO (die ("no such org: " <> slug))

-- | Refuse to run/score a run that does not belong to the given org. The
-- executor/grader run on the superuser connection (concurrent multi-session,
-- RLS not active), so this guard is what enforces org ownership for those
-- commands — without it @run \<id\> --org other@ would operate on any run.
ensureRunOrg :: Pool -> RunId -> OrgId -> String -> IO ()
ensureRunOrg pool rid org ridStr = do
  mRun <- withSession pool (get @Run (Key rid))
  case mRun of
    Nothing                -> die ("run not found: " <> ridStr)
    Just r | r.org /= org  -> die ("run " <> ridStr <> " does not belong to that org")
           | otherwise     -> pure ()

requireEnv :: String -> IO String
requireEnv name =
  lookupEnv name >>= maybe (die (name <> " is not set")) pure

-- | The live-edge API keys: Anthropic is required; OpenAI is optional and only
-- consulted when a grader's config selects @provider: openai@.
liveKeys :: IO LiveKeys
liveKeys = do
  a <- requireEnv "ANTHROPIC_API_KEY"
  o <- lookupEnv "OPENAI_API_KEY"
  pure (LiveKeys { anthropic = T.pack a, openai = T.pack <$> o })

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
