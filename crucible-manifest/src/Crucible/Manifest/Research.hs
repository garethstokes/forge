{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Postgres-backed 'ResearchStore' via manifest. Provides
-- 'researchStoreManifest' and 'migrateResearch'.
module Crucible.Manifest.Research
  ( researchStoreManifest
  , migrateResearch
  ) where

import Data.Functor.Identity (Identity)
import Data.List (sort)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import GHC.Generics (Generic)

import Manifest
  ( Db
  , Entity (..), Table (..)
  , Key (..)
  , withSession
  , add, save, flush, get, selectWhere
  , managed, migrateUp
  , Field, Pk, PrimaryKey
  )
import Manifest.Postgres (Pool)

import Crucible.Codec (JSONCodec, list', encodeText)
import Crucible.Decode (decodeLLM)
import Crucible.Research
  ( Page (..)
  , Slug (..)
  , Link
  , ResearchStore (..)
  , linkCodec
  , matchesQuery
  , unSlug
  )

-- ---------------------------------------------------------------------------
-- Entities
-- ---------------------------------------------------------------------------

data PageRowT f = PageRow
  { slug  :: Field f (PrimaryKey Text)
  , title :: Field f Text
  , body  :: Field f Text
  , links :: Field f Text   -- JSON-encoded [Link]
  , meta  :: Field f Text   -- JSON-encoded meta
  } deriving Generic

type PageRow = PageRowT Identity

deriving via (Table "pages" PageRowT) instance Entity PageRow

data ActivityRowT f = ActivityRow
  { actId :: Field f (Pk Int)
  , line  :: Field f Text
  } deriving Generic

type ActivityRow = ActivityRowT Identity

deriving via (Table "research_activity" ActivityRowT) instance Entity ActivityRow

-- ---------------------------------------------------------------------------
-- Migration
-- ---------------------------------------------------------------------------

migrateResearch :: Pool -> IO ()
migrateResearch pool =
  withSession pool $ do
    _ <- migrateUp
           [ managed (Proxy @PageRow)
           , managed (Proxy @ActivityRow)
           ]
    pure ()

-- ---------------------------------------------------------------------------
-- researchStoreManifest
-- ---------------------------------------------------------------------------

-- | Convert a 'Page meta' to a concrete 'PageRow' using the provided meta codec.
toRow :: JSONCodec meta -> Page meta -> PageRow
toRow mc p = PageRow
  { slug  = unSlug p.slug
  , title = p.title
  , body  = p.body
  , links = encodeText (list' linkCodec) p.links
  , meta  = encodeText mc p.meta
  }

-- | Attempt to decode a 'PageRow' back to a 'Page meta'. Returns 'Nothing' on
-- any decode failure (tolerant, matching 'runResearchDir' behaviour).
fromRow :: JSONCodec meta -> PageRow -> Maybe (Page meta)
fromRow mc r =
  case (decodeLLM (list' linkCodec) r.links, decodeLLM mc r.meta) of
    (Right ls, Right m) -> Just (Page (Slug r.slug) r.title ls r.body m)
    _                   -> Nothing

-- | Build a 'ResearchStore meta' backed by Postgres via manifest.
researchStoreManifest :: forall meta. JSONCodec meta -> Pool -> ResearchStore meta
researchStoreManifest mc pool = ResearchStore
  { doRead = \s -> withSession pool $ do
      mrow <- get (Key (unSlug s) :: Key PageRow)
      pure (mrow >>= fromRow mc)

  , doWrite = \p -> withSession pool $ do
      let row = toRow mc p
      mExisting <- get (Key (unSlug p.slug) :: Key PageRow)
      case mExisting of
        Nothing -> do
          _ <- add row
          pure ()
        Just _  -> do
          -- 'get' recorded the baseline; 'save' will diff and UPDATE only
          -- the changed columns. 'flush' must be called explicitly here —
          -- 'withSession' does NOT auto-flush on completion.
          save row
          flush

  , doIndex = withSession pool $ do
      rows <- (selectWhere [] :: Db [PageRow])
      pure (sort [ Slug ((.slug) r) | r <- rows ])

  , doSearch = \q -> withSession pool $ do
      rows <- (selectWhere [] :: Db [PageRow])
      pure (sort [ Slug ((.slug) r)
                 | r <- rows
                 , Just pg <- [fromRow mc r]
                 , matchesQuery q pg
                 ])

  , doLog = \ln -> withSession pool $ do
      _ <- add (ActivityRow 0 ln :: ActivityRow)
      pure ()
  }
