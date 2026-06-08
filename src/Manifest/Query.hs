{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Manifest.Query
  ( QueryM
  , Handle
  , Expr
  , from
  , innerJoin
  , (^.)
  , val
  , (.==), (./=), (.>), (.<), (.&&)
  , where_
  , orderBy, asc, desc, limit, offset, OrderTerm
  , Selectable (Result)
  , renderQueryM
  , runQuery
  ) where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.State.Strict (State, get, modify', put, runState)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Manifest.Core.Codec (RowDecoder, SqlParam, ToField (..), decodeRow)
import Manifest.Core.Meta (ColumnMeta (..), TableMeta (..))
import Manifest.Core.Query (Column (..))
import Manifest.Core.Sql (bcIntercalate)
import Manifest.Entity (Entity (..))
import Manifest.Error (DbError (..), DbException (..))
import Manifest.Session (Db, execDb)

newtype QueryM a = QueryM (State QueryState a)
  deriving (Functor, Applicative, Monad)

data QueryState = QueryState
  { qsAlias  :: Int
  , qsFrom   :: ByteString
  , qsFromP  :: [SqlParam]
  , qsWhere  :: [ByteString]
  , qsWhereP :: [SqlParam]
  , qsOrder  :: [ByteString]
  , qsGroup  :: [ByteString]
  , qsLimit  :: Maybe Int
  , qsOffset :: Maybe Int
  }

emptyState :: QueryState
emptyState = QueryState 0 "" [] [] [] [] [] Nothing Nothing

newtype Handle e = Handle ByteString
data    Expr t   = Expr ByteString [SqlParam]

-- | Project a column from a handle. The handle's entity @e@ unifies with the
-- (otherwise table-polymorphic) label column @Column e t@, binding the label to
-- the entity; the result is qualified by the handle's alias.
(^.) :: Handle e -> Column e t -> Expr t
Handle al ^. Column c = Expr (al <> "." <> c) []
infixl 8 ^.

val :: ToField t => t -> Expr t
val x = Expr "?" [toField x]

binop :: ByteString -> Expr t -> Expr t -> Expr Bool
binop o (Expr a pa) (Expr b pb) = Expr (a <> " " <> o <> " " <> b) (pa ++ pb)

(.==), (./=), (.>), (.<) :: Expr t -> Expr t -> Expr Bool
(.==) = binop "="
(./=) = binop "<>"
(.>)  = binop ">"
(.<)  = binop "<"
infix 4 .==, ./=, .>, .<

(.&&) :: Expr Bool -> Expr Bool -> Expr Bool
Expr a pa .&& Expr b pb = Expr ("(" <> a <> " AND " <> b <> ")") (pa ++ pb)
infixr 3 .&&

from :: forall e. Entity e => QueryM (Handle e)
from = QueryM $ do
  st <- get
  let i  = qsAlias st
      al = "t" <> BC.pack (show i)
  put st { qsAlias = i + 1, qsFrom = tmTable (tableMeta @e) <> " AS " <> al }
  pure (Handle al)

-- | INNER JOIN table @e@. The function receives the new handle and returns the
-- ON condition; handles bound earlier in the do-block are captured by the closure.
innerJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (Handle e)
innerJoin onf = QueryM $ do
  st <- get
  let i  = qsAlias st
      al = "t" <> BC.pack (show i)
      h  = Handle al
      Expr onTxt onPs = onf h
  put st { qsAlias  = i + 1
         , qsFrom   = qsFrom st <> " INNER JOIN " <> tmTable (tableMeta @e)
                        <> " AS " <> al <> " ON " <> onTxt
         , qsFromP  = qsFromP st ++ onPs
         }
  pure h

where_ :: Expr Bool -> QueryM ()
where_ (Expr t ps) = QueryM $ modify' $ \st ->
  st { qsWhere = qsWhere st ++ [t], qsWhereP = qsWhereP st ++ ps }

newtype OrderTerm = OrderTerm ByteString

asc, desc :: Expr t -> OrderTerm
asc  (Expr t _) = OrderTerm (t <> " ASC")
desc (Expr t _) = OrderTerm (t <> " DESC")

orderBy :: [OrderTerm] -> QueryM ()
orderBy ts = QueryM $ modify' $ \st -> st { qsOrder = qsOrder st ++ [ x | OrderTerm x <- ts ] }

limit :: Int -> QueryM ()
limit n = QueryM $ modify' $ \st -> st { qsLimit = Just n }

offset :: Int -> QueryM ()
offset n = QueryM $ modify' $ \st -> st { qsOffset = Just n }

class Selectable s where
  type Result s
  selCols :: s -> ByteString
  selDec  :: s -> RowDecoder (Result s)

instance Entity e => Selectable (Handle e) where
  type Result (Handle e) = e
  selCols (Handle al) =
    bcIntercalate ", " [ al <> "." <> cmName c | c <- tmColumns (tableMeta @e) ]
  selDec _ = rowDecoder @e

instance (Selectable a, Selectable b) => Selectable (a, b) where
  type Result (a, b) = (Result a, Result b)
  selCols (a, b) = selCols a <> ", " <> selCols b
  selDec  (a, b) = (,) <$> selDec a <*> selDec b

runQueryM :: QueryM a -> (a, QueryState)
runQueryM (QueryM m) = runState m emptyState

numberPlaceholders :: ByteString -> ByteString
numberPlaceholders = go (1 :: Int)
  where
    go n bs = case BC.break (== '?') bs of
      (pre, rest) -> case BC.uncons rest of
        Nothing        -> pre
        Just (_, more) -> pre <> "$" <> BC.pack (show n) <> go (n + 1) more

renderQueryM :: Selectable s => QueryM s -> (ByteString, [SqlParam])
renderQueryM qm =
  let (sel, st) = runQueryM qm
      whereTxt = if null (qsWhere st) then "" else " WHERE " <> bcIntercalate " AND " (qsWhere st)
      groupTxt = if null (qsGroup st) then "" else " GROUP BY " <> bcIntercalate ", " (qsGroup st)
      orderTxt = if null (qsOrder st) then "" else " ORDER BY " <> bcIntercalate ", " (qsOrder st)
      limTxt = maybe "" (\n -> " LIMIT "  <> BC.pack (show n)) (qsLimit st)
      offTxt = maybe "" (\n -> " OFFSET " <> BC.pack (show n)) (qsOffset st)
      raw = "SELECT " <> selCols sel <> " FROM " <> qsFrom st
              <> whereTxt <> groupTxt <> orderTxt <> limTxt <> offTxt
  in (numberPlaceholders raw, qsFromP st ++ qsWhereP st)

decodeRowAs :: RowDecoder x -> [SqlParam] -> Db x
decodeRowAs dec row =
  either (liftIO . throwIO . DbException . DecodeFailure) pure (decodeRow dec row)

runQuery :: Selectable s => QueryM s -> Db [Result s]
runQuery qm = do
  let (sql, params) = renderQueryM qm
      (sel, _)      = runQueryM qm
  rows <- execDb sql params
  mapM (decodeRowAs (selDec sel)) rows
