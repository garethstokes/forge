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
  , withCte, fromCte, CteRef
  , innerJoin
  , leftJoin, OptHandle, Projectable
  , rightJoin, fullJoin, opt
  , (^.)
  , val
  , (.==), (./=), (.>), (.<), (.&&)
  , where_
  , having, distinct
  , orderBy, asc, desc, limit, offset, OrderTerm
  , groupBy, countRows, sum_, avg_, min_, max_
  , Selectable (Result)
  , renderQueryM
  , runQuery
  ) where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.State.Strict (State, get, modify', put, runState)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Manifest.Core.Codec (FromField, RowDecoder (..), SqlParam, ToField (..), decodeRow, field)
import Manifest.Core.Meta (ColumnMeta (..), TableMeta (..))
import Manifest.Core.Query (Column (..))
import Manifest.Core.Sql (bcIntercalate)
import Manifest.Entity (Entity (..), pkIndex)
import Manifest.Error (DecodeError (..), DbError (..), DbException (..))
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
  , qsWith   :: [ByteString]     -- rendered "cteN AS (subsql)" fragments
  , qsWithP  :: [SqlParam]       -- subquery params, in order (render before SELECT)
  , qsCte    :: Int              -- next CTE index
  , qsHaving   :: [ByteString]
  , qsHavingP  :: [SqlParam]
  , qsDistinct :: Bool
  }

emptyState :: QueryState
emptyState = QueryState 0 "" [] [] [] [] [] Nothing Nothing [] [] 0 [] [] False

newtype Handle e = Handle ByteString
data    Expr t   = Expr ByteString [SqlParam]

-- | A handle whose columns may be NULL, so it selects as @Maybe e@. Produced by
-- 'leftJoin' / 'fullJoin' (the unmatched side) or by 'opt' (a table a RIGHT or FULL
-- join can leave unmatched).
newtype OptHandle e = OptHandle ByteString

-- | Things you can project a column from (a 'Handle', or a left-joined 'OptHandle').
-- The handle's entity @e@ unifies with the (otherwise table-polymorphic) label
-- column @Column e t@, binding the label to the entity; the result is qualified
-- by the handle's alias.
class Projectable h where
  (^.) :: h e -> Column e t -> Expr t
infixl 8 ^.

instance Projectable Handle where
  Handle al ^. Column c = Expr (al <> "." <> c) []

instance Projectable OptHandle where
  OptHandle al ^. Column c = Expr (al <> "." <> c) []

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

-- | A reference to a registered CTE producing rows of entity @e@.
newtype CteRef e = CteRef ByteString

-- | Register a subquery (which selects a whole entity) as a non-recursive CTE,
-- returning a reference. Use 'fromCte' to read from it.
withCte :: forall e. Entity e => QueryM (Handle e) -> QueryM (CteRef e)
withCte sub = QueryM $ do
  st <- get
  let i              = qsCte st
      name           = "cte" <> BC.pack (show i)
      (subRaw, subP) = renderRaw sub
  put st { qsCte   = i + 1
         , qsWith  = qsWith st ++ [name <> " AS (" <> subRaw <> ")"]
         , qsWithP = qsWithP st ++ subP
         }
  pure (CteRef name)

-- | Read from a CTE as if it were a table. The CTE's columns are @e@'s columns
-- (the subquery selected a whole entity), so the returned 'Handle' projects them.
fromCte :: forall e. CteRef e -> QueryM (Handle e)
fromCte (CteRef name) = QueryM $ do
  st <- get
  let i  = qsAlias st
      al = "t" <> BC.pack (show i)
  put st { qsAlias = i + 1, qsFrom = name <> " AS " <> al }
  pure (Handle al)

-- | Shared join machinery: allocate an alias, append "<kw> <table> AS tN ON <on>"
-- to the FROM, collect ON params, return the new alias.
addJoin :: forall e. Entity e => ByteString -> (Handle e -> Expr Bool) -> QueryM ByteString
addJoin kw onf = QueryM $ do
  st <- get
  let i  = qsAlias st
      al = "t" <> BC.pack (show i)
      Expr onTxt onPs = onf (Handle al)
  put st { qsAlias  = i + 1
         , qsFrom   = qsFrom st <> " " <> kw <> " " <> tmTable (tableMeta @e)
                        <> " AS " <> al <> " ON " <> onTxt
         , qsFromP  = qsFromP st ++ onPs
         }
  pure al

-- | INNER JOIN table @e@. The function receives the new handle and returns the ON
-- condition; handles bound earlier in the do-block are captured by the closure.
innerJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (Handle e)
innerJoin onf = Handle <$> addJoin @e "INNER JOIN" onf

-- | LEFT JOIN table @e@: selects as @Maybe e@ (unmatched right rows decode 'Nothing').
leftJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (OptHandle e)
leftJoin onf = OptHandle <$> addJoin @e "LEFT JOIN" onf

-- | RIGHT JOIN table @e@: keeps all of @e@'s rows; previously-joined tables may be
-- NULL, so select them with 'opt'. The new table is required ('Handle').
rightJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (Handle e)
rightJoin onf = Handle <$> addJoin @e "RIGHT JOIN" onf

-- | FULL OUTER JOIN table @e@: keeps unmatched rows on both sides. The new table
-- selects as @Maybe e@ ('OptHandle'); select prior tables with 'opt'.
fullJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (OptHandle e)
fullJoin onf = OptHandle <$> addJoin @e "FULL JOIN" onf

-- | Re-tag a handle so it /selects/ as @Maybe e@ (NULL-aware, via 'optDecoder').
-- Use for a table that a RIGHT or FULL join may leave unmatched. Does not change the
-- FROM clause, only how the column set is decoded.
opt :: Handle e -> OptHandle e
opt (Handle al) = OptHandle al

where_ :: Expr Bool -> QueryM ()
where_ (Expr t ps) = QueryM $ modify' $ \st ->
  st { qsWhere = qsWhere st ++ [t], qsWhereP = qsWhereP st ++ ps }

-- | A HAVING predicate over a grouped query (typically over an aggregate, e.g.
-- @having (countRows .> val 1)@). Multiple calls are ANDed.
having :: Expr Bool -> QueryM ()
having (Expr t ps) = QueryM $ modify' $ \st ->
  st { qsHaving = qsHaving st ++ [t], qsHavingP = qsHavingP st ++ ps }

-- | Make the query a @SELECT DISTINCT@.
distinct :: QueryM ()
distinct = QueryM $ modify' $ \st -> st { qsDistinct = True }

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

groupBy :: Expr t -> QueryM ()
groupBy (Expr t _) = QueryM $ modify' $ \st -> st { qsGroup = qsGroup st ++ [t] }

countRows :: Expr Int
countRows = Expr "COUNT(*)" []

aggFn :: ByteString -> Expr t -> Expr (Maybe t)
aggFn fn (Expr t p) = Expr (fn <> "(" <> t <> ")") p

sum_, avg_, min_, max_ :: Expr t -> Expr (Maybe t)
sum_ = aggFn "SUM"
avg_ = aggFn "AVG"
min_ = aggFn "MIN"
max_ = aggFn "MAX"

class Selectable s where
  type Result s
  selCols :: s -> ByteString
  selDec  :: s -> RowDecoder (Result s)
  -- | Parameters carried by the selection itself (e.g. a 'val' inside a selected
  -- expression). The SELECT clause renders first, so these are numbered before the
  -- FROM/JOIN and WHERE params. Most selections are param-free (the default).
  selParams :: s -> [SqlParam]
  selParams _ = []

instance Entity e => Selectable (Handle e) where
  type Result (Handle e) = e
  selCols (Handle al) =
    bcIntercalate ", " [ al <> "." <> cmName c | c <- tmColumns (tableMeta @e) ]
  selDec _ = rowDecoder @e

-- | Decode @e@'s columns, but yield 'Nothing' when the LEFT JOIN had no match
-- (its primary-key column is NULL). Consumes @e@'s columns either way.
optDecoder :: forall e. Entity e => RowDecoder (Maybe e)
optDecoder = RowDecoder $ \cols ->
  let n             = length (tmColumns (tableMeta @e))
      (these, rest) = splitAt n cols
  in if length these < n
       then Left (DecodeError "optDecoder: ran out of columns")
       else if these !! pkIndex @e == Nothing
              then Right (Nothing, rest)
              else case decodeRow (rowDecoder @e) these of
                     Right v  -> Right (Just v, rest)
                     Left err -> Left err

instance Entity e => Selectable (OptHandle e) where
  type Result (OptHandle e) = Maybe e
  selCols (OptHandle al) =
    bcIntercalate ", " [ al <> "." <> cmName c | c <- tmColumns (tableMeta @e) ]
  selDec _ = optDecoder @e

instance FromField t => Selectable (Expr t) where
  type Result (Expr t) = t
  selCols (Expr t _) = t
  selDec  _ = field
  selParams (Expr _ p) = p

instance (Selectable a, Selectable b) => Selectable (a, b) where
  type Result (a, b) = (Result a, Result b)
  selCols (a, b) = selCols a <> ", " <> selCols b
  selDec  (a, b) = (,) <$> selDec a <*> selDec b
  selParams (a, b) = selParams a ++ selParams b

runQueryM :: QueryM a -> (a, QueryState)
runQueryM (QueryM m) = runState m emptyState

numberPlaceholders :: ByteString -> ByteString
numberPlaceholders = go (1 :: Int)
  where
    go n bs = case BC.break (== '?') bs of
      (pre, rest) -> case BC.uncons rest of
        Nothing        -> pre
        Just (_, more) -> pre <> "$" <> BC.pack (show n) <> go (n + 1) more

-- | Assemble SQL with '?' placeholders (un-numbered) and params in textual order.
renderRaw :: Selectable s => QueryM s -> (ByteString, [SqlParam])
renderRaw qm =
  let (sel, st) = runQueryM qm
      withTxt  = if null (qsWith st) then ""
                 else "WITH " <> bcIntercalate ", " (qsWith st) <> " "
      selKw    = if qsDistinct st then "SELECT DISTINCT " else "SELECT "
      whereTxt = if null (qsWhere st) then "" else " WHERE " <> bcIntercalate " AND " (qsWhere st)
      groupTxt = if null (qsGroup st) then "" else " GROUP BY " <> bcIntercalate ", " (qsGroup st)
      havingTxt = if null (qsHaving st) then "" else " HAVING " <> bcIntercalate " AND " (qsHaving st)
      orderTxt = if null (qsOrder st) then "" else " ORDER BY " <> bcIntercalate ", " (qsOrder st)
      limTxt   = maybe "" (\n -> " LIMIT "  <> BC.pack (show n)) (qsLimit st)
      offTxt   = maybe "" (\n -> " OFFSET " <> BC.pack (show n)) (qsOffset st)
      raw = withTxt <> selKw <> selCols sel <> " FROM " <> qsFrom st
              <> whereTxt <> groupTxt <> havingTxt <> orderTxt <> limTxt <> offTxt
      params = qsWithP st ++ selParams sel ++ qsFromP st ++ qsWhereP st ++ qsHavingP st
  in (raw, params)

renderQueryM :: Selectable s => QueryM s -> (ByteString, [SqlParam])
renderQueryM qm = let (raw, ps) = renderRaw qm in (numberPlaceholders raw, ps)

decodeRowAs :: RowDecoder x -> [SqlParam] -> Db x
decodeRowAs dec row =
  either (liftIO . throwIO . DbException . DecodeFailure) pure (decodeRow dec row)

runQuery :: Selectable s => QueryM s -> Db [Result s]
runQuery qm = do
  let (sql, params) = renderQueryM qm
      (sel, _)      = runQueryM qm
  rows <- execDb sql params
  mapM (decodeRowAs (selDec sel)) rows
