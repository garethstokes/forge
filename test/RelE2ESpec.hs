{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module RelE2ESpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf, isPrefixOf)
import Fixtures (Post, PostT (..), User, UserT (..), withTestDb)
import Manifest
import Harness

upd :: [(BC.ByteString, [Maybe BC.ByteString])] -> [String]
upd = filter (isPrefixOf "UPDATE") . map (BC.unpack . fst)

tests :: [Test]
tests = group "RelE2E"
  [ test "load via A and D, edit a loaded child, save -> minimal child UPDATE" $
      withTestDb $ \pool -> do
        (aTitles, dTitles, log') <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          aps <- load #posts u                       -- A path
          e1  <- with (selectin #posts) (manage u)   -- D path
          let dps = rel #posts e1
          withTransaction $ save ((head dps) { postTitle = "Edited" } :: Post)  -- managed child
          l <- statementLog
          pure (map postTitle aps, map postTitle dps, l)
        assertEqual "A titles" ["P1", "P2"] aTitles
        assertEqual "D titles" ["P1", "P2"] dTitles
        assertEqual "minimal child update"
          ["UPDATE posts SET post_title = $1 WHERE post_id = $2"]
          (upd log')
  , test "belongs-to + joined through the public API" $
      withTestDb $ \pool -> do
        (authorName, joinedTitles, usedJoin) <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          p  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          a   <- load #author p                          -- belongs-to (A path, selectin)
          eu  <- with (joined #posts) (manage u)         -- joined strategy
          l   <- statementLog
          pure (userName a, map postTitle (rel #posts eu),
                any (isInfixOf "LEFT JOIN") (map (BC.unpack . fst) l))
        assertEqual "author" "Ada" authorName
        assertEqual "joined titles" ["P1", "P2"] joinedTitles
        assertBool "joined used a LEFT JOIN" usedJoin
  ]
