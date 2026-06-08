{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Main (main) where

import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import GHC.Generics (Generic)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Manifest

-- An example managed schema (the exe migrates this).
data NoteT f = Note
  { noteId    :: Col f (PrimaryKey (Serial Int))
  , noteTitle :: Col f Text
  , noteBody  :: Col f (Maybe Text)
  } deriving Generic
type Note = NoteT Identity

instance Entity Note where
  type PrimKey Note = Int
  tableMeta  = genericTableMeta @NoteT "notes"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = noteId

schema :: [ManagedTable]
schema = [ managed (Proxy @Note) ]

main :: IO ()
main = do
  args <- getArgs
  mUrl <- lookupEnv "MANIFEST_DATABASE_URL"
  case mUrl of
    Nothing  -> hPutStrLn stderr "set MANIFEST_DATABASE_URL" >> exitFailure
    Just url -> do
      pool <- newPool (BC.pack url) 1
      runMigrate schema pool args
      closePool pool
