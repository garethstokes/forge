{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module EndToEndSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isPrefixOf)
import Fixtures (User, UserT (..), withTestDb)
import Manifest
import Harness

stmtTexts :: [(BC.ByteString, [Maybe BC.ByteString])] -> [String]
stmtTexts = map (BC.unpack . fst)

tests :: [Test]
tests = group "EndToEnd"
  [ test "edit a plain value -> minimal UPDATE, one transaction, both paths" $
      withTestDb $ \pool -> do
        (finalName, finalEmail, log') <- withSession pool $ do
          u0 <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" } :: User)
          withTransaction $ do
            save (u0 { userName = "Bob" } :: User)                       -- snapshot-diff path
            update @User (Key (userId u0)) [ #userEmail =. ("bob@x.io" :: String) ]  -- command path
          reloaded <- get @User (Key (userId u0))
          l <- statementLog
          pure (fmap userName reloaded, fmap userEmail reloaded, l)
        assertEqual "name"  (Just "Bob") finalName
        assertEqual "email" (Just (Just "bob@x.io")) finalEmail
        let updates = filter ("UPDATE" `isPrefixOf`) (stmtTexts log')
        assertBool "snapshot-diff UPDATE present (only user_name)"
          ("UPDATE users SET user_name = $1 WHERE user_id = $2" `elem` updates)
        assertBool "command-path UPDATE present (user_email)"
          ("UPDATE users SET user_email = $1 WHERE user_id = $2" `elem` updates)
  ]
