{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module RelationSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Fixtures (Post, PostT (..), Profile, ProfileT (..), User, UserT (..), withTestDb)
import Manifest.Core.Relation (RelSpec (..), relSpec)
import Manifest.Entity (Key (..))
import Manifest.Relation (load)
import Manifest.Session
import Harness

tests :: [Test]
tests = group "Relation"
  [ test "relSpec for User \"posts\" is RelMany on post_author" $
      case relSpec @User @"posts" of
        RelMany fk -> assertEqual "fk" "post_author" fk
        _          -> assertBool "expected RelMany" False
  , test "relSpec for User \"profile\" is RelOpt on profile_user" $
      case relSpec @User @"profile" of
        RelOpt fk -> assertEqual "fk" "profile_user" fk
        _         -> assertBool "expected RelOpt" False
  , test "relSpec for Post \"author\" is RelOne on post_author" $
      case relSpec @Post @"author" of
        RelOne fk -> assertEqual "fk" "post_author" fk
        _         -> assertBool "expected RelOne" False
  , test "load #author returns the post's author (belongs-to; post_id /= post_author)" $
      withTestDb $ \pool -> do
        -- Decoys make the real post's PK (post_id=3) differ from its FK
        -- (post_author=2), so this fails if the loader keys on the PK not the FK.
        nm <- withSession pool $ do
          d <- add (User { userId = 0, userName = "Decoy", userEmail = Nothing } :: User)  -- user_id 1
          u <- add (User { userId = 0, userName = "Ada",   userEmail = Nothing } :: User)  -- user_id 2
          _ <- add (Post { postId = 0, postAuthor = userId d, postTitle = "D1" } :: Post)  -- post_id 1
          _ <- add (Post { postId = 0, postAuthor = userId d, postTitle = "D2" } :: Post)  -- post_id 2
          p <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)  -- post_id 3, author 2
          a <- load #author p
          pure (userName a)
        assertEqual "author name" "Ada" nm
  , test "load #posts returns the user's posts (managed)" $
      withTestDb $ \pool -> do
        titles <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          ps <- load #posts u
          pure (map postTitle ps)
        assertEqual "titles" ["P1", "P2"] titles
  , test "load #profile returns Nothing when absent, Just when present" $
      withTestDb $ \pool -> do
        (none, some) <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          n <- load #profile u
          _ <- add (Profile { profileId = 0, profileUser = Just (userId u), profileBio = "hi" } :: Profile)
          s <- load #profile u
          pure (fmap profileBio n, fmap profileBio s)
        assertEqual "none" Nothing none
        assertEqual "some" (Just "hi") some
  , test "a loaded child is managed: modify + save emits a minimal UPDATE" $
      withTestDb $ \pool -> do
        log' <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          ps <- load #posts u
          let p = head ps :: Post
          withTransaction $ save (p { postTitle = "Edited" } :: Post)
          statementLog
        assertEqual "minimal child update"
          ["UPDATE posts SET post_title = $1 WHERE post_id = $2"]
          (filter (BC.isPrefixOf "UPDATE" . fst) log' >>= \(s,_) -> [BC.unpack s])
  , test "a child loaded in a FRESH session (not added there) is managed — isolates selectByFk setBaseline" $
      withTestDb $ \pool -> do
        pk <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          pure (userId u)
        -- New session: the loaded Post was NOT added here, so its ONLY baseline
        -- source is selectByFk's setBaseline. Drop that and `save` throws
        -- UnmanagedSave — so this genuinely isolates the §5.5 registration.
        log' <- withSession pool $ do
          mu <- get @User (Key pk)
          let u = maybe (error "fresh-session user vanished") id mu :: User
          ps <- load #posts u
          let p = head ps :: Post
          withTransaction $ save (p { postTitle = "Edited" } :: Post)
          statementLog
        assertEqual "minimal child update"
          ["UPDATE posts SET post_title = $1 WHERE post_id = $2"]
          (filter (BC.isPrefixOf "UPDATE" . fst) log' >>= \(s,_) -> [BC.unpack s])
  ]
