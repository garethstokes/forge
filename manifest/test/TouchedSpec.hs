{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}

module TouchedSpec (tests) where

import Data.Functor.Identity (Identity)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Manifest.Core.Table (Field, PrimaryKey, Serial, Generated, Touched)
import Manifest.Core.Sql (renderUpdate)
import Manifest.Derive (Table (..))
import Manifest.Entity (Entity (..))
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
  ]
