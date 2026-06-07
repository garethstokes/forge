{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module CascadeSpec (tests) where

import Data.Proxy (Proxy (..))
import Fixtures (Post)
import Manifest.Core.Cascade (CascadeRule (..), OnDelete (..))
import Manifest.Core.Relation (cascade)
import Harness

tests :: [Test]
tests = group "Cascade"
  [ test "cascade derives the child table + FK column from the child + label" $
      assertEqual "rule"
        (CascadeRule "posts" "post_author" Cascade)
        (cascade (Proxy @Post) (Proxy @"postAuthor") Cascade)
  ]
