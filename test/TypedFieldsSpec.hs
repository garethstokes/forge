{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module TypedFieldsSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.Text (Text)
import GHC.Generics (Generic)
import Manifest
import Manifest.Postgres (execText, withConnection)
import Fixtures (withEmptyDb)
import Harness

-- A domain newtype declared with ONLY `import Manifest` in scope: proves the
-- column-type classes are re-exported from the umbrella.
newtype Email = Email Text
  deriving stock (Eq, Show)
  deriving newtype (ToField, FromField, ScalarMeta)

newtype AccountId = AccountId Int
  deriving stock (Eq, Show)
  deriving newtype (ToField, FromField, ScalarMeta)

newtype NoteId = NoteId Int
  deriving stock (Eq, Show)
  deriving newtype (ToField, FromField, ScalarMeta)

data AccountT f = Account
  { accountId   :: Col f (PrimaryKey (Serial AccountId))   -- runtime AccountId; column BIGSERIAL
  , accountName :: Col f Text
  } deriving Generic
type Account = AccountT Identity

instance Entity Account where
  type PrimKey Account = AccountId
  tableMeta  = genericTableMeta @AccountT "accounts"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = accountId

data NoteT f = Note
  { noteId      :: Col f (PrimaryKey (Serial NoteId))
  , noteAccount :: Col f AccountId          -- typed FK to accounts.account_id
  , noteBody    :: Col f Text
  } deriving Generic
type Note = NoteT Identity

instance Entity Note where
  type PrimKey Note = NoteId
  tableMeta  = genericTableMeta @NoteT "notes"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = noteId

accountsDDL, notesDDL :: BC.ByteString
accountsDDL = "CREATE TABLE accounts ( account_id BIGSERIAL PRIMARY KEY, account_name TEXT NOT NULL )"
notesDDL    = "CREATE TABLE notes ( note_id BIGSERIAL PRIMARY KEY, note_account BIGINT NOT NULL, note_body TEXT NOT NULL )"

tests :: [Test]
tests = group "TypedFields"
  [ test "a newtype column round-trips through the codec" $
      assertEqual "Email round-trip"
        (Right (Email "ada@x.io"))
        (fromField (toField (Email "ada@x.io")))
  , test "typed PK and typed FK round-trip end to end" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c accountsDDL [] >> execText c notesDDL [])
        (name, body) <- withSession pool $ do
          acc <- add (Account { accountId = AccountId 0, accountName = "Ada" } :: Account)
          _   <- add (Note { noteId = NoteId 0, noteAccount = accountId acc, noteBody = "hi" } :: Note)
          got <- get @Account (Key (accountId acc))
          ns  <- selectWhere [ #noteAccount ==. accountId acc ]
          pure (fmap accountName got, map noteBody (ns :: [Note]))
        assertEqual "account decoded by its typed Key" (Just "Ada") name
        assertEqual "note found via the typed FK" ["hi"] body
  ]
