{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Meta-eval ingest: load a labelled JSONL into a full run graph
-- (Dataset/Version + synthetic Target/Run + one Output per record carrying the
-- candidate completion + 'CriterionLabel's). The report runner (a later module)
-- reads from this graph.
module Evals.MetaEval.Ingest
  ( MetaLoadOpts (..)
  , MetaLoadError (..)
  , MetaLoadResult (..)
  , renderMetaLoadError
  , metaLoad
  ) where

import Control.Monad (foldM, forM_)
import Data.Aeson (Value (..), eitherDecodeStrict, (.=), object)
import qualified Data.Aeson.Types as AT
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)

import Manifest
import Manifest.Postgres (Pool)

import Evals.Ids
import Evals.Ingest (nonEmptyKey)
import Evals.Schema

-- | One parsed labelled record.
data MetaRow = MetaRow
  { key        :: Text
  , input      :: Value
  , rubric     :: Value
  , completion :: Text
  , labels     :: [(Text, Bool)]   -- (criterion, human verdict)
  }

data MetaLoadOpts = MetaLoadOpts
  { file :: FilePath, name :: Text, slug :: Text
  , version :: Int, skipBad :: Bool, force :: Bool }

data MetaLoadError
  = BadLine Int Text             -- malformed JSON / shape
  | NoSuchCriterion Int Text     -- a label references a criterion absent from the row's rubric
  | AlreadyExists Text Int
  deriving (Eq, Show)

data MetaLoadResult = MetaLoadResult
  { runId :: RunId, examples :: Int, labels :: Int, skipped :: Int }
  deriving (Eq, Show)

renderMetaLoadError :: MetaLoadError -> Text
renderMetaLoadError = \case
  BadLine n e         -> "line " <> tshow n <> ": " <> e
  NoSuchCriterion n c -> "line " <> tshow n <> ": label criterion not in rubric: " <> c
  AlreadyExists s v   -> "dataset " <> s <> " v" <> tshow v <> " already exists (use --force to replace)"
  where tshow = T.pack . show

-- | The criterion texts present in a rubric array (anything malformed -> []).
rubricCriteria :: Value -> [Text]
rubricCriteria v = fromMaybe [] (AT.parseMaybe p v)
  where p = AT.withArray "rubric" $ \arr ->
              mapM (AT.withObject "criterion" (AT..: "criterion")) (foldr (:) [] arr)

-- | Parse + validate one record: every label criterion must be in the rubric.
parseMetaRow :: Value -> Either Text MetaRow
parseMetaRow = first T.pack . AT.parseEither
  (AT.withObject "metarow" $ \o -> do
     k    <- o AT..: "key" >>= nonEmptyKey
     inp  <- o AT..: "input"
     rub  <- o AT..: "rubric"
     comp <- o AT..: "completion"
     lbls <- o AT..: "labels" >>= mapM (AT.withObject "label" $ \l ->
               (,) <$> l AT..: "criterion" <*> l AT..: "met")
     pure MetaRow { key = k, input = inp, rubric = rub, completion = comp, labels = lbls })

-- | Read the file, adapt + validate rows, seed the graph in one transaction.
metaLoad :: Pool -> MetaLoadOpts -> IO (Either MetaLoadError MetaLoadResult)
metaLoad pool opts = do
  contents <- BS.readFile opts.file
  let numbered = zip [1 :: Int ..] (BC.lines contents)
      nonBlank = [ (n, ln) | (n, ln) <- numbered, not (BC.all isSpace ln) ]
  case adaptAll opts.skipBad nonBlank of
    Left err            -> pure (Left err)
    Right (rows, nSkip) -> do
      now <- getCurrentTime
      withSession pool $ do
        existing <- selectWhere [ #slug ==. opts.slug ]
        case (existing :: [Dataset]) of
          (d : _) -> do
            vers <- selectWhere [ #dataset ==. d.id, #version ==. opts.version ]
            case (vers :: [DatasetVersion]) of
              (v : _)
                | not opts.force -> pure (Left (AlreadyExists opts.slug opts.version))
                | otherwise -> withTransaction $ do
                    runs <- selectWhere [ #datasetVersion ==. v.id ] :: Db [Run]
                    mapM_ delete runs   -- cascades Run -> Output -> {Score, CriterionLabel}
                    flush               -- runs + subtree gone before deleting the version
                    delete v            -- no runs reference it now (Restrict ok); cascades Examples
                    flush               -- version gone before seedGraph's eager inserts
                    Right <$> seedGraph d.id opts rows now nSkip
              [] -> withTransaction (Right <$> seedGraph d.id opts rows now nSkip)
          [] -> withTransaction $ do
            d <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = opts.name
                              , slug = opts.slug, createdAt = now } :: Dataset)
            Right <$> seedGraph d.id opts rows now nSkip

-- | Seed Version + synthetic Target/TargetVersion/Run + per-row Example/Output/Labels.
seedGraph :: DatasetId -> MetaLoadOpts -> [MetaRow] -> UTCTime -> Int -> Db MetaLoadResult
seedGraph did opts rows now nSkip = do
  v  <- add (DatasetVersion { id = DatasetVersionId 0, dataset = did, version = opts.version
                            , note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  t  <- add (Target { id = TargetId 0, org = OrgId 1, name = "metaeval", createdAt = now } :: Target)
  tv <- add (TargetVersion { id = TargetVersionId 0, target = t.id, version = 1, model = "n/a"
                           , prompt = "", params = Aeson (object []), createdAt = now } :: TargetVersion)
  r  <- add (Run { id = RunId 0, org = OrgId 1, datasetVersion = v.id, targetVersion = tv.id
                 , status = "succeeded", startedAt = Just now, finishedAt = Just now
                 , meta = Nothing, createdAt = now } :: Run)
  nLabels <- foldM (\acc row -> do
    e <- add (Example { id = ExampleId 0, datasetVersion = v.id, key = row.key
                      , input = Aeson row.input, expected = Just (Aeson row.rubric)
                      , meta = Nothing } :: Example)
    o <- add (Output { id = OutputId 0, run = r.id, example = e.id, response = Nothing
                     , text = Just row.completion, error = Nothing
                     , latencyMs = Nothing, tokens = Nothing } :: Output)
    forM_ row.labels $ \(c, h) ->
      add (CriterionLabel { id = CriterionLabelId 0, output = o.id, criterion = c
                          , human = h, source = Nothing, createdAt = now } :: CriterionLabel)
    pure (acc + length row.labels)) 0 rows
  pure MetaLoadResult { runId = r.id, examples = length rows, labels = nLabels, skipped = nSkip }

-- | Decode + validate each line; on a bad/invalid row, skip (counting) or abort.
adaptAll :: Bool -> [(Int, BS.ByteString)] -> Either MetaLoadError ([MetaRow], Int)
adaptAll skip numbered = fmap (\(rows, n) -> (reverse rows, n)) (foldM step ([], 0) numbered)
  where
    step (acc, nSkip) (n, ln) =
      case validate n ln of
        Right row -> Right (row : acc, nSkip)
        Left e
          | skip      -> Right (acc, nSkip + 1)
          | otherwise -> Left e
    validate n ln = do
      raw <- first (BadLine n . T.pack) (eitherDecodeStrict ln)
      row <- first (BadLine n) (parseMetaRow raw)
      let crits = rubricCriteria row.rubric
      case [ c | (c, _) <- row.labels, c `notElem` crits ] of
        (c : _) -> Left (NoSuchCriterion n c)
        []      -> Right row
