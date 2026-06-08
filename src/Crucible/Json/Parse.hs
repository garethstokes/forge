{-# LANGUAGE OverloadedStrings #-}
module Crucible.Json.Parse (parse) where

import Control.Applicative (Alternative(..))
import Data.Char (isDigit, isSpace, isHexDigit, chr)
import Data.Text (Text)
import qualified Data.Text as T
import Crucible.Json.Value (Value(..))

-- ---------------------------------------------------------------------------
-- Parser newtype + instances
-- ---------------------------------------------------------------------------

newtype Parser a = Parser { runParser :: Text -> Either String (a, Text) }

instance Functor Parser where
  fmap f (Parser p) = Parser $ \t -> case p t of
    Right (a, r) -> Right (f a, r)
    Left e       -> Left e

instance Applicative Parser where
  pure x = Parser $ \t -> Right (x, t)
  Parser pf <*> Parser px = Parser $ \t -> do
    (f, t1) <- pf t
    (x, t2) <- px t1
    pure (f x, t2)

instance Monad Parser where
  Parser p >>= f = Parser $ \t -> do
    (a, t1) <- p t
    runParser (f a) t1

instance Alternative Parser where
  empty = Parser $ const (Left "no parse")
  Parser a <|> Parser b = Parser $ \t -> either (const (b t)) Right (a t)

-- ---------------------------------------------------------------------------
-- Primitive combinators
-- ---------------------------------------------------------------------------

satisfy :: (Char -> Bool) -> Parser Char
satisfy ok = Parser $ \t -> case T.uncons t of
  Just (c, r) | ok c -> Right (c, r)
  _                  -> Left "satisfy"

char :: Char -> Parser Char
char c = satisfy (== c)

skipSpace :: Parser ()
skipSpace = Parser $ \t -> Right ((), T.dropWhile isSpace t)

lit :: Text -> a -> Parser a
lit s v = Parser $ \t -> case T.stripPrefix s t of
  Just r  -> Right (v, r)
  Nothing -> Left ("expected " ++ T.unpack s)

-- Run parser exactly n times, collecting results.
countP :: Int -> Parser a -> Parser [a]
countP 0 _ = pure []
countP n p = (:) <$> p <*> countP (n - 1) p

-- ---------------------------------------------------------------------------
-- String parser  (handles \" \\ \/ \n \t \r \b \f and \uXXXX)
-- ---------------------------------------------------------------------------
-- We accumulate decoded characters in a plain list (reversed) and
-- reverse at the end.  On a backslash we decode the escape and prepend
-- those chars before continuing.

pString :: Parser Text
pString = do
  _ <- char '"'
  go []
  where
    -- acc is in reverse order; we reverse once when we hit closing '"'
    go :: String -> Parser Text
    go acc = do
      c <- satisfy (const True)
      case c of
        '"'  -> pure (T.pack (reverse acc))
        '\\' -> do
          decoded <- pEscape
          go (reverse decoded ++ acc)
        _    -> go (c : acc)

    pEscape :: Parser String
    pEscape = do
      e <- satisfy (const True)
      case e of
        '"'  -> pure "\"";  '\\'-> pure "\\"
        '/'  -> pure "/"
        'n'  -> pure "\n";  't' -> pure "\t"
        'r'  -> pure "\r";  'b' -> pure "\b"
        'f'  -> pure "\f"
        'u'  -> do
          hexChars <- countP 4 (satisfy isHexDigit)
          pure [chr (hexVal hexChars)]
        _    -> Parser $ const (Left ("bad escape: \\" ++ [e]))

hexVal :: String -> Int
hexVal = foldl (\acc c -> acc * 16 + d c) 0
  where
    d c | isDigit c = fromEnum c - fromEnum '0'
        | c >= 'a'  = fromEnum c - fromEnum 'a' + 10
        | otherwise = fromEnum c - fromEnum 'A' + 10

-- ---------------------------------------------------------------------------
-- Number parser  (optional '-', digits, optional '.digits', optional exp)
-- ---------------------------------------------------------------------------
-- We grab the maximal token that looks like a number and parse it with
-- 'reads'.  This is acceptable for v1; RFC-strict grammar is a later
-- refinement.

pNumber :: Parser Value
pNumber = Parser $ \t ->
  let (tok, rest) = T.span (\c -> isDigit c || c `elem` ("+-.eE" :: String)) t
  in if T.null tok
       then Left "number"
       else case reads (T.unpack tok) :: [(Double, String)] of
              [(d, "")] -> Right (JNumber d, rest)
              _         -> Left ("bad number: " ++ T.unpack tok)

-- ---------------------------------------------------------------------------
-- Literal parser (null / true / false)
-- ---------------------------------------------------------------------------

pLit :: Parser Value
pLit =  lit "null"  JNull
    <|> lit "true"  (JBool True)
    <|> lit "false" (JBool False)

-- ---------------------------------------------------------------------------
-- Composite parsers
-- ---------------------------------------------------------------------------

-- | Parse a comma-separated list of 'p', allowing zero items.
sepByComma :: Parser a -> Parser [a]
sepByComma p =
  (do x  <- p
      xs <- many (skipSpace *> char ',' *> p)
      pure (x : xs))
  <|> pure []

pArray :: Parser Value
pArray = do
  _ <- char '['; skipSpace
  xs <- sepByComma pValue
  skipSpace; _ <- char ']'
  pure (JArray xs)

pObject :: Parser Value
pObject = do
  _ <- char '{'; skipSpace
  kvs <- sepByComma pMember
  skipSpace; _ <- char '}'
  pure (JObject kvs)
  where
    pMember = do
      skipSpace
      k <- pString
      skipSpace; _ <- char ':'
      v <- pValue
      pure (k, v)

-- | Top-level value parser (surrounded by optional whitespace).
pValue :: Parser Value
pValue =
  skipSpace *>
  (pObject <|> pArray <|> (JString <$> pString) <|> pNumber <|> pLit)
  <* skipSpace

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- | Parse JSON text.  Rejects trailing garbage.
parse :: Text -> Either String Value
parse t = case runParser (skipSpace *> pValue <* skipSpace) t of
  Right (v, rest)
    | T.null rest -> Right v
    | otherwise   -> Left ("trailing input: " ++ T.unpack rest)
  Left e -> Left e
