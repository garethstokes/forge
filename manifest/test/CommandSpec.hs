{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module CommandSpec (tests) where

import Fixtures (User, UserT (..), withTestDb)
import Manifest.Core.Query
import Manifest.Entity (Key (..))
import Manifest.Session hiding (update)
import Manifest.Session.Command
import Harness

tests :: [Test]
tests = group "Command"
  [ test "update blind-writes a column by key" $
      withTestDb $ \pool -> do
        name <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          update @User (Key (userId u)) [ #userName =. ("Zed" :: String) ]
          mu <- get @User (Key (userId u))
          pure (fmap userName mu)
        assertEqual "updated" (Just "Zed") name
  , test "deleteWhere bulk-deletes matching rows" $
      withTestDb $ \pool -> do
        remaining <- withSession pool $ do
          _ <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (User { userId = 0, userName = "Bob", userEmail = Nothing } :: User)
          deleteWhere @User [ #userName ==. ("Ada" :: String) ]
          us <- selectWhere ([] :: [Cond User])
          pure (map userName us)
        assertEqual "remaining" ["Bob"] remaining
  ]
