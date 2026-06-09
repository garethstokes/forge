{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CodecSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Char8 (pack)
import Data.Text (Text)
import Manifest.Core.Codec
import Manifest.Core.SqlType (SqlType(..), sqlTypeDDL, sqlTypeLive)
import Manifest.Error (DecodeError (..))
import Harness

-- 1. deriving newtype DbType reuses the base column type + encode.
newtype Email = Email Text
  deriving newtype DbType

-- 2. dimap builds a domain column.
newtype Money = Money Int
instance DbType Money where
  dbType = dimap (\(Money n) -> n) Money (dbType @Int)

-- 4. refine rejects invalid input.
newtype Age = Age Int
  deriving stock (Eq, Show)
instance DbType Age where
  dbType = refine (\n -> if n >= 0 then Right (Age n) else Left (DecodeError "neg"))
                  (lmap (\(Age n) -> n) (dbType @Int))

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False

-- Used polymorphically over the 'Profunctor' class to prove 'Codec' is a real
-- instance (this would not typecheck if 'dimap' were merely a local function).
idVia :: Profunctor p => p a b -> p a b
idVia = dimap id id

tests :: [Test]
tests = group "Codec"
  [ test "encodes scalars to text params" $ do
      assertEqual "int"     (Just (BC.pack "42")) (encode (42 :: Int))
      assertEqual "string"  (Just (BC.pack "hi")) (encode ("hi" :: String))
      assertEqual "nothing" (Nothing :: Maybe BC.ByteString) (encode (Nothing :: Maybe Int))
      assertEqual "just"    (Just (BC.pack "7")) (encode (Just (7 :: Int)))
  , test "decodes scalars from text params" $ do
      assertEqual "int"       (Right (42 :: Int)) (cDecode (dbType @Int) (Just (BC.pack "42")))
      assertEqual "maybe-null"(Right (Nothing :: Maybe Int)) (cDecode (dbType @(Maybe Int)) Nothing)
      assertBool  "bad int is Left"
        (either (const True) (const False) (cDecode (dbType @Int) (Just (BC.pack "x"))))
  , test "applicative RowDecoder runs left-to-right with no arity ceiling" $ do
      let dec = (,,,,) <$> decodeCol <*> decodeCol <*> decodeCol <*> decodeCol <*> decodeCol
          row = [ Just (BC.pack "1"), Just (BC.pack "a"), Nothing
                , Just (BC.pack "t"), Just (BC.pack "9") ]
      assertEqual "5-tuple"
        (Right (1 :: Int, "a" :: String, Nothing :: Maybe String, True, 9 :: Int))
        (decodeRow dec row)
  , test "deriving newtype DbType reuses base column type and encode" $ do
      assertEqual "sql type matches base"
        (cSqlType (dbType @Text))
        (cSqlType (dbType @Email))
      assertEqual "encode matches base"
        (encode ("ada" :: Text))
        (encode (Email "ada"))
  , test "dimap builds a domain column" $
      assertEqual "Money encodes like its underlying Int"
        (encode (100 :: Int))
        (encode (Money 100))
  , test "nullable encodes Nothing as NULL and is nullable" $ do
      assertEqual "Nothing encodes to NULL"
        (Nothing :: SqlParam)
        (encode (Nothing :: Maybe Int))
      assertBool "Maybe Int codec is nullable"
        (cNullable (dbType @(Maybe Int)))
  , test "refine accepts valid and rejects invalid" $ do
      assertBool "decoding 5 succeeds"
        (isRight (cDecode (dbType @Age) (Just (pack "5"))))
      assertBool "decoding -1 fails"
        (not (isRight (cDecode (dbType @Age) (Just (pack "-1")))))
  , test "Codec is a real Profunctor instance (class methods + polymorphic use)" $ do
      let c = rmap (+ (1 :: Int)) (dbType @Int)   -- rmap is a class method (no local def)
      assertEqual "rmap post-composes decode" (Right (43 :: Int)) (cDecode c (Just (BC.pack "42")))
      assertEqual "rmap leaves sqltype" (cSqlType (dbType @Int)) (cSqlType c)
      assertEqual "used through Profunctor p =>" (encode (5 :: Int)) (cEncode (idVia (dbType @Int)) 5)
  , test "SqlJsonb DDL and live spellings" $ do
      assertEqual "ddl"  "JSONB" (sqlTypeDDL SqlJsonb)
      assertEqual "live" "jsonb" (sqlTypeLive SqlJsonb)
  ]
