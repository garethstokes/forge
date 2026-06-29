{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
module ReferencesSpec (tests) where

import Data.Functor.Identity (Identity)
import Manifest.Core.Table (Field, Create, Update, Patch(..), Nullable, References)
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

tests :: [Test]
tests = group "References"
  [ test "FK projection proofs compile" $ assertBool "ok" True ]
