{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
module ReferencesSpec (tests) where

import Control.Exception (try, SomeException)
import Data.Functor.Identity (Identity)
import Data.List (isInfixOf)
import Data.Proxy (Proxy(..))
import GHC.Generics (Generic)
import Manifest.Core.Cascade (OnDelete(..))
import Manifest.Core.Meta (ColumnMeta(..), ForeignKey(..), SqlType(..), genericTableMeta)
import Manifest.Core.Query (Cond)
import Manifest.Core.Relation (cascade)
import Manifest.Core.Table (Field, Create, Update, Patch(..), Nullable, References, PrimaryKey, Serial)
import Manifest.Entity (Entity(..), Table(..))
import Manifest.Migrate (ManagedTable(..), managed, renderCreateTable, renderAddColumn, renderAddForeignKey, migrateUp, foreignKeyPlan, MigrationPlan)
import Manifest.Session (withSession, withTransaction, add, delete, selectWhere)
import Fixtures (User, UserT(..), withEmptyDb)
import Harness

-- Projection proofs: an FK column is a readwrite scalar of the target's PK type.
_createFkScalar :: Field Create (References User) -> Int
_createFkScalar = id
_identityFkScalar :: Field Identity (References User) -> Int
_identityFkScalar = id
_updateFkPatch :: Field Update (References User) -> Patch Int
_updateFkPatch = id
_createNullableFk :: Field Create (Nullable (References User)) -> Maybe Int
_createNullableFk = id

-- Fixture: a Doc entity with a required and a nullable FK to User.
-- Reused by Tasks 4 and 5 (DDL + migration).
data DocT f = Doc
  { docId     :: Field f (PrimaryKey (Serial Int))
  , docAuthor :: Field f (References User)           -- required FK
  , docEditor :: Field f (Nullable (References User)) -- nullable FK
  } deriving Generic
type Doc = DocT Identity
deriving via (Table "docs" DocT) instance Entity Doc

-- Fixtures for cascade-compatibility test: mutually referencing Owner/Item pair.
-- Owner declares a Cascade rule pointing at Item; Item has a References FK to Owner.
-- ownerSeq is a required dummy field: renderInsert needs at least one non-serial column.
data OwnerT f = Owner
  { ownerId  :: Field f (PrimaryKey (Serial Int))
  , ownerSeq :: Field f Int } deriving Generic
type Owner = OwnerT Identity
instance Entity Owner where
  tableMeta    = genericTableMeta @OwnerT "owners"
  cascadeRules = [ cascade (Proxy @Item) (Proxy @"itemOwner") Cascade ]

data ItemT f = Item
  { itemId    :: Field f (PrimaryKey (Serial Int))
  , itemOwner :: Field f (References Owner) } deriving Generic
type Item = ItemT Identity
deriving via (Table "items" ItemT) instance Entity Item

tests :: [Test]
tests = group "References"
  [ test "FK projection proofs compile" $ assertBool "ok" True
  , test "genericForeignKeys reflects required + nullable FK targets" $
      assertEqual "fks"
        [ ForeignKey "doc_author" "users" "user_id"
        , ForeignKey "doc_editor" "users" "user_id" ]
        (foreignKeys @Doc)
  , test "renderCreateTable emits columns only (no inline FK)" $
      assertEqual "create"
        "CREATE TABLE docs (doc_id BIGSERIAL PRIMARY KEY, doc_author BIGINT NOT NULL, doc_editor BIGINT)"
        (renderCreateTable (managed (Proxy @Doc)))
  , test "renderAddColumn emits no inline FK (2-arg)" $
      assertEqual "add"
        "ALTER TABLE docs ADD COLUMN doc_author BIGINT NOT NULL"
        (renderAddColumn "docs" (ColumnMeta "doc_author" False False False False SqlBigInt False))
  , test "renderAddForeignKey renders the ALTER TABLE ADD CONSTRAINT statement" $
      assertEqual "addfk"
        "ALTER TABLE docs ADD CONSTRAINT docs_doc_author_fkey FOREIGN KEY (doc_author) REFERENCES users(user_id)"
        (renderAddForeignKey "docs" (ForeignKey "doc_author" "users" "user_id"))
  , test "DB rejects an FK-violating insert" $
      withEmptyDb $ \pool -> do
        r <- try $ withSession pool $ do
               _ <- migrateUp [managed (Proxy @User), managed (Proxy @Doc)]
               add (Doc { docId = 0, docAuthor = 999, docEditor = Nothing } :: Doc)
        case (r :: Either SomeException Doc) of
          Left e  -> assertBool ("expected FK violation, got: " <> show e)
                                ("foreign key" `isInfixOf` show e)
          Right _ -> assertBool "expected FK violation for author=999" False
  , test "nullable FK insert with a valid editor succeeds and round-trips" $
      withEmptyDb $ \pool -> do
        doc <- withSession pool $ do
          _ <- migrateUp [managed (Proxy @User), managed (Proxy @Doc)]
          u <- add (User { userId = 0, userName = "u", userEmail = Nothing } :: User)
          add (Doc { docId = 0, docAuthor = userId u, docEditor = Just (userId u) } :: Doc)
        assertEqual "docEditor round-trips" (Just (docAuthor doc)) (docEditor doc)
  , test "app cascade composes with a NO ACTION FK (parent delete succeeds, child cascaded)" $
      withEmptyDb $ \pool -> do
        childGone <- withSession pool $ do
          _ <- migrateUp [managed (Proxy @Owner), managed (Proxy @Item)]
          o <- add (Owner { ownerId = 0, ownerSeq = 1 } :: Owner)
          _ <- add (Item { itemId = 0, itemOwner = ownerId o } :: Item)
          withTransaction $ delete o     -- app cascade deletes items first, then the owner
          items <- selectWhere ([] :: [Cond Item])
          pure (null items)
        assertBool "child cascaded and parent delete succeeded despite NO ACTION FK" childGone
  , test "migrateUp succeeds with child listed before parent (ordering-independent)" $
      withEmptyDb $ \pool -> do
        -- migrate with child (Doc) listed before parent (User) — must not throw
        migrateResult <- try $ withSession pool $ do
               _ <- migrateUp [managed (Proxy @Doc), managed (Proxy @User)]   -- child first
               pure ()
        case (migrateResult :: Either SomeException ()) of
          Left e -> assertBool ("migrateUp failed with child-first order: " <> show e) False
          Right () -> do
            -- FK must be enforced: insert a Doc with a non-existent author
            r <- try $ withSession pool $
                   add (Doc { docId = 0, docAuthor = 999, docEditor = Nothing } :: Doc)
            case (r :: Either SomeException Doc) of
              Left e  -> assertBool ("FK enforced: " <> show e) ("foreign key" `isInfixOf` show e)
              Right _ -> assertBool "FK constraint was not enforced" False
  , test "FK post-pass is idempotent (a second migrateUp is a clean no-op)" $
      withEmptyDb $ \pool -> do
        let tables = [managed (Proxy @User), managed (Proxy @Doc)]
        -- First migrate creates the tables + FK constraint.
        _ <- withSession pool $ migrateUp tables
        -- Second migrate must NOT raise (no duplicate-constraint error) ...
        r <- try (withSession pool $ migrateUp tables)
        case (r :: Either SomeException MigrationPlan) of
          Left e  -> assertBool ("second migrateUp raised: " <> show e) False
          Right _ -> pure ()
        -- ... and there must be no pending FK work.
        pending <- withSession pool $ foreignKeyPlan tables
        assertEqual "no pending FK statements after migrate" [] pending
  ]
