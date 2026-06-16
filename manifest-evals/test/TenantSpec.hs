{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
module TenantSpec (main) where

import Control.Exception (SomeException, try)
import Control.Monad (unless)
import Data.Time (getCurrentTime)
import Manifest
import Manifest.Testing (withEphemeralDb)
import Evals.Ids
import Evals.Schema
import Evals.Migrate (migrateAll)
import Evals.Tenant (withTenant)

expect :: String -> Bool -> IO ()
expect msg ok = unless ok (ioError (userError ("FAILED: " <> msg)))

main :: IO ()
main = withEphemeralDb $ \pool -> do
  now <- getCurrentTime
  -- migrate (tables + RLS + role + grants) and seed two orgs as owner (superuser bypasses RLS)
  withSession pool $ do
    _ <- migrateAll
    _ <- add (Org { id = OrgId 1, slug = "acme",   name = "Acme",   createdAt = now } :: Org)
    _ <- add (Org { id = OrgId 2, slug = "globex", name = "Globex", createdAt = now } :: Org)
    _ <- add (Dataset { id = DatasetId 0, org = OrgId 1, name = "a", slug = "a", createdAt = now } :: Dataset)
    _ <- add (Dataset { id = DatasetId 0, org = OrgId 2, name = "g", slug = "g", createdAt = now } :: Dataset)
    pure ()
  -- org 1's context sees ONLY org 1's dataset
  ds1 <- withSession pool $ withTenant (OrgId 1) (selectWhere ([] :: [Cond Dataset]))
  expect "org1 sees exactly its own dataset" (map (\d -> d.org) ds1 == [OrgId 1])
  ds2 <- withSession pool $ withTenant (OrgId 2) (selectWhere ([] :: [Cond Dataset]))
  expect "org2 sees exactly its own dataset" (map (\d -> d.org) ds2 == [OrgId 2])
  -- WITH CHECK rejects a cross-org insert under org 1's context
  res <- try (withSession pool $ withTenant (OrgId 1) $
                add (Dataset { id = DatasetId 0, org = OrgId 2, name = "x", slug = "x", createdAt = now } :: Dataset))
         :: IO (Either SomeException Dataset)
  expect "cross-org insert rejected by WITH CHECK" (either (const True) (const False) res)
  putStrLn "manifest-evals TenantSpec: rls isolation + with-check OK"
