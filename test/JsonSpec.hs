{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}

module JsonSpec (tests) where

import Autodocodec
import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.Text (Text)
import GHC.Generics (Generic)
import Manifest
import Manifest.Core.SqlType (SqlType (..))
import Manifest.Postgres (execText, withConnection)
import Fixtures (withEmptyDb)
import Harness (Test, group, test, assertEqual, assertBool)

data Prefs = Prefs { prefTheme :: Text, prefTags :: [Text] }
  deriving (Eq, Show)

instance HasCodec Prefs where
  codec = object "Prefs" $
    Prefs <$> requiredField "theme" "ui theme" .= prefTheme
          <*> requiredField "tags"  "tags"     .= prefTags

data SettingT f = Setting
  { settingId    :: Field f (Pk Int)
  , settingPrefs :: Field f (Json Prefs)
  , settingNote  :: Field f (Maybe (Json Prefs))
  } deriving Generic
type Setting = SettingT Identity
deriving via (Table "settings" SettingT) instance Entity Setting

settingsDDL :: BC.ByteString
settingsDDL = "CREATE TABLE settings ( setting_id BIGSERIAL PRIMARY KEY, setting_prefs JSONB NOT NULL, setting_note JSONB )"

tests :: [Test]
tests = group "Json"
  [ test "Json column reports jsonb and round-trips its codec" $ do
      let p   = Prefs "dark" ["a", "b"]
          enc = encode (Json p)
      assertEqual "sqltype is jsonb" SqlJsonb (cSqlType (dbType @(Json Prefs)))
      assertBool  "encodes to some bytes" (enc /= Nothing)
      assertEqual "decode . encode = id"
        (Right (Json p))
        (cDecode (dbType @(Json Prefs)) enc)
  , test "a jsonb column round-trips through add/get/save (incl. nullable)" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c settingsDDL [])
        (initialPrefs, updatedPrefs, updatedNote) <- withSession pool $ do
          let p0 = Prefs "dark" ["x"]
          s   <- add (Setting { settingId = 0, settingPrefs = Json p0, settingNote = Nothing } :: Setting)
          g1  <- get @Setting (Key (settingId s))
          save (s { settingPrefs = Json (Prefs "light" ["y", "z"]), settingNote = Just (Json p0) } :: Setting)
          g2  <- get @Setting (Key (settingId s))
          pure ( fmap (unJson . settingPrefs) g1
               , fmap (unJson . settingPrefs) g2
               , fmap (fmap unJson . settingNote) g2 )
        assertEqual "initial prefs round-trip" (Just (Prefs "dark" ["x"]))        initialPrefs
        assertEqual "updated prefs via save"   (Just (Prefs "light" ["y", "z"])) updatedPrefs
        assertEqual "updated nullable note"    (Just (Just (Prefs "dark" ["x"]))) updatedNote
  ]
