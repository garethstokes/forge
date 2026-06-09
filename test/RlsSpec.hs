{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module RlsSpec (tests) where

import Fixtures (User)
import Manifest
import Manifest.Core.Rls (PolicyDef (..), policyDef)
import Harness

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
  ]
