{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Postgres-backed 'LedgerStore' via manifest. Provides 'ledgerStoreManifest'
-- and 'migrateLedger'.
module Crucible.Manifest.Ledger
  ( ledgerStoreManifest
  , migrateLedger
  ) where

import Data.List (sortOn)
import Data.Proxy (Proxy (..))

import Manifest
  ( DbType (..), dimap, lmap, refine
  , DecodeError (..)
  , Entity (..), Table (..)
  , withSession
  , add, selectWhere
  , managed, migrateUp
  , encode
  , (==.)
  )
import Manifest.Session (execDb)
import Manifest.Postgres (Pool)
import Data.Text (Text)

import Crucible.Ledger
  ( WorkId (..)
  , WorkState (..)
  , WorkItemT (..)
  , WorkItem
  , LedgerStore (..)
  )

-- ---------------------------------------------------------------------------
-- DbType orphans for crucible ledger field types
-- ---------------------------------------------------------------------------

instance DbType WorkId where
  dbType = dimap (\(WorkId i) -> i) WorkId (dbType @Int)

instance DbType WorkState where
  dbType = refine decState (lmap encState (dbType @Text))
    where
      encState Ready   = "ready"
      encState Claimed = "claimed"
      encState Done    = "done"
      decState t = case t of
        "ready"   -> Right Ready
        "claimed" -> Right Claimed
        "done"    -> Right Done
        other     -> Left (DecodeError ("unknown WorkState: " <> show other))

-- ---------------------------------------------------------------------------
-- Entity instance
-- ---------------------------------------------------------------------------

deriving via (Table "work_items" WorkItemT) instance Entity WorkItem

-- ---------------------------------------------------------------------------
-- Migration
-- ---------------------------------------------------------------------------

migrateLedger :: Pool -> IO ()
migrateLedger pool =
  withSession pool $ do
    _ <- migrateUp
           [ managed (Proxy @WorkItem)
           ]
    pure ()

-- ---------------------------------------------------------------------------
-- ledgerStoreManifest
-- ---------------------------------------------------------------------------

-- | Build a 'LedgerStore' backed by Postgres via manifest.
ledgerStoreManifest :: Pool -> LedgerStore
ledgerStoreManifest pool = LedgerStore
  { doRecord = \p -> withSession pool $ do
      it <- add (WorkItem (WorkId 0) p Ready Nothing :: WorkItem)
      pure it.wid

  , doClaim = \w who -> withSession pool $ do
      rows <- execDb
        "UPDATE work_items SET state=$1, claimant=$2 WHERE wid=$3 AND state=$4 RETURNING wid"
        [ encode Claimed
        , encode (Just who :: Maybe Text)
        , encode w
        , encode Ready
        ]
      pure (not (null rows))

  , doComplete = \w -> withSession pool $ do
      _ <- execDb
        "UPDATE work_items SET state=$1 WHERE wid=$2"
        [ encode Done
        , encode w
        ]
      pure ()

  , doListReady = withSession pool $
      sortOn ((.wid) :: WorkItem -> WorkId) <$> selectWhere @WorkItem [#state ==. Ready]
  }
