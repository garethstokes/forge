{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module IndexSpec (tests) where

import Autodocodec
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as BS
import Data.ByteString (isInfixOf)
import Data.Functor.Identity (Identity)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified GHC.Generics
import Manifest
import Manifest.Core.Index (IndexDef (..), IndexMethod (..))
import Manifest.Session (Db, execDb)
import Fixtures (withEmptyDb)
import Harness

-- A jsonb-bearing entity that declares a GIN index on its jsonb column (so a
-- @> containment query can use an index) plus a btree on a scalar column.
data Prefs = Prefs { prefTheme :: Text, prefTags :: [Text] }
  deriving (Eq, Show)

instance HasCodec Prefs where
  codec = object "Prefs" $
    Prefs <$> requiredField "theme" "ui theme" .= prefTheme
          <*> requiredField "tags"  "tags"     .= prefTags

data DocT f = Doc
  { docId    :: Field f (Pk Int)
  , docName  :: Field f Text
  , docPrefs :: Field f (Json Prefs)
  } deriving GHC.Generics.Generic
type Doc = DocT Identity

-- Hand-written instance (like RlsSpec's Secret) so we can override `indexes`.
instance Entity Doc where
  tableMeta = genericTableMeta @DocT "idx_docs"
  indexes   = [ gin #docPrefs, btree #docName ]

-- The expected derived index names: <table>_<col>_<method>_idx.
ginIdxName :: BS.ByteString
ginIdxName = "idx_docs_doc_prefs_gin_idx"

btreeIdxName :: BS.ByteString
btreeIdxName = "idx_docs_doc_name_btree_idx"

execDb_ :: BS.ByteString -> Db ()
execDb_ s = void (execDb s [])

-- Read the index names live on a table.
liveIdx :: BS.ByteString -> Db [BS.ByteString]
liveIdx table = do
  rows <- execDb "SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename=$1" [Just table]
  pure [ n | [Just n] <- rows ]

-- Read one index's definition.
idxDef :: BS.ByteString -> Db (Maybe BS.ByteString)
idxDef name = do
  rows <- execDb "SELECT indexdef FROM pg_indexes WHERE schemaname='public' AND indexname=$1" [Just name]
  pure $ case rows of
    ([Just d] : _) -> Just d
    _              -> Nothing

tests :: [Test]
tests = group "Index"
  [ test "renderCreateIndex emits CREATE INDEX … USING gin (col)" $ do
      let ddl = renderCreateIndex "idx_docs"
                  (IndexDef "idx_docs_doc_prefs_gin_idx" Gin False ["doc_prefs"])
      assertEqual "gin DDL"
        "CREATE INDEX idx_docs_doc_prefs_gin_idx ON idx_docs USING gin (doc_prefs)"
        ddl
  , test "migrateUp creates the declared GIN (and btree) index using the right method" $
      withEmptyDb $ \pool -> withSession pool $ do
        _   <- migrateUp [managed (Proxy @Doc)]
        idx <- liveIdx "idx_docs"
        gd  <- idxDef ginIdxName
        liftIO $ do
          assertBool ("gin index present: " <> show idx)   (ginIdxName   `elem` idx)
          assertBool ("btree index present: " <> show idx) (btreeIdxName `elem` idx)
          assertBool ("def uses USING gin: " <> show gd)
            (maybe False ("USING gin" `isInfixOf`) gd)
  , test "migrateUp is idempotent: a second run plans no index work" $
      withEmptyDb $ \pool -> withSession pool $ do
        _      <- migrateUp [managed (Proxy @Doc)]
        before <- liveIdx "idx_docs"
        plan   <- migrate  [managed (Proxy @Doc)]
        _      <- migrateUp [managed (Proxy @Doc)]   -- no-op
        after  <- liveIdx "idx_docs"
        liftIO $ do
          assertEqual "second plan has no index work" [] (planIndexes plan)
          assertEqual "index set unchanged" before after
  , test "create-table-and-index in one migrateUp run (fresh DB)" $
      withEmptyDb $ \pool -> withSession pool $ do
        execDb_ "SELECT 1"          -- the DB is otherwise empty: idx_docs absent
        before <- liveIdx "idx_docs"
        _      <- migrateUp [managed (Proxy @Doc)]
        after  <- liveIdx "idx_docs"
        liftIO $ do
          assertEqual "no idx_docs indexes before" [] before
          assertBool  "gin index created with the table" (ginIdxName `elem` after)
  , test "migrateUp creates a UNIQUE multi-column index on (a, b)" $
      withEmptyDb $ \pool -> withSession pool $ do
        _   <- migrateUp [managed (Proxy @Pair)]
        idx <- liveIdx "idx_pairs"
        ud  <- idxDef uniqueIdxName
        liftIO $ do
          assertBool ("unique index present: " <> show idx) (uniqueIdxName `elem` idx)
          assertBool ("def is UNIQUE: " <> show ud)
            (maybe False ("UNIQUE" `isInfixOf`) ud)
          assertBool ("def covers (pair_a, pair_b): " <> show ud)
            (maybe False ("(pair_a, pair_b)" `isInfixOf`) ud)
  ]

-- A small 2-column entity that declares a UNIQUE composite index on (a, b).
data PairT f = Pair
  { pairId :: Field f (Pk Int)
  , pairA  :: Field f Text
  , pairB  :: Field f Text
  } deriving GHC.Generics.Generic
type Pair = PairT Identity

instance Entity Pair where
  tableMeta = genericTableMeta @PairT "idx_pairs"
  indexes   = [ unique [#pairA, #pairB] ]

-- The expected derived unique index name: <table>_<col1>_<col2>_unique_idx.
uniqueIdxName :: BS.ByteString
uniqueIdxName = "idx_pairs_pair_a_pair_b_unique_idx"
