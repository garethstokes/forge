module Manifest.Error
  ( DecodeError(..)
  , DbError(..)
  , DbException(..)
  ) where

import Control.Exception (Exception)
import Data.ByteString (ByteString)

-- | A column value could not be decoded into the requested Haskell type.
newtype DecodeError = DecodeError String
  deriving (Eq, Show)

-- | Errors surfaced from the database / session layer.
data DbError
  = QueryError ByteString          -- ^ libpq result error message
  | DecodeFailure DecodeError      -- ^ row decoding failed
  | UnmanagedSave String           -- ^ save/delete of an entity with no baseline in the identity map
  | OtherError String
  deriving (Eq, Show)

-- | Thrown internally so it composes with 'Control.Exception.bracket' for
-- automatic rollback; converted to 'Either' at the boundary by try-combinators (future).
newtype DbException = DbException DbError
  deriving (Show)

instance Exception DbException
