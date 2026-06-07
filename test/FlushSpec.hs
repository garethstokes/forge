{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module FlushSpec (tests) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Char8 as BC
import Data.List (isPrefixOf)
import Fixtures (User, UserT (..), withTestDb)
import Manifest.Core.Query (Cond)
import Manifest.Entity (Key (..))
import Manifest.Session
import Harness

dataStmts :: [(BC.ByteString, [Maybe BC.ByteString])] -> [String]
dataStmts = map (BC.unpack . fst)

tests :: [Test]
tests = group "Flush"
  [ test "add inserts eagerly and returns the PK-filled record" $
      withTestDb $ \pool -> do
        u <- withSession pool $ add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" } :: User)
        assertBool  "pk assigned" (userId u > 0)
        assertEqual "name" "Ada" (userName u)
  , test "save of a changed field emits a MINIMAL update (only that column)" $
      withTestDb $ \pool -> do
        log' <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" } :: User)
          withTransaction $ save (u { userName = "Bob" } :: User)
          statementLog
        assertEqual "minimal update"
          ["UPDATE users SET user_name = $1 WHERE user_id = $2"]
          (filter ("UPDATE" `isPrefixOf`) (dataStmts log'))
  , test "save with no change emits no UPDATE" $
      withTestDb $ \pool -> do
        log' <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          withTransaction $ save u
          statementLog
        assertEqual "no update" [] (filter ("UPDATE" `isPrefixOf`) (dataStmts log'))
  , test "the saved change is persisted (re-load sees it)" $
      withTestDb $ \pool -> do
        name <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          withTransaction $ save (u { userName = "Bob" } :: User)
          mu <- get @User (Key (userId u))
          pure (fmap userName mu)
        assertEqual "persisted" (Just "Bob") name
  , test "delete removes the row" $
      withTestDb $ \pool -> do
        after <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          withTransaction $ delete u
          mu <- get @User (Key (userId u))
          pure (fmap userId mu)
        assertEqual "deleted" Nothing after
  , test "rolls back the transaction on exception" $
      withTestDb $ \pool -> do
        _ <- (try :: IO a -> IO (Either SomeException a)) $ withSession pool $ do
               u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
               withTransaction $ do
                 save (u { userName = "Bob" } :: User)
                 -- autoflush emits the UPDATE *inside* the transaction, so the
                 -- exception below must ROLLBACK an already-issued write (proving
                 -- the bracket; without this the txn would wrap no DML).
                 _ <- get @User (Key (userId u))
                 _ <- liftIO (ioError (userError "boom"))
                 pure ()
        names <- withSession pool (selectWhere ([] :: [Cond User]))
        assertEqual "rolled back" ["Ada"] (map userName names)
  ]
