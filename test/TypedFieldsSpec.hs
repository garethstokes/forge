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

tests :: [Test]
tests = group "TypedFields"
  [ test "a newtype column round-trips through the codec" $
      assertEqual "Email round-trip"
        (Right (Email "ada@x.io"))
        (fromField (toField (Email "ada@x.io")))
  ]
