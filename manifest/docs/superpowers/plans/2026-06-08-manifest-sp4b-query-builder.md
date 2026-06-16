# Manifest SP4b — Table-handle query builder (esqueleto-style) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Note on history:** an earlier draft of this plan used a bare-`#label` combinator pipeline. Execution found that `#label` columns are entity-agnostic (`#userName :: Column a t`, any `a`), so a bare-label builder cannot infer which table a column belongs to and needs `@Table` annotations everywhere. The user chose the **table-handle (esqueleto-style)** design instead, captured here. **Task 1 replaces** the superseded `Manifest.Query`/`test/QueryBuilderSpec.hs` from commits on this branch.

**Goal:** A typed query builder where `from @User` binds a handle `u`, `u ^. #userName` is an entity- and alias-bound column expression, and you compose `where_` / `orderBy` / `limit` / `offset` / `innerJoin` / `groupBy` / aggregates inside a `QueryM` do-block, returning the selection and running it with `runQuery`.

**Architecture:** One new module `Manifest.Query`. A `QueryM` is a `State QueryState` builder. `from @e`/`innerJoin @e` allocate an alias (`t0`,`t1`,…), record the FROM/JOIN SQL, and return a `Handle e` (carrying the alias). `(^.) :: Handle e -> Column e t -> Expr t` qualifies the column by the handle's alias and unifies the entity-agnostic label's phantom with `e` (this is what gives entity-bound columns). `Expr t` is a rendered fragment + params (`?` placeholders, numbered at assembly). Comparison operators on `Expr` build `Expr Bool` for `where_`/join `ON`. The do-block's returned value (a `Handle`, an `Expr`, or a tuple of them) is the **selection**; a `Selectable` class turns it into the SELECT-list text and a composed `RowDecoder`. `runQuery` assembles the SQL, runs it via the session's `execDb`, and decodes.

**Tech Stack:** GHC 9.10.1 via zinc. `Control.Monad.Trans.State.Strict` (from `transformers`, already a lib dep). Existing `Manifest.Core.Query` (`Column a t = Column { colName }`), `Manifest.Core.Codec` (applicative `RowDecoder`, `field`, `FromField`, `ToField`, `SqlParam`), `Manifest.Core.Meta` (`tableMeta`/`tmTable`/`tmColumns`/`cmName`), `Manifest.Entity` (`Entity`, `rowDecoder`), `Manifest.Session` (`Db`, `execDb`), `Manifest.Error` (`DbException`/`DbError(DecodeFailure)`). Custom `test/Harness.hs`; `Fixtures` (`User`, `Post`, ephemeral Postgres).

**Operator-name note:** the existing command path already exports `(==.)`/`(>.)`/… as `Column a t -> t -> Cond a` (used by `deleteWhere`/`selectWhere`). To avoid a clash, the builder's expression comparisons use the leading-dot family `(.==)` `(./=)` `(.>)` `(.<)` (and `(.&&)`), with `val` lifting a literal into an `Expr`. So: `u ^. #userName .== val "Bob"`.

**Scope (MVP):** `from`, `innerJoin` (INNER only), `(^.)`, `val`, `(.==)`/`(./=)`/`(.>)`/`(.<)`/`(.&&)`, `where_`, `orderBy`/`asc`/`desc`, `limit`/`offset`, `groupBy`, aggregates `countRows`/`sum_`/`avg_`/`min_`/`max_`, `Selectable` for `Handle e`, `Expr t`, and 2-tuples, `runQuery`, and the pure `renderQueryM`. **Deferred (document as Planned):** outer joins, `HAVING`, `DISTINCT`, subqueries/CTEs, multiple `from`/cross joins, >2-table selection tuples beyond left-nesting, and session-management of results (builder results are plain decoded values, not identity-map entries; use `get`/`selectWhere` for managed rows).

---

## Design reference (Task 1 establishes all of this)

```haskell
-- Builder monad over a strict State.
newtype QueryM a = QueryM (State QueryState a)
  deriving (Functor, Applicative, Monad)

data QueryState = QueryState
  { qsAlias  :: Int            -- next alias index
  , qsFrom   :: ByteString     -- "users AS t0 INNER JOIN posts AS t1 ON …"
  , qsFromP  :: [SqlParam]     -- params from JOIN ON clauses, in order
  , qsWhere  :: [ByteString]   -- WHERE conjuncts (each Expr Bool text, with ? placeholders)
  , qsWhereP :: [SqlParam]     -- params from WHERE, in order
  , qsOrder  :: [ByteString]   -- "t0.user_name ASC"
  , qsGroup  :: [ByteString]   -- "t0.post_author"
  , qsLimit  :: Maybe Int
  , qsOffset :: Maybe Int
  }

newtype Handle e = Handle ByteString          -- the alias; e is the entity
data    Expr t   = Expr ByteString [SqlParam] -- rendered text (with ?) + params

-- column projection: pins the entity-agnostic label to the handle's entity AND alias
(^.) :: Handle e -> Column e t -> Expr t
val  :: ToField t => t -> Expr t

(.==), (./=), (.>), (.<) :: Expr t -> Expr t -> Expr Bool
(.&&)                    :: Expr Bool -> Expr Bool -> Expr Bool

from      :: forall e. Entity e => QueryM (Handle e)
innerJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (Handle e)
where_    :: Expr Bool -> QueryM ()
orderBy   :: [OrderTerm] -> QueryM ()
asc, desc :: Expr t -> OrderTerm
limit, offset :: Int -> QueryM ()
groupBy   :: Expr t -> QueryM ()

countRows :: Expr Int
sum_, avg_, min_, max_ :: Expr t -> Expr (Maybe t)

class Selectable s where
  type Result s
  selCols :: s -> ByteString
  selDec  :: s -> RowDecoder (Result s)
-- instances: Handle e (Entity e), Expr t (FromField t), (a,b) (Selectable a, Selectable b)

renderQueryM :: Selectable s => QueryM s -> (ByteString, [SqlParam])  -- pure; for tests
runQuery     :: Selectable s => QueryM s -> Db [Result s]
```

Invariants: aliases `t0`,`t1`,… by allocation order; `(^.)` qualifies as `alias.colName`; params assemble as `qsFromP ++ qsWhereP` (matching SQL order: JOIN ONs before WHERE); `?` placeholders are renumbered to `$1..$n` at the very end; the selection's `selCols`/`selDec` order agree (decoder consumes columns left-to-right).

Example end state:

```haskell
-- single table
us <- runQuery $ do
  u <- from @User
  where_ (u ^. #userName .== val "Bob")
  orderBy [asc (u ^. #userName)]
  pure u                                   -- :: Db [User]

-- inner join → tuples
pairs <- runQuery $ do
  u <- from @User
  p <- innerJoin @Post (\p -> u ^. #userId .== p ^. #postAuthor)
  pure (u, p)                              -- :: Db [(User, Post)]

-- group + aggregate
perAuthor <- runQuery $ do
  p <- from @Post
  groupBy (p ^. #postAuthor)
  pure (p ^. #postAuthor, countRows)       -- :: Db [(Int, Int)]
```

---

### Task 1: Builder core — `QueryM`, `Handle`, `Expr`, `from`, `(^.)`, `val`, comparisons, `where_`, `Selectable (Handle e)`, `runQuery`

**Files:**
- Replace: `src/Manifest/Query.hs` (overwrite the superseded version)
- Replace: `test/QueryBuilderSpec.hs` (overwrite)
- Keep: `test/Spec.hs` already imports/appends `QueryBuilderSpec` (from the earlier task) — leave that wiring.

- [ ] **Step 1: Write the failing test (overwrite `test/QueryBuilderSpec.hs`)**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module QueryBuilderSpec (tests) where

import Data.List (sort)
import Fixtures (Post, PostT (..), User, UserT (..), withTestDb)
import Manifest
import Manifest.Query
import Harness

tests :: [Test]
tests = group "QueryBuilder"
  [ test "single-table select renders SELECT alias.cols FROM table AS t0" $
      assertEqual "sql"
        "SELECT t0.user_id, t0.user_name, t0.user_email FROM users AS t0"
        (fst (renderQueryM (do u <- from @User; pure u)))
  , test "where_ renders an alias-qualified, numbered condition" $
      assertEqual "sql"
        "SELECT t0.user_id, t0.user_name, t0.user_email FROM users AS t0 WHERE t0.user_name = $1"
        (fst (renderQueryM (do u <- from @User
                               where_ (u ^. #userName .== val ("Bob" :: String))
                               pure u)))
  , test "runQuery returns all rows" $
      withTestDb $ \pool -> do
        names <- withSession pool $ do
          _ <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (User { userId = 0, userName = "Bob", userEmail = Nothing } :: User)
          us <- runQuery (do u <- from @User; pure u)
          pure (sort (map userName us))
        assertEqual "names" ["Ada", "Bob"] names
  , test "where_ filters rows at runtime" $
      withTestDb $ \pool -> do
        names <- withSession pool $ do
          _ <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (User { userId = 0, userName = "Bob", userEmail = Nothing } :: User)
          us <- runQuery (do u <- from @User
                             where_ (u ^. #userName .== val ("Bob" :: String))
                             pure u)
          pure (map userName us)
        assertEqual "names" ["Bob"] names
  ]
```

(`Post`/`PostT` import is for later tasks; harmless now — the test target has no `-Wall`.)

- [ ] **Step 2: Run to verify it fails**

`nix develop -c zinc test 2>&1 | tail -20` — expect missing `from`/`(^.)`/`val`/`(.==)`/`where_`/`renderQueryM`/`runQuery`.

- [ ] **Step 3: Implement `src/Manifest/Query.hs` (overwrite)**

```haskell
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
  , (^.)
  , val
  , (.==), (./=), (.>), (.<), (.&&)
  , where_
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
-- (otherwise polymorphic) label column @Column e t@, binding the label to the
-- entity, and the result is qualified by the handle's alias.
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

-- | Start the query over one table, returning its handle.
from :: forall e. Entity e => QueryM (Handle e)
from = QueryM $ do
  st <- get
  let i  = qsAlias st
      al = "t" <> BC.pack (show i)
  put st { qsAlias = i + 1, qsFrom = tmTable (tableMeta @e) <> " AS " <> al }
  pure (Handle al)

where_ :: Expr Bool -> QueryM ()
where_ (Expr t ps) = QueryM $ modify' $ \st ->
  st { qsWhere = qsWhere st ++ [t], qsWhereP = qsWhereP st ++ ps }

-- | What a do-block may return as its selection.
class Selectable s where
  type Result s
  selCols :: s -> ByteString
  selDec  :: s -> RowDecoder (Result s)

instance Entity e => Selectable (Handle e) where
  type Result (Handle e) = e
  selCols (Handle al) =
    bcIntercalate ", " [ al <> "." <> cmName c | c <- tmColumns (tableMeta @e) ]
  selDec _ = rowDecoder @e

runQueryM :: QueryM a -> (a, QueryState)
runQueryM (QueryM m) = runState m emptyState

-- | Replace each '?' with $1,$2,… left to right.
numberPlaceholders :: ByteString -> ByteString
numberPlaceholders = go (1 :: Int)
  where
    go n bs = case BC.break (== '?') bs of
      (pre, rest) -> case BC.uncons rest of
        Nothing       -> pre
        Just (_, more) -> pre <> "$" <> BC.pack (show n) <> go (n + 1) more

-- | Pure assembly of (SQL, params). Used by runQuery and tests.
renderQueryM :: Selectable s => QueryM s -> (ByteString, [SqlParam])
renderQueryM qm =
  let (sel, st) = runQueryM qm
      whereTxt = if null (qsWhere st) then ""
                 else " WHERE " <> bcIntercalate " AND " (qsWhere st)
      groupTxt = if null (qsGroup st) then ""
                 else " GROUP BY " <> bcIntercalate ", " (qsGroup st)
      orderTxt = if null (qsOrder st) then ""
                 else " ORDER BY " <> bcIntercalate ", " (qsOrder st)
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
```

> **Implementer notes:**
> - Confirm the decode-throw against `src/Manifest/Error.hs` + `Manifest.Session.decodeRowDb` (~line 109): the form is `DbException (DecodeFailure err)` where `DecodeFailure :: DecodeError -> DbError`. Adjust `decodeRowAs` if names differ; `Db` derives `MonadIO`.
> - `Column (..)` is exported from `Manifest.Core.Query` (`Column { colName }`); the pattern `Column c` binds the column name. The crucial line is `(^.)`: its type `Handle e -> Column e t -> Expr t` makes the label's polymorphic phantom unify with `e`, so `u ^. #userName` forces `#userName :: Column User Text`. This is the whole point — keep that signature exact.
> - `runQueryM` is called twice in `runQuery` (cheap, pure). If `-Wall` complains about anything, fix it; do not remove `numberPlaceholders`/`decodeRowAs` (later tasks reuse them).

- [ ] **Step 4: Run to verify it passes**

`nix develop -c zinc test 2>&1 | tail -8` then `nix develop -c .zinc/build/spec 2>&1 | tail -2`.
Expected: the four `QueryBuilder` tests pass. The earlier branch baseline was 89/89 with the *old* QueryBuilderSpec (4 tests); this overwrites those 4 with 4 new ones, so the total stays **89/89**. (If the previous spec had a different count, the new total is `baseline-before-QueryBuilderSpec + 4`.)

- [ ] **Step 5: -Wall check**

`nix develop -c zinc build 2>&1 | grep -iE "warning|Query.hs" | tail -20` — no warnings referencing `Manifest/Query.hs`.

- [ ] **Step 6: Commit**

```bash
git add src/Manifest/Query.hs test/QueryBuilderSpec.hs
git commit -m "feat(query): table-handle builder core — from/^./val/where_/runQuery"
```

---

### Task 2: `orderBy` / `asc` / `desc`, `limit`, `offset`

**Files:** Modify `src/Manifest/Query.hs`, `test/QueryBuilderSpec.hs`.

- [ ] **Step 1: Failing test** — append:

```haskell
  , test "orderBy + limit + offset render in order" $
      assertEqual "sql"
        "SELECT t0.user_id, t0.user_name, t0.user_email FROM users AS t0 ORDER BY t0.user_name DESC LIMIT 2 OFFSET 1"
        (fst (renderQueryM (do u <- from @User
                               orderBy [desc (u ^. #userName)]
                               limit 2; offset 1
                               pure u)))
  , test "orderBy + limit return rows in order, paginated" $
      withTestDb $ \pool -> do
        names <- withSession pool $ do
          mapM_ (\n -> add (User { userId = 0, userName = n, userEmail = Nothing } :: User))
                ["Ada","Bob","Cay","Dee"]
          runQuery (do u <- from @User; orderBy [asc (u ^. #userName)]; limit 2; pure u)
            >>= pure . map userName
        assertEqual "first two" ["Ada","Bob"] names
```

- [ ] **Step 2: Run — fails** (`orderBy`/`asc`/`desc`/`limit`/`offset`/`OrderTerm` missing).

- [ ] **Step 3: Implement.** Add to exports `, orderBy, asc, desc, limit, offset, OrderTerm`. Add:

```haskell
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
```

- [ ] **Step 4: Run — green** (total +2).
- [ ] **Step 5: Commit** `feat(query): orderBy/asc/desc, limit, offset`.

---

### Task 3: `innerJoin` and tuple selections

**Files:** Modify `src/Manifest/Query.hs`, `test/QueryBuilderSpec.hs`.

- [ ] **Step 1: Failing test** — append:

```haskell
  , test "innerJoin renders an aliased INNER JOIN selecting both tables" $
      assertEqual "sql"
        ( "SELECT t0.user_id, t0.user_name, t0.user_email, t1.post_id, t1.post_author, t1.post_title"
       <> " FROM users AS t0 INNER JOIN posts AS t1 ON t0.user_id = t1.post_author" )
        (fst (renderQueryM (do u <- from @User
                               p <- innerJoin @Post (\p -> u ^. #userId .== p ^. #postAuthor)
                               pure (u, p))))
  , test "innerJoin returns (User, Post) pairs" $
      withTestDb $ \pool -> do
        pairs <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          rows <- runQuery (do usr <- from @User
                               pst <- innerJoin @Post (\pst -> usr ^. #userId .== pst ^. #postAuthor)
                               pure (usr, pst))
          pure [ (userName a, postTitle b) | (a, b) <- rows ]
        assertEqual "pairs" [("Ada","P1"),("Ada","P2")] pairs
```

- [ ] **Step 2: Run — fails** (`innerJoin` missing; no `Selectable (a,b)`).

- [ ] **Step 3: Implement.** Add to exports `, innerJoin`. Add:

```haskell
-- | INNER JOIN table @e@; the function receives the new handle and returns the
-- ON condition (existing handles are captured from the enclosing do-block).
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
```

And the tuple `Selectable` instance (next to the others):

```haskell
instance (Selectable a, Selectable b) => Selectable (a, b) where
  type Result (a, b) = (Result a, Result b)
  selCols (a, b) = selCols a <> ", " <> selCols b
  selDec  (a, b) = (,) <$> selDec a <*> selDec b
```

> The decoder `(,) <$> selDec a <*> selDec b` consumes `a`'s columns then `b`'s, matching the SELECT-list order `selCols a <> ", " <> selCols b`. The join `ON` is `u ^. #userId .== p ^. #postAuthor` → `t0.user_id = t1.post_author` (handle aliases). ON params (rare) are tracked in `qsFromP`, which assembles before `qsWhereP`.

- [ ] **Step 4: Run — green** (total +2). If pair order differs, note Postgres returns join rows in insert order here; the assertion expects `[("Ada","P1"),("Ada","P2")]`.
- [ ] **Step 5: Commit** `feat(query): innerJoin + tuple selections`.

---

### Task 4: `groupBy` and aggregates

**Files:** Modify `src/Manifest/Query.hs`, `test/QueryBuilderSpec.hs`.

- [ ] **Step 1: Failing test** — append:

```haskell
  , test "groupBy + countRows counts children per key" $
      withTestDb $ \pool -> do
        grouped <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          runQuery (do p <- from @Post
                       groupBy (p ^. #postAuthor)
                       pure (p ^. #postAuthor, countRows))
        assertEqual "posts per author" [(1 :: Int, 2 :: Int)] grouped
  , test "sum_ aggregates a column" $
      withTestDb $ \pool -> do
        total <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          runQuery (do p <- from @Post; pure (sum_ (p ^. #postAuthor)))
        assertEqual "sum of author ids" [Just (2 :: Int)] total
```

(One inserted user has serial PK `1`; both posts have `post_author = 1`, so `COUNT=2`, `SUM=2`.)

- [ ] **Step 2: Run — fails** (`groupBy`/`countRows`/`sum_` missing; no `Selectable (Expr t)`).

- [ ] **Step 3: Implement.** Add to exports `, groupBy, countRows, sum_, avg_, min_, max_`. Import `FromField`, `field` from `Manifest.Core.Codec`. Add:

```haskell
groupBy :: Expr t -> QueryM ()
groupBy (Expr t _) = QueryM $ modify' $ \st -> st { qsGroup = qsGroup st ++ [t] }

countRows :: Expr Int
countRows = Expr "COUNT(*)" []

aggFn :: ByteString -> Expr t -> Expr (Maybe t)
aggFn fn (Expr t p) = Expr (fn <> "(" <> t <> ")") p

sum_, avg_, min_, max_ :: Expr t -> Expr (Maybe t)
sum_ = aggFn "SUM"; avg_ = aggFn "AVG"; min_ = aggFn "MIN"; max_ = aggFn "MAX"

instance FromField t => Selectable (Expr t) where
  type Result (Expr t) = t
  selCols (Expr t _) = t
  selDec  _ = field
```

> `pure (p ^. #postAuthor, countRows)` selects `t0.post_author, COUNT(*)` and decodes `(Int, Int)` via the `(a,b)` + `Expr` instances. `sum_ … :: Expr (Maybe Int)` decodes `Maybe Int` (NULL on empty set) via the existing `FromField (Maybe a)`. Aggregate exprs carry no `?` params, so placeholder numbering is unaffected.

- [ ] **Step 4: Run — green** (total +2). If `sum_` decodes wrong, check that Postgres returns `SUM(bigint)` as a plain integer literal that `FromField Int` reads.
- [ ] **Step 5: Commit** `feat(query): groupBy + aggregates (countRows/sum_/avg_/min_/max_)`.

---

### Task 5: Umbrella export, manual page, honest status updates

**Files:** Modify `src/Manifest.hs`, create `docs/queries.md`, modify `docs/index.md`, `docs/entities.md`, `docs/tutorials/index.md`.

- [ ] **Step 1: Re-export from the umbrella.** In `src/Manifest.hs`, add a section + import:

Export list:
```haskell
    -- * Query builder (table-handle)
  , QueryM
  , Handle
  , Expr
  , from
  , innerJoin
  , (^.)
  , val
  , (.==), (./=), (.>), (.<), (.&&)
  , where_
  , orderBy
  , asc
  , desc
  , limit
  , offset
  , groupBy
  , countRows
  , sum_
  , avg_
  , min_
  , max_
  , OrderTerm
  , Selectable (Result)
  , runQuery
```
Import:
```haskell
import Manifest.Query
  ( QueryM, Handle, Expr, from, innerJoin, (^.), val
  , (.==), (./=), (.>), (.<), (.&&), where_, orderBy, asc, desc
  , limit, offset, groupBy, countRows, sum_, avg_, min_, max_
  , OrderTerm, Selectable (Result), runQuery )
```
Build: `nix develop -c zinc build 2>&1 | tail -5` (no warnings, no clash with the command-path `==.`).

- [ ] **Step 2: Write `docs/queries.md`** (manual voice: no em-dashes, no SQLAlchemy, no positioning claims; `nav_order: 8`):

````markdown
---
title: Queries
nav_order: 8
---

# Queries

The query builder assembles a typed query in a do-block and runs it with
`runQuery`. `from @User` binds a handle, `u ^. #userName` is a column bound to that
table and its alias, and combinators add conditions, ordering, joins, grouping, and
aggregates. The do-block returns the selection (a handle, an expression, or a tuple),
which determines the result type.

## Single table

```haskell
us <- runQuery $ do
  u <- from @User
  where_ (u ^. #userName .== val "Bob")
  orderBy [asc (u ^. #userName)]
  limit 20
  pure u                       -- :: Db [User]
```

`u ^. #userName` qualifies the column by the handle's alias and binds the label to
`User`, so a column from a table you have not brought into the query is a type
error. Expression comparisons are `.==`, `./=`, `.>`, `.<`, combined with `.&&`;
`val` lifts a literal. (`runQuery` results are plain values, not identity-map
entries; use `get` / `selectWhere` for managed rows.)

## Inner joins

`innerJoin @Post` takes a function from the new handle to the join condition;
handles from earlier in the block are in scope:

```haskell
pairs <- runQuery $ do
  u <- from @User
  p <- innerJoin @Post (\p -> u ^. #userId .== p ^. #postAuthor)
  pure (u, p)                  -- :: Db [(User, Post)]
```

## Aggregates and grouping

`countRows`, `sum_`, `avg_`, `min_`, `max_` are expressions you return in the
selection; `groupBy` sets the key:

```haskell
perAuthor <- runQuery $ do
  p <- from @Post
  groupBy (p ^. #postAuthor)
  pure (p ^. #postAuthor, countRows)   -- :: Db [(Int, Int)]

total <- runQuery $ do
  p <- from @Post
  pure (sum_ (p ^. #postAuthor))       -- :: Db [Maybe Int]
```

## Status

Built and tested: `from`, `where_`, `orderBy`/`asc`/`desc`, `limit`/`offset`,
`innerJoin`, `groupBy`, `countRows`/`sum_`/`avg_`/`min_`/`max_`, tuple selections,
and `runQuery`. Columns are entity- and alias-bound through handles.

Planned, not built:

* **Outer joins, `HAVING`, `DISTINCT`, subqueries, and CTEs.** Only `INNER JOIN`
  and the aggregates above are built.
* **Multiple `from` / cross joins**, and selection tuples wider than pairs beyond
  left-nesting.
* **Session-managed results.** Builder results are plain decoded values; `get` and
  `selectWhere` return managed rows.
````

- [ ] **Step 3: Update `index.md` Status + Pages list.** Replace the single "Joins and aggregates … Planned" bullet so the builder is listed as built, keeping the relationship-`joined` distinction:

```markdown
## Status

The Unit of Work, relationships, cascades, migrations, the Template Haskell entity
front-end, and the query builder (joins, ordering, pagination, and aggregates) are
built and tested. See the reference pages, and [Queries](queries.md) for the builder.

The `mkEntity` macro generates the record, `deriving Generic`, and the `Entity`
instance from one block (see [Entities](entities.md)). It builds the core entity;
relationships and cascades are declared separately. Hand-writing the record and
instance is fully supported and is what the snippets above show.

The site is published by GitHub Pages' built-in Jekyll build of `docs/`; there is
no Actions workflow. The tutorials run as tests and require a Postgres (the suite
spins up an ephemeral one); a local Jekyll build is out of scope.
```

Add to the Pages list (after the Cascades/Migrations line):
```markdown
- [Queries](queries.md): the query builder, ordering, pagination, inner joins, and
  aggregates.
```

- [ ] **Step 4: Update `entities.md`'s query-DSL blockquote** (under `#label` column references) to reflect the builder is built:

```markdown
> The query builder (joins, ordering, pagination, aggregates) is built; see
> [Queries](queries.md). It binds columns to a table through handles
> (`u ^. #userName`). Still Planned: outer joins, `HAVING`, subqueries, and CTEs.
> Relationship loading uses a `LEFT JOIN` internally (the `joined` strategy); that is
> a separate path.
```

- [ ] **Step 5: Bump Tutorials nav_order** in `docs/tutorials/index.md` from `nav_order: 8` to `nav_order: 9`.

- [ ] **Step 6: Full suite + honesty grep.** `nix develop -c .zinc/build/spec 2>&1 | tail -2` (all green). `grep -rniE "sqlalchemy|—|no template haskell" docs/queries.md docs/index.md docs/entities.md` → none.

- [ ] **Step 7: Commit** `feat(query): export builder; Queries manual page; status updates`.

---

## Self-Review

**1. Spec coverage** (chosen "table-handle (esqueleto-style)" builder):
- `from`/handles → Task 1. `(^.)` entity+alias binding → Task 1 (the signature pins the label). `val` + `.==`/`./=`/`.>`/`.<`/`.&&` + `where_` → Task 1. `orderBy`/`asc`/`desc`/`limit`/`offset` → Task 2. `innerJoin` + tuple `Selectable` → Task 3. `groupBy` + aggregates + `Selectable (Expr)` → Task 4. `runQuery`/`renderQueryM` → Task 1. Umbrella + docs → Task 5. ✓
- Entity-agnostic-label problem solved: `(^.) :: Handle e -> Column e t -> Expr t` unifies the label phantom with the handle's entity, so columns are entity-bound without annotations. ✓
- Deferred items documented as Planned in `queries.md`. ✓

**2. Placeholder scan:** every task has complete code or exact commands. The two environment-specific spots (decode-throw form, `SUM`/`COUNT` text decoding as `Int`) are flagged with the exact source to copy from.

**3. Type consistency:**
- `QueryM` (monad), `Handle e`, `Expr t`, `Selectable (Result)` — introduced once (Task 1), reused throughout. `from :: QueryM (Handle e)`, `innerJoin :: (Handle e -> Expr Bool) -> QueryM (Handle e)`, `runQuery :: Selectable s => QueryM s -> Db [Result s]`. ✓
- `(^.) :: Handle e -> Column e t -> Expr t` and `Column (..)`/`Column c` match `Manifest.Core.Query`. The builder ops `.==`/etc. are `Expr t -> Expr t -> Expr Bool`, distinct from the command-path `==.` (no clash at the umbrella). ✓
- `Selectable` instances for `Handle e` (Task 1), `(a,b)` (Task 3), `Expr t` (Task 4) compose; `selCols`/`selDec` order agree, and `RowDecoder` is applicative so `(,) <$> … <*> …` decodes left-to-right matching the SELECT order. ✓
- `decodeRowAs`, `numberPlaceholders`, `runQueryM` defined once (Task 1), reused. ✓

**Open risks (resolved under TDD):** the decode-throw plumbing (copy `decodeRowDb`); `numberPlaceholders` correctness (covered by the Task 1/2 pure SQL-shape tests that assert exact `$1`/`$2`… output); aggregate `Maybe n` decoding (existing `FromField (Maybe a)`).
