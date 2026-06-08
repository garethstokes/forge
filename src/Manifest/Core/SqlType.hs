module Manifest.Core.SqlType
  ( SqlType(..)
  , sqlTypeDDL
  , sqlTypeLive
  ) where

import Data.ByteString (ByteString)

-- | The subset of Postgres column types SP3 derives from Haskell field types.
data SqlType = SqlBigInt | SqlText | SqlBool | SqlBigSerial
  deriving (Eq, Show)

-- | The DDL spelling (for CREATE TABLE / ADD COLUMN).
sqlTypeDDL :: SqlType -> ByteString
sqlTypeDDL SqlBigInt    = "BIGINT"
sqlTypeDDL SqlText      = "TEXT"
sqlTypeDDL SqlBool      = "BOOLEAN"
sqlTypeDDL SqlBigSerial = "BIGSERIAL"

-- | The normalized type name as @information_schema.columns.data_type@ reports it
-- (a BIGSERIAL column IS @bigint@ in the catalog, with a sequence default), used
-- for diffing the live DB against the records.
sqlTypeLive :: SqlType -> ByteString
sqlTypeLive SqlBigInt    = "bigint"
sqlTypeLive SqlText      = "text"
sqlTypeLive SqlBool      = "boolean"
sqlTypeLive SqlBigSerial = "bigint"
