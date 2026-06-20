{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module RlsSpec (tests) where

import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString
import Data.ByteString (isInfixOf)
import qualified Data.Functor.Identity
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified GHC.Generics
import Fixtures (User, withEmptyDb)
import Manifest
import Manifest.Core.Rls (PolicyDef (..), policyDef)
import Manifest.Session (Db, execDb)
import Harness

data SecretT f = Secret
  { secretId   :: Field f (PrimaryKey (Serial Int))
  , secretOrg  :: Field f Text
  , secretBody :: Field f Text
  } deriving GHC.Generics.Generic
type Secret = SecretT Data.Functor.Identity.Identity

instance Entity Secret where
  tableMeta  = genericTableMeta @SecretT "secrets"
  rlsPolicies =
    [ policy "org_isolation" `using` (\s -> s ^. #secretOrg .== currentSetting "app.current_org") ]

secretsDDL :: Data.ByteString.ByteString
secretsDDL = "CREATE TABLE secrets ( secret_id BIGSERIAL PRIMARY KEY, secret_org TEXT NOT NULL, secret_body TEXT NOT NULL )"

-- A second entity whose policy uses the missing-ok 'currentSettingOr': when the
-- context GUC is unset it falls back to a sentinel that matches no row, so a
-- context-less query returns nothing instead of erroring.
data VaultT f = Vault
  { vaultId   :: Field f (PrimaryKey (Serial Int))
  , vaultOrg  :: Field f Text
  , vaultBody :: Field f Text
  } deriving GHC.Generics.Generic
type Vault = VaultT Data.Functor.Identity.Identity

instance Entity Vault where
  tableMeta  = genericTableMeta @VaultT "vaults"
  rlsPolicies =
    [ policy "org_isolation_soft"
        `using` (\v -> v ^. #vaultOrg .== currentSettingOr "app.current_org" "__none__") ]

vaultsDDL :: Data.ByteString.ByteString
vaultsDDL = "CREATE TABLE vaults ( vault_id BIGSERIAL PRIMARY KEY, vault_org TEXT NOT NULL, vault_body TEXT NOT NULL )"

execDb_ :: Data.ByteString.ByteString -> Db ()
execDb_ s = void (execDb s [])

tests :: [Test]
tests = group "Rls"
  [ test "policy DSL renders the USING predicate to SQL" $ do
      let p = policy "org_isolation"
                `using` (\u -> u ^. #userName .== currentSetting "app.current_org")
              :: Policy User
          pd = policyDef p
      assertEqual "name" "org_isolation" (pdName pd)
      assertEqual "using" (Just "user_name = current_setting('app.current_org')") (pdUsing pd)
      assertEqual "check" Nothing (pdCheck pd)
  , test "castText renders ::text for an int-keyed RLS predicate" $ do
      let p = policy "org_isolation"
                `using` (\u -> castText (u ^. #userId) .== currentSetting "app.current_org")
              :: Policy User
          pd = policyDef p
      assertEqual "using" (Just "(user_id)::text = current_setting('app.current_org')") (pdUsing pd)
  , test "withRlsContext sets a transaction-local GUC; it is cleared afterward" $
      withEmptyDb $ \pool -> withSession pool $ do
        inside <- withTransaction $ withRlsContext [("app.current_org", "acme")] $ do
          rows <- execDb "SELECT current_setting('app.current_org', true)" []
          pure (head (head rows))
        outside <- withTransaction $ do
          rows <- execDb "SELECT current_setting('app.current_org', true)" []
          pure (head (head rows))
        liftIO $ do
          assertEqual "inside the context" (Just "acme") inside
          -- LOCAL set_config auto-clears the *value* at COMMIT, so the org name
          -- never leaks to the next checkout of this pooled connection. Postgres
          -- keeps the custom-GUC placeholder around as an empty string (not SQL
          -- NULL) once it has been referenced, so the next transaction reads
          -- Just "" — proving the value was cleared without leaking "acme".
          assertEqual "value cleared after the transaction" (Just "") outside
  , test "migrate emits ENABLE/FORCE RLS + CREATE POLICY for a policied entity" $
      withEmptyDb $ \pool -> withSession pool $ do
        execDb_ secretsDDL
        plan <- migrate [managed (Proxy @Secret)]
        let rls = planRls plan
        liftIO $ do
          assertBool "enables RLS" (any ("ENABLE ROW LEVEL SECURITY" `isInfixOf`) rls)
          assertBool "forces RLS"  (any ("FORCE ROW LEVEL SECURITY"  `isInfixOf`) rls)
          assertBool "creates the policy"
            (any ("CREATE POLICY org_isolation ON secrets" `isInfixOf`) rls)
  , test "migrateUp applies RLS and is a no-op on re-run" $
      withEmptyDb $ \pool -> withSession pool $ do
        execDb_ secretsDDL
        _    <- migrateUp [managed (Proxy @Secret)]
        plan <- migrate  [managed (Proxy @Secret)]
        liftIO $ assertEqual "idempotent RLS plan" [] (planRls plan)
  , test "RLS hides other tenants' rows within a Manifest session" $
      withEmptyDb $ \pool -> withSession pool $ do
        execDb_ secretsDDL
        -- seed both tenants (as superuser, before the role switch)
        _ <- add (Secret { secretId = 0, secretOrg = "acme",   secretBody = "a1" } :: Secret)
        _ <- add (Secret { secretId = 0, secretOrg = "globex", secretBody = "g1" } :: Secret)
        _ <- migrateUp [managed (Proxy @Secret)]            -- enable RLS + create policy
        -- a non-superuser role so RLS actually applies
        execDb_ "DROP ROLE IF EXISTS rls_tenant"
        execDb_ "CREATE ROLE rls_tenant NOLOGIN"
        execDb_ "GRANT SELECT ON secrets TO rls_tenant"
        let visibleFor org = withTransaction $ do
              execDb_ "SET LOCAL ROLE rls_tenant"
              withRlsContext [("app.current_org", org)] $ do
                rows <- execDb "SELECT secret_body FROM secrets ORDER BY secret_body" []
                pure [ b | [Just b] <- rows ]
        acme   <- visibleFor "acme"
        globex <- visibleFor "globex"
        liftIO $ do
          assertEqual "acme sees only its row"   ["a1"] acme
          assertEqual "globex sees only its row" ["g1"] globex
  , test "currentSettingOr renders coalesce(current_setting('name', true), 'default')" $ do
      let pd = policyDef
                 (policy "p"
                    `using` (\u -> u ^. #userName .== currentSettingOr "app.current_org" "__none__")
                  :: Policy User)
      assertEqual "using"
        (Just "user_name = coalesce(current_setting('app.current_org', true), '__none__')")
        (pdUsing pd)
  , test "a currentSettingOr policy returns no rows (not an error) when context is unset" $
      withEmptyDb $ \pool -> withSession pool $ do
        execDb_ vaultsDDL
        _ <- add (Vault { vaultId = 0, vaultOrg = "acme", vaultBody = "v1" } :: Vault)
        _ <- migrateUp [managed (Proxy @Vault)]
        execDb_ "DROP ROLE IF EXISTS rls_tenant2"
        execDb_ "CREATE ROLE rls_tenant2 NOLOGIN"
        execDb_ "GRANT SELECT ON vaults TO rls_tenant2"
        unset <- withTransaction $ do            -- no withRlsContext: soft fallback, no error
          execDb_ "SET LOCAL ROLE rls_tenant2"
          rows <- execDb "SELECT vault_body FROM vaults" []
          pure [ b | [Just b] <- rows ]
        set_ <- withTransaction $ do
          execDb_ "SET LOCAL ROLE rls_tenant2"
          withRlsContext [("app.current_org", "acme")] $ do
            rows <- execDb "SELECT vault_body FROM vaults" []
            pure [ b | [Just b] <- rows ]
        liftIO $ do
          assertEqual "unset context -> no rows, no error" [] unset
          assertEqual "set context -> the row" ["v1"] set_
  ]
