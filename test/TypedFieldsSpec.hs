{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module TypedFieldsSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.List (isInfixOf)
import Data.Text (Text)
import GHC.Generics (Generic)
import Manifest
import Manifest.Postgres (execText, withConnection)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)
import Fixtures (withEmptyDb)
import Harness

-- A domain newtype declared with ONLY `import Manifest` in scope: proves the
-- column-type classes are re-exported from the umbrella.
newtype Email = Email Text
  deriving stock (Eq, Show)
  deriving newtype (ToField, FromField, ScalarMeta, DbType)

newtype AccountId = AccountId Int
  deriving stock (Eq, Show)
  deriving newtype (ToField, FromField, ScalarMeta, DbType)

newtype NoteId = NoteId Int
  deriving stock (Eq, Show)
  deriving newtype (ToField, FromField, ScalarMeta, DbType)

data AccountT f = Account
  { accountId   :: Col f (PrimaryKey (Serial AccountId))   -- runtime AccountId; column BIGSERIAL
  , accountName :: Col f Text
  } deriving Generic
type Account = AccountT Identity

deriving via (Table "accounts" AccountT) instance Entity Account

data NoteT f = Note
  { noteId      :: Col f (PrimaryKey (Serial NoteId))
  , noteAccount :: Col f AccountId          -- typed FK to accounts.account_id
  , noteBody    :: Col f Text
  } deriving Generic
type Note = NoteT Identity

deriving via (Table "notes" NoteT) instance Entity Note

-- A brand-new plain entity declared ONLY via the deriving-via one-liner (no
-- explicit Entity instance body): proves a fresh entity round-trips end to end.
data GadgetT f = Gadget
  { gadgetId   :: Col f (PrimaryKey (Serial Int))
  , gadgetName :: Col f Text
  } deriving Generic
type Gadget = GadgetT Identity

deriving via (Table "gadgets" GadgetT) instance Entity Gadget

accountsDDL, notesDDL, gadgetsDDL :: BC.ByteString
accountsDDL = "CREATE TABLE accounts ( account_id BIGSERIAL PRIMARY KEY, account_name TEXT NOT NULL )"
notesDDL    = "CREATE TABLE notes ( note_id BIGSERIAL PRIMARY KEY, note_account BIGINT NOT NULL, note_body TEXT NOT NULL )"
gadgetsDDL  = "CREATE TABLE gadgets ( gadget_id BIGSERIAL PRIMARY KEY, gadget_name TEXT NOT NULL )"

wrongIdSource :: String
wrongIdSource = unlines
  [ "{-# LANGUAGE DataKinds #-}"
  , "{-# LANGUAGE DerivingStrategies #-}"
  , "{-# LANGUAGE GeneralizedNewtypeDeriving #-}"
  , "module WrongId where"
  , "import Data.Functor.Identity (Identity)"
  , "import Manifest (Col)"
  , "import Manifest.Core.Codec (ToField, FromField)"
  , "import Manifest.Core.Table (ScalarMeta)"
  , "newtype AccountId = AccountId Int deriving newtype (ToField, FromField, ScalarMeta)"
  , "newtype NoteId    = NoteId Int    deriving newtype (ToField, FromField, ScalarMeta)"
  , "data R f = R { rAcc :: Col f AccountId }"
  , "boom :: R Identity"
  , "boom = R { rAcc = NoteId 1 }"
  ]

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
  , test "a deriving-via plain entity round-trips end to end" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c gadgetsDDL [])
        (byKey, byCol) <- withSession pool $ do
          g   <- add (Gadget { gadgetId = 0, gadgetName = "wrench" } :: Gadget)
          got <- get @Gadget (Key (gadgetId g))
          gs  <- selectWhere [ #gadgetName ==. ("wrench" :: Text) ]
          pure (fmap gadgetName got, map gadgetName (gs :: [Gadget]))
        assertEqual "gadget decoded by its derived Key" (Just "wrench") byKey
        assertEqual "gadget found via selectWhere on a column" ["wrench"] byCol
  , test "a typed FK rejects the wrong id newtype at compile time" $ do
      tmp <- getTemporaryDirectory
      (path, h) <- openTempFile tmp "WrongId.hs"
      hClose h
      writeFile path wrongIdSource
      (_code, _out, err) <-
        readProcessWithExitCode "ghc"
          [ "-fno-code", "-fforce-recomp"
          , "-package-db", ".zinc/pkgdb"
          , "-i.zinc/lib"
          , path
          ]
          ""
      removeFile path
      let msg = unwords (words err)
      assertBool ("mentions AccountId; output was:\n" <> err) ("AccountId" `isInfixOf` msg)
      assertBool ("mentions NoteId; output was:\n" <> err)    ("NoteId"    `isInfixOf` msg)
  ]
