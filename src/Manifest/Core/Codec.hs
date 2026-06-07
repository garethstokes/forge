{-# LANGUAGE FlexibleInstances #-}

module Manifest.Core.Codec
  ( SqlParam
  , ToField(..)
  , FromField(..)
  , RowDecoder(..)
  , field
  , decodeRow
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Manifest.Error (DecodeError(..))
import Text.Read (readMaybe)

-- | A single column value in libpq text format. 'Nothing' is SQL NULL.
type SqlParam = Maybe ByteString

-- | Encode a Haskell value to a text-format column value.
class ToField a where
  toField :: a -> SqlParam

-- | Decode a text-format column value into a Haskell value.
class FromField a where
  fromField :: SqlParam -> Either DecodeError a

instance ToField Int where
  toField = Just . BC.pack . show
instance FromField Int where
  fromField (Just bs) =
    maybe (Left (DecodeError ("expected Int, got " <> show (BC.unpack bs)))) Right
          (readMaybe (BC.unpack bs))
  fromField Nothing = Left (DecodeError "expected Int, got NULL")

instance ToField Text where
  toField = Just . TE.encodeUtf8
instance FromField Text where
  fromField (Just bs) = Right (TE.decodeUtf8 bs)
  fromField Nothing   = Left (DecodeError "expected Text, got NULL")

instance ToField String where
  toField = Just . TE.encodeUtf8 . T.pack
instance FromField String where
  fromField (Just bs) = Right (T.unpack (TE.decodeUtf8 bs))
  fromField Nothing   = Left (DecodeError "expected String, got NULL")

instance ToField Bool where
  toField b = Just (if b then BC.pack "t" else BC.pack "f")
instance FromField Bool where
  fromField (Just bs) = case BC.unpack bs of
    "t" -> Right True
    "f" -> Right False
    other -> Left (DecodeError ("expected Bool (t/f), got " <> show other))
  fromField Nothing = Left (DecodeError "expected Bool, got NULL")

instance ToField a => ToField (Maybe a) where
  toField Nothing  = Nothing
  toField (Just x) = toField x
instance FromField a => FromField (Maybe a) where
  fromField Nothing  = Right Nothing
  fromField (Just v) = Just <$> fromField (Just v)

-- | An applicative row decoder. Consumes columns left-to-right; no fixed-arity
-- combinators, so it has no @mapN@ ceiling.
newtype RowDecoder a =
  RowDecoder { runRowDecoder :: [SqlParam] -> Either DecodeError (a, [SqlParam]) }

instance Functor RowDecoder where
  fmap f (RowDecoder g) = RowDecoder $ \cs -> do
    (a, rest) <- g cs
    pure (f a, rest)

instance Applicative RowDecoder where
  pure x = RowDecoder $ \cs -> Right (x, cs)
  RowDecoder f <*> RowDecoder g = RowDecoder $ \cs -> do
    (h, cs')  <- f cs
    (a, cs'') <- g cs'
    pure (h a, cs'')

-- | Decode one column with its 'FromField' instance.
field :: FromField a => RowDecoder a
field = RowDecoder $ \cs -> case cs of
  (c:rest) -> (\a -> (a, rest)) <$> fromField c
  []       -> Left (DecodeError "ran out of columns while decoding row")

-- | Run a decoder against a full row, requiring all columns consumed.
decodeRow :: RowDecoder a -> [SqlParam] -> Either DecodeError a
decodeRow (RowDecoder g) cs = do
  (a, rest) <- g cs
  if null rest
    then Right a
    else Left (DecodeError ("row had " <> show (length rest) <> " unconsumed column(s)"))
