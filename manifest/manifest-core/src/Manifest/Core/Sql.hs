module Manifest.Core.Sql
  ( bcIntercalate
  , renderConds
  , renderSelect
  , renderInsert
  , renderUpdate
  , renderDelete
  , renderJoined
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..))
import Manifest.Core.Query (Cond(..), Op(..))

bcIntercalate :: ByteString -> [ByteString] -> ByteString
bcIntercalate sep = BC.intercalate sep

placeholder :: Int -> ByteString
placeholder n = BC.pack ('$' : show n)

renderOp :: Op -> ByteString
renderOp OpEq  = "="
renderOp OpNeq = "<>"
renderOp OpGt  = ">"
renderOp OpLt  = "<"

-- | Render a WHERE clause (ANDed) starting at placeholder index @start@.
-- Returns the clause text (empty if no conditions) and the next free index.
renderConds :: Int -> [Cond a] -> (ByteString, Int)
renderConds start [] = ("", start)
renderConds start conds =
  let go i (Cond col op _) = (col <> " " <> renderOp op <> " " <> placeholder i, i + 1)
      step (acc, i) c = let (txt, i') = go i c in (acc ++ [txt], i')
      (clauses, next) = foldl step ([], start) conds
  in (" WHERE " <> bcIntercalate " AND " clauses, next)

-- | @SELECT c1, c2, ... FROM t [WHERE ...]@
renderSelect :: TableMeta a -> [Cond a] -> ByteString
renderSelect tm conds =
  let cols = bcIntercalate ", " (map cmName (tmColumns tm))
      (whereTxt, _) = renderConds 1 conds
  in "SELECT " <> cols <> " FROM " <> tmTable tm <> whereTxt

-- | @INSERT INTO t (cols) VALUES ($1, ...) RETURNING all_cols@
renderInsert :: TableMeta a -> [ColumnMeta] -> ByteString
renderInsert tm insCols =
  let names  = map cmName insCols
      vals   = [ placeholder i | i <- [1 .. length insCols] ]
      ret    = bcIntercalate ", " (map cmName (tmColumns tm))
  in "INSERT INTO " <> tmTable tm
       <> " (" <> bcIntercalate ", " names <> ")"
       <> " VALUES (" <> bcIntercalate ", " vals <> ")"
       <> " RETURNING " <> ret

-- | @UPDATE t SET c1 = $1, ..., <touched> = now() WHERE pk = $n@.
-- Touched columns (re-stamped on every update) are appended as literal
-- @= now()@ assignments read from the table meta. They consume no parameter,
-- so the PK placeholder stays at @length setCols + 1@; and they never appear in
-- @setCols@ (the Update projection omits them and the flush diff skips them).
renderUpdate :: TableMeta a -> [ByteString] -> ByteString -> ByteString
renderUpdate tm setCols pkCol =
  let sets    = [ c <> " = " <> placeholder i | (c, i) <- zip setCols [1 ..] ]
      touched = [ cmName c <> " = now()" | c <- tmColumns tm, cmTouchedOnUpdate c ]
      pkPh    = placeholder (length setCols + 1)
  in "UPDATE " <> tmTable tm
       <> " SET " <> bcIntercalate ", " (sets ++ touched)
       <> " WHERE " <> pkCol <> " = " <> pkPh

-- | @DELETE FROM t WHERE pk = $1@
renderDelete :: TableMeta a -> ByteString -> ByteString
renderDelete tm pkCol =
  "DELETE FROM " <> tmTable tm <> " WHERE " <> pkCol <> " = " <> placeholder 1

-- | A single LEFT JOIN that selects only the CHILD/target columns (qualified),
-- for loading one entity's relation. The owning row is pinned by its PK.
--
--   SELECT rel_t.<c1>, rel_t.<c2>, ...
--   FROM <self> AS self_t LEFT JOIN <child> AS rel_t
--   ON rel_t.<onChild> = self_t.<onSelf>
--   WHERE self_t.<selfPk> = $1
--
-- The two tables are aliased (@self_t@/@rel_t@) so a self-join
-- (@employees AS self_t LEFT JOIN employees AS rel_t@) is unambiguous.
renderJoined
  :: ByteString    -- ^ self (owning) table
  -> ByteString    -- ^ self PK column (the WHERE pin)
  -> ByteString    -- ^ child/target table
  -> [ByteString]  -- ^ child/target column names (in tableMeta order)
  -> ByteString    -- ^ join: child-side column
  -> ByteString    -- ^ join: self-side column
  -> ByteString
renderJoined selfT selfPk childT childCols onChild onSelf =
  "SELECT " <> bcIntercalate ", " ["rel_t." <> c | c <- childCols]
    <> " FROM " <> selfT <> " AS self_t"
    <> " LEFT JOIN " <> childT <> " AS rel_t"
    <> " ON rel_t." <> onChild <> " = self_t." <> onSelf
    <> " WHERE self_t." <> selfPk <> " = $1"
