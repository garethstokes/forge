{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module SqlSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Fixtures (User)
import Manifest.Core.Query
import Manifest.Core.Sql
import Manifest.Core.Meta (tmColumns, cmIsSerial)
import Manifest.Entity (Entity (..))
import Harness

tests :: [Test]
tests = group "Query"
  [ test "builds conditions from labels with camel→snake names" $ do
      assertEqual "eq" (Cond "user_name" OpEq (Just (BC.pack "Bob")))
                       (#userName ==. ("Bob" :: String) :: Cond User)
      assertEqual "lt" (Cond "user_id" OpLt (Just (BC.pack "5")))
                       (#userId <. (5 :: Int) :: Cond User)
  , test "builds assignments from labels" $
      assertEqual "asn" (Assign "user_name" (Just (BC.pack "Bob")))
                        (#userName =. ("Bob" :: String) :: Assign User)
  , test "renders SELECT with all columns and a WHERE" $
      assertEqual "sel"
        "SELECT user_id, user_name, user_email FROM users WHERE user_id = $1"
        (renderSelect (tableMeta @User) [Cond "user_id" OpEq (Just (BC.pack "42"))])
  , test "renders SELECT without a WHERE when no conditions" $
      assertEqual "sel0"
        "SELECT user_id, user_name, user_email FROM users"
        (renderSelect (tableMeta @User) [])
  , test "renders INSERT of non-serial columns RETURNING all columns" $
      assertEqual "ins"
        "INSERT INTO users (user_name, user_email) VALUES ($1, $2) RETURNING user_id, user_name, user_email"
        (renderInsert (tableMeta @User) (filter (not . cmIsSerial) (tmColumns (tableMeta @User))))
  , test "renders a minimal UPDATE with the PK placeholder last" $
      assertEqual "upd"
        "UPDATE users SET user_name = $1 WHERE user_id = $2"
        (renderUpdate (tableMeta @User) ["user_name"] "user_id")
  , test "renders DELETE by PK" $
      assertEqual "del"
        "DELETE FROM users WHERE user_id = $1"
        (renderDelete (tableMeta @User) "user_id")
  , test "ANDs multiple conditions and advances placeholders" $
      assertEqual "conds"
        " WHERE user_name = $1 AND user_id > $2"
        (fst (renderConds 1 [ Cond "user_name" OpEq (Just (BC.pack "Bob"))
                            , Cond "user_id"   OpGt (Just (BC.pack "3")) ]))
  , test "renderJoined (reverse FK: User has-many Posts)" $
      assertEqual "join"
        "SELECT rel_t.post_id, rel_t.post_author, rel_t.post_title \
        \FROM users AS self_t LEFT JOIN posts AS rel_t \
        \ON rel_t.post_author = self_t.user_id WHERE self_t.user_id = $1"
        (renderJoined "users" "user_id" "posts"
           ["post_id", "post_author", "post_title"] "post_author" "user_id")
  , test "renderJoined (forward FK: Post belongs-to User)" $
      assertEqual "join"
        "SELECT rel_t.user_id, rel_t.user_name, rel_t.user_email \
        \FROM posts AS self_t LEFT JOIN users AS rel_t \
        \ON rel_t.user_id = self_t.post_author WHERE self_t.post_id = $1"
        (renderJoined "posts" "post_id" "users"
           ["user_id", "user_name", "user_email"] "user_id" "post_author")
  ]
