{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module MigrateSpec (tests) where

import Control.Exception (SomeException, try)
import Data.Proxy (Proxy (..))
import Fixtures (User, withEmptyDb)
import Manifest.Core.Meta (ColumnMeta (..))
import Manifest.Migrate
import Manifest.Postgres (execText, withConnection)
import Manifest.Session (withSession)
import Harness

tests :: [Test]
tests = group "Migrate"
  [ test "diffTable on an empty DB says CreateTable" $
      withEmptyDb $ \pool -> do
        d <- withSession pool (diffTable (managed (Proxy @User)))
        case d of
          CreateTable mt -> assertEqual "name" "users" (mtName mt)
          _              -> assertBool "expected CreateTable" False
  , test "diffTable detects a missing column (additive)" $
      withEmptyDb $ \pool -> do
        withConnection pool $ \c ->
          mapM_ (\s -> execText c s [])
            ["CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL)"]
        d <- withSession pool (diffTable (managed (Proxy @User)))
        case d of
          AlterTable t adds destr -> do
            assertEqual "table" "users" t
            assertEqual "adds" ["user_email"] (map cmName adds)
            assertEqual "no destructive" [] destr
          _ -> assertBool "expected AlterTable" False
  , test "diffTable flags a type mismatch as destructive (NOT applied)" $
      withEmptyDb $ \pool -> do
        withConnection pool $ \c ->
          mapM_ (\s -> execText c s [])
            ["CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, user_name BIGINT NOT NULL, user_email TEXT)"]
        d <- withSession pool (diffTable (managed (Proxy @User)))
        case d of
          AlterTable _ adds destr -> do
            assertEqual "no adds" [] (map cmName adds)
            assertBool "user_name flagged" (any (\s -> "user_name" `elem` words s) destr)
          _ -> assertBool "expected AlterTable with destructive" False
  , test "migrateUp on an empty DB creates the managed tables; re-run is a no-op" $
      withEmptyDb $ \pool -> do
        let tbls = [managed (Proxy @User)]
        p1 <- withSession pool (migrateUp tbls)
        p2 <- withSession pool (migrateUp tbls)            -- idempotent
        existsUsers <- withSession pool (tableExists "users")
        assertBool  "users created" existsUsers
        assertEqual "first run had additive" 1 (length (planAdditive p1))
        assertEqual "second run is a no-op"  0 (length (planAdditive p2))
  , test "migrateUp applies a missing column" $
      withEmptyDb $ \pool -> do
        withConnection pool $ \c ->
          mapM_ (\s -> execText c s [])
            ["CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL)"]
        _ <- withSession pool (migrateUp [managed (Proxy @User)])
        d <- withSession pool (diffTable (managed (Proxy @User)))
        assertEqual "now up to date" UpToDate d
  , test "migrateUp aborts on a destructive diff (no DDL applied)" $
      withEmptyDb $ \pool -> do
        withConnection pool $ \c ->
          mapM_ (\s -> execText c s [])
            ["CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, user_name BIGINT NOT NULL, user_email TEXT)"]
        res <- (try :: IO a -> IO (Either SomeException a))
                 (withSession pool (migrateUp [managed (Proxy @User)]))
        assertBool "aborted" (either (const True) (const False) res)
  , test "end-to-end: migrate empty DB up, then everything is UpToDate" $
      withEmptyDb $ \pool -> do
        let tbls = [managed (Proxy @User)]
        _ <- withSession pool (migrateUp tbls)
        d <- withSession pool (diffTable (managed (Proxy @User)))
        assertEqual "up to date after migrate up" UpToDate d
  ]
