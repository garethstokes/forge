{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module UpdateSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Manifest
import Manifest.Session (withSession)
import Manifest.Session.Command (patch)
import Manifest.Core.Skeleton (neutral)
import Manifest.Core.Table (Patch(..))
import Manifest.Postgres (execText, withConnection)
import Fixtures (User, UserT(..), UserUpdate, withEmptyDb)
import Harness

usersDDL :: BC.ByteString
usersDDL = "CREATE TABLE users ( user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL, user_email TEXT )"

tests :: [Test]
tests = group "Update"
  [ test "patch via an explicit Patch changes only the Set columns" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c usersDDL [])
        name <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          patch @User (Key (userId u)) ((neutral :: UserUpdate) { userName = Set "Ada Lovelace" } :: UserUpdate)
          got <- get @User (Key (userId u))
          pure (fmap userName got)
        assertEqual "name updated by the patch" (Just "Ada Lovelace") name
  ]
