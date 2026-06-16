module PostgresSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Fixtures (withTestDb)
import Manifest.Postgres (execText, withConnection)
import Harness

tests :: [Test]
tests = group "Postgres"
  [ test "runs SELECT 1 against an ephemeral cluster" $
      withTestDb $ \pool -> withConnection pool $ \conn -> do
        rows <- execText conn "SELECT 1" []
        assertEqual "select 1" [[Just (BC.pack "1")]] rows
  , test "round-trips a parameterised text value" $
      withTestDb $ \pool -> withConnection pool $ \conn -> do
        rows <- execText conn "SELECT $1::text" [Just (BC.pack "hello")]
        assertEqual "param" [[Just (BC.pack "hello")]] rows
  , test "applies DDL so the users table exists and is empty" $
      withTestDb $ \pool -> withConnection pool $ \conn -> do
        rows <- execText conn "SELECT count(*) FROM users" []
        assertEqual "count" [[Just (BC.pack "0")]] rows
  ]
