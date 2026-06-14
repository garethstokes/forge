{-# LANGUAGE OverloadedStrings #-}

-- | Run a Db body scoped to one org: switch to the low-privilege evals_tenant
-- role (so RLS applies — the default connection is superuser and bypasses it)
-- and set the app.org GUC, both transaction-local (cleared at commit).
module Evals.Tenant (withTenant) where

import qualified Data.Text as T
import Manifest (Db, withTransaction, withRlsContext)
import Manifest.Session (execDb)
import Evals.Ids (OrgId (..))

withTenant :: OrgId -> Db a -> Db a
withTenant (OrgId n) body =
  withTransaction $ do
    _ <- execDb "SET LOCAL ROLE evals_tenant" []
    withRlsContext [("app.org", T.pack (show n))] body
