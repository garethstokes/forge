{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Postgres-backed 'MemoryStore' via manifest. Provides 'memoryStoreManifest'
-- and 'migrateMemory'.
module Crucible.Manifest.Memory
  ( memoryStoreManifest
  , migrateMemory
  , MemoryTombstoneT (..)
  , MemoryTombstone
  ) where

import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LB
import Data.Functor.Identity (Identity)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)

import Manifest
  ( DbType (..), dimap, lmap, refine
  , DecodeError (..)
  , Entity (..), Table (..)
  , withSession
  , add, selectWhere
  , managed, migrateUp
  )
import Manifest.Core.Table (Field, Pk)
import Manifest.Postgres (Pool)

import qualified Data.Text as T
import Crucible.Codec (encodeText)
import Crucible.Decode (decodeLLM)
import qualified Crucible.Decode as Dec
import Crucible.Memory
  ( MemoryDraft (..)
  , MemoryEntry (..)
  , MemoryId (..)
  , MemoryItem
  , MemoryItemT (..)
  , MemoryKind (..)
  , MemoryStore (..)
  , Provenance (..)
  , Query (..)
  , queryLive
  , provenanceCodec
  )

-- ---------------------------------------------------------------------------
-- DbType orphans for crucible field types
-- ---------------------------------------------------------------------------

instance DbType MemoryId where
  dbType = dimap (\(MemoryId i) -> i) MemoryId (dbType @Int)

instance DbType MemoryKind where
  dbType = refine decKind (lmap encKind (dbType @Text))
    where
      encKind Episodic   = "episodic"
      encKind Semantic   = "semantic"
      encKind Procedural = "procedural"
      decKind t = case t of
        "episodic"   -> Right Episodic
        "semantic"   -> Right Semantic
        "procedural" -> Right Procedural
        other        -> Left (DecodeError ("DbType MemoryKind: unknown value: " <> show other))

instance DbType Provenance where
  dbType = refine decodeProv (lmap encodeProv (dbType @Text))
    where
      encodeProv = encodeText provenanceCodec
      decodeProv t = case decodeLLM provenanceCodec t of
        Right p                    -> Right p
        Left (Dec.DecodeError m _) -> Left (DecodeError ("DbType Provenance: " <> T.unpack m))

instance DbType [Text] where
  dbType = refine decTags (lmap encTags (dbType @Text))
    where
      encTags ts = TE.decodeUtf8 . LB.toStrict . A.encode $ ts
      decTags t  = case A.eitherDecode (LB.fromStrict (TE.encodeUtf8 t)) of
        Right ts -> Right ts
        Left err -> Left (DecodeError ("DbType [Text]: " <> err))

-- ---------------------------------------------------------------------------
-- Entity instances
-- ---------------------------------------------------------------------------

deriving via (Table "memory" MemoryItemT) instance Entity MemoryItem

data MemoryTombstoneT f = MemoryTombstone
  { tombId :: Field f (Pk Int)
  , memRef :: Field f MemoryId
  } deriving Generic

type MemoryTombstone = MemoryTombstoneT Identity

deriving instance Eq   (MemoryTombstoneT Identity)
deriving instance Show (MemoryTombstoneT Identity)

deriving via (Table "memory_tombstones" MemoryTombstoneT) instance Entity MemoryTombstone

-- ---------------------------------------------------------------------------
-- Migration
-- ---------------------------------------------------------------------------

migrateMemory :: Pool -> IO ()
migrateMemory pool =
  withSession pool $ do
    _ <- migrateUp
           [ managed (Proxy @MemoryItem)
           , managed (Proxy @MemoryTombstone)
           ]
    pure ()

-- ---------------------------------------------------------------------------
-- memoryStoreManifest
-- ---------------------------------------------------------------------------

-- | Build a 'MemoryStore' backed by Postgres via manifest.
memoryStoreManifest :: Pool -> MemoryStore
memoryStoreManifest pool = MemoryStore
  { doRemember = \draft -> withSession pool $ do
      let placeholder = (MemoryItem
            { memId     = MemoryId 0
            , kind      = draft.kind
            , content   = draft.content
            , tags      = draft.tags
            , source    = draft.source
            , createdAt = 0
            } :: MemoryItem)
      row <- add placeholder
      pure row.memId

  , doRecall = \q -> withSession pool $ do
      items  <- selectWhere @MemoryItem []
      tombs  <- selectWhere @MemoryTombstone []
      let entries =
            [ Remembered it { createdAt = idInt it.memId }
            | it <- items
            ] ++
            [ Forgot t.memRef
            | t <- tombs
            ]
      pure (queryLive q entries)

  , doForget = \i -> withSession pool $ do
      let placeholder = (MemoryTombstone
            { tombId = 0
            , memRef = i
            } :: MemoryTombstone)
      _ <- add placeholder
      pure ()
  }
  where
    idInt (MemoryId n) = n
