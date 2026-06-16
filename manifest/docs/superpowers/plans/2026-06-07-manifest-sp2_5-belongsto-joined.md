# Manifest Sub-project 2.5 — belongs-to (`One`) + the `joined` strategy

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the relationship-loading story — add **belongs-to / forward-FK** (the `One` cardinality: `load #author post :: Db User`) and the **`joined` LEFT-JOIN strategy** (`with (joined #posts) ent`), so all three cardinalities (Many/Opt/One) work under both strategies (selectin/joined), with NULL-aware nested decoding.

**Architecture:** SP2 left `RelSpec` with `RelMany`/`RelOpt` (reverse-FK: `child.fk = parent.pk`). SP2.5 adds `RelOne` (forward-FK: `target.pk = self.fk_value`) and generalizes the selectin executor to "SELECT target WHERE keyCol = keyVal" so all three cardinalities share it. A new `joined` strategy renders a single `LEFT JOIN` (`Core.Sql.renderJoined`) and decodes the child/target portion per row, skipping LEFT-JOIN misses (child PK `NULL`). `Strategy` becomes `Selectin | Joined`; `with` dispatches. The A path (`load`) stays selectin; `joined` is opt-in via `with`.

**Tech Stack:** GHC 9.10.1 · zinc (`nix develop -c zinc build/test`) · the hand-rolled `test/Harness.hs` · `Data.Dynamic`, `GHC.TypeLits`/`GHC.TypeError` (unchanged from SP2).

---

## EXECUTION NOTES (carry over — apply everywhere)

1. **Build/test:** `nix develop -c zinc build` / `nix develop -c zinc test` (wrap in `nix develop -c`; Bash `timeout: 600000`). **Always `zinc test` before reading `.zinc/build/spec`** (otherwise the binary is stale).
2. **Tests use `test/Harness.hs`** (`group`/`test`/`assertBool`/`assertEqual` msg-expected-actual), NOT hspec. Each spec module exports `tests :: [Test]`; `test/Spec.hs` aggregates with `++`.
3. **Test DB:** the thin `initdb`/`pg_ctl` harness in `test/Fixtures.hs` (`withTestDb`). Tables `users`/`posts`/`profiles` already exist (SP2).
4. **`zinc build` doesn't surface `-Wall`.** Verify clean via direct GHC against the built interfaces: `nix develop -c bash -lc 'cd "$PWD" && ghc -fno-code -Wall -fforce-recomp -package-db .zinc/pkgdb -i.zinc/lib <module.hs>'`.
5. **Relationship labels use `Rel a (name :: Symbol)`** (in `Manifest.Core.Query`), NOT `Column a t`. `#posts`/`#author` elaborate to `Rel a name`.
6. **HKD record literals** need `:: User`/`:: Post`/`:: Profile` annotations.
7. **`Db` does not derive `MonadFail`** — don't use `Just x <- ...` binds; use `mu <- ...; let x = maybe (error "...") id mu`.

Baseline: `main` at `8b333ee`, SP2 complete, 44/44 green on GHC 9.10.1.

---

## File Structure

| File | Change |
|---|---|
| `src/Manifest/Core/Relation.hs` | add `RelOne :: Entity c => ByteString -> RelSpec c` to the GADT; add `belongsTo` builder. |
| `src/Manifest/Relation.hs` | generalize `selectByFk` → `selectByKey`; add `colValueOf`; handle `RelOne` in `loadRel`. |
| `src/Manifest/Core/Sql.hs` | add `renderJoined` (the LEFT-JOIN SQL). |
| `src/Manifest/Relation/Loaded.hs` | `Strategy = Selectin \| Joined`; add `joined` builder; `joinedLoad`/`joinReverse`/`joinForward`/`decodeJoinRows`; `with` dispatches on strategy. |
| `src/Manifest.hs` | re-export `joined`. |
| `test/Fixtures.hs` | add `HasRelation Post "author"` (One, `belongsTo (Proxy @"postAuthor")`). |
| `test/RelationSpec.hs` | belongs-to A-path tests. |
| `test/SqlSpec.hs` | `renderJoined` pure tests. |
| `test/JoinedSpec.hs` | `joined` strategy tests (Many/Opt/One, LEFT JOIN in log, NULL handling). |
| `test/RelE2ESpec.hs` | extend the capstone with belongs-to + joined. |

---

### Task 1: belongs-to — `RelOne` + the `One` cardinality (selectin)

Forward-FK: `load #author post` loads the `User` whose PK equals `post.post_author`.

**Files:** Modify `src/Manifest/Core/Relation.hs`, `src/Manifest/Relation.hs`, `test/Fixtures.hs`, `test/RelationSpec.hs`.

- [ ] **Step 1: Add `RelOne` + `belongsTo` to `Core/Relation.hs`**

In the `RelSpec` GADT add:
```haskell
  RelOne  :: Entity c => ByteString -> RelSpec c   -- forward FK: target.pk = self.<fk>
```
Add the builder (the FK is a column on SELF, holding the target's PK):
```haskell
-- | @belongsTo #selfFk@ — a to-one whose target is the row with
-- @target.pk = self.<selfFk>@ (a forward foreign key on the owning entity).
belongsTo :: forall c fk. (Entity c, KnownSymbol fk) => Proxy fk -> RelSpec c
belongsTo _ = RelOne (camelToSnake (symbolVal (Proxy @fk)))
```
Export `belongsTo`.

- [ ] **Step 2: Generalize the executor + handle `RelOne` in `Relation.hs`**

Replace `selectByFk` with a key-generic version and add `colValueOf`; extend `loadRel`:
```haskell
-- | @SELECT <child cols> FROM <child> WHERE <keyCol> = $1@, decoding + registering
-- each child in the identity map. Shared by every cardinality's selectin loader.
selectByKey :: forall c. Entity c => ByteString -> SqlParam -> Db [c]
selectByKey keyCol keyVal = do
  let tm  = tableMeta @c
      sql = renderSelect tm [Cond keyCol OpEq keyVal]
  rows <- execDb sql [keyVal]
  mapM (\row -> do child <- decodeRowDb @c row; setBaseline child; pure child) rows

-- | The encoded value of column @col@ on @parent@ (looked up by name in tableMeta).
colValueOf :: forall a. Entity a => ByteString -> a -> SqlParam
colValueOf col parent =
  case [v | (c, v) <- zip (tmColumns (tableMeta @a)) (rowEncode parent), cmName c == col] of
    (v : _) -> v
    []      -> error ("Manifest: column " <> show col <> " not found on entity")

loadRel :: forall a name. (HasRelation a name) => a -> Db (Target a name)
loadRel parent = case relSpec @a @name of
  RelMany childFk -> selectByKey childFk (pkParam parent)
  RelOpt  childFk -> listToMaybe <$> selectByKey childFk (pkParam parent)
  RelOne  selfFk  -> do
    let targetPkCol = cmName (pkColumn (tableMeta `forTarget` relSpec @a @name))
    one <- selectByKey targetPkCol (colValueOf @a selfFk parent)
    case one of
      (x : _) -> pure x
      []      -> liftIO (throwIO (DbException (OtherError "belongs-to: target row missing")))
```

> The `RelOne` branch needs the TARGET's PK column name and the target's `Entity` dict. Pull both from the GADT match: in `case relSpec @a @name of RelOne selfFk -> ...`, the constructor brings `Entity c` and `Target a name ~ c` into scope, so `tableMeta @c`/`pkColumn`/`decodeRowDb @c` work and the returned `x :: c` matches `Target a name`. Drop the `forTarget` pseudo-helper above — instead write it inline within the matched branch:
> ```haskell
>   RelOne selfFk -> do
>     let targetPkCol = cmName (pkColumn (tableMeta @c))   -- c is in scope from the GADT match
>     one <- selectByKey @c targetPkCol (colValueOf @a selfFk parent)
>     case one of
>       (x : _) -> pure x
>       []      -> liftIO (throwIO (DbException (OtherError "belongs-to: target row missing")))
> ```
> Add imports: `Control.Exception (throwIO)`, `Control.Monad.IO.Class (liftIO)`, `Manifest.Error (DbError(OtherError), DbException(..))`, and `Manifest.Core.Meta (pkColumn)`. Keep `selectByKey`'s old callers working (RelMany/RelOpt). `RelMany`/`RelOpt`/`RelOne` all bind a fresh `c` via the GADT, so the per-branch `@c` is unambiguous.

- [ ] **Step 3: Add the belongs-to relationship to Fixtures**

In `test/Fixtures.hs`, add (the `posts` table already has `post_author`):
```haskell
instance HasRelation Post "author" where
  type Target      Post "author" = User
  type Cardinality Post "author" = 'One
  relSpec = belongsTo (Proxy @"postAuthor")
```
Import `belongsTo` from `Manifest.Core.Relation`.

- [ ] **Step 4: Tests (append to `test/RelationSpec.hs`)**

```haskell
  , test "relSpec for Post \"author\" is RelOne on post_author" $
      case relSpec @Post @"author" of
        RelOne fk -> assertEqual "fk" "post_author" fk
        _         -> assertBool "expected RelOne" False
  , test "load #author returns the post's author (belongs-to)" $
      withTestDb $ \pool -> do
        nm <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          p <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          a <- load #author p
          pure (userName a)
        assertEqual "author name" "Ada" nm
```
(`relSpec @Post @"author"` needs `RelOne(..)` in scope — already imported via `RelSpec(..)`. `load #author p` returns `Db User`.)

- [ ] **Step 5: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `46/46 tests passed`. `-Wall`-clean on `Core/Relation.hs` + `Relation.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp2.5): belongs-to (One cardinality) — RelOne + belongsTo + forward-FK loader

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `renderJoined` — the LEFT-JOIN SQL (pure)

**Files:** Modify `src/Manifest/Core/Sql.hs`, `test/SqlSpec.hs`.

- [ ] **Step 1: Add `renderJoined` to `Core/Sql.hs`**

```haskell
-- | A single LEFT JOIN that selects only the CHILD/target columns (qualified),
-- for loading one entity's relation. The owning row is pinned by its PK.
--
--   SELECT <child>.<c1>, <child>.<c2>, ...
--   FROM <self> LEFT JOIN <child> ON <child>.<onChild> = <self>.<onSelf>
--   WHERE <self>.<selfPk> = $1
renderJoined
  :: ByteString    -- ^ self (owning) table
  -> ByteString    -- ^ self PK column (the WHERE pin)
  -> ByteString    -- ^ child/target table
  -> [ByteString]  -- ^ child/target column names (in tableMeta order)
  -> ByteString    -- ^ join: child-side column
  -> ByteString    -- ^ join: self-side column
  -> ByteString
renderJoined selfT selfPk childT childCols onChild onSelf =
  "SELECT " <> bcIntercalate ", " [childT <> "." <> c | c <- childCols]
    <> " FROM " <> selfT
    <> " LEFT JOIN " <> childT
    <> " ON " <> childT <> "." <> onChild <> " = " <> selfT <> "." <> onSelf
    <> " WHERE " <> selfT <> "." <> selfPk <> " = $1"
```
Export `renderJoined`. (`bcIntercalate` already exists in `Core/Sql.hs`.)

- [ ] **Step 2: Pure tests (append to `test/SqlSpec.hs`)**

```haskell
  , test "renderJoined (reverse FK: User has-many Posts)" $
      assertEqual "join"
        "SELECT posts.post_id, posts.post_author, posts.post_title \
        \FROM users LEFT JOIN posts ON posts.post_author = users.user_id \
        \WHERE users.user_id = $1"
        (renderJoined "users" "user_id" "posts"
           ["post_id", "post_author", "post_title"] "post_author" "user_id")
  , test "renderJoined (forward FK: Post belongs-to User)" $
      assertEqual "join"
        "SELECT users.user_id, users.user_name, users.user_email \
        \FROM posts LEFT JOIN users ON users.user_id = posts.post_author \
        \WHERE posts.post_id = $1"
        (renderJoined "posts" "post_id" "users"
           ["user_id", "user_name", "user_email"] "user_id" "post_author")
```
(Import `renderJoined`. Mind the exact spacing — assertions are byte-exact.)

- [ ] **Step 3: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `48/48 tests passed`. `-Wall`-clean on `Core/Sql.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp2.5): renderJoined — LEFT JOIN SQL for the joined strategy

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: the `joined` strategy execution

`with (joined #posts) ent` loads via a single LEFT JOIN, NULL-aware. Covers all three cardinalities.

**Files:** Modify `src/Manifest/Relation/Loaded.hs`, `test/JoinedSpec.hs`.

- [ ] **Step 1: Extend `Relation/Loaded.hs` — `Strategy`, `joined`, `joinedLoad`, dispatch**

Change the strategy type + builder, and add the joined executor:
```haskell
-- | A loading strategy for relation @name@.
data Strategy (name :: Symbol) = Selectin | Joined

selectin :: Rel a name -> Strategy name
selectin _ = Selectin

joined :: Rel a name -> Strategy name
joined _ = Joined

with :: forall name a l.
        (HasRelation a name, KnownSymbol name, Typeable (Target a name))
     => Strategy name -> Ent l a -> Db (Ent (Insert name l) a)
with strat (Ent v rels) = do
  t <- case strat of
         Selectin -> loadRel  @a @name v
         Joined   -> joinedLoad @a @name v
  pure (Ent v (Map.insert (symbolVal (Proxy @name)) (toDyn t) rels))
```
Add `joinedLoad` (in `Manifest.Relation` is fine too, but keep it next to the strategy in `Loaded.hs`; it needs `execDb`/`setBaseline`/`decodeRowDb` from `Session` and `renderJoined` from `Core.Sql` and `pkParam`/`tableMeta`/`pkColumn`/`tmColumns`/`cmName`/`pkIndex`):
```haskell
joinedLoad :: forall a name. (HasRelation a name) => a -> Db (Target a name)
joinedLoad parent = case relSpec @a @name of
  RelMany childFk -> joinReverse @a @c childFk parent
  RelOpt  childFk -> listToMaybe <$> joinReverse @a @c childFk parent
  RelOne  selfFk  -> do
    rs <- joinForward @a @c selfFk parent
    case rs of
      (x : _) -> pure x
      []      -> liftIO (throwIO (DbException (OtherError "belongs-to (joined): target row missing")))

-- reverse FK: SELECT child cols FROM self LEFT JOIN child ON child.<fk> = self.<pk> WHERE self.<pk> = $1
joinReverse :: forall a c. (Entity a, Entity c) => ByteString -> a -> Db [c]
joinReverse childFk parent = do
  let selfTm = tableMeta @a; childTm = tableMeta @c
      sql = renderJoined (tmTable selfTm) (cmName (pkColumn selfTm))
                         (tmTable childTm) (map cmName (tmColumns childTm))
                         childFk (cmName (pkColumn selfTm))
  rows <- execDb sql [pkParam parent]
  decodeJoinRows @c rows

-- forward FK: SELECT target cols FROM self LEFT JOIN target ON target.<pk> = self.<fk> WHERE self.<pk> = $1
joinForward :: forall a c. (Entity a, Entity c) => ByteString -> a -> Db [c]
joinForward selfFk parent = do
  let selfTm = tableMeta @a; tgtTm = tableMeta @c
      sql = renderJoined (tmTable selfTm) (cmName (pkColumn selfTm))
                         (tmTable tgtTm) (map cmName (tmColumns tgtTm))
                         (cmName (pkColumn tgtTm)) selfFk
  rows <- execDb sql [pkParam parent]
  decodeJoinRows @c rows

-- decode child rows, skipping LEFT-JOIN misses (child PK column NULL); register each.
decodeJoinRows :: forall c. Entity c => [[SqlParam]] -> Db [c]
decodeJoinRows rows = do
  let pkIx = pkIndex @c
  fmap concat $ mapM (\row ->
    if (row !! pkIx) == Nothing
      then pure []
      else do child <- decodeRowDb @c row; setBaseline child; pure [child]) rows
```
Add the needed imports to `Loaded.hs`: `Control.Exception (throwIO)`, `Control.Monad.IO.Class (liftIO)`, `Data.Maybe (listToMaybe)`, `Manifest.Core.Meta (pkColumn, tmTable, tmColumns, cmName)`, `Manifest.Core.Sql (renderJoined)`, `Manifest.Entity (pkParam, pkIndex, tableMeta)`, `Manifest.Error (DbError(OtherError), DbException(..))`, `Manifest.Relation (loadRel)`, `Manifest.Session (execDb, setBaseline, decodeRowDb)`. Export `joined`.

> Each `case relSpec of` branch binds a fresh `c` with `Entity c` + `Target a name ~ [c]`/`Maybe c`/`c`; the `@c` applications resolve from that. `decodeJoinRows` returns `[c]`; `joinReverse`/`joinForward` are `[c]`; the cardinality wrappers (`id`/`listToMaybe`/`head`) match the branch's `Target`.

- [ ] **Step 2: Write `test/JoinedSpec.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module JoinedSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Fixtures (Post, PostT (..), Profile, ProfileT (..), User, UserT (..), withTestDb)
import Manifest.Relation.Loaded
import Manifest.Session
import Harness

stmts :: [(BC.ByteString, [Maybe BC.ByteString])] -> [String]
stmts = map (BC.unpack . fst)

tests :: [Test]
tests = group "Joined"
  [ test "joined #posts (Many) loads children via a LEFT JOIN" $
      withTestDb $ \pool -> do
        (titles, log') <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          e1 <- with (joined #posts) (manage u)
          l  <- statementLog
          pure (map postTitle (rel #posts e1), l)
        assertEqual "titles" ["P1", "P2"] titles
        assertBool "used a LEFT JOIN" (any ("LEFT JOIN" `isInfixOf`) (stmts log'))
  , test "joined #posts with no children yields [] (LEFT JOIN miss skipped)" $
      withTestDb $ \pool -> do
        ps <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          e1 <- with (joined #posts) (manage u)
          pure (rel #posts e1)
        assertEqual "no posts" ([] :: [Post]) (map postTitle ps)
  , test "joined #profile (Opt) loads Nothing/Just" $
      withTestDb $ \pool -> do
        (none, some) <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          e0 <- with (joined #profile) (manage u)
          _  <- add (Profile { profileId = 0, profileUser = userId u, profileBio = "hi" } :: Profile)
          e1 <- with (joined #profile) (manage u)
          pure (rel #profile e0, rel #profile e1)
        assertEqual "none" Nothing (fmap profileBio none)
        assertEqual "some" (Just "hi") (fmap profileBio some)
  , test "joined #author (One, belongs-to) loads the target via LEFT JOIN" $
      withTestDb $ \pool -> do
        (nm, log') <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          p  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          e1 <- with (joined #author) (manage p)
          l  <- statementLog
          pure (userName (rel #author e1), l)
        assertEqual "author" "Ada" nm
        assertBool "used a LEFT JOIN" (any ("LEFT JOIN" `isInfixOf`) (stmts log'))
  ]
```
Wire into `test/Spec.hs`: `import qualified JoinedSpec` and `++ JoinedSpec.tests`.

> `rel #posts e1` etc. require `Member "posts" '["posts"] User` — satisfied because `with` recorded it. `e0`/`e1` from `with (joined ...)` have the relation in the load-set so `rel` typechecks.

- [ ] **Step 3: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `52/52 tests passed`. `-Wall`-clean on `Relation/Loaded.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp2.5): joined LEFT-JOIN strategy (Many/Opt/One, NULL-aware) + with dispatch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: umbrella + end-to-end

**Files:** Modify `src/Manifest.hs`, `test/RelE2ESpec.hs`.

- [ ] **Step 1: Re-export `joined` from the umbrella**

In `src/Manifest.hs`, add `joined` to the D-path export group (alongside `selectin`/`with`/`rel`). Do NOT export `belongsTo`/`RelOne`/`joinedLoad` (declaration/internal). `load #author` works through the already-exported `load`.

- [ ] **Step 2: Extend the capstone `test/RelE2ESpec.hs`**

Add a test exercising all three new capabilities through `Manifest` only:
```haskell
  , test "belongs-to + joined through the public API" $
      withTestDb $ \pool -> do
        (authorName, joinedTitles, usedJoin) <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          p  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          a   <- load #author p                          -- belongs-to (A path, selectin)
          eu  <- with (joined #posts) (manage u)         -- joined strategy
          l   <- statementLog
          pure (userName a, map postTitle (rel #posts eu),
                any (isInfixOf "LEFT JOIN") (map (BC.unpack . fst) l))
        assertEqual "author" "Ada" authorName
        assertEqual "joined titles" ["P1", "P2"] joinedTitles
        assertBool "joined used a LEFT JOIN" usedJoin
```
(Add `import Data.List (isInfixOf)` if not present.)

- [ ] **Step 3: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `53/53 tests passed`. `-Wall`-clean library (`src/Manifest.hs`). Commit:
```bash
git add -A
git commit -m "feat(sp2.5): umbrella joined export + belongs-to/joined end-to-end

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Spec coverage check (self-review)

| Design § | Requirement | Where covered |
|---|---|---|
| §5.3 | `One → Author` cardinality (belongs-to / forward FK) | Task 1 (`RelOne`/`belongsTo`/`loadRel` forward case) |
| §5.4 | `joined` (single LEFT JOIN, decode nested) | Tasks 2 (SQL) + 3 (execution) |
| §5.4 | strategy choice via `with (joined #x)` | Task 3 (`Strategy = Selectin \| Joined`, dispatch) |
| §5.4 | joined "multiplies rows for collections" handled | Task 3 (`decodeJoinRows` per-row) |
| §5.5 | joined-loaded children are managed | Task 3 (`decodeJoinRows` calls `setBaseline`) |
| §5.4 | LEFT JOIN miss → no child (NULL) | Task 3 (`decodeJoinRows` skips child-PK-NULL rows; tested with a childless parent) |

**Type-consistency notes:** `Strategy name = Selectin | Joined`; `selectin`/`joined :: Rel a name -> Strategy name`; `with` dispatches `Selectin → loadRel`, `Joined → joinedLoad`. `RelSpec` now has `RelMany`/`RelOpt`/`RelOne`; `loadRel` and `joinedLoad` both case-split over all three. `selectByKey :: Entity c => ByteString -> SqlParam -> Db [c]` (renamed from `selectByFk`, same behavior for RelMany/RelOpt). `renderJoined` arg order: `selfT selfPk childT childCols onChild onSelf`.

**Deferred to SP2.6 (still out of scope):** one-level nested loading (`#posts ./ #comments`, needs a 3rd table + the `./` operator + depth-1 chaining); `onDelete` cascades (Cascade/SetNull/Restrict); save-cascade / delete-orphan; arbitrary-depth nesting; batched selectin IN-loading across many parents; named per-relation accessors (TH sugar).
