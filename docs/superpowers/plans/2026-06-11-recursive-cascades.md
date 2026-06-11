# Recursive Cascade Deletes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `delete` walks the whole cascade tree (Restrict anywhere aborts everything; Cascade/SetNull apply at depth), so deleting a `Run` no longer orphans the `Score`s under its `Output`s.

**Architecture:** `CascadeRule` grows `crChildPk` + a lazily-captured `crChildRules` (capturable because `cascade` already has `Entity c`). `flushDelete` keeps its two-pass all-or-nothing shape but each pass recurses, carrying a SQL *scope* — nested `IN` subqueries chained through the child PKs — with a visited-table path as the cycle guard. Recursive semantics are the default; no new API.

**Tech Stack:** GHC 9.10.1, zinc, Postgres via `Manifest.Testing.withEphemeralDb`, the in-repo `Harness` test framework (no hspec).

**Spec:** `docs/superpowers/specs/2026-06-11-recursive-cascades-design.md` · **Issue:** manifest-va2

**Repo facts (verified):** `restrictCheck`/`applyMutating` are NOT exported from `Manifest.Session` — free to reshape. The only positional `CascadeRule` constructions/matches are `Manifest.Core.Relation.cascade`, two patterns in `Manifest.Session`, and one test in `test/CascadeSpec.hs:21`. No existing test deletes a parent whose children have grandchildren, so only that one test changes behaviorally. The suite is currently 140 tests; it ends at 144.

## File structure

- Modify `src/Manifest/Core/Cascade.hs` — the two new fields; hand-written `Eq`/`Show` (the rule tree can be infinite).
- Modify `src/Manifest/Core/Relation.hs` — `cascade` captures `crChildPk`/`crChildRules`.
- Modify `src/Manifest/Session.hs` — `flushDelete` + the recursive `restrictPass`/`mutatePass` (replacing `restrictCheck`/`applyMutating`).
- Modify `test/CascadeSpec.hs` — the rule-derivation test asserts fields instead of positional equality.
- Create `test/RecursiveCascadeSpec.hs` — self-contained fixture entities (Org→Team→{Member,Badge,Locker}, self-ref Node) + the four behaviour tests.
- Modify `test/Spec.hs` — wire in the new module.
- Modify `docs/tutorials/Tutorial/Cascades.lhs` — one sentence: cascades walk the whole tree.

---

### Task 1: CascadeRule grows child PK + child rules

**Files:**
- Modify: `src/Manifest/Core/Cascade.hs`
- Modify: `src/Manifest/Core/Relation.hs` (the `cascade` function, end of file)
- Modify: `src/Manifest/Session.hs:230-244` (two pattern arities only, this task)
- Test: `test/CascadeSpec.hs:19-22`

- [ ] **Step 1: Update the rule-derivation test to assert the new fields.** In `test/CascadeSpec.hs`, add `{-# LANGUAGE OverloadedStrings #-}` to the pragmas and replace the first test (lines 19–22):

```haskell
  [ test "cascade derives child table, FK column and child PK from the child + label" $ do
      let r = cascade (Proxy @Post) (Proxy @"postAuthor") Cascade
      assertEqual "child table" "posts" (crChildTable r)
      assertEqual "fk column" "post_author" (crFkColumn r)
      assertEqual "policy" Cascade (crPolicy r)
      assertEqual "child pk" "post_id" (crChildPk r)
      assertEqual "post has no child rules" 0 (length (crChildRules r))
```

- [ ] **Step 2: Run to verify failure.** Run: `nix develop -c zinc test 2>&1 | tail -5`. Expected: compile FAILURE — `crChildPk`/`crChildRules` not in scope.

- [ ] **Step 3: Extend `CascadeRule`.** Replace the record in `src/Manifest/Core/Cascade.hs` (and drop the derived instances):

```haskell
-- | A resolved cascade: the child table, the child FK column that references
-- the parent's PK, and the policy — plus what the recursive walk needs: the
-- child's own PK column (for scope subqueries) and the child's OWN cascade
-- rules, captured lazily. Built by 'Manifest.Core.Relation.cascade'.
--
-- 'crChildRules' is potentially INFINITE for self-referential or mutually
-- recursive entities — never force it whole. 'Eq'/'Show' are hand-written
-- over the finite fields for the same reason.
data CascadeRule = CascadeRule
  { crChildTable :: ByteString
  , crFkColumn   :: ByteString
  , crPolicy     :: OnDelete
  , crChildPk    :: ByteString
  , crChildRules :: [CascadeRule]
  }

instance Eq CascadeRule where
  a == b =
    (crChildTable a, crFkColumn a, crPolicy a, crChildPk a)
      == (crChildTable b, crFkColumn b, crPolicy b, crChildPk b)

instance Show CascadeRule where
  show r =
    "CascadeRule " <> show (crChildTable r) <> " " <> show (crFkColumn r)
      <> " " <> show (crPolicy r) <> " " <> show (crChildPk r) <> " <child rules>"
```

- [ ] **Step 4: Capture the fields in `cascade`.** In `src/Manifest/Core/Relation.hs`, extend the `Manifest.Core.Meta` import with `cmName` and `pkColumn`, the `Manifest.Entity` import with `cascadeRules`, and replace `cascade`:

```haskell
-- | Declare a cascade rule for a reverse-FK relation: the @Child@ rows whose
-- @selfFk@ column references this entity's PK get @policy@ on delete. Derives
-- the child table + PK from @Entity Child@, the FK column name from the label,
-- and captures the child's own rules (lazily) so deletes recurse.
cascade :: forall c fk. (Entity c, KnownSymbol fk)
        => Proxy c -> Proxy fk -> OnDelete -> CascadeRule
cascade _ _ policy = CascadeRule
  { crChildTable = tmTable tm
  , crFkColumn   = camelToSnake (symbolVal (Proxy @fk))
  , crPolicy     = policy
  , crChildPk    = cmName (pkColumn tm)
  , crChildRules = cascadeRules @c
  }
  where tm = tableMeta @c
```

- [ ] **Step 5: Fix the two pattern arities in `Manifest.Session` (flat semantics unchanged this task).** `restrictCheck` and `applyMutating` match positionally; make them ignore the new fields:

```haskell
restrictCheck :: SqlParam -> CascadeRule -> Db ()
restrictCheck parent (CascadeRule childT fk _ _ _) = do
```

```haskell
applyMutating :: SqlParam -> CascadeRule -> Db ()
applyMutating parent (CascadeRule childT fk policy _ _) = case policy of
```

- [ ] **Step 6: Run to verify pass.** Run: `nix develop -c zinc test 2>&1 | tail -3`. Expected: `140/140 tests passed` (the rewritten rule test included).

- [ ] **Step 7: Commit.**

```bash
git add src/Manifest/Core/Cascade.hs src/Manifest/Core/Relation.hs src/Manifest/Session.hs test/CascadeSpec.hs
git commit -m "feat(cascade): CascadeRule carries the child PK + the child's own rules (lazily)"
```

---

### Task 2: the recursive-behaviour tests (failing)

**Files:**
- Create: `test/RecursiveCascadeSpec.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: Write the self-contained spec module.** Fixture chain: `Org →Cascade Team`, `Team →Cascade Member / →Restrict Badge / →SetNull Locker`, plus self-referential `Node →Cascade Node`. Create `test/RecursiveCascadeSpec.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Recursive (multi-level) cascade behaviour, on a dedicated fixture chain:
-- Org -Cascade-> Team -Cascade-> Member / -Restrict-> Badge / -SetNull-> Locker,
-- plus a self-referential Node -Cascade-> Node for the cycle guard.
module RecursiveCascadeSpec (tests) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import GHC.Generics (Generic)
import Data.Functor.Identity (Identity)

import Manifest.Core.Cascade (OnDelete (..))
import Manifest.Core.Meta (genericTableMeta)
import Manifest.Core.Query (Cond)
import Manifest.Core.Relation (cascade)
import Manifest.Core.Table (Field, Nullable, Pk)
import Manifest.Derive ()
import Manifest.Entity (Entity (..), Table (..))
import Manifest.Postgres (Pool, execText, withConnection)
import Manifest.Session
import Manifest.Testing (withEphemeralDb)
import Harness

-- Fixtures ------------------------------------------------------------------

data OrgT f = Org
  { orgId   :: Field f (Pk Int)
  , orgName :: Field f Text
  } deriving Generic
type Org = OrgT Identity

instance Entity Org where
  tableMeta    = genericTableMeta @OrgT "orgs"
  cascadeRules = [ cascade (Proxy @Team) (Proxy @"teamOrg") Cascade ]

data TeamT f = Team
  { teamId   :: Field f (Pk Int)
  , teamOrg  :: Field f Int
  , teamName :: Field f Text
  } deriving Generic
type Team = TeamT Identity

instance Entity Team where
  tableMeta    = genericTableMeta @TeamT "teams"
  cascadeRules =
    [ cascade (Proxy @Member) (Proxy @"memberTeam") Cascade
    , cascade (Proxy @Badge)  (Proxy @"badgeTeam")  Restrict
    , cascade (Proxy @Locker) (Proxy @"lockerTeam") SetNull
    ]

data MemberT f = Member
  { memberId   :: Field f (Pk Int)
  , memberTeam :: Field f Int
  , memberName :: Field f Text
  } deriving Generic
type Member = MemberT Identity
deriving via (Table "members" MemberT) instance Entity Member

data BadgeT f = Badge
  { badgeId    :: Field f (Pk Int)
  , badgeTeam  :: Field f Int
  , badgeLabel :: Field f Text
  } deriving Generic
type Badge = BadgeT Identity
deriving via (Table "badges" BadgeT) instance Entity Badge

data LockerT f = Locker
  { lockerId   :: Field f (Pk Int)
  , lockerTeam :: Field f (Nullable Int)
  , lockerCode :: Field f Text
  } deriving Generic
type Locker = LockerT Identity
deriving via (Table "lockers" LockerT) instance Entity Locker

-- Self-referential: a node cascades onto its own table (cycle guard target).
data NodeT f = Node
  { nodeId     :: Field f (Pk Int)
  , nodeParent :: Field f (Nullable Int)
  , nodeName   :: Field f Text
  } deriving Generic
type Node = NodeT Identity

instance Entity Node where
  tableMeta    = genericTableMeta @NodeT "nodes"
  cascadeRules = [ cascade (Proxy @Node) (Proxy @"nodeParent") Cascade ]

withRecDb :: (Pool -> IO a) -> IO a
withRecDb body = withEphemeralDb $ \pool -> do
  let ddls =
        [ "CREATE TABLE orgs    (org_id BIGSERIAL PRIMARY KEY, org_name TEXT NOT NULL)"
        , "CREATE TABLE teams   (team_id BIGSERIAL PRIMARY KEY, team_org BIGINT NOT NULL, team_name TEXT NOT NULL)"
        , "CREATE TABLE members (member_id BIGSERIAL PRIMARY KEY, member_team BIGINT NOT NULL, member_name TEXT NOT NULL)"
        , "CREATE TABLE badges  (badge_id BIGSERIAL PRIMARY KEY, badge_team BIGINT NOT NULL, badge_label TEXT NOT NULL)"
        , "CREATE TABLE lockers (locker_id BIGSERIAL PRIMARY KEY, locker_team BIGINT, locker_code TEXT NOT NULL)"
        , "CREATE TABLE nodes   (node_id BIGSERIAL PRIMARY KEY, node_parent BIGINT, node_name TEXT NOT NULL)"
        ]
  withConnection pool (\c -> mapM_ (\s -> execText c s []) ddls)
  body pool

-- | Seed one org with two teams and one member per team; no badges, no lockers.
seedOrg :: Db Org
seedOrg = do
  o  <- add (Org { orgId = 0, orgName = "Acme" } :: Org)
  t1 <- add (Team { teamId = 0, teamOrg = orgId o, teamName = "T1" } :: Team)
  t2 <- add (Team { teamId = 0, teamOrg = orgId o, teamName = "T2" } :: Team)
  _  <- add (Member { memberId = 0, memberTeam = teamId t1, memberName = "M1" } :: Member)
  _  <- add (Member { memberId = 0, memberTeam = teamId t2, memberName = "M2" } :: Member)
  pure o

countAll :: forall a. Entity a => Pool -> IO Int
countAll pool = withSession pool (length <$> selectWhere ([] :: [Cond a]))

-- Tests -----------------------------------------------------------------------

tests :: [Test]
tests = group "RecursiveCascade"
  [ test "Cascade recurses: deleting the org removes teams AND members" $
      withRecDb $ \pool -> do
        usedSubquery <- withSession pool $ do
          o <- seedOrg
          withTransaction $ delete o
          l <- statementLog
          let sqls = map (BC.unpack . fst) l
          pure (any (\s -> "DELETE FROM members" `isInfixOf` s
                        && "IN (SELECT" `isInfixOf` s) sqls)
        assertReturns "orgs gone"    0 (countAll @Org pool)
        assertReturns "teams gone"   0 (countAll @Team pool)
        assertReturns "members gone" 0 (countAll @Member pool)
        assertBool "member delete is scoped by an IN subquery" usedSubquery
  , test "Restrict at depth aborts the whole delete (nothing mutated)" $
      withRecDb $ \pool -> do
        res <- (try :: IO a -> IO (Either SomeException a)) $ withSession pool $ do
          o <- seedOrg
          ts <- selectWhere ([] :: [Cond Team])
          _ <- add (Badge { badgeId = 0, badgeTeam = teamId (head ts), badgeLabel = "B" } :: Badge)
          withTransaction $ delete o
        assertBool "delete was rejected" (either (const True) (const False) res)
        assertReturns "org survives"     1 (countAll @Org pool)
        assertReturns "teams survive"    2 (countAll @Team pool)
        assertReturns "members survive"  2 (countAll @Member pool)
        assertReturns "badge survives"   1 (countAll @Badge pool)
  , test "SetNull at depth nulls the FK; the row survives" $
      withRecDb $ \pool -> do
        fks <- withSession pool $ do
          o <- seedOrg
          ts <- selectWhere ([] :: [Cond Team])
          _ <- add (Locker { lockerId = 0, lockerTeam = Just (teamId (head ts)), lockerCode = "L1" } :: Locker)
          withTransaction $ delete o
          ls <- selectWhere ([] :: [Cond Locker])
          pure (map lockerTeam ls)
        assertEqual "locker survives, FK nulled" [Nothing] fks
  , test "cycle guard: self-ref cascades one level per edge and terminates" $
      withRecDb $ \pool -> do
        names <- withSession pool $ do
          r <- add (Node { nodeId = 0, nodeParent = Nothing, nodeName = "root" } :: Node)
          c <- add (Node { nodeId = 0, nodeParent = Just (nodeId r), nodeName = "child" } :: Node)
          _ <- add (Node { nodeId = 0, nodeParent = Just (nodeId c), nodeName = "grandchild" } :: Node)
          withTransaction $ delete r
          ns <- selectWhere ([] :: [Cond Node])
          pure (map nodeName ns)
        -- Documented limitation: one level per declared edge — the grandchild
        -- row survives (row-level recursion would need WITH RECURSIVE).
        assertEqual "only the grandchild remains" ["grandchild"] names
  ]
```

- [ ] **Step 2: Wire into `test/Spec.hs`.** Add `import qualified RecursiveCascadeSpec` and append `++ RecursiveCascadeSpec.tests` to the `runTests` list.

- [ ] **Step 3: Run to verify the right failures.** Run: `nix develop -c zinc test 2>&1 | tail -10`. Expected: **141/144** — `Cascade recurses` FAILS (members survive: the orphan bug), `Restrict at depth` FAILS (delete succeeds instead of aborting), `SetNull at depth` FAILS (locker FK untouched). `cycle guard` PASSES already (flat = one level too) — it locks the documented limitation, the other three prove the change.

- [ ] **Step 4: Commit the red tests.**

```bash
git add test/RecursiveCascadeSpec.hs test/Spec.hs
git commit -m "test(cascade): recursive-delete behaviour specs (red: orphan bug reproduced)"
```

---

### Task 3: the recursive walk in flushDelete

**Files:**
- Modify: `src/Manifest/Session.hs:213-244` (`flushDelete`, `restrictCheck`, `applyMutating`)

- [ ] **Step 1: Replace the flat pass with the scoped tree walk.** In `src/Manifest/Session.hs`, replace `flushDelete`, `restrictCheck`, and `applyMutating` with:

```haskell
-- | Emit a DELETE for the record, applying onDelete cascades first, and drop it
-- from the identity map. Cascades run in two passes over the WHOLE rule tree:
-- all reachable 'Restrict' checks first (aborting the delete if any child
-- exists anywhere in the tree, so nothing is partially mutated), then the
-- mutating policies, deepest-first ('Cascade' DELETE / 'SetNull' UPDATE).
flushDelete :: forall a. Entity a => a -> Db ()
flushDelete a = do
  let tm     = tableMeta @a
      parent = pkParam a
      rules  = cascadeRules @a
      path   = [tmTable tm]
  -- 1. all Restrict checks first (abort the whole delete if any child exists)
  restrictPass parent path Nothing rules
  -- 2. then the mutating policies, deepest-first
  mutatePass parent path Nothing rules
  -- 3. delete the parent
  _ <- execDb (renderDelete tm (cmName (pkColumn tm))) [parent]
  Db $ do
    sess <- ask
    liftIO $ modifyIORef' (sessIdentity sess) (Map.delete (identityKey a))

-- | The walk's scope: Nothing at the root (the rule's FK matches the deleted
-- PK, @$1@, directly); deeper, the enclosing rule's (table, pk, condition) —
-- the child FK must be IN the enclosing rule's selected rows.
type Enclosing = Maybe (ByteString, ByteString, ByteString)

-- | The WHERE condition selecting a rule's in-scope child rows.
ruleCond :: CascadeRule -> Enclosing -> ByteString
ruleCond r Nothing = crFkColumn r <> " = $1"
ruleCond r (Just (pTable, pPk, pCond)) =
  crFkColumn r <> " IN (SELECT " <> pPk <> " FROM " <> pTable <> " WHERE " <> pCond <> ")"

-- | Descend into a Cascade rule's children unless its table is already on the
-- path (cycle guard: one level per declared self/mutual edge).
descend :: SqlParam -> [ByteString] -> Enclosing -> CascadeRule
        -> (SqlParam -> [ByteString] -> Enclosing -> [CascadeRule] -> Db ()) -> Db ()
descend parent path enclosing r walk =
  unless (crChildTable r `elem` path) $
    walk parent (crChildTable r : path)
         (Just (crChildTable r, crChildPk r, ruleCond r enclosing))
         (crChildRules r)

-- | Pass 1: every 'Restrict' rule reachable through 'Cascade' edges, checked
-- before anything mutates. A hit aborts the whole delete.
restrictPass :: SqlParam -> [ByteString] -> Enclosing -> [CascadeRule] -> Db ()
restrictPass parent path enclosing = mapM_ check
  where
    check r = case crPolicy r of
      Restrict -> do
        rows <- execDb ("SELECT 1 FROM " <> crChildTable r <> " WHERE "
                          <> ruleCond r enclosing <> " LIMIT 1") [parent]
        unless (null rows) $
          liftIO (throwIO (DbException (OtherError
            ("onDelete Restrict: " <> show (crChildTable r) <> " still has children"))))
      Cascade  -> descend parent path enclosing r restrictPass
      SetNull  -> pure ()

-- | Pass 2: mutations, deepest-first. 'Cascade' recurses into the child's own
-- rules before deleting the child rows; 'SetNull' applies at its depth and
-- does not descend (those rows survive).
mutatePass :: SqlParam -> [ByteString] -> Enclosing -> [CascadeRule] -> Db ()
mutatePass parent path enclosing = mapM_ apply
  where
    apply r = case crPolicy r of
      Restrict -> pure ()  -- handled in restrictPass
      SetNull  -> void $ execDb ("UPDATE " <> crChildTable r <> " SET " <> crFkColumn r
                                   <> " = NULL WHERE " <> ruleCond r enclosing) [parent]
      Cascade  -> do
        descend parent path enclosing r mutatePass
        void $ execDb ("DELETE FROM " <> crChildTable r <> " WHERE "
                         <> ruleCond r enclosing) [parent]
```

(`throwIO`, `DbException`, `OtherError`, `void`, `unless`, `liftIO` are already imported/used in this module; no import changes expected. The `CascadeRule` positional patterns from Task 1 Step 5 disappear with `restrictCheck`/`applyMutating`.)

- [ ] **Step 2: Run to verify green.** Run: `nix develop -c zinc test 2>&1 | tail -4`. Expected: **144/144 tests passed** — the three red tests now pass; the existing CascadeSpec two-pass atomicity tests ("Restrict aborts BEFORE any Cascade mutates", autoflush variant) still pass; everything else untouched.

- [ ] **Step 3: Commit.**

```bash
git add src/Manifest/Session.hs
git commit -m "feat(cascade): deletes walk the whole rule tree (manifest-va2)

Restrict anywhere in the tree aborts the delete before any mutation;
Cascade/SetNull apply at depth via nested IN-subquery scopes; visited-table
path guards cycles (one level per declared self-edge)."
```

---

### Task 4: docs + issue + push

**Files:**
- Modify: `docs/tutorials/Tutorial/Cascades.lhs:110-112`

- [ ] **Step 1: Update the tutorial paragraph** (the prose right after the policy examples) to:

```
Declare the on-delete policy once, on the parent entity's `cascadeRules`, and the
session enforces it at flush — across the whole tree: `Cascade` removes the
children and recurses into THEIR cascade rules (grandchildren and deeper follow),
`SetNull` orphans them, `Restrict` blocks the delete from anywhere in the tree
before anything is mutated. You do not write the child `DELETE`s by hand.
```

- [ ] **Step 2: Full suite once more.** Run: `nix develop -c zinc test 2>&1 | tail -3`. Expected: `144/144 tests passed` (the tutorial is compiled as a test module — this validates the `.lhs` edit).

- [ ] **Step 3: Close the issue, commit, push.**

```bash
bd close manifest-va2 --reason "Deletes walk the whole cascade tree: Restrict anywhere aborts atomically; Cascade/SetNull apply at depth via nested IN-subquery scopes; cycle guard documented (one level per self-edge). Spec: docs/superpowers/specs/2026-06-11-recursive-cascades-design.md"
git add -A
git commit -m "docs(cascade): tutorial reflects recursive semantics; close manifest-va2"
git push 2>&1 | tail -1
```

**Follow-up (separate repo, NOT this plan):** in manifest-evals, after re-pinning manifest, update SchemaSpec scenario A's "cascades are single-level" comment + assert Run-delete removes Scores transitively.

---

## Self-Review

**1. Spec coverage:** §1 rule capture (fields, laziness, hand-written Eq/Show) → Task 1; §2 walk (scoped two passes, restrict-before-mutation, deepest-first, SetNull-no-descent, cycle guard seeded with the root table) → Task 3; §3 blast radius (only the three src files + the one positional test; helpers unexported) → Tasks 1/3; §4 tests 1–4 → Task 2 (three-level, restrict-at-depth atomicity, SetNull-at-depth, cycle guard), §4 test 5 (existing suite green, flat-semantics test updated deliberately) → Task 1 Step 1 + the 144/144 gates; the manifest-evals follow-up is flagged at the end of Task 4 as out-of-plan, matching the spec. §5 out-of-scope items appear in no task.

**2. Placeholder scan:** none — every code step has full code, every run step has a command + expected count.

**3. Type consistency:** `crChildTable/crFkColumn/crPolicy/crChildPk/crChildRules` match across Cascade.hs (Task 1), Relation.hs (Task 1), Session.hs (Task 3), CascadeSpec (Task 1), RecursiveCascadeSpec (Task 2 uses only the public `cascade`). `restrictPass`/`mutatePass`/`ruleCond`/`descend`/`Enclosing` are defined and used only in Task 3. The fixture field names in Task 2 (`teamOrg`→`team_org` etc.) match the DDL column names and the `genericTableMeta` camel→snake convention verified in Fixtures.hs.
