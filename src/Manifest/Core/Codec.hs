{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Manifest.Core.Codec
  ( SqlParam
  , ToField(..)
  , FromField(..)
  , RowDecoder(..)
  , field
  , decodeRow
  , Codec(..)
  , DbType(..)
  , dimap
  , lmap
  , rmap
  , refine
  , nullable
  , encode
  , decodeCol
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Manifest.Core.SqlType (SqlType(..))
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

-- | A profunctor column codec: pairs an encoder (Haskell -> column) with a
-- decoder (column -> Haskell), plus the SQL column type and nullability. The
-- @a@ side is contravariant (encode), the @b@ side covariant (decode), so a
-- value-level @Codec a a@ is what a 'DbType' instance provides.
data Codec a b = Codec
  { cEncode   :: a -> SqlParam
  , cDecode   :: SqlParam -> Either DecodeError b
  , cSqlType  :: SqlType
  , cNullable :: Bool
  }

-- | Profunctor 'dimap': pre-compose on the encode side, post-compose on decode.
dimap :: (a' -> a) -> (b -> b') -> Codec a b -> Codec a' b'
dimap f g (Codec e d s n) = Codec (e . f) (fmap g . d) s n

-- | Map the contravariant (encode) side only.
lmap :: (a' -> a) -> Codec a b -> Codec a' b
lmap f = dimap f id

-- | Map the covariant (decode) side only.
rmap :: (b -> b') -> Codec a b -> Codec a b'
rmap = dimap id

-- | Refine the decoded value with a partial function that may reject.
refine :: (b -> Either DecodeError c) -> Codec a b -> Codec a c
refine k (Codec e d s n) = Codec e (\p -> d p >>= k) s n

-- | Lift a non-null codec to a nullable one: 'Nothing' round-trips to SQL NULL.
nullable :: Codec a a -> Codec (Maybe a) (Maybe a)
nullable (Codec e d s _) =
  Codec (maybe Nothing e)
        (\p -> case p of Nothing -> Right Nothing; Just v -> Just <$> d (Just v))
        s True

-- | A type with a canonical column codec.
class DbType a where
  dbType :: Codec a a

instance DbType Int where
  dbType = Codec (Just . BC.pack . show)
                 (\p -> case p of
                          Just bs -> maybe (Left (DecodeError ("expected Int, got " <> show (BC.unpack bs)))) Right (readMaybe (BC.unpack bs))
                          Nothing -> Left (DecodeError "expected Int, got NULL"))
                 SqlBigInt False

instance DbType Text where
  dbType = Codec (Just . TE.encodeUtf8)
                 (\p -> case p of Just bs -> Right (TE.decodeUtf8 bs); Nothing -> Left (DecodeError "expected Text, got NULL"))
                 SqlText False

instance DbType Bool where
  dbType = Codec (\b -> Just (if b then BC.pack "t" else BC.pack "f"))
                 (\p -> case p of
                          Just bs -> case BC.unpack bs of { "t" -> Right True; "f" -> Right False; o -> Left (DecodeError ("expected Bool (t/f), got " <> show o)) }
                          Nothing -> Left (DecodeError "expected Bool, got NULL"))
                 SqlBool False

instance DbType String where
  dbType = dimap T.pack T.unpack (dbType :: Codec Text Text)

instance DbType a => DbType (Maybe a) where
  dbType = nullable dbType

-- | Encode a value to a column using its 'DbType' instance.
encode :: DbType a => a -> SqlParam
encode = cEncode dbType

-- | Decode one column with its 'DbType' instance.
decodeCol :: forall a. DbType a => RowDecoder a
decodeCol = RowDecoder $ \cs -> case cs of
  (c:rest) -> (\a -> (a, rest)) <$> cDecode (dbType @a) c
  []       -> Left (DecodeError "ran out of columns while decoding row")
