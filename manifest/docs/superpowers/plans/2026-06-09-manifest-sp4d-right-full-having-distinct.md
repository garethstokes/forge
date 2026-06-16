# Manifest SP4d — Query builder: RIGHT/FULL joins, HAVING, DISTINCT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Round out the relational surface of the table-handle query builder (`Manifest.Query`): **RIGHT** and **FULL** outer joins (with `opt` to select previously-bound tables as `Maybe`), **`HAVING`**, and **`SELECT DISTINCT`**.

**Architecture:** All four extend the existing handle-based builder. (1) Joins: the four join keywords share one helper; `rightJoin @e` returns a required `Handle e` (the *prior* tables become nullable), `fullJoin @e` returns an `OptHandle e` (both sides nullable). Because a RIGHT/FULL join makes an already-bound handle nullable but its type can't change retroactively, `opt :: Handle e -> OptHandle e` re-tags a handle so it *selects* as `Maybe e` (NULL-aware, reusing the existing `optDecoder`). (2) `having :: Expr Bool -> QueryM ()` accumulates a `HAVING` clause (rendered after `GROUP BY`, params after `WHERE`). (3) `distinct :: QueryM ()` sets a flag that makes the SELECT a `SELECT DISTINCT`.

**Tech Stack:** GHC 9.10.1 via zinc. Read `src/Manifest/Query.hs` first — this plan edits it. Custom `test/Harness.hs`; `Fixtures` (`User`, `Post`; `posts.post_author` is a plain `BIGINT NOT NULL` with **no FK constraint**, so orphan posts — `postAuthor` pointing at a non-existent user — can be inserted to exercise outer joins).

**Scope (MVP):** `rightJoin`, `fullJoin`, `opt`, `having`, `distinct`. **Deferred (keep Planned in docs):** recursive CTEs (`WITH RECURSIVE`), CTEs over non-entity selections, non-CTE subqueries, multiple `from`/cross joins, selection tuples wider than pairs beyond left-nesting, and session-managed results.

---

## Current state (verified — Task code edits this exact structure)

- `QueryState` fields: `qsAlias, qsFrom, qsFromP, qsWhere, qsWhereP, qsOrder, qsGroup, qsLimit, qsOffset, qsWith, qsWithP, qsCte`; `emptyState = QueryState 0 "" [] [] [] [] [] Nothing Nothing [] [] 0`.
- `newtype Handle e = Handle ByteString`; `newtype OptHandle e = OptHandle ByteString`; `data Expr t = Expr ByteString [SqlParam]`.
- `class Projectable h where (^.) :: h e -> Column e t -> Expr t` (instances `Handle`, `OptHandle`).
- `innerJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (Handle e)` and `leftJoin :: … -> QueryM (OptHandle e)` — each: allocate alias `tN` from `qsAlias`, append `" <KEYWORD> " <> tmTable (tableMeta @e) <> " AS " <> tN <> " ON " <> onTxt` to `qsFrom`, `qsFromP ++ onPs`, return the handle.
- `Selectable` with instances `Handle e` (→ `e`), `OptHandle e` (→ `Maybe e`, NULL-aware `optDecoder`), `Expr t` (→ `t`), `(a,b)`.
- `renderRaw` builds `withTxt <> "SELECT " <> selCols sel <> " FROM " <> qsFrom st <> whereTxt <> groupTxt <> orderTxt <> limTxt <> offTxt`, params `qsWithP ++ selParams sel ++ qsFromP ++ qsWhereP`; `renderQueryM = numberPlaceholders . renderRaw`.
- Module already has `ScopedTypeVariables`, `TypeApplications`, `FlexibleInstances`, `TypeFamilies`, `GeneralizedNewtypeDeriving` on.

---

### Task 1: RIGHT and FULL joins + `opt`

**Files:** Modify `src/Manifest/Query.hs`, `test/QueryBuilderSpec.hs`.

- [ ] **Step 1: Write the failing tests** — append to the `group "QueryBuilder" [ ... ]` list:

```haskell
  , test "rightJoin renders RIGHT JOIN; opt selects the left table as Maybe" $
      assertEqual "sql"
        ( "SELECT t0.user_id, t0.user_name, t0.user_email, t1.post_id, t1.post_author, t1.post_title"
       <> " FROM users AS t0 RIGHT JOIN posts AS t1 ON t1.post_author = t0.user_id" )
        (fst (renderQueryM (do u <- from @User
                               p <- rightJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                               pure (opt u, p))))
  , test "fullJoin renders FULL JOIN; both sides select as Maybe" $
      assertEqual "sql"
        ( "SELECT t0.user_id, t0.user_name, t0.user_email, t1.post_id, t1.post_author, t1.post_title"
       <> " FROM users AS t0 FULL JOIN posts AS t1 ON t1.post_author = t0.user_id" )
        (fst (renderQueryM (do u  <- from @User
                               fp <- fullJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                               pure (opt u, fp))))
  , test "rightJoin keeps unmatched right rows (orphan post -> Nothing user)" $
      withTestDb $ \pool -> do
        rows <- withSession pool $ do
          ada <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _   <- add (Post { postId = 0, postAuthor = userId ada, postTitle = "A1" } :: Post)
          _   <- add (Post { postId = 0, postAuthor = 999, postTitle = "Orphan" } :: Post)  -- no such user
          runQuery (do u <- from @User
                       p <- rightJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                       pure (opt u, p))
        assertEqual "every post kept; orphan has no user"
          [(Just "Ada", "A1"), (Nothing, "Orphan")]
          (sortOn snd [ (fmap userName mu, postTitle p) | (mu, p) <- rows ])
  , test "fullJoin keeps unmatched rows on both sides" $
      withTestDb $ \pool -> do
        rows <- withSession pool $ do
          ada <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _   <- add (User { userId = 0, userName = "Bob", userEmail = Nothing } :: User)  -- no posts
          _   <- add (Post { postId = 0, postAuthor = userId ada, postTitle = "A1" } :: Post)
          _   <- add (Post { postId = 0, postAuthor = 999, postTitle = "Orphan" } :: Post) -- no user
          runQuery (do u  <- from @User
                       fp <- fullJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                       pure (opt u, fp))
        assertEqual "matched, user-without-post, post-without-user"
          [ (Just "Ada", Just "A1"), (Just "Bob", Nothing), (Nothing, Just "Orphan") ]
          (sort [ (fmap userName mu, fmap postTitle mp) | (mu, mp) <- rows ])
```

Add `import Data.List (sort, sortOn)` to `test/QueryBuilderSpec.hs` if not already imported (it currently imports `Data.List (sort)`; change to `Data.List (sort, sortOn)`).

- [ ] **Step 2: Run to verify it fails** — `nix develop -c zinc test 2>&1 | tail -15`: `rightJoin`/`fullJoin`/`opt` not in scope.

- [ ] **Step 3: Implement.**

(a) Add `, rightJoin, fullJoin, opt` to the export list.

(b) Factor the four joins through one helper. **Replace** the current `innerJoin` and `leftJoin` definitions with:
```haskell
-- | Shared join machinery: allocate an alias, append "<kw> <table> AS tN ON <on>"
-- to the FROM, collect ON params, and return the new alias.
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

-- | RIGHT JOIN table @e@: keeps all of @e@'s rows; the previously-joined tables may
-- be NULL, so select them with 'opt'. The new table is required ('Handle').
rightJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (Handle e)
rightJoin onf = Handle <$> addJoin @e "RIGHT JOIN" onf

-- | FULL OUTER JOIN table @e@: keeps unmatched rows on both sides. The new table
-- selects as @Maybe e@ ('OptHandle'); select prior tables with 'opt'.
fullJoin :: forall e. Entity e => (Handle e -> Expr Bool) -> QueryM (OptHandle e)
fullJoin onf = OptHandle <$> addJoin @e "FULL JOIN" onf
```

(c) Add `opt` (near the handle types or the joins):
```haskell
-- | Re-tag a handle so it /selects/ as @Maybe e@ (NULL-aware, via 'optDecoder').
-- Use it for a table that a RIGHT or FULL join may leave unmatched. It does not
-- change the FROM clause, only how the column set is decoded.
opt :: Handle e -> OptHandle e
opt (Handle al) = OptHandle al
```

> The `@e` on `addJoin @e` is explicit so the entity is unambiguous (the module has `ScopedTypeVariables`/`TypeApplications`). `Handle`/`OptHandle` are newtypes over the alias `ByteString`, so `Handle <$> addJoin …` / `OptHandle <$> addJoin …` just tag the returned alias; the phantom `e` is pinned by each function's signature. `opt` reuses the existing `Selectable (OptHandle e)` instance (NULL-aware `optDecoder`), so a RIGHT/FULL-joined table with no match decodes to `Nothing`.

- [ ] **Step 4: Run to verify it passes** — `nix develop -c zinc test 2>&1 | tail -8` then `… .zinc/build/spec | tail -2`. Expected **105/105** (baseline 101 + 4). **Confirm the existing innerJoin/leftJoin tests still pass** (the `addJoin` refactor must be behaviour-preserving). If a render test is off, the join keyword spacing is the likely culprit (one leading space before the keyword, as in `qsFrom st <> " " <> kw`).

- [ ] **Step 5: -Wall check** — `nix develop -c zinc build 2>&1 | grep -iE "warning|Query.hs" | tail -20`: none for `Manifest/Query.hs`.

- [ ] **Step 6: Commit**
```bash
git add src/Manifest/Query.hs test/QueryBuilderSpec.hs
git commit -m "feat(query): RIGHT/FULL joins + opt (select a joined table as Maybe)"
```

---

### Task 2: `HAVING` and `DISTINCT`

**Files:** Modify `src/Manifest/Query.hs`, `test/QueryBuilderSpec.hs`.

- [ ] **Step 1: Write the failing tests** — append:

```haskell
  , test "having renders after GROUP BY; param numbers after WHERE" $
      assertEqual "sql + params"
        ( "SELECT t0.post_author, COUNT(*) FROM posts AS t0 WHERE t0.post_title <> $1"
       <> " GROUP BY t0.post_author HAVING COUNT(*) > $2"
        , [Just "x", Just "1"] )
        (renderQueryM (do p <- from @Post
                          where_ (p ^. #postTitle ./= val ("x" :: String))
                          groupBy (p ^. #postAuthor)
                          having (countRows .> val (1 :: Int))
                          pure (p ^. #postAuthor, countRows)))
  , test "having filters groups at runtime" $
      withTestDb $ \pool -> do
        authors <- withSession pool $ do
          u1 <- add (User { userId = 0, userName = "A", userEmail = Nothing } :: User)
          u2 <- add (User { userId = 0, userName = "B", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u1, postTitle = "p1" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u1, postTitle = "p2" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u2, postTitle = "p3" } :: Post)
          runQuery (do p <- from @Post
                       groupBy (p ^. #postAuthor)
                       having (countRows .> val (1 :: Int))
                       pure (p ^. #postAuthor))
        assertEqual "only the author with >1 post" [userIdOf 1] authors
  , test "distinct renders SELECT DISTINCT and dedups rows" $
      withTestDb $ \pool -> do
        authors <- withSession pool $ do
          u1 <- add (User { userId = 0, userName = "A", userEmail = Nothing } :: User)
          u2 <- add (User { userId = 0, userName = "B", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u1, postTitle = "p1" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u1, postTitle = "p2" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u2, postTitle = "p3" } :: Post)
          runQuery (do distinct
                       p <- from @Post
                       pure (p ^. #postAuthor))
        assertEqual "distinct authors (3 posts, 2 authors)" [1, 2] (sort authors)
```

Replace `userIdOf 1` and `[1, 2]` with literal `Int`s: the first inserted user has serial PK `1`, the second `2`. So the HAVING test's expected is `[1 :: Int]` and the DISTINCT test's is `[1, 2] :: [Int]`. (Delete the `userIdOf` placeholder; use the literal `[1 :: Int]`.) Also add a pure render test for DISTINCT:

```haskell
  , test "distinct renders SELECT DISTINCT" $
      assertEqual "sql"
        "SELECT DISTINCT t0.post_author FROM posts AS t0"
        (fst (renderQueryM (do distinct; p <- from @Post; pure (p ^. #postAuthor))))
```

- [ ] **Step 2: Run to verify it fails** — `having`/`distinct` not in scope.

- [ ] **Step 3: Implement.**

(a) Add `, having, distinct` to the export list.

(b) Extend `QueryState` (append three fields) and `emptyState`:
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
  , qsWith   :: [ByteString]
  , qsWithP  :: [SqlParam]
  , qsCte    :: Int
  , qsHaving  :: [ByteString]    -- HAVING conjuncts
  , qsHavingP :: [SqlParam]
  , qsDistinct :: Bool
  }

emptyState :: QueryState
emptyState = QueryState 0 "" [] [] [] [] [] Nothing Nothing [] [] 0 [] [] False
```

(c) Add the combinators (near `where_`/`groupBy`):
```haskell
-- | A HAVING predicate over a grouped query (typically over an aggregate, e.g.
-- @having (countRows .> val 1)@). Multiple calls are ANDed.
having :: Expr Bool -> QueryM ()
having (Expr t ps) = QueryM $ modify' $ \st ->
  st { qsHaving = qsHaving st ++ [t], qsHavingP = qsHavingP st ++ ps }

-- | Make the query a @SELECT DISTINCT@.
distinct :: QueryM ()
distinct = QueryM $ modify' $ \st -> st { qsDistinct = True }
```

(d) Update `renderRaw` to honour DISTINCT and emit HAVING after GROUP BY, with HAVING params after WHERE params. **Replace** the body of `renderRaw` with:
```haskell
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
```

> Behaviour-preserving for non-HAVING/non-DISTINCT queries: `qsDistinct` defaults `False` (so `selKw = "SELECT "`), `qsHaving` empty (so `havingTxt = ""` and `qsHavingP = []`). The clause order is the SQL-canonical `… WHERE … GROUP BY … HAVING … ORDER BY …`, and params follow textual order, so the HAVING param comes after the WHERE param.

- [ ] **Step 4: Run to verify it passes** — `… .zinc/build/spec | tail -2`. Expected **109/109** (105 + 4: two render + two runtime). Confirm the existing 105 still pass (the `renderRaw` and `QueryState` changes are additive).

- [ ] **Step 5: -Wall check** — none for `Manifest/Query.hs`.

- [ ] **Step 6: Commit**
```bash
git add src/Manifest/Query.hs test/QueryBuilderSpec.hs
git commit -m "feat(query): HAVING and SELECT DISTINCT"
```

---

### Task 3: Umbrella export + docs

**Files:** Modify `src/Manifest.hs`, `docs/queries.md`.

- [ ] **Step 1: Re-export from the umbrella.** In `src/Manifest.hs`, add to both the export list and the `import Manifest.Query (...)` block: `rightJoin`, `fullJoin`, `opt`, `having`, `distinct`. Build: `nix develop -c zinc build 2>&1 | tail -5` (clean).

- [ ] **Step 2: Update `docs/queries.md`** (plain voice: no em-dashes, no SQLAlchemy, no positioning claims). Read it first.

(a) In the "Joins" section, after the `leftJoin` example, add:

````markdown
`rightJoin` keeps all rows of the joined table (the previously-joined tables may be
NULL); `fullJoin` keeps unmatched rows on both sides. Use `opt` to select a table
that a right or full join can leave unmatched, so it decodes as `Maybe`:

```haskell
rows <- runQuery $ do
  u <- from @User
  p <- rightJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
  pure (opt u, p)              -- :: Db [(Maybe User, Post)]
```
````

(b) In the "Aggregates and grouping" section, after the `groupBy` example, add:

````markdown
`having` filters groups (typically on an aggregate); `distinct` makes the query a
`SELECT DISTINCT`:

```haskell
prolific <- runQuery $ do
  p <- from @Post
  groupBy (p ^. #postAuthor)
  having (countRows .> val 1)
  pure (p ^. #postAuthor, countRows)   -- authors with more than one post
```
````

(c) Update the `## Status` section: add `rightJoin`/`fullJoin`/`opt`, `having`, and `distinct` to the built list, and **replace the Planned bullet list** with:

```markdown
Planned, not built:

* **Recursive CTEs and non-CTE subqueries.** `INNER`/`LEFT`/`RIGHT`/`FULL` joins,
  aggregates, `HAVING`, `DISTINCT`, and non-recursive entity CTEs are built.
* **CTEs over non-entity selections.** A CTE's subquery selects a whole entity; a CTE
  whose selection is a tuple or expression is not supported.
* **Multiple `from` / cross joins**, and selection tuples wider than pairs beyond
  left-nesting.
* **Session-managed results.** Builder results are plain decoded values; `get` and
  `selectWhere` return managed rows.
```

- [ ] **Step 3: Verify** — `… .zinc/build/spec | tail -2` (109/109); `grep -nE "—|sqlalchemy" docs/queries.md` (nothing).

- [ ] **Step 4: Commit**
```bash
git add src/Manifest.hs docs/queries.md
git commit -m "feat(query): export RIGHT/FULL joins, opt, having, distinct; docs"
```

---

## Self-Review

**1. Spec coverage:** RIGHT/FULL joins + `opt` → Task 1. HAVING → Task 2. DISTINCT → Task 2. Export + docs → Task 3. Deferred (recursive CTEs, non-entity CTEs, subqueries, multiple-from, wide tuples, managed results) documented as Planned. ✓

**2. Placeholder scan:** complete code per step; the param-ordering subtlety (HAVING after WHERE) is pinned by the "having … param numbers after WHERE" render test asserting `$1`/`$2` + `[Just "x", Just "1"]`.

**3. Type consistency:**
- `addJoin :: Entity e => ByteString -> (Handle e -> Expr Bool) -> QueryM ByteString`; `innerJoin`/`rightJoin` wrap with `Handle`, `leftJoin`/`fullJoin` with `OptHandle` — both newtypes over the alias, so the wraps typecheck and the existing inner/left tests are unchanged. ✓
- `opt :: Handle e -> OptHandle e` reuses `Selectable (OptHandle e)` (`Result = Maybe e`). RIGHT/FULL selections like `(opt u, p)` / `(opt u, fp)` get `(Maybe User, Post)` / `(Maybe User, Maybe Post)` via the tuple instance. ✓
- `having :: Expr Bool -> QueryM ()`, `distinct :: QueryM ()`; `qsHaving`/`qsHavingP`/`qsDistinct` added to `QueryState`/`emptyState` consistently (positional `emptyState` updated to 15 fields). All other `st { … }` record updates are unaffected by the added fields. ✓
- `renderRaw` change is behaviour-preserving for existing queries (`qsDistinct=False`, `qsHaving=[]`). ✓

**Open risks (resolved under TDD):** (a) the `addJoin` refactor must not change inner/left SQL — guarded by their existing render+runtime tests; (b) RIGHT/FULL row-keeping + `opt` NULL-decode depends on orphan posts (no FK in the fixture DDL) — the runtime tests insert `postAuthor = 999`; (c) the `qsHaving`/`qsDistinct` field additions touch every `QueryState` literal — only `emptyState` constructs one positionally, updated here.
