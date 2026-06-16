# Manifest Sub-project 2.7 — forward-FK `Opt` + one-level nested loading

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the relationship-loading story — (1) a **nullable belongs-to** (`Employee.manager :: Maybe Employee`, the forward-FK `Opt` cardinality), and (2) **one-level nested loading** with batching: `loadNested (#posts ./ #comments) user :: Db [(Post, [Comment])]` issues ONE query for all comments across the loaded posts (the `IN` optimization SP2 deferred) and stitches them in memory.

**Architecture:** Forward-FK `Opt` adds a `RelOptOne` constructor (forward FK like `RelOne`/belongs-to, but cardinality `Opt`: a NULL self-FK or a missing target yields `Nothing`) + a `belongsToMaybe` builder; `loadRel`/`joinedLoad` gain the case. Nested loading adds a `Comment` fixture (child of `Post`), a `./` operator building a 2-level `Path`, and `loadNested` which loads the mid relation (`loadRel`), batch-loads the leaf relation for all mids via a single `WHERE leafFk IN (…)` query, registers every loaded row in the identity map, and groups leaves under their parent. Scope: both levels are to-many (`posts`, `comments`); the D-path `with (selectin (#posts ./ #comments))` (nested `Ent`s) is a follow-up.

**Tech Stack:** GHC 9.10.1 · zinc · the hand-rolled `test/Harness.hs`. No new external deps.

---

## EXECUTION NOTES (carry over — apply everywhere)

1. **Build/test:** `nix develop -c zinc build` / `nix develop -c zinc test` (wrap in `nix develop -c`; Bash `timeout: 600000`). **Always `zinc test` before `.zinc/build/spec`** (staleness). `.zinc/build/spec` runs green only INSIDE `nix develop`.
2. **Tests use `test/Harness.hs`** (`group`/`test`/`assertBool`/`assertEqual` msg-expected-actual), NOT hspec. Spec modules export `tests :: [Test]`; `test/Spec.hs` aggregates with `++`.
3. **Test DB:** the thin `initdb`/`pg_ctl` harness (`test/Fixtures.hs withTestDb`); extend its DDL list for `comments`.
4. **`-Wall`** via direct GHC against built interfaces WITH lib extensions: `nix develop -c bash -lc 'cd "$PWD" && ghc -fno-code -Wall -fforce-recomp -package-db .zinc/pkgdb -i.zinc/lib -XOverloadedStrings -XScopedTypeVariables -XTypeApplications -XLambdaCase -XTupleSections <module.hs>'` (plus the module's own pragmas).
5. **GADT existential gotcha:** a `c` bound by `case relSpec of …` is NOT nameable as `@c`; hoist into a top-level `forall a c` helper (as `loadOne`/`joinReverse`/`joinForward` do).
6. HKD record literals need `:: User`/`:: Post`/etc.; `Db` has no `MonadFail`; labels are `Rel a name`; column names camelCase→snake_case (no prefix strip); a nullable FK DDL column needs the Haskell field typed `Col f (Maybe Int)`.

Baseline: `main` at `79b40f2`, SP2.6 complete, 62/62 green on GHC 9.10.1.

Relevant existing definitions: `RelSpec` GADT (`RelMany`/`RelOpt`/`RelOne`) and `loadRel`/`selectByKey`/`colValueOf`/`loadOne` in `src/Manifest/Relation.hs`; `joinedLoad`/`joinForward`/`decodeJoinRows` in `src/Manifest/Relation/Loaded.hs`; `belongsTo`/`hasMany`/`hasOpt` in `src/Manifest/Core/Relation.hs`; `Rel a name` + `IsLabel` in `src/Manifest/Core/Query.hs`.

---

## File Structure

| File | Change |
|---|---|
| `src/Manifest/Core/Relation.hs` | add `RelOptOne :: Entity c => ByteString -> RelSpec (Maybe c)` + `belongsToMaybe` builder. |
| `src/Manifest/Relation.hs` | `loadRel` gains the `RelOptOne` case (forward FK, Opt); add `selectByKeyIn` (batched `IN`); add `loadNested`; add the `Path`/`(./)` types. |
| `src/Manifest/Relation/Loaded.hs` | `joinedLoad` gains the `RelOptOne` case (`listToMaybe <$> joinForward`). |
| `src/Manifest.hs` | re-export `belongsToMaybe`(no — keep internal like `belongsTo`), `loadNested`, `(./)`, `Path`. |
| `test/Fixtures.hs` | change `Employee "manager"` to `Maybe Employee` via `belongsToMaybe`; add a `Comment` table + `Entity Comment` + `HasRelation Post "comments"`. |
| `test/SelfRefSpec.hs` | update `#manager` tests for `Maybe Employee` (Nothing at top, Just below). |
| `test/NestedSpec.hs` | NEW — `loadNested (#posts ./ #comments)` + the single-batched-query assertion. |
| `test/RelE2ESpec.hs` | extend with a nested + nullable-manager capstone. |

---

### Task 1: forward-FK `Opt` — `RelOptOne` + `belongsToMaybe`

A nullable belongs-to: `Employee.manager :: Maybe Employee` (top of the chain → `Nothing`).

**Files:** Modify `src/Manifest/Core/Relation.hs`, `src/Manifest/Relation.hs`, `src/Manifest/Relation/Loaded.hs`, `test/Fixtures.hs`, `test/SelfRefSpec.hs`.

- [ ] **Step 1: `RelOptOne` + `belongsToMaybe`** (`src/Manifest/Core/Relation.hs`)

Add to the `RelSpec` GADT:
```haskell
  RelOptOne :: Entity c => ByteString -> RelSpec (Maybe c)   -- forward FK, nullable target
```
Add the builder (forward FK on self, like `belongsTo`, but `Opt`):
```haskell
-- | A nullable to-one via a forward FK: the target (if the self FK is set and
-- the row exists) is the one with @target.pk = self.<selfFk>@; otherwise 'Nothing'.
belongsToMaybe :: forall c fk. (Entity c, KnownSymbol fk) => Proxy fk -> RelSpec (Maybe c)
belongsToMaybe _ = RelOptOne (camelToSnake (symbolVal (Proxy @fk)))
```
Export `belongsToMaybe`.

- [ ] **Step 2: `loadRel` forward-Opt case** (`src/Manifest/Relation.hs`)

Add a `RelOptOne` branch to `loadRel`, delegating to a hoisted helper (the GADT `c` isn't nameable inline):
```haskell
  RelOptOne selfFk -> loadOptOne selfFk parent
```
and the helper (mirrors `loadOne` but Opt + NULL-FK aware):
```haskell
-- forward FK, nullable: NULL self-FK → Nothing; else SELECT target by its PK, listToMaybe.
loadOptOne :: forall a c. (Entity a, Entity c) => ByteString -> a -> Db (Maybe c)
loadOptOne selfFk parent =
  case colValueOf @a selfFk parent of
    Nothing -> pure Nothing                                   -- self FK is NULL → no manager
    fkVal   -> listToMaybe <$> selectByKey @c (cmName (pkColumn (tableMeta @c))) fkVal
```
(`colValueOf` returns `SqlParam = Maybe ByteString`; `Nothing` means the FK column was NULL.)

- [ ] **Step 3: `joinedLoad` forward-Opt case** (`src/Manifest/Relation/Loaded.hs`)

```haskell
  RelOptOne selfFk -> listToMaybe <$> joinForward selfFk parent
```
(`joinForward`'s LEFT JOIN already yields no row when the self FK is NULL or the target is missing — `decodeJoinRows` skips the NULL-target row — so `listToMaybe` gives `Nothing` correctly.)

- [ ] **Step 4: change `Employee "manager"` to `Maybe Employee`** (`test/Fixtures.hs`)

```haskell
instance HasRelation Employee "manager" where
  type Target      Employee "manager" = Maybe Employee
  type Cardinality Employee "manager" = 'Opt
  relSpec = belongsToMaybe (Proxy @"employeeManager")
```
Import `belongsToMaybe`.

- [ ] **Step 5: update the `#manager` tests** (`test/SelfRefSpec.hs`)

The `load #manager` test now returns `Maybe Employee`:
```haskell
  , test "load #manager (nullable belongs-to self): Just below, Nothing at top" $
      withTestDb $ \pool -> do
        (mgrOfReport, mgrOfBoss) <- withSession pool $ do
          boss <- add (Employee { employeeId = 0, employeeManager = Nothing, employeeName = "Boss" } :: Employee)
          r1   <- add (Employee { employeeId = 0, employeeManager = Just (employeeId boss), employeeName = "R1" } :: Employee)
          m1   <- load #manager r1     -- Just Boss
          m2   <- load #manager boss   -- Nothing (no manager)
          pure (fmap employeeName m1, fmap employeeName m2)
        assertEqual "report's manager" (Just "Boss") mgrOfReport
        assertEqual "boss's manager"   Nothing        mgrOfBoss
```
(Replace the old SP2.6 `One`-with-set-manager `#manager` test with this. The `#reports` and `joined #reports` tests are unchanged.)

- [ ] **Step 6: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `62/62 tests passed` (the old `#manager` test is replaced by the new one — count unchanged). `-Wall`-clean on the 3 changed src modules. Commit:
```bash
git add -A
git commit -m "feat(sp2.7): forward-FK Opt — RelOptOne + belongsToMaybe (nullable belongs-to)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: one-level nested loading — `./`, `Path`, `loadNested` (batched)

`loadNested (#posts ./ #comments) user :: Db [(Post, [Comment])]` — load the user's posts, then ONE query for all those posts' comments, grouped.

**Files:** Modify `test/Fixtures.hs`; modify `src/Manifest/Relation.hs`; create `test/NestedSpec.hs`.

- [ ] **Step 1: `Comment` fixture** (`test/Fixtures.hs`)

```haskell
data CommentT f = Comment
  { commentId   :: Col f (PrimaryKey (Serial Int))
  , commentPost :: Col f Int          -- FK → post_id
  , commentBody :: Col f Text
  } deriving Generic
type Comment = CommentT Identity

instance Entity Comment where
  type PrimKey Comment = Int
  tableMeta  = genericTableMeta @CommentT "comments"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = commentId

instance HasRelation Post "comments" where
  type Target      Post "comments" = [Comment]
  type Cardinality Post "comments" = 'Many
  relSpec = hasMany (Proxy @"commentPost")
```
DDL `commentsDDL = "CREATE TABLE comments ( comment_id BIGSERIAL PRIMARY KEY, comment_post BIGINT NOT NULL, comment_body TEXT NOT NULL )"`, wired into `withTestDb`. Export `CommentT(..)`, `Comment`, `commentsDDL`.

- [ ] **Step 2: `Path`, `(./)`, `selectByKeyIn`, `loadNested`** (`src/Manifest/Relation.hs`)

```haskell
-- A two-level load path: relation @n1@ on @a@, then relation @n2@ on its elements.
data Path a (n1 :: Symbol) mid (n2 :: Symbol) = Path

-- | Compose two relation labels into a nested path: @#posts ./ #comments@.
(./) :: Rel a n1 -> Rel mid n2 -> Path a n1 mid n2
_ ./ _ = Path
infixr 5 ./

-- | @SELECT <child cols> FROM <child> WHERE <keyCol> IN ($1,...)@ — one batched
-- query for the children of MANY parents; decodes + registers each.
selectByKeyIn :: forall c. Entity c => ByteString -> [SqlParam] -> Db [c]
selectByKeyIn _ [] = pure []
selectByKeyIn keyCol keyVals = do
  let tm    = tableMeta @c
      cols  = bcIntercalate ", " (map cmName (tmColumns tm))
      phs   = bcIntercalate ", " [BC.pack ('$' : show i) | i <- [1 .. length keyVals]]
      sql   = "SELECT " <> cols <> " FROM " <> tmTable tm <> " WHERE " <> keyCol <> " IN (" <> phs <> ")"
  rows <- execDb sql keyVals
  mapM (\row -> do c <- decodeRowDb @c row; setBaseline c; pure c) rows

-- | One-level nested load (both levels to-many), batched: load the mids, then a
-- single IN-query for all leaves, grouped under their parent mid.
loadNested
  :: forall a n1 mid n2 leaf.
     ( HasRelation a n1, Target a n1 ~ [mid], Entity mid
     , HasRelation mid n2, Entity leaf )
  => Path a n1 mid n2 -> a -> Db [(mid, [leaf])]
loadNested _ parent = do
  mids <- loadRel @a @n1 parent                  -- [mid]
  case relSpec @mid @n2 of
    RelMany leafFk -> do
      leaves <- selectByKeyIn @leaf leafFk (map pkParam mids)
      pure [ (m, [ l | l <- leaves, colValueOf @leaf leafFk l == pkParam m ]) | m <- mids ]
    _ -> liftIO (throwIO (DbException (OtherError "loadNested: leaf relation must be to-many (Many) in this MVP")))
```
Export `Path`, `(./)`, `loadNested`. Add imports: `qualified Data.ByteString.Char8 as BC`, `Manifest.Core.Sql (bcIntercalate)` (export `bcIntercalate` from `Core.Sql` if not already), `Manifest.Core.Meta (tmTable, tmColumns, cmName)`. `Target mid n2 ~ [leaf]` is implied by the `RelMany` match (it binds `leaf` from `Entity c => RelSpec [c]`).

> The `RelMany leafFk` match binds a fresh existential for the leaf; because `loadNested`'s result type fixes `leaf` via `selectByKeyIn @leaf`, write the helper calls without re-applying `@leaf` to the existential if GHC complains (let unification connect them — as in `joinedLoad`). If the `Target mid n2 ~ [leaf]` constraint is awkward, drop it from the signature and let the `RelMany` branch unify `leaf` (the other branches throw). Iterate until it compiles; the BEHAVIOUR (batched IN, grouped tuples) is the contract.

- [ ] **Step 3: `test/NestedSpec.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module NestedSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Fixtures (Comment, CommentT (..), Post, PostT (..), User, UserT (..), withTestDb)
import Manifest.Relation (loadNested, (./))
import Manifest.Session
import Harness

commentSelects :: [(BC.ByteString, [Maybe BC.ByteString])] -> Int
commentSelects = length . filter (\(s,_) -> "FROM comments" `isInfixOf` BC.unpack s)

tests :: [Test]
tests = group "Nested"
  [ test "loadNested (#posts ./ #comments) groups comments under each post, in ONE batched query" $
      withTestDb $ \pool -> do
        (shape, nCommentQueries) <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          p1 <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          p2 <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          _  <- add (Comment { commentId = 0, commentPost = postId p1, commentBody = "c1" } :: Comment)
          _  <- add (Comment { commentId = 0, commentPost = postId p1, commentBody = "c2" } :: Comment)
          _  <- add (Comment { commentId = 0, commentPost = postId p2, commentBody = "c3" } :: Comment)
          -- clear the log of the inserts by reading it after, then count comment SELECTs in the WHOLE log
          res <- loadNested (#posts ./ #comments) u
          l   <- statementLog
          pure ([ (postTitle p, map commentBody cs) | (p, cs) <- res ], commentSelects l)
        assertEqual "grouped" [("P1", ["c1", "c2"]), ("P2", ["c3"])] shape
        assertEqual "single batched comments query" 1 nCommentQueries
  ]
```
Wire into `test/Spec.hs`: `import qualified NestedSpec` and `++ NestedSpec.tests`.

> The batched-query assertion counts statements selecting `FROM comments`. The `add (Comment …)` calls use `INSERT INTO comments … RETURNING …` (no `FROM comments`), so they don't count; only `loadNested`'s single `SELECT … FROM comments WHERE comment_post IN (…)` matches. If `INSERT … RETURNING` somehow matches `FROM comments` in your build, tighten the predicate to `"SELECT"` + `"FROM comments"`.

- [ ] **Step 4: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `63/63 tests passed`. `-Wall`-clean on `Relation.hs` (+ `Core/Sql.hs` if `bcIntercalate` export added). Commit:
```bash
git add -A
git commit -m "feat(sp2.7): one-level nested loading (#posts ./ #comments), batched IN query

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: umbrella exports + end-to-end

**Files:** Modify `src/Manifest.hs`, `test/RelE2ESpec.hs`.

- [ ] **Step 1: re-export the nested API** (`src/Manifest.hs`)

Add `loadNested`, `(./)`, `Path` (from `Manifest.Relation`) to the umbrella export list and `import Manifest.Relation (..., loadNested, (./), Path)`. (Keep `belongsToMaybe` internal, like `belongsTo`/`hasMany` — relationship declaration lives in `Manifest.Core.Relation`, which users import for instances.) `Maybe Employee` from `load #manager` already works via the exported `load`.

- [ ] **Step 2: capstone** (`test/RelE2ESpec.hs`)

```haskell
  , test "nested loading + nullable manager through the public API" $
      withTestDb $ \pool -> do
        (shape, topMgr) <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          p1 <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _  <- add (Comment { commentId = 0, commentPost = postId p1, commentBody = "c1" } :: Comment)
          nested <- loadNested (#posts ./ #comments) u
          boss   <- add (Employee { employeeId = 0, employeeManager = Nothing, employeeName = "Boss" } :: Employee)
          mgr    <- load #manager boss      -- Nothing
          pure ([ (postTitle p, map commentBody cs) | (p, cs) <- nested ], fmap employeeName mgr)
        assertEqual "nested" [("P1", ["c1"])] shape
        assertEqual "top has no manager" Nothing topMgr
```
(Import `Comment`/`CommentT(..)`, `Employee`/`EmployeeT(..)` from `Fixtures`; everything else via `Manifest`.)

- [ ] **Step 3: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `64/64 tests passed`. `-Wall`-clean library (`src/Manifest.hs`). Commit:
```bash
git add -A
git commit -m "feat(sp2.7): umbrella nested-loading exports + nested/nullable-manager end-to-end

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Spec coverage check (self-review)

| Design § | Requirement | Where covered |
|---|---|---|
| §5.3 | `One`/`Opt`/`Many` cardinalities all expressible — incl. nullable forward-FK (`Opt` belongs-to) | Task 1 (`RelOptOne`/`belongsToMaybe`) |
| §5.4 | one level of nesting (`#posts ./ #comments`) | Task 2 (`./`/`Path`/`loadNested`) |
| §5.4 | `selectin` batching ("one `SELECT child WHERE fk IN (parent_pks)`") | Task 2 (`selectByKeyIn`) |
| §5.5 | nested-loaded rows are managed | Task 2 (`selectByKeyIn`/`loadRel` call `setBaseline`) |

**Deferred to a later slice (explicit):** the D-path nested form `with (selectin (#posts ./ #comments)) ent` returning nested `Ent`s (SP2.7 ships the A-path `loadNested` → `[(mid,[leaf])]`); arbitrary-depth nesting (>1 level); nested leaf relations that are `Opt`/`One` (this MVP requires the leaf to be `Many`); multi-level / recursive cascade; the `cascade #label` sugar; an `in_` query-combinator in `Core.Query` (SP2.7 builds the `IN` clause inline in `selectByKeyIn`).

**Type-consistency notes:** `RelOptOne :: Entity c => ByteString -> RelSpec (Maybe c)`; `belongsToMaybe :: Proxy fk -> RelSpec (Maybe c)`; `loadRel`/`joinedLoad` both case-split over `RelMany`/`RelOpt`/`RelOne`/`RelOptOne`. `Path a n1 mid n2`; `(./) :: Rel a n1 -> Rel mid n2 -> Path a n1 mid n2` (infixr 5); `loadNested :: Path a n1 mid n2 -> a -> Db [(mid, [leaf])]`. `selectByKeyIn :: Entity c => ByteString -> [SqlParam] -> Db [c]` reuses the snapshot-registering pattern of `selectByKey`.
