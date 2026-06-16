{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module JoinedSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Data.Text (Text)
import Fixtures (Post, PostT (..), Profile, ProfileT (..), User, UserT (..), withTestDb)
import Manifest.Relation.Loaded
import Manifest.Session
import Harness

stmts :: [(BC.ByteString, [Maybe BC.ByteString])] -> [String]
stmts = map (BC.unpack . fst)

tests :: [Test]
tests = group "Joined"
  [ test "joined #posts (Many) loads children via a LEFT JOIN" $
      withTestDb $ \pool -> do
        (titles, log') <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          e1 <- with (joined #posts) (manage u)
          l  <- statementLog
          pure (map postTitle (rel #posts e1), l)
        assertEqual "titles" ["P1", "P2"] titles
        assertBool "used a LEFT JOIN" (any ("LEFT JOIN" `isInfixOf`) (stmts log'))
  , test "joined #posts with no children yields [] (LEFT JOIN miss skipped)" $
      withTestDb $ \pool -> do
        ps <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          e1 <- with (joined #posts) (manage u)
          pure (map postTitle (rel #posts e1))
        assertEqual "no posts" ([] :: [Text]) ps
  , test "joined #profile (Opt) loads Nothing/Just" $
      withTestDb $ \pool -> do
        (none, some) <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          e0 <- with (joined #profile) (manage u)
          _  <- add (Profile { profileId = 0, profileUser = Just (userId u), profileBio = "hi" } :: Profile)
          e1 <- with (joined #profile) (manage u)
          pure (rel #profile e0, rel #profile e1)
        assertEqual "none" Nothing (fmap profileBio none)
        assertEqual "some" (Just "hi") (fmap profileBio some)
  , test "joined #author (One, belongs-to) loads the target via LEFT JOIN" $
      withTestDb $ \pool -> do
        (nm, log') <- withSession pool $ do
          -- Decoys so the real post's PK (3) /= its FK (post_author=2): the
          -- joined forward-FK must key the JOIN on post_author, not post_id.
          d  <- add (User { userId = 0, userName = "Decoy", userEmail = Nothing } :: User)  -- user_id 1
          u  <- add (User { userId = 0, userName = "Ada",   userEmail = Nothing } :: User)  -- user_id 2
          _  <- add (Post { postId = 0, postAuthor = userId d, postTitle = "D1" } :: Post)  -- post_id 1
          _  <- add (Post { postId = 0, postAuthor = userId d, postTitle = "D2" } :: Post)  -- post_id 2
          p  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)  -- post_id 3, author 2
          e1 <- with (joined #author) (manage p)
          l  <- statementLog
          pure (userName (rel #author e1), l)
        assertEqual "author" "Ada" nm
        assertBool "used a LEFT JOIN" (any ("LEFT JOIN" `isInfixOf`) (stmts log'))
  ]
