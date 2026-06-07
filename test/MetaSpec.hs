{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module MetaSpec (tests) where

import Data.Functor.Identity (Identity)
import Data.Text (Text)
import Manifest.Core.Table (Base, Col, FieldMeta (..), PrimaryKey, Serial)
import Harness

-- Compile-time proofs that Base/Col reduce as intended (won't compile otherwise).
_pkReduces :: Base (PrimaryKey (Serial Int)) -> Int
_pkReduces = id

_colIdentityReduces :: Col Identity (PrimaryKey (Serial Int)) -> Int
_colIdentityReduces = id

_textPassesThrough :: Base Text -> Text
_textPassesThrough = id

tests :: [Test]
tests = group "Table"
  [ test "reflects PK/serial flags from marker structure" $ do
      assertBool "PK(Serial Int) is pk"        (fieldIsPK @(PrimaryKey (Serial Int)))
      assertBool "PK(Serial Int) is serial"    (fieldIsSerial @(PrimaryKey (Serial Int)))
      assertBool "Text is not pk"              (not (fieldIsPK @Text))
      assertBool "Text is not serial"          (not (fieldIsSerial @Text))
      assertBool "Serial Int is serial"        (fieldIsSerial @(Serial Int))
      assertBool "Serial Int is not pk"        (not (fieldIsPK @(Serial Int)))
  ]
