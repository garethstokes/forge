{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}

module FlushSpec (tests) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import GHC.Generics (Generic)
import Fixtures (User, UserT (..), withEmptyDb, withTestDb)
import Manifest
import Manifest.Core.Table (Field, Generated, PrimaryKey, Serial)
import Manifest.Core.Query (Cond)
import Manifest.Entity (Key (..))
import Manifest.Postgres (execText, withConnection)
import Manifest.Session
import Harness

data EventT f = Event
  { eventId   :: Field f (PrimaryKey (Serial Int))
  , eventName :: Field f Text
  , eventAt   :: Field f (Generated UTCTime)
  } deriving Generic
type Event = EventT Identity
deriving via (Table "events" EventT) instance Entity Event

eventsDDL :: BC.ByteString
eventsDDL = "CREATE TABLE events ( event_id BIGSERIAL PRIMARY KEY, event_name TEXT NOT NULL, event_at TIMESTAMPTZ NOT NULL DEFAULT now() )"

t1, t2 :: UTCTime
t1 = UTCTime (fromGregorian 2020 1 1) (secondsToDiffTime 0)
t2 = UTCTime (fromGregorian 2021 1 1) (secondsToDiffTime 0)

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
  , test "flushSave skips generated columns even when mutated in memory" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c eventsDDL [])
        sqls <- withSession pool $ do
          e <- add (Event { eventId = 0, eventName = "boot", eventAt = t1 } :: Event)
          save ((e { eventName = "boot2", eventAt = t2 }) :: Event)   -- mutate a normal AND the generated col
          flush
          map (BC.unpack . fst) <$> statementLog
        let upd = filter (isInfixOf "UPDATE") sqls
        assertBool ("one UPDATE expected; got " <> show sqls) (length upd == 1)
        assertBool "UPDATE sets event_name"                   (any (isInfixOf "event_name") upd)
        assertBool "UPDATE does NOT set event_at (generated)" (not (any (isInfixOf "event_at") upd))
  , test "flush of an unchanged managed entity emits no UPDATE" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c eventsDDL [])
        sqls <- withSession pool $ do
          e <- add (Event { eventId = 0, eventName = "boot", eventAt = t1 } :: Event)
          save e
          flush
          map (BC.unpack . fst) <$> statementLog
        assertBool ("no UPDATE expected; got " <> show sqls) (not (any (isInfixOf "UPDATE") sqls))
  ]
