{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}

module TouchedSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import GHC.Generics (Generic)
import Manifest.Core.Table (Field, PrimaryKey, Serial, Generated, Touched)
import Manifest.Core.Sql (renderUpdate)
import Manifest.Core.Query ((=.))
import Manifest.Derive (Table (..))
import Manifest.Entity (Entity (..), Key (..))
import Manifest.Session (add, get, save, withSession, withTransaction, statementLog)
import Manifest.Session.Command (update)
import Manifest.Postgres (execText, withConnection)
import Fixtures (withEmptyDb)
import Harness

-- A doc with a Generated created_at (insert-only) and a Touched updated_at
-- (insert + re-stamped on every UPDATE).
data DocT f = Doc
  { docId      :: Field f (PrimaryKey (Serial Int))
  , docTitle   :: Field f Text
  , docCreated :: Field f (Generated UTCTime)
  , docUpdated :: Field f (Touched UTCTime)
  } deriving Generic
type Doc = DocT Identity
deriving via (Table "docs" DocT) instance Entity Doc

docsDDL :: BC.ByteString
docsDDL =
  "CREATE TABLE docs \
  \( doc_id      BIGSERIAL PRIMARY KEY \
  \, doc_title   TEXT NOT NULL \
  \, doc_created TIMESTAMPTZ NOT NULL DEFAULT now() \
  \, doc_updated TIMESTAMPTZ NOT NULL DEFAULT now() )"

t2020 :: UTCTime
t2020 = UTCTime (fromGregorian 2020 1 1) (secondsToDiffTime 0)

tests :: [Test]
tests = group "Touched"
  [ test "renderUpdate appends touched columns as `= now()` after the param sets" $
      assertEqual "upd"
        "UPDATE docs SET doc_title = $1, doc_updated = now() WHERE doc_id = $2"
        (renderUpdate (tableMeta @Doc) ["doc_title"] "doc_id")
  , test "touched literal does not consume a placeholder (PK index = #setCols + 1)" $
      assertEqual "pk-index"
        "UPDATE docs SET doc_title = $1, doc_created = $2, doc_updated = now() WHERE doc_id = $3"
        (renderUpdate (tableMeta @Doc) ["doc_title", "doc_created"] "doc_id")
  , test "save (snapshot-diff) stamps updated_at and leaves created_at" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c docsDDL [])
        sqls <- withSession pool $ do
          d <- add (Doc { docId = 0, docTitle = "draft"
                        , docCreated = t2020, docUpdated = t2020 } :: Doc)
          withTransaction $ save (d { docTitle = "final" } :: Doc)
          map (BC.unpack . fst) <$> statementLog
        let upd = filter ("UPDATE" `isPrefixOf`) sqls
        assertBool ("one UPDATE expected; got " <> show sqls) (length upd == 1)
        assertBool "UPDATE sets doc_title"                 (any (isInfixOf "doc_title = $1")     upd)
        assertBool "UPDATE stamps doc_updated = now()"     (any (isInfixOf "doc_updated = now()") upd)
        assertBool "UPDATE does NOT touch doc_created"     (not (any (isInfixOf "doc_created")    upd))
  , test "update (explicit command) stamps updated_at and leaves created_at" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c docsDDL [])
        sqls <- withSession pool $ do
          d <- add (Doc { docId = 0, docTitle = "draft"
                        , docCreated = t2020, docUpdated = t2020 } :: Doc)
          withTransaction $ update @Doc (Key (docId d)) [ #docTitle =. ("renamed" :: Text) ]
          map (BC.unpack . fst) <$> statementLog
        let upd = filter ("UPDATE" `isPrefixOf`) sqls
        assertBool ("one UPDATE expected; got " <> show sqls) (length upd == 1)
        assertBool "UPDATE stamps doc_updated = now()"  (any (isInfixOf "doc_updated = now()") upd)
        assertBool "UPDATE does NOT touch doc_created"  (not (any (isInfixOf "doc_created")    upd))
  , test "get after update: docCreated unchanged, docUpdated advanced beyond t2020" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c docsDDL [])
        (orig, mb) <- withSession pool $ do
          d <- add (Doc { docId = 0, docTitle = "draft"
                        , docCreated = t2020, docUpdated = t2020 } :: Doc)
          withTransaction $ save (d { docTitle = "final" } :: Doc)
          mb <- get @Doc (Key (docId d))
          pure (d, mb)
        case mb of
          Nothing  -> assertBool "row should exist after insert+update" False
          Just row -> do
            assertEqual "docCreated unchanged" (docCreated orig) (docCreated row)
            assertBool  "docUpdated advanced"  (docUpdated row /= t2020)
  , test "renderUpdate with no set columns still stamps touched (PK at $1)" $
      assertEqual "empty-set"
        "UPDATE docs SET doc_updated = now() WHERE doc_id = $1"
        (renderUpdate (tableMeta @Doc) [] "doc_id")
  ]
