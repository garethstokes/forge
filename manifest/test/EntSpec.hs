{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module EntSpec (tests) where

import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Fixtures (Post, PostT (..), User, UserT (..), withTestDb)
import Manifest.Entity (Key (..))
import Manifest.Relation.Loaded
import Manifest.Session
import Harness

tests :: [Test]
tests = group "Ent"
  [ test "manage wraps a value with an empty load-set" $
      withTestDb $ \pool -> do
        nm <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          pure (userName (entVal (manage u)))
        assertEqual "entVal" "Ada" nm
  , test "getEnt loads a persistent value with nothing loaded" $
      withTestDb $ \pool -> do
        present <- withTestDbSeedAndGet pool
        assertBool "got an Ent" present
  , test "with #posts records the relation in entRels" $
      withTestDb $ \pool -> do
        keys <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          e0 <- pure (manage u)
          e1 <- with (selectin #posts) e0
          pure (Map.keys (entRels e1))
        assertEqual "loaded key" ["posts"] keys
  , test "rel #posts reads the loaded relation" $
      withTestDb $ \pool -> do
        titles <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          e1 <- with (selectin #posts) (manage u)
          pure (map postTitle (rel #posts e1))
        assertEqual "titles" ["P1"] titles
  ]
  where
    withTestDbSeedAndGet pool = withSession pool $ do
      u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
      me <- getEnt (Key (userId u) :: Key User)
      pure (isJust me)
