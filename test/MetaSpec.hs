{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module MetaSpec (tests) where

import Data.Functor.Identity (Identity)
import Data.Text (Text)
import Manifest.Core.Table (Base, Col, FieldMeta (..), PrimaryKey, Serial)
import Manifest.Core.Meta (ColumnMeta (..), SqlType (..), TableMeta (..), genericTableMeta)
import Fixtures (User, UserT (..))
import Manifest.Entity (Entity (..), pkParam)
import Manifest.Core.Codec (decodeRow)
import qualified Data.ByteString.Char8 as BC
import Harness

-- Compile-time proofs that Base/Col reduce as intended (won't compile otherwise).
_pkReduces :: Base (PrimaryKey (Serial Int)) -> Int
_pkReduces = id

_colIdentityReduces :: Col Identity (PrimaryKey (Serial Int)) -> Int
_colIdentityReduces = id

_textPassesThrough :: Base Text -> Text
_textPassesThrough = id

tests :: [Test]
tests = group "Table"
  [ test "reflects PK/serial flags from marker structure" $ do
      assertBool "PK(Serial Int) is pk"        (fieldIsPK @(PrimaryKey (Serial Int)))
      assertBool "PK(Serial Int) is serial"    (fieldIsSerial @(PrimaryKey (Serial Int)))
      assertBool "Text is not pk"              (not (fieldIsPK @Text))
      assertBool "Text is not serial"          (not (fieldIsSerial @Text))
      assertBool "Serial Int is serial"        (fieldIsSerial @(Serial Int))
      assertBool "Serial Int is not pk"        (not (fieldIsPK @(Serial Int)))
  , test "genericTableMeta derives ordered columns with PK/serial flags from UserT" $ do
      let tm = genericTableMeta @UserT "users"
      assertEqual "table name" "users" (tmTable tm)
      assertEqual "columns"
        [ ColumnMeta "user_id"    True  True  SqlBigSerial False
        , ColumnMeta "user_name"  False False SqlText      False
        , ColumnMeta "user_email" False False SqlText      True
        ]
        (tmColumns tm)
  , test "rowEncode encodes a User to its column vector in table order" $ do
      let u = User { userId = 7, userName = "Bob", userEmail = Just "b@x.io" } :: User
      assertEqual "row"
        [ Just (BC.pack "7"), Just (BC.pack "Bob"), Just (BC.pack "b@x.io") ]
        (rowEncode u)
  , test "rowEncode encodes a NULL email as Nothing" $ do
      let u = User { userId = 7, userName = "Bob", userEmail = Nothing } :: User
      assertEqual "row" [ Just (BC.pack "7"), Just (BC.pack "Bob"), Nothing ] (rowEncode u)
  , test "row codec round-trips through decodeRow" $ do
      let u = User { userId = 7, userName = "Bob", userEmail = Just "b@x.io" } :: User
      assertEqual "roundtrip"
        (Right (7 :: Int, "Bob" :: Text, Just "b@x.io" :: Maybe Text))
        (fmap (\u' -> (userId u', userName u', userEmail u'))
              (decodeRow (rowDecoder @User) (rowEncode u)))
  , test "pkParam extracts the PK bytes" $ do
      let u = User { userId = 7, userName = "Bob", userEmail = Nothing } :: User
      assertEqual "pk" (Just (BC.pack "7")) (pkParam u)
  ]
