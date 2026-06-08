{-# LANGUAGE OverloadedStrings #-}
module Crucible.Json.Decode
  ( Decoder(..), Error(..), Crumb(..)
  , string, bool, int, float, null_, value
  , field, at, index, list, nullable, oneOf, succeed, failD, andThen
  , decodeValue, decodeString
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Crucible.Json.Value (Value(..))
import Crucible.Json.Parse (parse)

newtype Decoder a = Decoder { runD :: Value -> Either Error a }
data Error = Error { crumbs :: [Crumb], message :: String } deriving (Eq, Show)
data Crumb = AtField Text | AtIndex Int deriving (Eq, Show)

err :: String -> Either Error a
err m = Left (Error [] m)

push :: Crumb -> Either Error a -> Either Error a
push c (Left (Error cs m)) = Left (Error (c:cs) m)
push _ ok = ok

instance Functor Decoder where
  fmap f (Decoder d) = Decoder $ \v -> f <$> d v
instance Applicative Decoder where
  pure x = Decoder $ \_ -> Right x
  Decoder df <*> Decoder dx = Decoder $ \v -> df v <*> dx v
instance Monad Decoder where
  Decoder d >>= f = Decoder $ \v -> d v >>= \a -> runD (f a) v

tag :: Value -> String
tag v = case v of
  JNull     -> "null"
  JBool{}   -> "bool"
  JNumber{} -> "number"
  JString{} -> "string"
  JArray{}  -> "array"
  JObject{} -> "object"

string :: Decoder Text
string = Decoder $ \v -> case v of JString t -> Right t; _ -> err ("expected string, got " ++ tag v)

bool :: Decoder Bool
bool = Decoder $ \v -> case v of JBool b -> Right b; _ -> err ("expected bool, got " ++ tag v)

float :: Decoder Double
float = Decoder $ \v -> case v of JNumber n -> Right n; _ -> err ("expected number, got " ++ tag v)

int :: Decoder Int
int = Decoder $ \v -> case v of
  JNumber n | n == fromIntegral (round n :: Int) -> Right (round n)
            | otherwise -> err "expected integer, got fractional"
  _ -> err ("expected number, got " ++ tag v)

null_ :: a -> Decoder a
null_ x = Decoder $ \v -> case v of JNull -> Right x; _ -> err ("expected null, got " ++ tag v)

value :: Decoder Value
value = Decoder Right

field :: Text -> Decoder a -> Decoder a
field k (Decoder d) = Decoder $ \v -> case v of
  JObject kvs -> case lookup k kvs of
    Just v' -> push (AtField k) (d v')
    Nothing -> err ("missing field " ++ show k)
  _ -> err ("expected object, got " ++ tag v)

at :: [Text] -> Decoder a -> Decoder a
at ks d = foldr field d ks

index :: Int -> Decoder a -> Decoder a
index i (Decoder d) = Decoder $ \v -> case v of
  JArray xs | i >= 0 && i < length xs -> push (AtIndex i) (d (xs !! i))
            | otherwise -> err ("index " ++ show i ++ " out of bounds")
  _ -> err ("expected array, got " ++ tag v)

list :: Decoder a -> Decoder [a]
list (Decoder d) = Decoder $ \v -> case v of
  JArray xs -> sequence [ push (AtIndex i) (d x) | (i, x) <- zip [0..] xs ]
  _ -> err ("expected array, got " ++ tag v)

nullable :: Decoder a -> Decoder (Maybe a)
nullable (Decoder d) = Decoder $ \v -> case v of JNull -> Right Nothing; _ -> Just <$> d v

oneOf :: [Decoder a] -> Decoder a
oneOf ds = Decoder $ \v -> case [ r | Decoder d <- ds, Right r <- [d v] ] of
  (r:_) -> Right r
  []    -> err "no alternative matched"

succeed :: a -> Decoder a
succeed = pure

failD :: String -> Decoder a
failD m = Decoder $ \_ -> err m

andThen :: (a -> Decoder b) -> Decoder a -> Decoder b
andThen f d = d >>= f

decodeValue :: Decoder a -> Value -> Either Error a
decodeValue = runD

decodeString :: Decoder a -> Text -> Either Error a
decodeString d t = case parse t of
  Right v -> runD d v
  Left e  -> Left (Error [] ("parse error: " ++ e))
