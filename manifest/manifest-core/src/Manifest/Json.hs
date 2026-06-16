{-# LANGUAGE FlexibleInstances #-}

module Manifest.Json
  ( Json (..)
  , Aeson (..)
  ) where

import Autodocodec (HasCodec, encodeJSONViaCodec, eitherDecodeJSONViaCodec)
import Data.Aeson (FromJSON, ToJSON, encode, eitherDecode)
import Data.Bifunctor (bimap)
import qualified Data.ByteString.Lazy as LB
import Manifest.Core.Codec (Codec (..), DbType (..))
import Manifest.Core.SqlType (SqlType (SqlJsonb))
import Manifest.Error (DecodeError (..))

-- | A column that stores its value as Postgres @jsonb@, serialized through the
-- value's autodocodec 'HasCodec' instance.
newtype Json a = Json { unJson :: a }
  deriving (Eq, Show)

instance HasCodec a => DbType (Json a) where
  dbType = Codec
    { cEncode   = \(Json x) -> Just (LB.toStrict (encodeJSONViaCodec x))
    , cDecode   = \p -> case p of
        Just bs -> bimap (DecodeError . ("jsonb decode: " <>)) Json
                         (eitherDecodeJSONViaCodec (LB.fromStrict bs))
        Nothing -> Left (DecodeError "expected jsonb, got NULL")
    , cSqlType  = SqlJsonb
    , cNullable = False
    }

-- | A column that stores its value as Postgres @jsonb@ via the value's aeson
-- 'ToJSON'/'FromJSON' instances (the alternative to 'Json', which uses autodocodec).
newtype Aeson a = Aeson { unAeson :: a }
  deriving (Eq, Show)

instance (ToJSON a, FromJSON a) => DbType (Aeson a) where
  dbType = Codec
    { cEncode   = \(Aeson x) -> Just (LB.toStrict (encode x))
    , cDecode   = \p -> case p of
        Just bs -> bimap (DecodeError . ("jsonb (aeson) decode: " <>)) Aeson
                         (eitherDecode (LB.fromStrict bs))
        Nothing -> Left (DecodeError "expected jsonb, got NULL")
    , cSqlType  = SqlJsonb
    , cNullable = False
    }
