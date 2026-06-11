{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The change feed's subscriber half. A 'Change' is a WAKE-UP — a hint that
-- current state for a table moved — never data: consumers re-read. A missed
-- notification (listener not yet attached, connection drop, queue overflow)
-- means staleness until the next write; pollable consumers should poll as a
-- backstop. Durable delivery is the (future) event-store's job, not this
-- feed's. Emission lives in "Manifest.Session" behind the per-entity
-- @notifyChanges@ flag (next slice of this feature).
module Manifest.Notify
  ( Change (..)
  , listenChanges
  ) where

import Control.Concurrent (threadWaitRead)
import Control.Exception (bracket, throwIO)
import Control.Monad (forever, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.Maybe (fromMaybe)
import qualified Database.PostgreSQL.LibPQ as PQ
import Manifest.Error (DbError (..), DbException (..))

-- | Current state for 'table' moved. 'key' is the pk rendered as text, or
-- 'Nothing' for bulk operations. Re-read; never trust as data.
data Change = Change
  { table :: ByteString
  , key   :: Maybe ByteString
  }
  deriving (Eq, Show)

-- | Open a DEDICATED connection (LISTEN occupies it for life — a pool
-- checkout would starve writers), LISTEN on each table's
-- @manifest_\<table\>@ channel, then block forever dispatching notifications
-- to the callback. The callback runs on this thread: slow callbacks delay
-- subsequent deliveries — hand off if you do real work. Throws 'DbException'
-- on connection loss or callback exception (queued notifications are dropped).
-- Retry\/supervision is the caller's policy.
--
-- Note: channel identifiers longer than 63 bytes are truncated by LISTEN while
-- pg_notify errors — very long table names would silently never match.
listenChanges :: ByteString -> [ByteString] -> (Change -> IO ()) -> IO ()
listenChanges conninfo tables onChange =
  bracket (PQ.connectdb conninfo) PQ.finish $ \conn -> do
    st <- PQ.status conn
    unless (st == PQ.ConnectionOk) (failWith conn)
    mapM_ (\t -> run conn ("LISTEN \"manifest_" <> escapeIdent t <> "\"")) tables
    drain conn
    forever $ do
      fd <- PQ.socket conn >>= maybe (failWith conn) pure
      threadWaitRead fd
      ok <- PQ.consumeInput conn
      unless ok (failWith conn)
      drain conn
  where
    -- Escape embedded double-quotes in the table name for use inside a
    -- double-quoted identifier.
    escapeIdent t = BS.intercalate "\"\"" (BS8.split '"' t)

    run conn sql = do
      mres <- PQ.exec conn sql
      case mres of
        Nothing  -> failWith conn
        Just res -> do
          rst <- PQ.resultStatus res
          unless (rst `elem` [PQ.CommandOk, PQ.TuplesOk]) $ do
            mmsg <- PQ.resultErrorMessage res
            let msg = case mmsg of
                  Just m | not (BS.null m) -> m
                  _                        -> "LISTEN failed"
            throwIO (DbException (QueryError msg))
    drain conn =
      PQ.notifies conn >>= \case
        Nothing -> pure ()
        Just n -> do
          let chan    = PQ.notifyRelname n
              t       = fromMaybe chan (BS.stripPrefix "manifest_" chan)
              payload = PQ.notifyExtra n
          onChange (Change t (if BS.null payload then Nothing else Just payload))
          drain conn

failWith :: PQ.Connection -> IO a
failWith conn = do
  mmsg <- PQ.errorMessage conn
  let msg = case mmsg of
        Just m | not (BS.null m) -> m
        _                        -> "connection lost"
  throwIO (DbException (QueryError msg))
