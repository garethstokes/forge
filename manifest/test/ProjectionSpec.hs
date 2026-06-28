{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
module ProjectionSpec (tests) where

import Data.Text (Text)
import Data.Time (UTCTime)
import Manifest.Core.Table
  (Field, Create, Update, Omitted, Patch(..),
   PrimaryKey, Serial, Generated, Default, Secret, ReadOnly, Touched)
import Manifest.Core.Skeleton (neutral)
import Fixtures (UserT(..), UserUpdate)
import Harness

-- Create projection
_createOmitsSerialPk :: Field Create (PrimaryKey (Serial Int)) -> Omitted
_createOmitsSerialPk = id
_createKeepsAppPk     :: Field Create (PrimaryKey Text) -> Text
_createKeepsAppPk     = id
_createOmitsGenerated :: Field Create (Generated UTCTime) -> Omitted
_createOmitsGenerated = id
_createDefaultOptional :: Field Create (Default Text) -> Maybe Text
_createDefaultOptional = id
_createPlainPresent   :: Field Create Text -> Text
_createPlainPresent   = id
_createSecretPresent  :: Field Create (Secret Text) -> Text
_createSecretPresent  = id
_createOmitsReadOnly  :: Field Create (ReadOnly Int) -> Omitted
_createOmitsReadOnly  = id

-- Update projection
_updateOmitsPk      :: Field Update (PrimaryKey (Serial Int)) -> Omitted
_updateOmitsPk      = id
_updateOmitsGen     :: Field Update (Generated UTCTime) -> Omitted
_updateOmitsGen     = id

-- Touched projection (identical to Generated: omitted on Create AND Update)
_createOmitsTouched :: Field Create (Touched UTCTime) -> Omitted
_createOmitsTouched = id
_updateOmitsTouched :: Field Update (Touched UTCTime) -> Omitted
_updateOmitsTouched = id

_updatePatchesPlain  :: Field Update Text -> Patch Text
_updatePatchesPlain  = id
_updatePatchesSecret :: Field Update (Secret Text) -> Patch Text
_updatePatchesSecret = id

tests :: [Test]
tests = group "Projection"
  [ test "type-family projections compile" $ assertBool "ok" True
  , test "neutral Update skeleton is all-Keep; record-update overrides one field" $ do
      let u = (neutral :: UserUpdate) { userEmail = Set (Just "n@x.io") } :: UserUpdate
      assertEqual "untouched name stays Keep"  Keep                  (userName u)
      assertEqual "email is the Set override"  (Set (Just "n@x.io")) (userEmail u)
  ]
