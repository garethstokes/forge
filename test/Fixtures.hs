{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Fixtures
  ( withTestDb
  , usersDDL
  , postsDDL
  , profileDDL
  , tagsDDL
  , employeesDDL
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
  ) where

import Control.Exception (SomeException, finally, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.Proxy (Proxy(..))
import Data.Text (Text)
import GHC.Generics (Generic)
import System.Directory (removeDirectoryRecursive)
import System.Process (callProcess, readProcess)
import Manifest.Core.Table (Col, PrimaryKey, Serial)
import Manifest.Core.Meta (genericTableMeta)
import Manifest.Core.Cascade (OnDelete(..))
import Manifest.Core.Relation (Card(..), HasRelation(..), belongsTo, cascade, hasMany, hasOpt)
import Manifest.Entity (Entity (..), genericRowDecoder, genericRowEncode)
import Manifest.Postgres (Pool, closePool, execText, newPool, withConnection)

-- | The example higher-kinded table. One declaration; @UserT Identity@ is the
-- clean runtime value, @UserT Exposed@ carries markers for the deriver.
data UserT f = User
  { userId    :: Col f (PrimaryKey (Serial Int))
  , userName  :: Col f Text
  , userEmail :: Col f (Maybe Text)
  } deriving Generic

-- | The runtime row type: @userId :: Int, userName :: Text, userEmail :: Maybe Text@.
type User = UserT Identity

instance Entity User where
  type PrimKey User = Int
  tableMeta  = genericTableMeta @UserT "users"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = userId
  cascadeRules =
    [ cascade (Proxy @Post)    (Proxy @"postAuthor")  Cascade
    , cascade (Proxy @Profile) (Proxy @"profileUser") SetNull
    , cascade (Proxy @Tag)     (Proxy @"tagUser")     Restrict
    ]

-- Posts: each belongs to a user via post_author = users.user_id (to-many from User).
data PostT f = Post
  { postId     :: Col f (PrimaryKey (Serial Int))
  , postAuthor :: Col f Int
  , postTitle  :: Col f Text
  } deriving Generic
type Post = PostT Identity

instance Entity Post where
  type PrimKey Post = Int
  tableMeta  = genericTableMeta @PostT "posts"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = postId

-- Profiles: optional one-per-user via profile_user = users.user_id. The FK is
-- nullable (so SetNull can null it; the row then survives, parentless).
data ProfileT f = Profile
  { profileId   :: Col f (PrimaryKey (Serial Int))
  , profileUser :: Col f (Maybe Int)
  , profileBio  :: Col f Text
  } deriving Generic
type Profile = ProfileT Identity

instance Entity Profile where
  type PrimKey Profile = Int
  tableMeta  = genericTableMeta @ProfileT "profiles"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = profileId

-- Tags: each belongs to a user via tag_user = users.user_id (Restrict on delete).
data TagT f = Tag
  { tagId    :: Col f (PrimaryKey (Serial Int))
  , tagUser  :: Col f Int
  , tagLabel :: Col f Text
  } deriving Generic
type Tag = TagT Identity

instance Entity Tag where
  type PrimKey Tag = Int
  tableMeta  = genericTableMeta @TagT "tags"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = tagId

-- Employees: a self-referential table. employee_manager is a nullable self-FK
-- referencing employee_id, so an employee can have a manager (forward FK) and
-- reports (reverse FK), both targeting the same table — needs aliased joins.
data EmployeeT f = Employee
  { employeeId      :: Col f (PrimaryKey (Serial Int))
  , employeeManager :: Col f (Maybe Int)   -- nullable self-FK → employee_id
  , employeeName    :: Col f Text
  } deriving Generic
type Employee = EmployeeT Identity

instance Entity Employee where
  type PrimKey Employee = Int
  tableMeta  = genericTableMeta @EmployeeT "employees"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = employeeId

-- forward FK (belongs-to self): the manager is the employee whose PK = self.employee_manager
instance HasRelation Employee "manager" where
  type Target      Employee "manager" = Employee
  type Cardinality Employee "manager" = 'One
  relSpec = belongsTo (Proxy @"employeeManager")

-- reverse FK (has-many self): reports are employees whose employee_manager = self.PK
instance HasRelation Employee "reports" where
  type Target      Employee "reports" = [Employee]
  type Cardinality Employee "reports" = 'Many
  relSpec = hasMany (Proxy @"employeeManager")

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

-- | Spin up an ephemeral, isolated Postgres for the action: initdb + pg_ctl on a
-- private unix socket, create the schema, hand over a 2-connection pool, tear down.
withTestDb :: (Pool -> IO a) -> IO a
withTestDb body = do
  base <- fmap (takeWhile (/= '\n')) (readProcess "mktemp" ["-d", "/tmp/manifest-pg.XXXXXX"] "")
  let dataDir  = base ++ "/data"
      sock     = base                     -- unix socket dir
      port     = "55432"                  -- only names the socket file; TCP disabled below
      conninfo = BC.pack ("host=" ++ sock ++ " port=" ++ port ++ " dbname=postgres user=postgres")
      pgOpts   = "-k " ++ sock ++ " -p " ++ port ++ " -c listen_addresses=''"  -- no TCP
      stop     = callProcess "pg_ctl" ["stop", "-D", dataDir, "-m", "immediate", "-w"]
      ignoring act = (try act :: IO (Either SomeException ())) >> pure ()
      cleanup  = ignoring stop `finally` ignoring (removeDirectoryRecursive base)
  flip finally cleanup $ do
    _ <- readProcess "initdb" ["-D", dataDir, "-U", "postgres", "-A", "trust", "--no-sync"] ""
    callProcess "pg_ctl" ["start", "-D", dataDir, "-w", "-l", base ++ "/postgres.log", "-o", pgOpts]
    pool <- newPool conninfo 2
    (do withConnection pool (\c -> mapM_ (\s -> execText c s []) [usersDDL, postsDDL, profileDDL, tagsDDL, employeesDDL])
        body pool) `finally` closePool pool
