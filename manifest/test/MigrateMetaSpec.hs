{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module MigrateMetaSpec (tests) where

import Fixtures (UserT)
import Manifest.Core.Meta (ColumnMeta (..), SqlType (..), TableMeta (..), genericTableMeta)
import Harness

tests :: [Test]
tests = group "MigrateMeta"
  [ test "genericTableMeta derives SqlType + nullability for UserT" $
      assertEqual "columns"
        [ ColumnMeta "user_id"    True  True  True  False SqlBigSerial False
        , ColumnMeta "user_name"  False False False False SqlText      False
        , ColumnMeta "user_email" False False False False SqlText      True   -- Maybe Text → nullable
        ]
        (tmColumns (genericTableMeta @UserT "users"))
  ]
