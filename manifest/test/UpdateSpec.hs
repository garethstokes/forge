{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module UpdateSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Manifest
import Manifest.Session (runUpdate, statementLog, withSession)
import Manifest.Postgres (execText, withConnection)
import Fixtures (User, UserT(..), withEmptyDb)
import Harness

usersDDL :: BC.ByteString
usersDDL = "CREATE TABLE users ( user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL, user_email TEXT )"

tests :: [Test]
tests = group "Update"
  [ test "runUpdate renders a minimal UPDATE for the given assignments" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c usersDDL [])
        sqls <- withSession pool $ do
          runUpdate @User (Just (BC.pack "7"))
            [ (BC.pack "user_name", Just (BC.pack "Ada")) ]
          map (BC.unpack . fst) <$> statementLog
        assertBool ("an UPDATE of user_name expected; got " <> show sqls)
          (any (\s -> "UPDATE" `isInfixOf` s && "user_name" `isInfixOf` s) sqls)
  , test "runUpdate with no assignments emits no statement" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c usersDDL [])
        sqls <- withSession pool $ do
          runUpdate @User (Just (BC.pack "7")) []
          map fst <$> statementLog
        assertEqual "no statements logged" 0 (length sqls)
  ]
