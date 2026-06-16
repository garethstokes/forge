# Manifest SP4c — Query builder: outer joins + CTEs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the table-handle query builder (`Manifest.Query`) with **LEFT (outer) joins** — `leftJoin @Post (...)` whose right side selects as `Maybe Post` (NULL when there is no match) — and **non-recursive CTEs** — `withCte` registers a `WITH name AS (subquery)` you then `fromCte`.

**Architecture:** Both build on the existing handle-based builder. (1) LEFT JOIN: a new `OptHandle e` (returned by `leftJoin`) whose `Selectable` instance decodes the right entity NULL-aware — if its primary-key column is NULL, the row had no match and yields `Nothing`. Column projection `(^.)` is generalised from a plain function into a small `Projectable` class so both `Handle` and `OptHandle` can be projected (the `leftJoin` ON closure still gets a plain `Handle e`). (2) CTEs: the query state gains a `WITH` accumulator; `withCte` renders the subquery (keeping `?` placeholders, NOT pre-numbered) into `cteN AS (…)` and returns a `CteRef e`; `fromCte` uses that as the FROM table, returning a `Handle e` (its columns are the entity's, since the subquery selected a whole entity). To keep placeholders correct across the WITH/SELECT boundary, `renderQueryM` is split into `renderRaw` (assembles `?`-SQL + params in textual order) and a final single `numberPlaceholders` pass.

**Tech Stack:** GHC 9.10.1 via zinc. Existing `Manifest.Query` (read it first: `src/Manifest/Query.hs`). New imports needed: `RowDecoder(..)` (the constructor, for the NULL-aware decoder — currently imported without it), `DecodeError(..)` from `Manifest.Error`, and `pkIndex` from `Manifest.Entity`. Custom `test/Harness.hs`; `Fixtures` (`User`, `Post`; `Post.postAuthor` is the FK to `User.userId`).

**Scope (MVP):** `leftJoin` (LEFT OUTER), `OptHandle`, NULL-aware `Maybe`-decode, `Projectable` generalisation of `(^.)`; `withCte`/`fromCte`/`CteRef` for non-recursive entity CTEs. **Deferred (keep as Planned in the docs):** `RIGHT`/`FULL` joins, recursive CTEs (`WITH RECURSIVE`), CTEs whose selection is a tuple/expression rather than a whole entity, `HAVING`, `DISTINCT`, and non-CTE subqueries. State the boundaries; don't imply them.

---

## Current state of `Manifest.Query` (verified — Task code edits this exact structure)

- `data QueryState = QueryState { qsAlias :: Int, qsFrom, qsFromP, qsWhere, qsWhereP, qsOrder, qsGroup, qsLimit, qsOffset }`; `emptyState = QueryState 0 "" [] [] [] [] [] Nothing Nothing`.
- `newtype Handle e = Handle ByteString`; `data Expr t = Expr ByteString [SqlParam]`.
- `(^.) :: Handle e -> Column e t -> Expr t` with `infixl 8 ^.` (a plain function today).
- `innerJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (Handle e)`.
- `class Selectable s where { type Result s; selCols :: s -> ByteString; selDec :: s -> RowDecoder (Result s); selParams :: s -> [SqlParam]; selParams _ = [] }` with instances for `Handle e`, `Expr t`, `(a,b)`.
- `renderQueryM :: Selectable s => QueryM s -> (ByteString, [SqlParam])` builds `"SELECT " <> selCols <> " FROM " <> qsFrom <> where/group/order/limit/offset`, params `selParams sel ++ qsFromP ++ qsWhereP`, then `numberPlaceholders`.
- `runQueryM :: QueryM a -> (a, QueryState)` runs `runState m emptyState`. `numberPlaceholders` replaces each `?` with `$1..$n`. `decodeRowAs`/`runQuery` as before.
- Imports today: `Manifest.Core.Codec (FromField, RowDecoder, SqlParam, ToField (..), decodeRow, field)`, `Manifest.Entity (Entity (..))`, `Manifest.Error (DbError (..), DbException (..))`.

---

### Task 1: LEFT JOIN — `OptHandle`, `Projectable`, `leftJoin`, NULL-aware decode

**Files:** Modify `src/Manifest/Query.hs`, `test/QueryBuilderSpec.hs`.

- [ ] **Step 1: Write the failing tests** — append to the `group "QueryBuilder" [ ... ]` list:

```haskell
  , test "leftJoin renders a LEFT JOIN selecting both tables" $
      assertEqual "sql"
        ( "SELECT t0.user_id, t0.user_name, t0.user_email, t1.post_id, t1.post_author, t1.post_title"
       <> " FROM users AS t0 LEFT JOIN posts AS t1 ON t1.post_author = t0.user_id" )
        (fst (renderQueryM (do u <- from @User
                               mp <- leftJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                               pure (u, mp))))
  , test "leftJoin yields Nothing for unmatched rows, Just for matched" $
      withTestDb $ \pool -> do
        rows <- withSession pool $ do
          _   <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)  -- no posts
          bob <- add (User { userId = 0, userName = "Bob", userEmail = Nothing } :: User)
          _   <- add (Post { postId = 0, postAuthor = userId bob, postTitle = "B1" } :: Post)
          runQuery (do u  <- from @User
                       mp <- leftJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                       orderBy [asc (u ^. #userName)]
                       pure (u, mp))
        assertEqual "Ada has no post, Bob has B1"
          [("Ada", Nothing), ("Bob", Just "B1")]
          [ (userName u, fmap postTitle mp) | (u, mp) <- rows ]
```

- [ ] **Step 2: Run to verify it fails** — `nix develop -c zinc test 2>&1 | tail -15`: `leftJoin` not in scope; no `Selectable (OptHandle …)`.

- [ ] **Step 3: Implement.**

(a) Fix imports at the top of `src/Manifest/Query.hs`:
- change `RowDecoder` to `RowDecoder (..)` in the `Manifest.Core.Codec` import (need the constructor);
- add `Manifest.Error (DecodeError (..), DbError (..), DbException (..))` (add `DecodeError (..)`);
- change `Manifest.Entity (Entity (..))` to `Manifest.Entity (Entity (..), pkIndex)`.

(b) Add `, leftJoin, OptHandle, Projectable` to the export list.

(c) Generalise `(^.)` into a class. **Replace** the current definition:
```haskell
(^.) :: Handle e -> Column e t -> Expr t
Handle al ^. Column c = Expr (al <> "." <> c) []
infixl 8 ^.
```
with:
```haskell
-- | Things you can project a column from (a 'Handle', or a left-joined 'OptHandle').
class Projectable h where
  (^.) :: h e -> Column e t -> Expr t
infixl 8 ^.

instance Projectable Handle where
  Handle al ^. Column c = Expr (al <> "." <> c) []

instance Projectable OptHandle where
  OptHandle al ^. Column c = Expr (al <> "." <> c) []
```

(d) Add the `OptHandle` type (near `Handle`):
```haskell
-- | A handle to the right side of a LEFT JOIN: its columns may be NULL, so it
-- selects as @Maybe e@.
newtype OptHandle e = OptHandle ByteString
```

(e) Add `leftJoin` (next to `innerJoin`):
```haskell
-- | LEFT JOIN table @e@. Like 'innerJoin', but the result selects as @Maybe e@:
-- rows with no match decode to 'Nothing'. The ON closure gets a plain 'Handle e'.
leftJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (OptHandle e)
leftJoin onf = QueryM $ do
  st <- get
  let i  = qsAlias st
      al = "t" <> BC.pack (show i)
      Expr onTxt onPs = onf (Handle al)
  put st { qsAlias  = i + 1
         , qsFrom   = qsFrom st <> " LEFT JOIN " <> tmTable (tableMeta @e)
                        <> " AS " <> al <> " ON " <> onTxt
         , qsFromP  = qsFromP st ++ onPs
         }
  pure (OptHandle al)
```

(f) Add the NULL-aware decoder and the `Selectable (OptHandle e)` instance (near the other `Selectable` instances):
```haskell
-- | Decode @e@'s columns, but yield 'Nothing' when the row had no LEFT-JOIN match
-- (detected by the primary-key column being NULL). Consumes @e@'s columns either way.
optDecoder :: forall e. Entity e => RowDecoder (Maybe e)
optDecoder = RowDecoder $ \cols ->
  let n            = length (tmColumns (tableMeta @e))
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
```

> Notes: `RowDecoder` is `RowDecoder { runRowDecoder :: [SqlParam] -> Either DecodeError (a, [SqlParam]) }`, so the lambda above must return `Either DecodeError (Maybe e, [SqlParam])`. `SqlParam = Maybe ByteString`; a SQL NULL is `Nothing`, so `these !! pkIndex @e == Nothing` tests the PK-is-NULL (no match) case. `pkIndex @e` is the PK's position within `e`'s columns. In the test, the ON is written `p ^. #postAuthor .== u ^. #userId` so the rendered ON is `t1.post_author = t0.user_id` (matching the asserted SQL); the closure's `p` is a `Handle Post`.

- [ ] **Step 4: Run to verify it passes** — `nix develop -c zinc test 2>&1 | tail -8` then `… .zinc/build/spec | tail -2`. Expected **98/98** (baseline 96 + 2). If the unmatched row doesn't decode to `Nothing`, check `pkIndex @Post` and that the LEFT JOIN miss really NULLs the post columns.

- [ ] **Step 5: -Wall check** — `nix develop -c zinc build 2>&1 | grep -iE "warning|Query.hs" | tail -20`: none for `Manifest/Query.hs`.

- [ ] **Step 6: Commit**
```bash
git add src/Manifest/Query.hs test/QueryBuilderSpec.hs
git commit -m "feat(query): leftJoin (LEFT OUTER) with NULL-aware Maybe decode"
```

---

### Task 2: CTEs — `withCte` / `fromCte` / `CteRef`, with a `renderRaw` refactor

**Files:** Modify `src/Manifest/Query.hs`, `test/QueryBuilderSpec.hs`.

- [ ] **Step 1: Write the failing tests** — append:

```haskell
  , test "withCte + fromCte render a WITH clause and select from it" $
      assertEqual "sql"
        ( "WITH cte0 AS (SELECT t0.user_id, t0.user_name, t0.user_email FROM users AS t0"
       <> " WHERE t0.user_name = $1) SELECT t0.user_id, t0.user_name, t0.user_email FROM cte0 AS t0" )
        (fst (renderQueryM (do c <- withCte (do u <- from @User
                                                where_ (u ^. #userName .== val ("Bob" :: String))
                                                pure u)
                               h <- fromCte c
                               pure h)))
  , test "CTE param numbers before the outer WHERE param" $
      assertEqual "params + numbering"
        ( "WITH cte0 AS (SELECT t0.user_id, t0.user_name, t0.user_email FROM users AS t0"
       <> " WHERE t0.user_name > $1) SELECT t0.user_id, t0.user_name, t0.user_email FROM cte0 AS t0"
       <> " WHERE t0.user_name < $2"
        , [Just "A", Just "C"] )
        (renderQueryM (do c <- withCte (do u <- from @User
                                           where_ (u ^. #userName .> val ("A" :: String))
                                           pure u)
                          h <- fromCte c
                          where_ (h ^. #userName .< val ("C" :: String))
                          pure h))
  , test "fromCte over a filtered CTE returns the filtered rows" $
      withTestDb $ \pool -> do
        names <- withSession pool $ do
          mapM_ (\n -> add (User { userId = 0, userName = n, userEmail = Nothing } :: User))
                ["Ada","Bob","Cay"]
          runQuery (do c <- withCte (do u <- from @User
                                        where_ (u ^. #userName .> val ("Ada" :: String))
                                        pure u)
                       h <- fromCte c
                       orderBy [asc (h ^. #userName)]
                       pure h)
        assertEqual "names > Ada" ["Bob","Cay"] (map userName names)
```

- [ ] **Step 2: Run to verify it fails** — `withCte`/`fromCte` not in scope.

- [ ] **Step 3: Implement.**

(a) Add `, withCte, fromCte, CteRef` to the export list.

(b) Extend `QueryState` and `emptyState` with the WITH accumulator + a CTE counter:
```haskell
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
  }

emptyState :: QueryState
emptyState = QueryState 0 "" [] [] [] [] [] Nothing Nothing [] [] 0
```

(c) Refactor `renderQueryM` into a raw assembler + a numbering pass, and include the WITH prefix. **Replace** the current `renderQueryM` with:
```haskell
-- | Assemble SQL with '?' placeholders (un-numbered) and params in textual order.
renderRaw :: Selectable s => QueryM s -> (ByteString, [SqlParam])
renderRaw qm =
  let (sel, st) = runQueryM qm
      withTxt  = if null (qsWith st) then ""
                 else "WITH " <> bcIntercalate ", " (qsWith st) <> " "
      whereTxt = if null (qsWhere st) then "" else " WHERE " <> bcIntercalate " AND " (qsWhere st)
      groupTxt = if null (qsGroup st) then "" else " GROUP BY " <> bcIntercalate ", " (qsGroup st)
      orderTxt = if null (qsOrder st) then "" else " ORDER BY " <> bcIntercalate ", " (qsOrder st)
      limTxt   = maybe "" (\n -> " LIMIT "  <> BC.pack (show n)) (qsLimit st)
      offTxt   = maybe "" (\n -> " OFFSET " <> BC.pack (show n)) (qsOffset st)
      raw = withTxt <> "SELECT " <> selCols sel <> " FROM " <> qsFrom st
              <> whereTxt <> groupTxt <> orderTxt <> limTxt <> offTxt
      params = qsWithP st ++ selParams sel ++ qsFromP st ++ qsWhereP st
  in (raw, params)

renderQueryM :: Selectable s => QueryM s -> (ByteString, [SqlParam])
renderQueryM qm = let (raw, ps) = renderRaw qm in (numberPlaceholders raw, ps)
```

> This is behaviour-preserving for non-CTE queries: `qsWith`/`qsWithP` are empty so `withTxt = ""` and `params = selParams ++ qsFromP ++ qsWhereP` (identical to before). The win: the subquery is rendered RAW (with `?`) by `withCte`, and the single final `numberPlaceholders` numbers every `?` across WITH + SELECT in textual order, so CTE params get the low numbers.

(d) Add the CTE combinators (near `from`):
```haskell
-- | A reference to a registered CTE producing rows of entity @e@.
newtype CteRef e = CteRef ByteString

-- | Register a subquery (which must select a whole entity) as a CTE, returning a
-- reference. Use 'fromCte' to read from it. Non-recursive.
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
```

> `withCte` renders the subquery with `renderRaw` (fresh `emptyState` inside `runQueryM`, so it has its own `t0…` aliases, scoped inside the parens) and does NOT touch the outer alias counter. `fromCte` then sets the outer FROM to `cteN AS tK`. The subquery's params (`subP`) accumulate in `qsWithP`, which `renderRaw` places first. Note `fromCte` doesn't need `Entity e` (it only uses the name), but keep the `Handle e` result so projection works; the `e` flows from `CteRef e`.

- [ ] **Step 4: Run to verify it passes** — `… .zinc/build/spec | tail -2`. Expected **101/101** (98 + 3). If a SQL assertion is off, print the `fst (renderQueryM …)` and compare; the most likely slip is a stray space around the WITH clause or the `cte0 AS t0` alias.

- [ ] **Step 5: -Wall check** — none for `Manifest/Query.hs`.

- [ ] **Step 6: Commit**
```bash
git add src/Manifest/Query.hs test/QueryBuilderSpec.hs
git commit -m "feat(query): non-recursive entity CTEs (withCte/fromCte) + renderRaw split"
```

---

### Task 3: Umbrella export + docs

**Files:** Modify `src/Manifest.hs`, `docs/queries.md`.

- [ ] **Step 1: Re-export the new names from the umbrella.** In `src/Manifest.hs`, the "Query builder (table-handle)" export section and its `import Manifest.Query (...)` block already exist. Add `leftJoin`, `OptHandle`, `Projectable`, `withCte`, `fromCte`, `CteRef` to BOTH the export list and the import list (alongside `innerJoin`/`from`/etc.).

Build to confirm: `nix develop -c zinc build 2>&1 | tail -5` (clean).

- [ ] **Step 2: Update `docs/queries.md`.** Two changes, in the manual's plain voice (no em-dashes, no SQLAlchemy, no positioning claims):

(a) Add a LEFT JOIN paragraph to the "Inner joins" section (or rename it "Joins"). After the inner-join example, add:

````markdown
A `leftJoin` keeps rows from the left table even when the right side has no match;
the right side selects as `Maybe`:

```haskell
rows <- runQuery $ do
  u  <- from @User
  mp <- leftJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
  pure (u, mp)                 -- :: Db [(User, Maybe Post)]
```
````

(b) Add a CTEs section before the Status section:

````markdown
## Common table expressions

`withCte` registers a subquery (which selects a whole entity) as a `WITH` clause and
returns a reference; `fromCte` reads from it like a table:

```haskell
names <- runQuery $ do
  active <- withCte (do u <- from @User
                        where_ (u ^. #userName .> val "A")
                        pure u)
  h <- fromCte active
  orderBy [asc (h ^. #userName)]
  pure h                       -- :: Db [User]
```
````

(c) Update the **Status** section. Move LEFT JOIN and non-recursive CTEs into "built", and narrow the Planned list. The Planned list should now read:

```markdown
Planned, not built:

* **`RIGHT` / `FULL` joins, `HAVING`, `DISTINCT`, recursive CTEs, and non-CTE
  subqueries.** `INNER` and `LEFT` joins, the aggregates above, and non-recursive
  entity CTEs are built.
* **CTEs over non-entity selections.** A CTE's subquery selects a whole entity; a CTE
  whose selection is a tuple or expression is not supported.
* **Multiple `from` / cross joins**, and selection tuples wider than pairs beyond
  left-nesting.
* **Session-managed results.** Builder results are plain decoded values; `get` and
  `selectWhere` return managed rows.
```

And update the "Built and tested" sentence to include `leftJoin` and `withCte`/`fromCte`.

- [ ] **Step 3: Verify** — `nix develop -c .zinc/build/spec 2>&1 | tail -2` (101/101); `grep -rniE "sqlalchemy|—" docs/queries.md` (nothing).

- [ ] **Step 4: Commit**
```bash
git add src/Manifest.hs docs/queries.md
git commit -m "feat(query): export leftJoin + CTE combinators; docs"
```

---

## Self-Review

**1. Spec coverage:** LEFT outer join with `Maybe`-decode → Task 1. CTEs (`withCte`/`fromCte`) → Task 2. Export + docs → Task 3. Deferred items (RIGHT/FULL, recursive CTEs, tuple-CTEs, HAVING, DISTINCT, subqueries) documented as Planned in `queries.md` Status. ✓

**2. Placeholder scan:** complete code per step; the one subtle area (cross-CTE placeholder numbering) is solved structurally by the `renderRaw`/`numberPlaceholders` split and pinned by the "CTE param numbers before the outer WHERE param" test.

**3. Type consistency:**
- `(^.)` becomes `Projectable h => h e -> Column e t -> Expr t`; existing `Handle` uses still resolve (instance `Projectable Handle`), and `OptHandle` gets the same projection. ✓
- `leftJoin :: Entity e => (Handle e -> Expr Bool) -> QueryM (OptHandle e)` (closure gets `Handle`, returns `OptHandle`); `Selectable (OptHandle e)` has `Result = Maybe e`. ✓
- `optDecoder :: Entity e => RowDecoder (Maybe e)` uses the `RowDecoder` constructor, `pkIndex @e`, `tmColumns`/`tableMeta @e`, `decodeRow`/`rowDecoder @e` — all imported (with the import fixes in Task 1 Step 3a). ✓
- `withCte :: Entity e => QueryM (Handle e) -> QueryM (CteRef e)`, `fromCte :: CteRef e -> QueryM (Handle e)`. `renderRaw`/`renderQueryM` split is behaviour-preserving for non-CTE queries (empty `qsWith`). ✓
- `QueryState`/`emptyState` extended consistently (3 new fields, matched positionally in `emptyState`). All `st { … }` updates elsewhere are record updates, unaffected by added fields. ✓

**Open risks (resolved under TDD):** (a) `OptHandle` NULL detection assumes a LEFT-JOIN miss NULLs the PK column (true — a real row's PK is never NULL); (b) the `cteN`/outer-`t0` alias reuse is valid SQL (separate scopes), pinned by the runtime CTE test; (c) the `renderRaw` refactor must not change existing SQL — guarded by the full existing suite (96 tests) still passing.
