module Manifest.Postgres
  ( Connection
  , Pool
  , newPool
  , closePool
  , withConnection
  , execText
  ) where

import Control.Concurrent.STM
import Control.Exception (bracket, throwIO)
import Control.Monad (forM, replicateM, unless)
import Data.ByteString (ByteString)
import qualified Database.PostgreSQL.LibPQ as PQ
import Manifest.Core.Codec (SqlParam)
import Manifest.Error (DbError(..), DbException(..))

-- | A borrowed libpq connection.
type Connection = PQ.Connection

-- | A fixed-size STM connection pool.
data Pool = Pool
  { poolAvail :: TVar [Connection]
  , poolAll   :: [Connection]
  }

-- | Open @size@ connections to @conninfo@ (a libpq conninfo/URI string).
newPool :: ByteString -> Int -> IO Pool
newPool conninfo size = do
  conns <- replicateM size $ do
    c <- PQ.connectdb conninfo
    st <- PQ.status c
    unless (st == PQ.ConnectionOk) $ do
      msg <- maybe (pure (mempty :: ByteString)) pure =<< PQ.errorMessage c
      throwIO (DbException (QueryError msg))
    pure c
  avail <- newTVarIO conns
  pure (Pool avail conns)

-- | Close every connection in the pool.
closePool :: Pool -> IO ()
closePool = mapM_ PQ.finish . poolAll

-- | Borrow a connection for the duration of the action, returning it after.
withConnection :: Pool -> (Connection -> IO a) -> IO a
withConnection pool = bracket acquire release
  where
    acquire = atomically $ do
      cs <- readTVar (poolAvail pool)
      case cs of
        []       -> retry
        (c:rest) -> writeTVar (poolAvail pool) rest >> pure c
    release c = atomically $ modifyTVar' (poolAvail pool) (c :)

-- | Execute a parameterised statement (text format) and return result rows as
-- vectors of nullable text values. Throws 'DbException' on error.
execText :: Connection -> ByteString -> [SqlParam] -> IO [[SqlParam]]
execText conn sql params = do
  let pqParams = [ fmap (\bs -> (PQ.Oid 0, bs, PQ.Text)) p | p <- params ]
  mres <- PQ.execParams conn sql pqParams PQ.Text
  case mres of
    Nothing  -> throwIO (DbException (QueryError (sql <> " — no result")))
    Just res -> do
      st <- PQ.resultStatus res
      if st `elem` [PQ.TuplesOk, PQ.CommandOk]
        then readRows res
        else do
          msg <- maybe (pure (mempty :: ByteString)) pure =<< PQ.resultErrorMessage res
          throwIO (DbException (QueryError msg))

readRows :: PQ.Result -> IO [[SqlParam]]
readRows res = do
  PQ.Row nrows <- PQ.ntuples res
  PQ.Col ncols <- PQ.nfields res
  forM [0 .. nrows - 1] $ \r ->
    forM [0 .. ncols - 1] $ \c ->
      PQ.getvalue res (PQ.toRow r) (PQ.toColumn c)
