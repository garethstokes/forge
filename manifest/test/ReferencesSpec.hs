{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
module ReferencesSpec (tests) where

import Data.Functor.Identity (Identity)
import GHC.Generics (Generic)
import Manifest.Core.Table (Field, Create, Update, Patch(..), Nullable, References, PrimaryKey, Serial)
import Manifest.Core.Meta (ForeignKey(..))
import Manifest.Entity (Entity(..), Table(..))
import Fixtures (User)
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

tests :: [Test]
tests = group "References"
  [ test "FK projection proofs compile" $ assertBool "ok" True
  , test "genericForeignKeys reflects required + nullable FK targets" $
      assertEqual "fks"
        [ ForeignKey "doc_author" "users" "user_id"
        , ForeignKey "doc_editor" "users" "user_id" ]
        (foreignKeys @Doc)
  ]
