# Manifest Sub-project 2.6 — onDelete cascades + self-referential relations

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `onDelete` cascade policies (`Cascade`/`SetNull`/`Restrict`, honored at flush when a parent is deleted) and support **self-referential relations** (`Employee.manager → Employee`) by aliasing the two table references in `renderJoined`.

**Architecture:** A relationship's cascade behaviour is declared per owning entity via a new `Entity.cascadeRules :: [CascadeRule]` method (default `[]`, backward-compatible). Each `CascadeRule` carries (child table, child FK, policy), built by `cascade (Proxy @Child) (Proxy @"selfFkLabel") policy` (derives both from the `Entity` dict + label — no magic strings, no GADT change). `flushDelete` applies them BEFORE deleting the parent: all `Restrict` checks first (abort if any child exists), then `Cascade` (DELETE children) / `SetNull` (NULL the FK). Self-referential joins work once `renderJoined` aliases `self`/`rel` so a self-join (`employees LEFT JOIN employees`) is unambiguous.

**Tech Stack:** GHC 9.10.1 · zinc · the hand-rolled `test/Harness.hs` (no hspec). No new external deps.

---

## EXECUTION NOTES (carry over — apply everywhere)

1. **Build/test:** `nix develop -c zinc build` / `nix develop -c zinc test` (wrap in `nix develop -c`; Bash `timeout: 600000`). **Always `zinc test` before `.zinc/build/spec`** (staleness). `.zinc/build/spec` only runs green INSIDE `nix develop` (the RelationError golden test shells out to `ghc`).
2. **Tests use `test/Harness.hs`** (`group`/`test`/`assertBool`/`assertEqual` msg-expected-actual), NOT hspec. Spec modules export `tests :: [Test]`; `test/Spec.hs` aggregates with `++`.
3. **Test DB:** the thin `initdb`/`pg_ctl` harness in `test/Fixtures.hs` (`withTestDb`); extend its DDL list for new/changed tables.
4. **`-Wall` not surfaced by zinc.** Verify via direct GHC against built interfaces, WITH the lib extensions: `nix develop -c bash -lc 'cd "$PWD" && ghc -fno-code -Wall -fforce-recomp -package-db .zinc/pkgdb -i.zinc/lib -XOverloadedStrings -XScopedTypeVariables -XTypeApplications -XLambdaCase -XTupleSections <module.hs>'` (plus the module's own pragmas).
5. **GADT existential gotcha:** a `c` bound by `case relSpec of RelMany … ->` is NOT nameable as `@c`; hoist into a top-level `forall a c` helper. (Not needed here — `cascade` names the child via `Proxy @Child`.)
6. HKD record literals need `:: User`/`:: Post`/etc. `Db` has no `MonadFail`. Relationship labels are `Rel a name`. Column names: camelCase→snake_case, no prefix stripping.

Baseline: `main` at `6c7c4ff`, SP2.5 complete, 53/53 green on GHC 9.10.1.

---

## File Structure

| File | Change |
|---|---|
| `src/Manifest/Core/Cascade.hs` | NEW — `OnDelete(..)`, `CascadeRule(..)` (pure data; no Entity dep, breaks the import cycle). |
| `src/Manifest/Entity.hs` | add `cascadeRules :: [CascadeRule]` to `Entity` (default `[]`); import `Manifest.Core.Cascade`. |
| `src/Manifest/Core/Relation.hs` | add the `cascade` builder (`Proxy c -> Proxy fk -> OnDelete -> CascadeRule`). |
| `src/Manifest/Session.hs` | `flushDelete` applies `cascadeRules @a` (Restrict-pass then mutate-pass) before the parent DELETE. |
| `src/Manifest/Core/Sql.hs` | `renderJoined` aliases the two tables (`AS self_t` / `AS rel_t`) so self-joins are unambiguous. |
| `src/Manifest.hs` | re-export `OnDelete(..)`, `cascade`. |
| `test/Fixtures.hs` | make `profiles.profile_user` NULLABLE (for SetNull); add a `tags` table + `Entity Tag` (for Restrict); add `User`'s `cascadeRules`; add an `Employee` self-FK table + `Entity Employee` + self-ref `HasRelation` instances. |
| `test/CascadeSpec.hs` | NEW — Cascade/SetNull/Restrict at delete + the pure `cascade` builder test. |
| `test/SqlSpec.hs` | update the two `renderJoined` byte-exact tests to the aliased form. |
| `test/SelfRefSpec.hs` | NEW — self-referential selectin + joined. |
| `test/RelE2ESpec.hs` | extend with a cascade + self-ref capstone. |

---

### Task 1: Cascade types + `Entity.cascadeRules` + the `cascade` builder

**Files:** Create `src/Manifest/Core/Cascade.hs`; modify `src/Manifest/Entity.hs`, `src/Manifest/Core/Relation.hs`; create `test/CascadeSpec.hs`.

- [ ] **Step 1: `src/Manifest/Core/Cascade.hs`** (pure data — no Entity import, so Entity can import this)

```haskell
module Manifest.Core.Cascade
  ( OnDelete(..)
  , CascadeRule(..)
  ) where

import Data.ByteString (ByteString)

-- | What happens to a relation's children when the parent is deleted.
data OnDelete = Cascade | SetNull | Restrict
  deriving (Eq, Show)

-- | A resolved cascade: the child table, the child FK column that references
-- the parent's PK, and the policy. Built by 'Manifest.Core.Relation.cascade'.
data CascadeRule = CascadeRule
  { crChildTable :: ByteString
  , crFkColumn   :: ByteString
  , crPolicy     :: OnDelete
  } deriving (Eq, Show)
```

- [ ] **Step 2: add `cascadeRules` to `Entity`** (`src/Manifest/Entity.hs`)

Add `import Manifest.Core.Cascade (CascadeRule)`. In the `Entity` class, add a method WITH A DEFAULT (so existing instances are unaffected):
```haskell
  -- | onDelete cascade rules applied when a value of this type is deleted.
  -- Default: none. Override with the 'cascade' builder.
  cascadeRules :: [CascadeRule]
  cascadeRules = []
```
Export `cascadeRules` (add to the module export list). The default makes this backward-compatible: `Entity Post`/`Entity Profile` etc. keep compiling unchanged.

- [ ] **Step 3: the `cascade` builder** (`src/Manifest/Core/Relation.hs`)

Add `import Manifest.Core.Cascade (OnDelete, CascadeRule(..))`, `import Manifest.Core.Meta (tmTable)`, and:
```haskell
-- | Declare a cascade rule for a reverse-FK relation: the @Child@ rows whose
-- @selfFk@ column references this entity's PK get @policy@ on delete. Derives
-- the child table from @Entity Child@ and the FK column name from the label.
cascade :: forall c fk. (Entity c, KnownSymbol fk)
        => Proxy c -> Proxy fk -> OnDelete -> CascadeRule
cascade _ _ policy =
  CascadeRule (tmTable (tableMeta @c)) (camelToSnake (symbolVal (Proxy @fk))) policy
```
(`tableMeta`/`Entity` come from `Manifest.Entity` — already imported. `Proxy`/`KnownSymbol`/`symbolVal`/`camelToSnake` already in scope.) Export `cascade`.

- [ ] **Step 4: pure test** (`test/CascadeSpec.hs`)

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module CascadeSpec (tests) where

import Data.Proxy (Proxy (..))
import Fixtures (Post)
import Manifest.Core.Cascade (CascadeRule (..), OnDelete (..))
import Manifest.Core.Relation (cascade)
import Harness

tests :: [Test]
tests = group "Cascade"
  [ test "cascade derives the child table + FK column from the child + label" $
      assertEqual "rule"
        (CascadeRule "posts" "post_author" Cascade)
        (cascade (Proxy @Post) (Proxy @"postAuthor") Cascade)
  ]
```
Wire into `test/Spec.hs`: `import qualified CascadeSpec` and `++ CascadeSpec.tests`. (The delete-behaviour tests come in Task 2.)

- [ ] **Step 5: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `54/54 tests passed`. `-Wall`-clean on `Core/Cascade.hs`, `Entity.hs`, `Core/Relation.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp2.6): OnDelete/CascadeRule + Entity.cascadeRules + cascade builder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `flushDelete` applies cascades

**Files:** Modify `src/Manifest/Session.hs`, `test/Fixtures.hs`; create `test/CascadeSpec.hs` delete tests (append).

- [ ] **Step 1: Fixtures — nullable profile FK, a `tags` table, and `User`'s `cascadeRules`**

In `test/Fixtures.hs`:
- Change the `profiles` DDL: `profile_user BIGINT` (drop `NOT NULL`) so `SetNull` can null it. (Existing profile tests still pass — they always set it.)
- Add a `tags` table + `Entity Tag` (for the Restrict policy):
```haskell
data TagT f = Tag
  { tagId    :: Col f (PrimaryKey (Serial Int))
  , tagUser  :: Col f Int
  , tagLabel :: Col f Text
  } deriving Generic
type Tag = TagT Identity

instance Entity Tag where
  type PrimKey Tag = Int
  tableMeta  = genericTableMeta @TagT "tags"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = tagId
```
with DDL `tagsDDL = "CREATE TABLE tags ( tag_id BIGSERIAL PRIMARY KEY, tag_user BIGINT NOT NULL, tag_label TEXT NOT NULL )"`, wired into `withTestDb`'s DDL list. Export `TagT(..)`, `Tag`, `tagsDDL`.
- Add `User`'s cascade rules to the `Entity User` instance (import `cascade` from `Manifest.Core.Relation`, `OnDelete(..)` from `Manifest.Core.Cascade`, `Proxy` from `Data.Proxy`):
```haskell
  cascadeRules =
    [ cascade (Proxy @Post)    (Proxy @"postAuthor")  Cascade
    , cascade (Proxy @Profile) (Proxy @"profileUser") SetNull
    , cascade (Proxy @Tag)     (Proxy @"tagUser")     Restrict
    ]
```

- [ ] **Step 2: `flushDelete` applies cascades** (`src/Manifest/Session.hs`)

Add `import Manifest.Core.Cascade (OnDelete(..), CascadeRule(..))` and `import Control.Monad (void, unless)`. Replace `flushDelete` so it runs cascades (Restrict checks first, then mutating policies) before the parent DELETE:
```haskell
flushDelete :: forall a. Entity a => a -> Db ()
flushDelete a = do
  let tm     = tableMeta @a
      parent = pkParam a
      rules  = cascadeRules @a
  -- 1. all Restrict checks first (abort the whole delete if any child exists)
  mapM_ (restrictCheck parent) [r | r <- rules, crPolicy r == Restrict]
  -- 2. then the mutating policies
  mapM_ (applyMutating parent) [r | r <- rules, crPolicy r /= Restrict]
  -- 3. delete the parent (unchanged from SP1)
  _ <- execDb (renderDelete tm (cmName (pkColumn tm))) [parent]
  Db $ do
    sess <- ask
    liftIO $ modifyIORef' (sessIdentity sess) (Map.delete (identityKey a))

restrictCheck :: SqlParam -> CascadeRule -> Db ()
restrictCheck parent (CascadeRule childT fk _) = do
  rows <- execDb ("SELECT 1 FROM " <> childT <> " WHERE " <> fk <> " = $1 LIMIT 1") [parent]
  unless (null rows) $
    liftIO (throwIO (DbException (OtherError ("onDelete Restrict: " <> show childT <> " still has children"))))

applyMutating :: SqlParam -> CascadeRule -> Db ()
applyMutating parent (CascadeRule childT fk policy) = case policy of
  Cascade  -> void $ execDb ("DELETE FROM " <> childT <> " WHERE " <> fk <> " = $1") [parent]
  SetNull  -> void $ execDb ("UPDATE " <> childT <> " SET " <> fk <> " = NULL WHERE " <> fk <> " = $1") [parent]
  Restrict -> pure ()  -- handled in restrictCheck
```
(`liftIO`/`throwIO`/`DbException`/`OtherError` are already imported in Session for `withTransaction`/`add`; if not, add them.)

> MVP scope: cascade emits SQL only — it does not recurse (one level) and does not prune cascaded children from the in-memory identity map. Both are acknowledged follow-ups.

- [ ] **Step 3: delete-behaviour tests** (append to `test/CascadeSpec.hs`)

Add imports (`OverloadedLabels`, `Fixtures`, `Manifest.Session`, `Manifest.Entity (Key(..))`, `Control.Exception (try, SomeException)`, `qualified Data.ByteString.Char8 as BC`). Append:
```haskell
  , test "Cascade deletes the children" $
      withTestDb $ \pool -> do
        n <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          withTransaction $ delete u
          ps <- selectWhere ([] :: [Cond Post])
          pure (length ps)
        assertEqual "posts cascaded away" 0 n
  , test "SetNull nulls the child FK" $
      withTestDb $ \pool -> do
        bios <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Profile { profileId = 0, profileUser = userId u, profileBio = "hi" } :: Profile)
          withTransaction $ delete u
          ps <- selectWhere ([] :: [Cond Profile])
          pure (map profileBio ps)               -- profile row survives, FK nulled
        assertEqual "profile kept" ["hi"] bios
  , test "Restrict aborts the delete when children exist" $
      withTestDb $ \pool -> do
        (res, remaining) <- withTestDbBody pool
        assertBool "delete was rejected" (either (const True) (const False) res)
        assertEqual "user still there" 1 remaining
  ]
  where
    withTestDbBody pool = do
      res <- (try :: IO a -> IO (Either SomeException a)) $ withSession pool $ do
        u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
        _ <- add (Tag { tagId = 0, tagUser = userId u, tagLabel = "vip" } :: Tag)
        withTransaction $ delete u
      remaining <- withSession pool (length <$> selectWhere ([] :: [Cond User]))
      pure (res, remaining)
```
(Import `Cond` from `Manifest.Core.Query`, `Tag`/`TagT(..)` from `Fixtures`. The Restrict test relies on `withTransaction` rolling back the aborted delete so the user survives — but note `add` is eager, so the user INSERT is autocommitted; the `delete` throwing inside `withTransaction` rolls back nothing-yet-deleted, and the user remains because the Restrict check threw before the parent DELETE. The user row persists from the eager add.)

> NOTE on the Restrict test: because `add` is eager (autocommit), the user is inserted before the transaction. The `delete` runs inside `withTransaction`; `restrictCheck` throws, the transaction ROLLBACKs (no parent DELETE happened), and a fresh `selectWhere` sees the user (count 1). Confirm this holds; if `add`'s eagerness makes the count assertion flaky, assert on the `try` result (delete rejected) alone.

- [ ] **Step 4: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `57/57 tests passed`. `-Wall`-clean on `Session.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp2.6): onDelete cascades at flush (Cascade/SetNull/Restrict)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `renderJoined` table aliases (enables self-joins)

**Files:** Modify `src/Manifest/Core/Sql.hs`, `test/SqlSpec.hs`.

- [ ] **Step 1: alias the two tables in `renderJoined`** (`src/Manifest/Core/Sql.hs`)

Rewrite the body to alias `self_t`/`rel_t` (so a self-join `employees AS self_t LEFT JOIN employees AS rel_t` is unambiguous). Columns are selected/joined via the aliases:
```haskell
renderJoined selfT selfPk childT childCols onChild onSelf =
  "SELECT " <> bcIntercalate ", " ["rel_t." <> c | c <- childCols]
    <> " FROM " <> selfT <> " AS self_t"
    <> " LEFT JOIN " <> childT <> " AS rel_t"
    <> " ON rel_t." <> onChild <> " = self_t." <> onSelf
    <> " WHERE self_t." <> selfPk <> " = $1"
```
(Signature unchanged.) `decodeJoinRows` uses column POSITION, not name, so aliasing the SELECT does not affect decoding.

- [ ] **Step 2: update the two byte-exact `renderJoined` tests** (`test/SqlSpec.hs`)

```haskell
  , test "renderJoined (reverse FK: User has-many Posts)" $
      assertEqual "join"
        "SELECT rel_t.post_id, rel_t.post_author, rel_t.post_title \
        \FROM users AS self_t LEFT JOIN posts AS rel_t \
        \ON rel_t.post_author = self_t.user_id WHERE self_t.user_id = $1"
        (renderJoined "users" "user_id" "posts"
           ["post_id", "post_author", "post_title"] "post_author" "user_id")
  , test "renderJoined (forward FK: Post belongs-to User)" $
      assertEqual "join"
        "SELECT rel_t.user_id, rel_t.user_name, rel_t.user_email \
        \FROM posts AS self_t LEFT JOIN users AS rel_t \
        \ON rel_t.user_id = self_t.post_author WHERE self_t.post_id = $1"
        (renderJoined "posts" "post_id" "users"
           ["user_id", "user_name", "user_email"] "user_id" "post_author")
```

- [ ] **Step 3: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `57/57 tests passed` (the existing JoinedSpec behaviour tests still pass — they assert titles + `LEFT JOIN` infix, both still true). `-Wall`-clean on `Core/Sql.hs`. Commit:
```bash
git add -A
git commit -m "feat(sp2.6): alias tables in renderJoined so self-joins are unambiguous

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: self-referential relations (`Employee.manager → Employee`)

**Files:** Modify `test/Fixtures.hs`; create `test/SelfRefSpec.hs`.

- [ ] **Step 1: Employee self-FK fixture** (`test/Fixtures.hs`)

```haskell
data EmployeeT f = Employee
  { employeeId      :: Col f (PrimaryKey (Serial Int))
  , employeeManager :: Col f (Maybe Int)   -- nullable self-FK → employee_id
  , employeeName    :: Col f Text
  } deriving Generic
type Employee = EmployeeT Identity

instance Entity Employee where
  type PrimKey Employee = Int
  tableMeta  = genericTableMeta @EmployeeT "employees"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = employeeId

-- forward FK (belongs-to self): the manager is the employee whose PK = self.employee_manager
instance HasRelation Employee "manager" where
  type Target      Employee "manager" = Maybe Employee   -- Opt: top of chain has no manager
  type Cardinality Employee "manager" = 'Opt
  relSpec = hasOpt (Proxy @"employeeId")  -- see note

-- reverse FK (has-many self): reports are employees whose employee_manager = self.PK
instance HasRelation Employee "reports" where
  type Target      Employee "reports" = [Employee]
  type Cardinality Employee "reports" = 'Many
  relSpec = hasMany (Proxy @"employeeManager")
```

> **Important nuance:** `"manager"` is a FORWARD FK (self.employee_manager → employee.id), which is the belongs-to shape. But belongs-to is the `One` cardinality via `belongsTo`; a nullable manager (top of the chain) is `Opt`. SP2's `RelOpt`/`hasOpt` is the REVERSE-FK shape (child.fk = parent.pk), which is wrong for a forward-FK manager. **Resolve this:** the cleanest is to model `"manager"` as belongs-to with `Opt` cardinality — but `belongsTo` currently produces `RelOne` (One). For this slice, model the self-ref via the two shapes we HAVE:
> - `"reports"` (reverse FK, Many) — `hasMany (Proxy @"employeeManager")` — works directly (employees whose `employee_manager = self.id`). This is the primary self-ref demonstration.
> - `"manager"` — to keep it in-shape, model it as `One` belongs-to (`belongsTo (Proxy @"employeeManager")`, Target `Employee`, Cardinality `One`) and ONLY test it on an employee whose manager is set (non-null). A nullable-manager (`Opt` forward-FK) is a genuine gap — `RelOpt` is reverse-FK only. **Add `RelOptOne` / forward-FK-Opt as an explicit SP2.7 follow-up; for SP2.6, `"manager"` is `One` (belongs-to) tested only with a set manager, and `"reports"` is `Many`.**
>
> So the fixture instances are:
> ```haskell
> instance HasRelation Employee "manager" where
>   type Target      Employee "manager" = Employee
>   type Cardinality Employee "manager" = 'One
>   relSpec = belongsTo (Proxy @"employeeManager")
> instance HasRelation Employee "reports" where
>   type Target      Employee "reports" = [Employee]
>   type Cardinality Employee "reports" = 'Many
>   relSpec = hasMany (Proxy @"employeeManager")
> ```
> Import `belongsTo`. DDL: `employeesDDL = "CREATE TABLE employees ( employee_id BIGSERIAL PRIMARY KEY, employee_manager BIGINT, employee_name TEXT NOT NULL )"` (manager nullable), wired into `withTestDb`. Export `EmployeeT(..)`, `Employee`, `employeesDDL`.

- [ ] **Step 2: self-ref tests** (`test/SelfRefSpec.hs`)

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module SelfRefSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Fixtures (Employee, EmployeeT (..), withTestDb)
import Manifest.Relation (load)
import Manifest.Relation.Loaded
import Manifest.Session
import Harness

stmts :: [(BC.ByteString, [Maybe BC.ByteString])] -> [String]
stmts = map (BC.unpack . fst)

tests :: [Test]
tests = group "SelfRef"
  [ test "load #reports (reverse self-FK) returns the manager's reports" $
      withTestDb $ \pool -> do
        names <- withSession pool $ do
          boss <- add (Employee { employeeId = 0, employeeManager = Nothing, employeeName = "Boss" } :: Employee)
          _    <- add (Employee { employeeId = 0, employeeManager = Just (employeeId boss), employeeName = "R1" } :: Employee)
          _    <- add (Employee { employeeId = 0, employeeManager = Just (employeeId boss), employeeName = "R2" } :: Employee)
          rs   <- load #reports boss
          pure (map employeeName rs)
        assertEqual "reports" ["R1", "R2"] names
  , test "joined #reports self-joins employees (aliased, unambiguous)" $
      withTestDb $ \pool -> do
        (names, usedJoin) <- withSession pool $ do
          boss <- add (Employee { employeeId = 0, employeeManager = Nothing, employeeName = "Boss" } :: Employee)
          _    <- add (Employee { employeeId = 0, employeeManager = Just (employeeId boss), employeeName = "R1" } :: Employee)
          e    <- with (joined #reports) (manage boss)
          l    <- statementLog
          pure (map employeeName (rel #reports e), any ("employees AS self_t" `isInfixOf`) (stmts l))
        assertEqual "reports" ["R1"] names
        assertBool "self-aliased join" usedJoin
  , test "load #manager (belongs-to self) returns the report's manager" $
      withTestDb $ \pool -> do
        nm <- withSession pool $ do
          boss <- add (Employee { employeeId = 0, employeeManager = Nothing, employeeName = "Boss" } :: Employee)
          r1   <- add (Employee { employeeId = 0, employeeManager = Just (employeeId boss), employeeName = "R1" } :: Employee)
          m    <- load #manager r1
          pure (employeeName m)
        assertEqual "manager" "Boss" nm
  ]
```
Wire into `test/Spec.hs`: `import qualified SelfRefSpec` and `++ SelfRefSpec.tests`.

- [ ] **Step 3: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `60/60 tests passed`. Commit:
```bash
git add -A
git commit -m "feat(sp2.6): self-referential relations (Employee manager/reports) via aliased joins

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: umbrella exports + end-to-end

**Files:** Modify `src/Manifest.hs`, `test/RelE2ESpec.hs`.

- [ ] **Step 1: re-export the cascade surface** (`src/Manifest.hs`)

Add `OnDelete(..)` (from `Manifest.Core.Cascade`) and `cascade` (from `Manifest.Core.Relation`) to the umbrella, plus `import Manifest.Core.Cascade`. (`cascadeRules` is an `Entity` method — already surfaced via `Entity(..)`.) Do NOT export `CascadeRule(..)` internals beyond what's needed (export it too if the e2e/user needs to pattern-match — but `cascade` + `OnDelete` suffice for declaration).

- [ ] **Step 2: capstone** (`test/RelE2ESpec.hs`)

Append a test through the `Manifest` umbrella only:
```haskell
  , test "cascade-on-delete through the public API" $
      withTestDb $ \pool -> do
        n <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          withTransaction $ delete u            -- User's cascadeRules cascade-delete posts
          length <$> selectWhere ([] :: [Cond Post])
        assertEqual "posts cascaded" 0 n
```
(`Cond` is already exported from the umbrella.)

- [ ] **Step 3: Run → fail → implement → pass → commit**

`nix develop -c .zinc/build/spec` → `61/61 tests passed`. `-Wall`-clean library (`src/Manifest.hs`). Commit:
```bash
git add -A
git commit -m "feat(sp2.6): umbrella cascade exports + cascade end-to-end

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Spec coverage check (self-review)

| Design § | Requirement | Where covered |
|---|---|---|
| §5.5 | per-relation `onDelete` policy (`Cascade`/`SetNull`/`Restrict`) honored at flush | Tasks 1–2 |
| §5.4 | self-referential relations loadable (joined) | Tasks 3–4 (aliased `renderJoined`) |
| §5.3 | cardinalities continue to work for self-ref | Task 4 (`reports` Many, `manager` One) |

**Deferred to SP2.7 (explicitly out of this slice):** one-level nested loading (`#posts ./ #comments`); recursive (multi-level) cascade; pruning cascaded children from the in-memory identity map; **forward-FK `Opt` (a nullable belongs-to, e.g. a nullable `manager` as `Maybe Employee`)** — SP2.6's `"manager"` is `One` (tested with a set manager); save-cascade / delete-orphan; arbitrary-depth nesting; the `cascade #relLabel policy` sugar (deriving table+FK from `relSpec` instead of `Proxy @Child`/`Proxy @"fk"`).

**Type-consistency notes:** `cascade :: Proxy c -> Proxy fk -> OnDelete -> CascadeRule`; `cascadeRules :: [CascadeRule]` (Entity method, default `[]`); `flushDelete` runs `restrictCheck` for all `Restrict` rules then `applyMutating` for the rest, then the parent DELETE. `renderJoined`'s signature is unchanged; only its output gains `AS self_t`/`AS rel_t` aliases (the two SqlSpec byte-exact tests updated to match). `OnDelete`/`CascadeRule` live in `Manifest.Core.Cascade` (imported by both `Entity` and `Core.Relation`, breaking the would-be cycle).
