{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module SessionSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Fixtures (User, UserT (..), withTestDb)
import Manifest.Core.Query
import Manifest.Entity (Key (..))
import Manifest.Postgres (Connection, execText, withConnection)
import Manifest.Session
import Harness

seed :: Connection -> IO ()
seed conn = do
  _ <- execText conn
         "INSERT INTO users (user_name, user_email) VALUES ($1,$2),($3,$4)"
         [ Just (BC.pack "Ada"), Just (BC.pack "ada@x.io")
         , Just (BC.pack "Bob"), Nothing ]
  pure ()

tests :: [Test]
tests = group "Session(read)"
  [ test "get returns Nothing for a missing key" $
      withTestDb $ \pool -> do
        mu <- withSession pool (get @User (Key 999))
        assertEqual "missing" Nothing (fmap userId mu)
  , test "get loads a row by primary key" $
      withTestDb $ \pool -> do
        withConnection pool seed
        mu <- withSession pool (get @User (Key 1))
        assertEqual "ada" (Just (1 :: Int, "Ada", Just "ada@x.io"))
          (fmap (\u -> (userId u, userName u, userEmail u)) mu)
  , test "selectWhere filters by condition" $
      withTestDb $ \pool -> do
        withConnection pool seed
        us <- withSession pool (selectWhere [#userName ==. ("Bob" :: String)]) :: IO [User]
        assertEqual "bob" [("Bob", Nothing)] (map (\u -> (userName u, userEmail u)) us)
  ]
