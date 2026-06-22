{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module UpdateSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Manifest hiding (update)
import Manifest.Session (runUpdate, statementLog, withSession, update)
import Manifest.Core.Skeleton (neutral)
import Manifest.Core.Table (Patch(..))
import Manifest.Postgres (execText, withConnection)
import Fixtures (User, UserT(..), UserUpdate, withEmptyDb)
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
  , test "update via an explicit Patch changes only the Set columns" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c usersDDL [])
        name <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          update @User (Key (userId u)) ((neutral :: UserUpdate) { userName = Set "Ada Lovelace" } :: UserUpdate)
          got <- get @User (Key (userId u))
          pure (fmap userName got)
        assertEqual "name updated by the patch" (Just "Ada Lovelace") name
  ]
