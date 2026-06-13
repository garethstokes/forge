{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Ingestion: turn a JSONL file into a Dataset / DatasetVersion / Examples
-- graph. A 'Format' adapts one parsed JSON object to an 'IngestRow' (the four
-- Example payload fields) or rejects it; 'ingestFile' streams the file and
-- writes the graph in one transaction.
module Evals.Ingest
  ( IngestRow (..)
  , Format
  , generic
  , healthbench
  , formatFor
  , IngestOpts (..)
  , IngestError (..)
  , IngestResult (..)
  , renderIngestError
  , ingestFile
  ) where

import Control.Monad (foldM)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Types as AT
import Data.Bifunctor (first)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)

import Manifest
import Manifest.Postgres (Pool)

import Evals.Ids
import Evals.Schema

data IngestRow = IngestRow
  { key      :: Text
  , input    :: Value
  , expected :: Maybe Value
  , meta     :: Maybe Value
  }
  deriving (Eq, Show)

type Format = Value -> Either Text IngestRow

-- | Reject an empty/whitespace key; the parser fails with the given context.
nonEmptyKey :: Text -> AT.Parser Text
nonEmptyKey k = if T.null (T.strip k) then fail "key must be non-empty" else pure k

-- | Generic format: a top-level @{key, input, expected?, meta?}@ object.
generic :: Format
generic = first T.pack . AT.parseEither
  (AT.withObject "row" $ \o ->
     IngestRow <$> (o AT..: "key" >>= nonEmptyKey) <*> o AT..: "input"
               <*> o AT..:? "expected" <*> o AT..:? "meta")

-- | HealthBench format: wrap the bare @prompt@ array as @{messages: ...}@,
-- pass @rubrics@ through verbatim, fold @example_tags@/
-- @ideal_completions_data@/@canary@ into meta.
healthbench :: Format
healthbench = first T.pack . AT.parseEither
  (AT.withObject "hb" $ \o -> do
     k       <- o AT..: "prompt_id" >>= nonEmptyKey
     prompt  <- o AT..: "prompt"  :: AT.Parser Value
     rubrics <- o AT..: "rubrics" :: AT.Parser Value
     let metaKeys = ["example_tags", "ideal_completions_data", "canary"]
         present  = [ (K.fromText nm, val)
                    | nm <- metaKeys, Just val <- [KM.lookup (K.fromText nm) o] ]
     pure IngestRow
       { key      = k
       , input    = object ["messages" .= prompt]
       , expected = Just rubrics
       , meta     = if null present then Nothing else Just (Object (KM.fromList present))
       })

-- | Resolve a @--format@ name.
formatFor :: Text -> Maybe Format
formatFor "generic"     = Just generic
formatFor "healthbench" = Just healthbench
formatFor _             = Nothing

-- | Everything 'ingestFile' needs. @format@ is the resolved adapter.
data IngestOpts = IngestOpts
  { file    :: FilePath
  , name    :: Text
  , slug    :: Text
  , version :: Int
  , format  :: Format
  , limit   :: Maybe Int
  , skipBad :: Bool
  , force   :: Bool
  }

data IngestError
  = BadLine Int Text
  | AlreadyExists Text Int
  | HasRuns Text Int
  deriving (Eq, Show)

data IngestResult = IngestResult { ingested :: Int, skipped :: Int }
  deriving (Eq, Show)

renderIngestError :: IngestError -> Text
renderIngestError = \case
  BadLine n e       -> "line " <> T.pack (show n) <> ": " <> e
  AlreadyExists s v -> "dataset " <> s <> " v" <> T.pack (show v)
                         <> " already exists (use --force to replace)"
  HasRuns s v       -> "dataset " <> s <> " v" <> T.pack (show v)
                         <> " has runs; delete them before --force"

-- | Read the file, adapt rows, and write the graph in one transaction.
-- Refuses an existing (slug, version) unless 'force'; 'force' is blocked when
-- Runs reference the version (a clean error, not a cascade-Restrict throw).
ingestFile :: Pool -> IngestOpts -> IO (Either IngestError IngestResult)
ingestFile pool opts = do
  contents <- BS.readFile opts.file
  let numbered = zip [1 :: Int ..] (BC.lines contents)
      nonBlank = [ (n, ln) | (n, ln) <- numbered, not (BC.all isSpace ln) ]
      limited  = maybe id take opts.limit nonBlank
  case adaptAll opts.format opts.skipBad limited of
    Left err            -> pure (Left err)
    Right (rows, nSkip) -> do
      now <- getCurrentTime
      withSession pool $ do
        -- These reads are deliberately pre-transaction; the unique index is the
        -- race backstop (single-user CLI).
        existing <- selectWhere [ #slug ==. opts.slug ]
        case (existing :: [Dataset]) of
          (d : _) -> do
            vers <- selectWhere [ #dataset ==. d.id, #version ==. opts.version ]
            case (vers :: [DatasetVersion]) of
              (v : _)
                | not opts.force -> pure (Left (AlreadyExists opts.slug opts.version))
                | otherwise -> do
                    runs <- selectWhere [ #datasetVersion ==. v.id ]
                    if not (null (runs :: [Run]))
                      then pure (Left (HasRuns opts.slug opts.version))
                      else withTransaction $ do
                        delete v
                        flush         -- the queued DELETE must hit the DB before
                                      -- writeVersion's eager INSERT, or the
                                      -- unique (dataset, version) index throws
                        writeVersion d.id opts rows now nSkip
              [] -> withTransaction (writeVersion d.id opts rows now nSkip)
          [] -> withTransaction $ do
            d <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = opts.name
                              , slug = opts.slug, createdAt = now } :: Dataset)
            writeVersion d.id opts rows now nSkip

writeVersion :: DatasetId -> IngestOpts -> [IngestRow] -> UTCTime -> Int -> Db (Either IngestError IngestResult)
writeVersion did opts rows now nSkip = do
  v <- add (DatasetVersion { id = DatasetVersionId 0, dataset = did, version = opts.version
                           , note = Nothing, finalizedAt = Just now, createdAt = now } :: DatasetVersion)
  mapM_ (\r -> add (Example { id = ExampleId 0, datasetVersion = v.id, key = r.key
                            , input = Aeson r.input, expected = fmap Aeson r.expected
                            , meta = fmap Aeson r.meta } :: Example)) rows
  pure (Right (IngestResult { ingested = length rows, skipped = nSkip }))

adaptAll :: Format -> Bool -> [(Int, BS.ByteString)] -> Either IngestError ([IngestRow], Int)
adaptAll fmt skip numbered =
  fmap (\(rows, n) -> (reverse rows, n)) (foldM step ([], 0) numbered)
  where
    step (acc, nSkip) (n, ln) =
      case eitherDecodeStrict ln >>= (first T.unpack . fmt) of
        Right r -> Right (r : acc, nSkip)
        Left err
          | skip      -> Right (acc, nSkip + 1)
          | otherwise -> Left (BadLine n (T.pack err))
