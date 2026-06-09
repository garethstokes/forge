{-# LANGUAGE FlexibleInstances #-}

module Manifest.Json
  ( Json (..)
  ) where

import Autodocodec (HasCodec, encodeJSONViaCodec, eitherDecodeJSONViaCodec)
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
