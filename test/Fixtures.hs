{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Fixtures
  ( withTestDb
  , withEmptyDb
  , usersDDL
  , postsDDL
  , profileDDL
  , tagsDDL
  , employeesDDL
  , commentsDDL
  , UserT(..)
  , User
  , PostT(..)
  , Post
  , ProfileT(..)
  , Profile
  , TagT(..)
  , Tag
  , EmployeeT(..)
  , Employee
  , CommentT(..)
  , Comment
  ) where

import Data.ByteString (ByteString)
import Data.Functor.Identity (Identity)
import Data.Proxy (Proxy(..))
import Data.Text (Text)
import GHC.Generics (Generic)
import Manifest.Core.Table (Field, Pk, Nullable)
import Manifest.Core.Meta (genericTableMeta)
import Manifest.Core.Cascade (OnDelete(..))
import Manifest.Core.Relation (Card(..), HasRelation(..), belongsTo, belongsToMaybe, cascade, hasMany, hasOpt)
import Manifest.Derive ()
import Manifest.Entity (Entity (..), Table (..))
import Manifest.Postgres (Pool, execText, withConnection)
import Manifest.Testing (withEphemeralDb)

-- | The example higher-kinded table. One declaration; @UserT Identity@ is the
-- clean runtime value, @UserT Exposed@ carries markers for the deriver.
data UserT f = User
  { userId    :: Field f (Pk Int)
  , userName  :: Field f Text
  , userEmail :: Field f (Nullable Text)
  } deriving Generic

-- | The runtime row type: @userId :: Int, userName :: Text, userEmail :: Maybe Text@.
type User = UserT Identity

instance Entity User where
  tableMeta  = genericTableMeta @UserT "users"
  cascadeRules =
    [ cascade (Proxy @Post)    (Proxy @"postAuthor")  Cascade
    , cascade (Proxy @Profile) (Proxy @"profileUser") SetNull
    , cascade (Proxy @Tag)     (Proxy @"tagUser")     Restrict
    ]

-- Posts: each belongs to a user via post_author = users.user_id (to-many from User).
data PostT f = Post
  { postId     :: Field f (Pk Int)
  , postAuthor :: Field f Int
  , postTitle  :: Field f Text
  } deriving Generic
type Post = PostT Identity

deriving via (Table "posts" PostT) instance Entity Post

-- Profiles: optional one-per-user via profile_user = users.user_id. The FK is
-- nullable (so SetNull can null it; the row then survives, parentless).
data ProfileT f = Profile
  { profileId   :: Field f (Pk Int)
  , profileUser :: Field f (Nullable Int)
  , profileBio  :: Field f Text
  } deriving Generic
type Profile = ProfileT Identity

deriving via (Table "profiles" ProfileT) instance Entity Profile

-- Tags: each belongs to a user via tag_user = users.user_id (Restrict on delete).
data TagT f = Tag
  { tagId    :: Field f (Pk Int)
  , tagUser  :: Field f Int
  , tagLabel :: Field f Text
  } deriving Generic
type Tag = TagT Identity

deriving via (Table "tags" TagT) instance Entity Tag

-- Employees: a self-referential table. employee_manager is a nullable self-FK
-- referencing employee_id, so an employee can have a manager (forward FK) and
-- reports (reverse FK), both targeting the same table — needs aliased joins.
data EmployeeT f = Employee
  { employeeId      :: Field f (Pk Int)
  , employeeManager :: Field f (Nullable Int)   -- nullable self-FK → employee_id
  , employeeName    :: Field f Text
  } deriving Generic
type Employee = EmployeeT Identity

deriving via (Table "employees" EmployeeT) instance Entity Employee

-- forward FK (nullable belongs-to self): the manager is the employee whose PK =
-- self.employee_manager, or Nothing when the self-FK is NULL (top of the chain).
instance HasRelation Employee "manager" where
  type Target      Employee "manager" = Maybe Employee
  type Cardinality Employee "manager" = 'Opt
  relSpec = belongsToMaybe (Proxy @"employeeManager")

-- reverse FK (has-many self): reports are employees whose employee_manager = self.PK
instance HasRelation Employee "reports" where
  type Target      Employee "reports" = [Employee]
  type Cardinality Employee "reports" = 'Many
  relSpec = hasMany (Proxy @"employeeManager")

-- Comments: each belongs to a post via comment_post = posts.post_id (to-many from Post).
data CommentT f = Comment
  { commentId   :: Field f (Pk Int)
  , commentPost :: Field f Int          -- FK → post_id
  , commentBody :: Field f Text
  } deriving Generic
type Comment = CommentT Identity

deriving via (Table "comments" CommentT) instance Entity Comment

instance HasRelation Post "comments" where
  type Target      Post "comments" = [Comment]
  type Cardinality Post "comments" = 'Many
  relSpec = hasMany (Proxy @"commentPost")

instance HasRelation User "posts" where
  type Target      User "posts" = [Post]
  type Cardinality User "posts" = 'Many
  relSpec = hasMany (Proxy @"postAuthor")

instance HasRelation User "profile" where
  type Target      User "profile" = Maybe Profile
  type Cardinality User "profile" = 'Opt
  relSpec = hasOpt (Proxy @"profileUser")

instance HasRelation Post "author" where
  type Target      Post "author" = User
  type Cardinality Post "author" = 'One
  relSpec = belongsTo (Proxy @"postAuthor")

-- | DDL for the example table. Column order matches UserT's field order; names
-- are camelCase→snake_case with no prefix stripping (see plan §"Resolved open questions").
usersDDL :: ByteString
usersDDL =
  "CREATE TABLE users \
  \( user_id    BIGSERIAL PRIMARY KEY \
  \, user_name  TEXT NOT NULL \
  \, user_email TEXT )"

postsDDL :: ByteString
postsDDL =
  "CREATE TABLE posts \
  \( post_id     BIGSERIAL PRIMARY KEY \
  \, post_author BIGINT NOT NULL \
  \, post_title  TEXT NOT NULL )"

profileDDL :: ByteString
profileDDL =
  "CREATE TABLE profiles \
  \( profile_id   BIGSERIAL PRIMARY KEY \
  \, profile_user BIGINT \
  \, profile_bio  TEXT NOT NULL )"

tagsDDL :: ByteString
tagsDDL =
  "CREATE TABLE tags \
  \( tag_id    BIGSERIAL PRIMARY KEY \
  \, tag_user  BIGINT NOT NULL \
  \, tag_label TEXT NOT NULL )"

employeesDDL :: ByteString
employeesDDL =
  "CREATE TABLE employees \
  \( employee_id      BIGSERIAL PRIMARY KEY \
  \, employee_manager BIGINT \
  \, employee_name    TEXT NOT NULL )"

commentsDDL :: ByteString
commentsDDL =
  "CREATE TABLE comments \
  \( comment_id   BIGSERIAL PRIMARY KEY \
  \, comment_post BIGINT NOT NULL \
  \, comment_body TEXT NOT NULL )"

-- | Spin up an ephemeral, isolated Postgres for the action with the example
-- schema pre-created, hand over a 2-connection pool, tear down. Built on the
-- library's 'withEphemeralDb' plus the fixture DDLs.
withTestDb :: (Pool -> IO a) -> IO a
withTestDb body = withEphemeralDb $ \pool -> do
  let ddls = [usersDDL, postsDDL, profileDDL, tagsDDL, employeesDDL, commentsDDL]
  withConnection pool (\c -> mapM_ (\s -> execText c s []) ddls)
  body pool

-- | Same ephemeral cluster as 'withTestDb' but creates NO tables — for migration
-- tests that introspect/diff against an empty schema. Re-exports the library helper.
withEmptyDb :: (Pool -> IO a) -> IO a
withEmptyDb = withEphemeralDb
