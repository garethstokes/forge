# Manifest Sub-project 2 (core slice) — Relationships & `selectin` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add relationships to the Unit-of-Work — the explicit-load **A path** (`load #posts user :: Db [Post]`), the phantom-load-tracking **D path** (`Ent loaded a` + `with` + a total `rel` accessor whose "not loaded" failure is a written sentence), the **`selectin`** loading strategy, and UoW integration (loaded children become managed entities that flush through snapshot-diff).

**Architecture:** Relationships are NOT stored columns — they're declared via a `HasRelation a name` class (associated `Target`/`Cardinality` + a target-indexed `RelSpec` GADT). The A path loads + registers children in the identity map. The D path wraps a value in `Ent (loaded :: [Symbol]) a`, accumulates the load-set in the phantom via `with`, and reads relations through a `rel` accessor gated by a `Member name loaded` constraint that reduces to `GHC.TypeError.Unsatisfiable` (custom message) when the relation isn't loaded. Core slice covers cardinalities **Many** and **Opt** (uniform "FK-on-child references parent PK" loader); belongs-to/forward-FK (**One**), `joined`, nested loading, and cascades are SP2.5.

**Tech Stack:** **GHC 9.10.1** (bumped from 9.6.5 for `GHC.TypeError.Unsatisfiable`) · zinc (`zinc.toml`, `nix develop -c zinc build/test`) · Nix flake devShell (nixos-24.11) · `GHC.Generics`, `Data.Dynamic`, `GHC.TypeLits`/`GHC.TypeError` · `Data.Map` · `postgresql-libpq` · the hand-rolled `test/Harness.hs` (no hspec).

---

## EXECUTION NOTES (carry over from SP1 — apply everywhere)

1. **Build/test:** `nix develop -c zinc build` / `nix develop -c zinc test` (always wrap in `nix develop -c`; Bash `timeout: 600000`). `zinc test` prints only `N test suite(s) passed`; per-test detail: `nix develop -c .zinc/build/spec`.
2. **Tests use `test/Harness.hs`** (NOT hspec): `runTests`, `group`, `test :: String -> IO () -> Test`, `assertBool :: String -> Bool -> IO ()`, `assertEqual :: (Eq a,Show a) => String -> a -> a -> IO ()` (args `message expected actual`), `assertReturns`. Each spec module exports `tests :: [Test]`; `test/Spec.hs` aggregates with `++`.
3. **Test DB:** the thin `initdb`/`pg_ctl` harness in `test/Fixtures.hs` (`withTestDb`). Extend its DDL list to create the new tables.
4. **`zinc build`/`zinc test` do NOT surface `-Wall` warnings.** Confirm warning-cleanliness via direct GHC: `nix develop -c bash -lc 'cd "$PWD" && ghc -fno-code -Wall -isrc <module.hs>'` with the lib's extensions + the module's own pragmas.
5. **Higher-kinded record ambiguity:** because `Col` is a non-injective type family, a `UserT {...}` / `PostT {...}` record literal is ambiguous in `f`; annotate `:: User` / `:: Post` at construction sites (as SP1 did).
6. **Column naming:** camelCase→snake_case, no prefix stripping (`postAuthor` → `post_author`).

Baseline before starting: `main` at `c122e1c`, SP1 complete, 32/32 tests green on GHC 9.6.5.

---

## File Structure

| File | Responsibility |
|---|---|
| `flake.nix`, `zinc.toml` | (Task 1) bump GHC 9.6.5 → 9.10.1 (nixpkgs nixos-24.11, `ghc9101`). |
| `src/Manifest/Session.hs` | (Task 3) add `decodeRowDb` to the export list (relationships decode child rows). |
| `src/Manifest/Core/Relation.hs` | `Card` kind; `HasRelation` class (`Target`/`Cardinality`/`relSpec`); target-indexed `RelSpec` GADT; `hasMany`/`hasOpt` builders. |
| `src/Manifest/Relation.hs` | A path: `load`; `loadRel`/`selectByFk` (the `selectin` execution + identity-map registration). |
| `src/Manifest/Relation/Loaded.hs` | D path: `Ent`, `RelMap`, `manage`, `getEnt`, `Strategy`/`selectin`, `with`, `Insert`, `Member`/`NotLoaded` (`Unsatisfiable`), `rel`. |
| `src/Manifest.hs` | extend the umbrella with the relationship surface. |
| `test/Fixtures.hs` | add `PostT`/`Post`, `ProfileT`/`Profile`, their `Entity` instances, `postsDDL`/`profileDDL`, the `HasRelation` instances, and the multi-table `withTestDb`. |
| `test/RelationSpec.hs` | A-path tests (`load`, cardinality wrapping, managed children). |
| `test/EntSpec.hs` | D-path tests (`with`/`rel`/`manage`/`getEnt`, load-set accumulation). |
| `test/RelationErrorSpec.hs` | the golden test for the "not loaded" custom error (deferred-type-error). |
| `test/RelE2ESpec.hs` | end-to-end: load a child, mutate it, `save` → minimal `UPDATE` on the child table. |

---

### Task 1: Bump to GHC 9.10.1

The D path needs `GHC.TypeError.Unsatisfiable` (GHC 9.8+). Verified empirically that GHC 9.10.1 + `postgresql-libpq` build cleanly under zinc with nixos-24.11.

**Files:** Modify `flake.nix`, `zinc.toml`.

- [ ] **Step 1: Point the flake at nixos-24.11 / ghc9101**

In `flake.nix`: change `inputs.nixpkgs.url` to `github:NixOS/nixpkgs/nixos-24.11`, and the compiler `pkgs.haskell.compiler.ghc965` → `pkgs.haskell.compiler.ghc9101`. Keep `postgresql`, `pkg-config`, `zlib` and the `LIBRARY_PATH`/`LD_LIBRARY_PATH` shellHook unchanged.

- [ ] **Step 2: Set the zinc GHC version**

In `zinc.toml`, `[workspace]`: `ghc = "9.10.1"`.

- [ ] **Step 3: Re-resolve the dependency closure under 9.10 and verify SP1 still passes**

Run:
```bash
rm -f zinc.lock
nix develop -c zinc add postgresql-libpq --yes
nix develop -c zinc build
nix develop -c zinc test
nix develop -c .zinc/build/spec
```
Expected: `zinc add` re-pins `postgresql-libpq` + `postgresql-libpq-pkgconfig`; build green; `.zinc/build/spec` → `32/32 tests passed`. **If any SP1 module fails to compile under 9.10** (e.g. an overlapping-instance or generics nuance), fix it minimally and note it — the whole SP1 suite must be green on 9.10 before proceeding.

- [ ] **Step 4: Commit**

```bash
git add flake.nix zinc.toml zinc.lock
git commit -m "build(sp2): bump GHC 9.6.5 -> 9.10.1 (nixos-24.11) for Unsatisfiable

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Core.Relation` — metadata, `RelSpec`, builders + fixtures

The relationship declaration surface (pure types + a GADT), plus the second/third example tables and the `HasRelation` instances.

**Files:** Create `src/Manifest/Core/Relation.hs`; modify `test/Fixtures.hs`; create `test/RelationSpec.hs`.

- [ ] **Step 1: Write `src/Manifest/Core/Relation.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Manifest.Core.Relation
  ( Card(..)
  , HasRelation(..)
  , RelSpec(..)
  , hasMany
  , hasOpt
  ) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Proxy (Proxy(..))
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Manifest.Core.Meta (camelToSnake)
import Manifest.Entity (Entity)

-- | Relationship cardinality (promoted to a kind via DataKinds).
data Card = Many | One | Opt
  deriving (Eq, Show)

-- | A relationship named @name@ on entity @a@. SP2 core supports the
-- \"FK on the child references the parent's PK\" shape (Many and Opt).
class (Entity a, KnownSymbol name) => HasRelation a (name :: Symbol) where
  type Target      a name :: Type   -- ^ [Post] / Maybe Profile
  type Cardinality a name :: Card   -- ^ 'Many / 'Opt
  relSpec :: RelSpec (Target a name)

-- | A relationship's runtime spec, indexed by its target type so the loader
-- is type-safe. Each carries the child's 'Entity' dictionary and the child
-- column (the FK) that holds the parent's PK value.
data RelSpec t where
  RelMany :: Entity c => ByteString -> RelSpec [c]
  RelOpt  :: Entity c => ByteString -> RelSpec (Maybe c)

-- | @hasMany #childFk@ — a to-many relationship whose child rows are those
-- with @child_fk = parent_pk@. The child type comes from the 'Target'.
hasMany :: forall c fk. (Entity c, KnownSymbol fk) => Proxy fk -> RelSpec [c]
hasMany _ = RelMany (camelToSnake (symbolVal (Proxy @fk)))

-- | @hasOpt #childFk@ — an optional to-one whose child (if any) has
-- @child_fk = parent_pk@.
hasOpt :: forall c fk. (Entity c, KnownSymbol fk) => Proxy fk -> RelSpec (Maybe c)
hasOpt _ = RelOpt (camelToSnake (symbolVal (Proxy @fk)))
```

> Note: `hasMany`/`hasOpt` take a `Proxy fk` (the FK column-name Symbol). At a `HasRelation` instance you'll write `relSpec = hasMany (Proxy @"postAuthor")` — `OverloadedLabels` is for value-level column refs, but at the `relSpec` definition a `Proxy @"postAuthor"` is the clean way to pass the FK name. The child type `c` is fixed by the instance's `Target`.

- [ ] **Step 2: Add Post + Profile fixtures, Entity instances, DDLs, HasRelation instances**

In `test/Fixtures.hs`, add (keep `UserT`/`User`/`Entity User`/`withTestDb`):

```haskell
-- Posts: each belongs to a user via post_author = users.user_id (to-many from User).
data PostT f = Post
  { postId     :: Col f (PrimaryKey (Serial Int))
  , postAuthor :: Col f Int
  , postTitle  :: Col f Text
  } deriving Generic
type Post = PostT Identity

instance Entity Post where
  type PrimKey Post = Int
  tableMeta  = genericTableMeta @PostT "posts"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = postId

-- Profiles: optional one-per-user via profile_user = users.user_id.
data ProfileT f = Profile
  { profileId   :: Col f (PrimaryKey (Serial Int))
  , profileUser :: Col f Int
  , profileBio  :: Col f Text
  } deriving Generic
type Profile = ProfileT Identity

instance Entity Profile where
  type PrimKey Profile = Int
  tableMeta  = genericTableMeta @ProfileT "profiles"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = profileId

instance HasRelation User "posts" where
  type Target      User "posts" = [Post]
  type Cardinality User "posts" = 'Many
  relSpec = hasMany (Proxy @"postAuthor")

instance HasRelation User "profile" where
  type Target      User "profile" = Maybe Profile
  type Cardinality User "profile" = 'Opt
  relSpec = hasOpt (Proxy @"profileUser")
```

Add the imports: `Manifest.Core.Relation (Card(..), HasRelation(..), hasMany, hasOpt)`, `Data.Proxy (Proxy(..))`. Export `PostT(..)`, `Post`, `ProfileT(..)`, `Profile`, `postsDDL`, `profileDDL`.

Add the DDLs and wire them into `withTestDb`'s DDL list:
```haskell
postsDDL :: ByteString
postsDDL =
  "CREATE TABLE posts \
  \( post_id     BIGSERIAL PRIMARY KEY \
  \, post_author BIGINT NOT NULL \
  \, post_title  TEXT NOT NULL )"

profileDDL :: ByteString
profileDDL =
  "CREATE TABLE profiles \
  \( profile_id   BIGSERIAL PRIMARY KEY \
  \, profile_user BIGINT NOT NULL \
  \, profile_bio  TEXT NOT NULL )"
```
In `withTestDb`, change the schema creation to `mapM_ (\s -> execText c s []) [usersDDL, postsDDL, profileDDL]`.

- [ ] **Step 3: Write `test/RelationSpec.hs` (failing) — metadata reflects**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module RelationSpec (tests) where

import Data.Proxy (Proxy (..))
import Fixtures (User)
import Manifest.Core.Relation (RelSpec (..), relSpec)
import Harness

tests :: [Test]
tests = group "Relation"
  [ test "relSpec for User \"posts\" is RelMany on post_author" $
      case relSpec @User @"posts" of
        RelMany fk -> assertEqual "fk" "post_author" fk
        _          -> assertBool "expected RelMany" False
  , test "relSpec for User \"profile\" is RelOpt on profile_user" $
      case relSpec @User @"profile" of
        RelOpt fk -> assertEqual "fk" "profile_user" fk
        _         -> assertBool "expected RelOpt" False
  ]
```
Wire into `test/Spec.hs`: `import qualified RelationSpec` and `++ RelationSpec.tests`.

- [ ] **Step 4: Run → fail → implement → pass → commit**

Run `nix develop -c zinc test` (FAIL: `Manifest.Core.Relation` missing), implement Steps 1–2, then `nix develop -c .zinc/build/spec` → `34/34 tests passed`. Confirm `-Wall`-clean on `Core/Relation.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp2): HasRelation, RelSpec, hasMany/hasOpt + Post/Profile fixtures

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: A path — `load` + `selectin` + identity-map registration

`load #posts user :: Db [Post]`, executed as a separate `SELECT child WHERE fk = parent_pk`, with every loaded child entering the identity map (so a fetched `Post` is a managed Persistent entity).

**Files:** Modify `src/Manifest/Session.hs` (export `decodeRowDb`); create `src/Manifest/Relation.hs`; create the A-path tests in `test/RelationSpec.hs`.

- [ ] **Step 1: Export `decodeRowDb` from `Manifest.Session`**

In `src/Manifest/Session.hs`, add `decodeRowDb` to the module export list (it already exists as an internal helper `decodeRowDb :: forall a. Entity a => [SqlParam] -> Db a`). No other change.

- [ ] **Step 2: Write `src/Manifest/Relation.hs`**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Manifest.Relation
  ( load
  , loadRel
  ) where

import Data.Maybe (listToMaybe)
import Data.Proxy (Proxy(..))
import GHC.OverloadedLabels (IsLabel)
import GHC.TypeLits (KnownSymbol)
import Manifest.Core.Codec (SqlParam)
import Manifest.Core.Meta (TableMeta, tmColumns, cmName)
import Manifest.Core.Query (Column, Cond(..), Op(..))
import Manifest.Core.Relation (HasRelation(..), RelSpec(..))
import Manifest.Core.Sql (renderSelect)
import Manifest.Entity (Entity(..), pkParam)
import Manifest.Session (Db, decodeRowDb, execDb, setBaseline)

-- | Load relation @name@ off a bare value (the A path). Zero type-level
-- tracking; returns the plain 'Target' ([Post] / Maybe Profile).
load :: forall a name. (HasRelation a name) => Column a name -> a -> Db (Target a name)
load _ = loadRel @a @name

-- | The strategy execution shared by the A and D paths: run a separate SELECT
-- for the children (the @selectin@ strategy) and wrap by cardinality.
loadRel :: forall a name. (HasRelation a name) => a -> Db (Target a name)
loadRel parent = case relSpec @a @name of
  RelMany fk -> selectByFk fk (pkParam parent)
  RelOpt  fk -> listToMaybe <$> selectByFk fk (pkParam parent)

-- | @SELECT <child cols> FROM <child> WHERE <fk> = $1@, decoding each row and
-- registering it in the identity map (so loaded children are managed and flow
-- through snapshot-diff on a later 'Manifest.Session.save').
selectByFk :: forall c. Entity c => ByteString -> SqlParam -> Db [c]
selectByFk fkCol parentPk = do
  let tm  = tableMeta @c
      sql = renderSelect tm [Cond fkCol OpEq parentPk]
  rows <- execDb sql [parentPk]
  mapM (\row -> do child <- decodeRowDb @c row; setBaseline child; pure child) rows
```

> `load`'s first argument is a `Column a name` so it accepts `#posts` (the same `IsLabel`-built ref the query layer uses) and pins both `a` and `name`. `Column`/`IsLabel` come from `Manifest.Core.Query`. Import `Data.ByteString (ByteString)` for `selectByFk`. Drop any unused imports for `-Wall`.

- [ ] **Step 3: A-path tests (append to `test/RelationSpec.hs`)**

Add imports and a seed helper:
```haskell
{-# LANGUAGE OverloadedLabels #-}
import qualified Data.ByteString.Char8 as BC
import Fixtures (Post, PostT (..), Profile, ProfileT (..), User, UserT (..), withTestDb)
import Manifest.Entity (Key (..))
import Manifest.Postgres (Connection, execText, withConnection)
import Manifest.Relation (load)
import Manifest.Session
```
Append these tests:
```haskell
  , test "load #posts returns the user's posts (managed)" $
      withTestDb $ \pool -> do
        titles <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          ps <- load #posts u
          pure (map postTitle ps)
        assertEqual "titles" ["P1", "P2"] titles
  , test "load #profile returns Nothing when absent, Just when present" $
      withTestDb $ \pool -> do
        (none, some) <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          n <- load #profile u
          _ <- add (Profile { profileId = 0, profileUser = userId u, profileBio = "hi" } :: Profile)
          s <- load #profile u
          pure (fmap profileBio n, fmap profileBio s)
        assertEqual "none" Nothing none
        assertEqual "some" (Just "hi") some
  , test "a loaded child is managed: modify + save emits a minimal UPDATE" $
      withTestDb $ \pool -> do
        log' <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          [p] <- load #posts u
          withTransaction $ save (p { postTitle = "Edited" } :: Post)
          statementLog
        assertEqual "minimal child update"
          ["UPDATE posts SET post_title = $1 WHERE post_id = $2"]
          (filter (BC.isPrefixOf "UPDATE" . fst) log' >>= \(s,_) -> [BC.unpack s])
  ]
```

> The last test proves §5.5: the loaded `Post` entered the identity map (via `selectByFk`'s `setBaseline`), so editing it and `save`ing emits a minimal `UPDATE posts ...`. If `statementLog`'s element type makes the filter awkward, mirror SP1's `dataStmts` helper (`map (BC.unpack . fst)` then `filter (isPrefixOf "UPDATE")`).

- [ ] **Step 4: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `37/37 tests passed`. `-Wall`-clean on `Relation.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp2): A-path load + selectin + identity-map registration

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: D path — `Ent`, `with`, `manage`/`getEnt`, the load-set phantom

The opt-in wrapper that accumulates the load-set in a phantom `[Symbol]`. The total accessor + custom error come in Task 5.

**Files:** Create `src/Manifest/Relation/Loaded.hs`; create `test/EntSpec.hs`.

- [ ] **Step 1: Write the D-path core in `src/Manifest/Relation/Loaded.hs`** (accessor/Member added in Task 5)

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Manifest.Relation.Loaded
  ( Ent(..)
  , RelMap
  , manage
  , getEnt
  , Strategy
  , selectin
  , Insert
  , with
  ) where

import Data.Dynamic (Dynamic, toDyn)
import Data.Kind (Type)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Proxy (Proxy(..))
import Data.Typeable (Typeable)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Manifest.Core.Codec (ToField)
import Manifest.Core.Query (Column)
import Manifest.Core.Relation (HasRelation(..))
import Manifest.Entity (Entity, Key, PrimKey)
import Manifest.Relation (loadRel)
import Manifest.Session (Db, get)

-- | Loaded relations, type-erased, keyed by relation name.
type RelMap = Map String Dynamic

-- | A value plus a type-level record of which relations have been loaded onto
-- it. The phantom @loaded@ rides on this wrapper ONLY — never on the bare @a@.
data Ent (loaded :: [Symbol]) a = Ent
  { entVal  :: a
  , entRels :: RelMap
  }

-- | Wrap a bare persistent value with an empty load-set.
manage :: a -> Ent '[] a
manage v = Ent v Map.empty

-- | Load by PK into the D path (nothing loaded yet).
getEnt :: (Entity a, ToField (PrimKey a)) => Key a -> Db (Maybe (Ent '[] a))
getEnt k = fmap manage <$> get k

-- | A loading strategy for relation @name@. SP2 core has only @selectin@.
data Strategy (name :: Symbol) = Selectin

-- | The default (and only, in SP2 core) strategy: a separate SELECT.
selectin :: Column a name -> Strategy name
selectin _ = Selectin

-- | Add @name@ to the load-set (simple prepend; membership is all that matters).
type family Insert (name :: Symbol) (loaded :: [Symbol]) :: [Symbol] where
  Insert name loaded = name ': loaded

-- | Load relation @name@ onto an 'Ent', recording it in the load-set phantom.
with :: forall name a l.
        (HasRelation a name, KnownSymbol name, Typeable (Target a name))
     => Strategy name -> Ent l a -> Db (Ent (Insert name l) a)
with _ (Ent v rels) = do
  t <- loadRel @a @name v
  pure (Ent v (Map.insert (symbolVal (Proxy @name)) (toDyn t) rels))
```

> `Column a name` is `Manifest.Core.Query.Column`; `selectin #posts :: Strategy "posts"`. The result `Ent v (...) :: Ent (Insert name l) a` typechecks because `loaded` is phantom (not stored), so changing it is free.

- [ ] **Step 2: Write `test/EntSpec.hs` (failing)**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module EntSpec (tests) where

import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Fixtures (Post, PostT (..), User, UserT (..), withTestDb)
import Manifest.Entity (Key (..))
import Manifest.Relation.Loaded
import Manifest.Session
import Harness

tests :: [Test]
tests = group "Ent"
  [ test "manage wraps a value with an empty load-set" $
      withTestDb $ \pool -> do
        nm <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          pure (userName (entVal (manage u)))
        assertEqual "entVal" "Ada" nm
  , test "getEnt loads a persistent value with nothing loaded" $
      withTestDb $ \pool -> do
        present <- withTestDbSeedAndGet pool
        assertBool "got an Ent" present
  , test "with #posts records the relation in entRels" $
      withTestDb $ \pool -> do
        keys <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          e0 <- pure (manage u)
          e1 <- with (selectin #posts) e0
          pure (Map.keys (entRels e1))
        assertEqual "loaded key" ["posts"] keys
  ]
  where
    withTestDbSeedAndGet pool = withSession pool $ do
      u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
      me <- getEnt (Key (userId u) :: Key User)
      pure (isJust me)
```
Wire into `test/Spec.hs`: `import qualified EntSpec` and `++ EntSpec.tests`.

- [ ] **Step 3: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `40/40 tests passed`. `-Wall`-clean on `Relation/Loaded.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp2): D-path Ent + with + manage/getEnt + load-set phantom

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: The `rel` accessor + `Member`/`Unsatisfiable` + golden error test

The total accessor, gated by a membership constraint that prints a written sentence (not a type-list dump) when the relation isn't loaded.

**Files:** Modify `src/Manifest/Relation/Loaded.hs`; create `test/RelationErrorSpec.hs`.

- [ ] **Step 1: Add `Member`, `NotLoaded`, and `rel` to `src/Manifest/Relation/Loaded.hs`**

Add pragmas `{-# LANGUAGE UndecidableInstances #-}` and imports:
```haskell
import Data.Dynamic (fromDynamic)
import GHC.TypeError (Unsatisfiable, ErrorMessage(..))
import GHC.TypeLits (CmpSymbol)
import Data.Kind (Constraint)
```
Add to the export list: `Member`, `rel`. Then:
```haskell
-- | The custom message shown when reading a relation that isn't loaded.
type NotLoaded (name :: Symbol) (a :: Type) =
  'Text "Relation '" ':<>: 'Text name ':<>: 'Text "' is not loaded on this "
    ':<>: 'ShowType a ':<>: 'Text "."
  ':$$: 'Text "Add `with (selectin #" ':<>: 'Text name ':<>: 'Text ")`, "
    ':<>: 'Text "or call `load #" ':<>: 'Text name ':<>: 'Text " value` for the bare A-path."

-- | Holds iff @name@ is in the load-set; otherwise reduces to a custom
-- 'Unsatisfiable' constraint (membership-only; tracks Symbols, not types).
type Member :: Symbol -> [Symbol] -> Type -> Constraint
type family Member name loaded a where
  Member name '[]       a = Unsatisfiable (NotLoaded name a)
  Member name (x ': xs) a = MemberCmp (CmpSymbol name x) name xs a

type MemberCmp :: Ordering -> Symbol -> [Symbol] -> Type -> Constraint
type family MemberCmp o name xs a where
  MemberCmp 'EQ _    _  _ = ()
  MemberCmp _   name xs a = Member name xs a

-- | Read a loaded relation, totally. Only typechecks when @name@ is in the
-- load-set; the @Member@ constraint is the only user-visible failure surface.
rel :: forall name a loaded.
       ( HasRelation a name
       , Member name loaded a
       , Typeable (Target a name)
       )
    => Column a name -> Ent loaded a -> Target a name
rel _ (Ent _ rels) =
  case Map.lookup (symbolVal (Proxy @name)) rels >>= fromDynamic of
    Just t  -> t
    Nothing -> error "Manifest: internal invariant — Member held but relation absent in RelMap"
```

> The `Member name loaded a` carries the entity type `a` so the message reads "...on this User." `Unsatisfiable` (GHC 9.8+) makes any use of `rel #x ent` where `x ∉ loaded` fail with `NotLoaded`'s sentence. `CmpSymbol`/`MemberCmp` avoids non-linear type-family patterns. The runtime `error` is unreachable (a satisfied `Member` means `with` stored the relation).

- [ ] **Step 2: Add the happy-path accessor test to `test/EntSpec.hs`**

```haskell
  , test "rel #posts reads the loaded relation" $
      withTestDb $ \pool -> do
        titles <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          e1 <- with (selectin #posts) (manage u)
          pure (map postTitle (rel #posts e1))
        assertEqual "titles" ["P1"] titles
```
(Import `rel` from `Manifest.Relation.Loaded`.)

- [ ] **Step 3: Write the golden error test `test/RelationErrorSpec.hs`**

Reading an unloaded relation is a *type* error; we observe its message at runtime via `-fdefer-type-errors`:
```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fdefer-type-errors -Wno-deferred-type-errors #-}

module RelationErrorSpec (tests) where

import Control.Exception (TypeError(..), evaluate, try)
import Data.List (isInfixOf)
import Fixtures (User, UserT (..))
import Manifest.Relation.Loaded (manage, rel)
import Harness

tests :: [Test]
tests = group "RelationError"
  [ test "reading an unloaded relation yields the custom 'not loaded' message" $ do
      let u   = User { userId = 1, userName = "Ada", userEmail = Nothing } :: User
          ent = manage u                              -- Ent '[] User — nothing loaded
      r <- try (evaluate (length (rel #posts ent))) :: IO (Either TypeError Int)
      case r of
        Left (TypeError msg) -> do
          assertBool "names the relation"   ("posts" `isInfixOf` msg)
          assertBool "says not loaded"       ("is not loaded" `isInfixOf` msg)
          assertBool "suggests with selectin" ("with (selectin #posts)" `isInfixOf` msg)
        Right _ -> assertBool "expected a deferred type error, got a value" False
  ]
```
Wire into `test/Spec.hs`: `import qualified RelationErrorSpec` and `++ RelationErrorSpec.tests`.

> `rel #posts ent` with `ent :: Ent '[] User` makes `Member "posts" '[] User` reduce to `Unsatisfiable (NotLoaded ...)`; under `-fdefer-type-errors` GHC compiles it to a thunk that throws `Control.Exception.TypeError` (with the rendered message) when forced by `length`. This is mitigation #8 (golden-test the error output) realized as a runtime assertion, so a refactor that regresses the message fails the suite.

- [ ] **Step 4: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `42/42 tests passed` (the happy-path `rel` test + the golden error test). Note: `RelationErrorSpec` compiles WITH a deferred error by design; that's expected and `-Wno-deferred-type-errors` keeps it quiet. `-Wall`-clean on `Relation/Loaded.hs` (the production module — the test module's deferred error is intentional). Commit:
```bash
git add -A
git commit -m "feat(sp2): total rel accessor + Member/Unsatisfiable custom error + golden test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Umbrella export + relationships end-to-end

Surface the relationship API on `Manifest` and prove the worked example (both paths + a managed loaded child) through the public surface.

**Files:** Modify `src/Manifest.hs`; create `test/RelE2ESpec.hs`.

- [ ] **Step 1: Extend the `Manifest` umbrella**

In `src/Manifest.hs`, add re-exports:
```haskell
  -- * Relationships (A path)
  , load
  , HasRelation(..)
  , Card(..)
  -- * Relationships (D path)
  , Ent(..)
  , manage
  , getEnt
  , with
  , selectin
  , rel
  , Member
```
and the corresponding `import Manifest.Core.Relation`, `import Manifest.Relation`, `import Manifest.Relation.Loaded`. (Do NOT re-export `RelSpec`/`hasMany`/`hasOpt`/`loadRel`/`Strategy`/`Insert` — those are the declaration/internal surface, kept out of the public API for now; if the e2e test needs `Strategy`/`selectin` it gets `selectin` which is exported.)

- [ ] **Step 2: Write `test/RelE2ESpec.hs` — the capstone (imports only `Manifest` + `Fixtures` + `Harness`)**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module RelE2ESpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isPrefixOf)
import Fixtures (Post, PostT (..), User, UserT (..), withTestDb)
import Manifest
import Harness

upd :: [(BC.ByteString, [Maybe BC.ByteString])] -> [String]
upd = filter (isPrefixOf "UPDATE") . map (BC.unpack . fst)

tests :: [Test]
tests = group "RelE2E"
  [ test "load via A and D, edit a loaded child, save -> minimal child UPDATE" $
      withTestDb $ \pool -> do
        (aTitles, dTitles, log') <- withSession pool $ do
          u  <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          aps <- load #posts u                       -- A path
          e1  <- with (selectin #posts) (manage u)   -- D path
          let dps = rel #posts e1
          withTransaction $ save (head dps { postTitle = "Edited" } :: Post)  -- managed child
          l <- statementLog
          pure (map postTitle aps, map postTitle dps, l)
        assertEqual "A titles" ["P1", "P2"] aTitles
        assertEqual "D titles" ["P1", "P2"] dTitles
        assertEqual "minimal child update"
          ["UPDATE posts SET post_title = $1 WHERE post_id = $2"]
          (upd log')
  ]
```
Wire into `test/Spec.hs`: `import qualified RelE2ESpec` and `++ RelE2ESpec.tests`.

> If `head dps { postTitle = "Edited" }` parses as `head (dps { ... })`, parenthesize: `save ((head dps) { postTitle = "Edited" } :: Post)`.

- [ ] **Step 2.5: Run → fail → implement → pass**

`nix develop -c .zinc/build/spec` → `43/43 tests passed`. `-Wall`-clean library via direct GHC on `src/Manifest.hs`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(sp2): umbrella relationship exports + end-to-end worked example

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Spec coverage check (self-review)

| Design § | Requirement | Where covered |
|---|---|---|
| §5.1 | A path `load :: HasRelation a name => Label name -> a -> Db (Target a name)` | Task 3 |
| §5.1 | D path `Ent (loaded :: [Symbol]) a`, `with` accumulates, total accessor | Tasks 4, 5 |
| §5.1 | phantom on `Ent` only; bare `a`/`Db` never carry it | Task 4 (`loaded` is phantom, unstored) |
| §5.2 #1 | `Unsatisfiable` custom message on the accessor | Task 5 (`Member`/`NotLoaded`) — needs GHC 9.8+ → Task 1 |
| §5.2 #2,#3 | membership-only; track Symbols not types | Task 5 (`Member`/`CmpSymbol`) |
| §5.2 #4 | users never write the list (accumulated by `with`) | Task 4 (`Insert`) |
| §5.2 #5 | closed total type families | Task 5 (`Member`/`MemberCmp`) |
| §5.2 #6 | HasField-style accessor hides the constraint | Task 5 (`rel #name ent`) |
| §5.2 #8 | golden-test the error output | Task 5 (`RelationErrorSpec`, deferred-type-error) |
| §5.2 | drop-to-A: `load #posts (entVal u)` | Task 6 (both paths coexist; `entVal` exported) |
| §5.3 | `HasRelation` + `Target`/`Cardinality` + `relSpec` | Task 2 |
| §5.3 | cardinality → result type (`Many → [Post]`, `Opt → Maybe Profile`) | Task 2 (`RelSpec` GADT), Task 3 (wrapping) |
| §5.4 | `selectin` (separate SELECT, stitch) — the default | Task 3 (`selectByFk`) |
| §5.5 | loaded children enter the identity map (managed) | Task 3 (`setBaseline` per child), Tasks 3 & 6 (mutate+save→UPDATE) |

**Deferred to SP2.5 (explicitly out of this slice):** `joined` LEFT-JOIN strategy; one-level nested loading (`#posts ./ #comments`); belongs-to / forward-FK (the **One** cardinality, `RelOne`); `onDelete` cascades (Cascade/SetNull/Restrict); batched `selectin` IN-loading across many parents; named per-relation accessors (TH sugar). The `RelSpec` GADT intentionally omits `RelOne` in this slice — add it (and the belongs-to loader) in SP2.5.

**Type-consistency note:** `Member` takes three params `(name, loaded, a)` everywhere (Task 5); `with` returns `Ent (Insert name l) a` and `Insert name l = name ': l` (Task 4); `loadRel`/`load` return `Target a name` (Tasks 2–3). `selectin`/`load` both accept a `Column a name` (the `#label` ref). `RelSpec` is indexed by the target type (`RelSpec [c]` / `RelSpec (Maybe c)`).
