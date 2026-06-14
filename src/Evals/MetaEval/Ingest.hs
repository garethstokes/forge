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
  , MetaRow (..)
  , metaFormatFor
  , renderMetaLoadError
  , metaLoad
  ) where

import Control.Monad (foldM, forM_)
import Data.Aeson (Value (..), eitherDecodeStrict, toJSON, (.=), object)
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
  , version :: Int, format :: Text, skipBad :: Bool, force :: Bool }

data MetaLoadError
  = BadLine Int Text             -- malformed JSON / shape
  | NoSuchCriterion Int Text     -- a label references a criterion absent from the row's rubric
  | AlreadyExists Text Int
  | UnknownFormat Text
  deriving (Eq, Show)

data MetaLoadResult = MetaLoadResult
  { runId :: RunId, examples :: Int, labels :: Int, skipped :: Int }
  deriving (Eq, Show)

renderMetaLoadError :: MetaLoadError -> Text
renderMetaLoadError = \case
  BadLine n e         -> "line " <> tshow n <> ": " <> e
  NoSuchCriterion n c -> "line " <> tshow n <> ": label criterion not in rubric: " <> c
  AlreadyExists s v   -> "dataset " <> s <> " v" <> tshow v <> " already exists (use --force to replace)"
  UnknownFormat f     -> "unknown --format: " <> f <> " (expected generic|healthbench)"
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

-- | Row parsers keyed by --format. The parser takes the line index (used to
-- synthesise a key for formats whose rows aren't self-keyed).
metaFormatFor :: Text -> Maybe (Int -> Value -> Either Text MetaRow)
metaFormatFor "generic"     = Just (\_ v -> parseMetaRow v)
metaFormatFor "healthbench" = Just healthbenchRow
metaFormatFor _             = Nothing

-- | HealthBench consensus row -> one labelled MetaRow: a single-criterion
-- rubric + a majority-vote human label. binary_labels is the physician panel;
-- consensus = mean >= 0.5 (ties -> met). category becomes a single tag.
healthbenchRow :: Int -> Value -> Either Text MetaRow
healthbenchRow i = first T.pack . AT.parseEither
  (AT.withObject "consensus" $ \o -> do
     prompt <- o AT..: "prompt"               :: AT.Parser Value
     comp   <- o AT..: "completion"           :: AT.Parser Text
     crit   <- o AT..: "rubric"               :: AT.Parser Text
     labels <- o AT..: "binary_labels"        :: AT.Parser [Bool]
     cat    <- o AT..:? "category" AT..!= ""  :: AT.Parser Text
     let n      = length labels
         met    = n > 0 && 2 * length (filter id labels) >= n
         tags   = if T.null cat then [] else ["category:" <> cat] :: [Text]
         rubric = toJSON
                    [ object [ "criterion" .= crit, "points" .= (1 :: Int), "tags" .= tags ] ]
     pure MetaRow
       { key        = "hb-" <> T.justifyRight 4 '0' (T.pack (show i))
       , input      = object [ "messages" .= prompt ]
       , rubric     = rubric
       , completion = comp
       , labels     = [ (crit, met) ]
       })

-- | Read the file, adapt + validate rows, seed the graph in one transaction.
metaLoad :: Pool -> MetaLoadOpts -> IO (Either MetaLoadError MetaLoadResult)
metaLoad pool opts = do
  contents <- BS.readFile opts.file
  let numbered = zip [1 :: Int ..] (BC.lines contents)
      nonBlank = [ (n, ln) | (n, ln) <- numbered, not (BC.all isSpace ln) ]
  case metaFormatFor opts.format of
    Nothing       -> pure (Left (UnknownFormat opts.format))
    Just parseRow -> case adaptAll parseRow opts.skipBad nonBlank of
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
adaptAll :: (Int -> Value -> Either Text MetaRow) -> Bool -> [(Int, BS.ByteString)] -> Either MetaLoadError ([MetaRow], Int)
adaptAll parseRow skip numbered = fmap (\(rows, n) -> (reverse rows, n)) (foldM step ([], 0) numbered)
  where
    step (acc, nSkip) (n, ln) =
      case validate n ln of
        Right row -> Right (row : acc, nSkip)
        Left e
          | skip      -> Right (acc, nSkip + 1)
          | otherwise -> Left e
    validate n ln = do
      raw <- first (BadLine n . T.pack) (eitherDecodeStrict ln)
      row <- first (BadLine n) (parseRow n raw)
      let crits = rubricCriteria row.rubric
      case [ c | (c, _) <- row.labels, c `notElem` crits ] of
        (c : _) -> Left (NoSuchCriterion n c)
        []      -> Right row
