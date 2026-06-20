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
import GoldenGhc (goldenGhcArgs)
import Fixtures (withEmptyDb)
import Harness

-- A domain newtype declared with ONLY `import Manifest` in scope: proves the
-- column-type classes are re-exported from the umbrella.
newtype Email = Email Text
  deriving stock (Eq, Show)
  deriving newtype DbType

newtype AccountId = AccountId Int
  deriving stock (Eq, Show)
  deriving newtype DbType

newtype NoteId = NoteId Int
  deriving stock (Eq, Show)
  deriving newtype DbType

-- A domain column whose codec is built EXPLICITLY with `dimap` (not GND):
-- proves the dimap path round-trips end to end through the DB.
newtype Cents = Cents Int
  deriving stock (Eq, Show)

instance DbType Cents where
  dbType = dimap (\(Cents n) -> n) Cents (dbType @Int)

data ItemT f = Item
  { itemId    :: Field f (PrimaryKey (Serial Int))
  , itemPrice :: Field f Cents
  } deriving Generic
type Item = ItemT Identity

deriving via (Table "items" ItemT) instance Entity Item

data AccountT f = Account
  { accountId   :: Field f (PrimaryKey (Serial AccountId))   -- runtime AccountId; column BIGSERIAL
  , accountName :: Field f Text
  } deriving Generic
type Account = AccountT Identity

deriving via (Table "accounts" AccountT) instance Entity Account

data NoteT f = Note
  { noteId      :: Field f (PrimaryKey (Serial NoteId))
  , noteAccount :: Field f AccountId          -- typed FK to accounts.account_id
  , noteBody    :: Field f Text
  } deriving Generic
type Note = NoteT Identity

deriving via (Table "notes" NoteT) instance Entity Note

-- A brand-new plain entity declared ONLY via the deriving-via one-liner (no
-- explicit Entity instance body): proves a fresh entity round-trips end to end.
data GadgetT f = Gadget
  { gadgetId   :: Field f (PrimaryKey (Serial Int))
  , gadgetName :: Field f Text
  } deriving Generic
type Gadget = GadgetT Identity

deriving via (Table "gadgets" GadgetT) instance Entity Gadget

-- A 4+-field entity: GHC builds a BALANCED Generic Rep tree for these, so the
-- first field sits at the left spine of a nested (:*:). GPrimKeyType must recurse
-- the left branch to reach it; this guards that core type-family invariant inside
-- the library's own suite (all other test entities are <= 3 fields).
data WideT f = Wide
  { wideId :: Field f (PrimaryKey (Serial Int))
  , wideA  :: Field f Text
  , wideB  :: Field f Int
  , wideC  :: Field f Bool
  } deriving Generic
type Wide = WideT Identity

deriving via (Table "wides" WideT) instance Entity Wide

accountsDDL, notesDDL, gadgetsDDL, itemsDDL :: BC.ByteString
accountsDDL = "CREATE TABLE accounts ( account_id BIGSERIAL PRIMARY KEY, account_name TEXT NOT NULL )"
notesDDL    = "CREATE TABLE notes ( note_id BIGSERIAL PRIMARY KEY, note_account BIGINT NOT NULL, note_body TEXT NOT NULL )"
gadgetsDDL  = "CREATE TABLE gadgets ( gadget_id BIGSERIAL PRIMARY KEY, gadget_name TEXT NOT NULL )"
itemsDDL    = "CREATE TABLE items ( item_id BIGSERIAL PRIMARY KEY, item_price BIGINT NOT NULL )"

wrongIdSource :: String
wrongIdSource = unlines
  [ "{-# LANGUAGE DataKinds #-}"
  , "{-# LANGUAGE DerivingStrategies #-}"
  , "{-# LANGUAGE GeneralizedNewtypeDeriving #-}"
  , "module WrongId where"
  , "import Data.Functor.Identity (Identity)"
  , "import Manifest (Field)"
  , "import Manifest.Core.Codec (DbType)"
  , "newtype AccountId = AccountId Int deriving newtype DbType"
  , "newtype NoteId    = NoteId Int    deriving newtype DbType"
  , "data R f = R { rAcc :: Field f AccountId }"
  , "boom :: R Identity"
  , "boom = R { rAcc = NoteId 1 }"
  ]

tests :: [Test]
tests = group "TypedFields"
  [ test "primKey of a 4+-field entity (balanced Rep) is the first field" $
      assertEqual "first field is the PK"
        (7 :: Int)
        (primKey (Wide { wideId = 7, wideA = "x", wideB = 3, wideC = True } :: Wide))
  , test "a newtype column round-trips through the codec" $
      assertEqual "Email round-trip"
        (Right (Email "ada@x.io"))
        (cDecode dbType (encode (Email "ada@x.io")))
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
  , test "a dimap-defined domain column round-trips through the DB" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c itemsDDL [])
        out <- withSession pool $ do
          i  <- add (Item { itemId = 0, itemPrice = Cents 1999 } :: Item)
          mi <- get @Item (Key (itemId i))
          is <- selectWhere [ #itemPrice ==. Cents 1999 ]
          pure (fmap itemPrice mi, map itemPrice (is :: [Item]))
        assertEqual "got price by key" (Just (Cents 1999)) (fst out)
        assertEqual "found by typed col" [Cents 1999] (snd out)
  , test "a typed FK rejects the wrong id newtype at compile time" $ do
      tmp <- getTemporaryDirectory
      (path, h) <- openTempFile tmp "WrongId.hs"
      hClose h
      writeFile path wrongIdSource
      ghcArgs <- goldenGhcArgs
      (_code, _out, err) <-
        readProcessWithExitCode "ghc"
          ( [ "-fno-code", "-fforce-recomp" ] ++ ghcArgs ++ [ path ] )
          ""
      removeFile path
      let msg = unwords (words err)
      assertBool ("mentions AccountId; output was:\n" <> err) ("AccountId" `isInfixOf` msg)
      assertBool ("mentions NoteId; output was:\n" <> err)    ("NoteId"    `isInfixOf` msg)
  ]
