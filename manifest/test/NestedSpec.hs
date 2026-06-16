{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module NestedSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Fixtures (Comment, CommentT (..), Post, PostT (..), User, UserT (..), withTestDb)
import Manifest.Relation (loadNested, (./))
import Manifest.Session
import Harness

commentSelects :: [(BC.ByteString, [Maybe BC.ByteString])] -> Int
commentSelects = length . filter (\(s,_) -> "FROM comments" `isInfixOf` BC.unpack s)

tests :: [Test]
tests = group "Nested"
  [ test "loadNested (#posts ./ #comments) groups comments under each post, in ONE batched query" $
      withTestDb $ \pool -> do
        (shape, nCommentQueries) <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          p1 <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          p2 <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          _  <- add (Comment { commentId = 0, commentPost = postId p1, commentBody = "c1" } :: Comment)
          _  <- add (Comment { commentId = 0, commentPost = postId p1, commentBody = "c2" } :: Comment)
          _  <- add (Comment { commentId = 0, commentPost = postId p2, commentBody = "c3" } :: Comment)
          res <- loadNested (#posts ./ #comments) u
          l   <- statementLog
          pure ([ (postTitle p, map commentBody cs) | (p, cs) <- res ], commentSelects l)
        assertEqual "grouped" [("P1", ["c1", "c2"]), ("P2", ["c3"])] shape
        assertEqual "single batched comments query" 1 nCommentQueries
  ]
