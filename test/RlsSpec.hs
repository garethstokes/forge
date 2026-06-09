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
  { secretId   :: Col f (PrimaryKey (Serial Int))
  , secretOrg  :: Col f Text
  , secretBody :: Col f Text
  } deriving GHC.Generics.Generic
type Secret = SecretT Data.Functor.Identity.Identity

instance Entity Secret where
  type PrimKey Secret = Int
  tableMeta  = genericTableMeta @SecretT "secrets"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = secretId
  rlsPolicies =
    [ policy "org_isolation" `using` (\s -> s ^. #secretOrg .== currentSetting "app.current_org") ]

secretsDDL :: Data.ByteString.ByteString
secretsDDL = "CREATE TABLE secrets ( secret_id BIGSERIAL PRIMARY KEY, secret_org TEXT NOT NULL, secret_body TEXT NOT NULL )"

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
  ]
