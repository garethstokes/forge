{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module MigrateSqlSpec (tests) where

import Data.Proxy (Proxy (..))
import Fixtures (User)
import Manifest.Core.Meta (ColumnMeta (..), SqlType (..))
import Manifest.Migrate (managed, mtColumns, renderAddColumn, renderCreateTable)
import Harness

tests :: [Test]
tests = group "MigrateSql"
  [ test "renderCreateTable matches the hand-written users DDL" $
      assertEqual "create"
        "CREATE TABLE users (user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL, user_email TEXT)"
        (renderCreateTable (managed (Proxy @User)))
  , test "renderAddColumn for a nullable text column" $
      assertEqual "add"
        "ALTER TABLE users ADD COLUMN nickname TEXT"
        (renderAddColumn "users" (ColumnMeta "nickname" False False SqlText True))
  , test "renderAddColumn for a NOT NULL bigint column" $
      assertEqual "add"
        "ALTER TABLE users ADD COLUMN age BIGINT NOT NULL"
        (renderAddColumn "users" (ColumnMeta "age" False False SqlBigInt False))
  ]
