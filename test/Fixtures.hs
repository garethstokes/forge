{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}

module Fixtures (withTestDb, usersDDL, UserT(..), User) where

import Control.Exception (SomeException, finally, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.Text (Text)
import GHC.Generics (Generic)
import System.Directory (removeDirectoryRecursive)
import System.Process (callProcess, readProcess)
import Manifest.Core.Table (Col, PrimaryKey, Serial)
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

-- | DDL for the example table. Column order matches UserT's field order; names
-- are camelCase→snake_case with no prefix stripping (see plan §"Resolved open questions").
usersDDL :: ByteString
usersDDL =
  "CREATE TABLE users \
  \( user_id    BIGSERIAL PRIMARY KEY \
  \, user_name  TEXT NOT NULL \
  \, user_email TEXT )"

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
    (do withConnection pool (\c -> mapM_ (\s -> execText c s []) [usersDDL])
        body pool) `finally` closePool pool
