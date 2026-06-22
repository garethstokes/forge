{-# LANGUAGE OverloadedStrings #-}
-- | Serialization masking for 'Manifest.Core.Table.Secret' columns: a 'Secret'
-- value is read and written to the database normally, but masked when serialized
-- (JSON / 'Show' / logs). 'Masked' is the masking carrier used by the serialization
-- view; it never reveals the wrapped value.
module Manifest.Core.Secret (Masked(..), mask) where

import Data.Aeson (ToJSON(..))

newtype Masked a = Masked a

instance Show (Masked a) where
  show _ = "<redacted>"

instance ToJSON (Masked a) where
  toJSON _ = "***"   -- a JSON string; requires OverloadedStrings (Value's IsString)

mask :: a -> Masked a
mask = Masked
