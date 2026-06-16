# Manifest RLS (manifest-yyb) — PostgreSQL Row-Level Security Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Manifest drive PostgreSQL Row-Level Security so multi-tenant access is enforced by the database. Three pieces: (1) a **typed policy DSL** annotating entities (`rlsPolicies` on `Entity`), (2) **declarative migration** of RLS (`ENABLE`/`FORCE ROW LEVEL SECURITY` + `CREATE`/`DROP POLICY`, reconciled against the live DB), and (3) a **pool-safe session context** (`withRlsContext`) that sets the GUC variables policies read.

**Architecture:** Policies are written on the entity with a typed predicate that reuses the query-builder expression DSL: `policy "org_isolation" \`using\` (\o -> o ^. #docOrg .== currentSetting "app.current_org")`. The predicate is rendered to SQL at construction and stored as a `PolicyDef` (entity-erased). The migration engine reflects `rlsPolicies` per entity, and reconciles the live policy set (`pg_policies`) and the RLS flags (`pg_class`) to match the declarations (create missing by name, drop extra by name, enable/force when not already set). `withRlsContext` issues `set_config(name, value, true)` (transaction-LOCAL, so a pooled connection cannot leak context).

**Module layering (avoids a cycle):**
- `Manifest.Core.Rls` (NEW, low): `PolicyDef`, `PolicyCmd`, `Policy a` (phantom newtype over `PolicyDef`), `policyDef`. Imports: bytestring/text only.
- `Manifest.Entity`: imports `Core.Rls`; gains `rlsPolicies :: [Policy a]` (default `[]`, like `cascadeRules`).
- `Manifest.Query`: additions only — `Self e` (bare-column projection), `currentSetting`, `lit`, `renderPredicate`.
- `Manifest.Rls` (NEW, high): imports `Query` + `Core.Rls`; the builders `policy`/`using`/`withCheck`/`forCommand`.
- `Manifest.Migrate`: imports `Entity`/`Core.Rls`; `ManagedTable` gains `mtPolicies`; RLS reconciliation; `MigrationPlan` gains `planRls`.
- `Manifest.Session`: adds `withRlsContext`.
This is acyclic: `Core.Rls` depends on nothing Manifest; `Entity → Core.Rls`; `Query → Entity` and `Query`'s new bits use only `Core.Query`/`Core.Codec`; `Rls → Query + Core.Rls`; `Migrate → Entity + Core.Rls`.

**Tech Stack:** GHC 9.10.1 via zinc. Existing `Manifest.Query` (`Expr`, `Projectable`/`(^.)`, `.==`/`.&&`, `Column`), `Manifest.Entity` (`Entity`, `cascadeRules` precedent), `Manifest.Migrate` (`ManagedTable`/`managed`/`migrate`/`migrateUp`/`liveColumns`/`MigrationPlan`), `Manifest.Session` (`Db`, `execDb`, `withTransaction`). Custom `test/Harness.hs`; `Fixtures.withTestDb`/`withEmptyDb`.

**Scope:** typed policy DSL + declarative policy/RLS migration (create/drop by name, enable/force) + `withRlsContext` (GUC) + an end-to-end tenant-isolation test. **Deferred (note in docs):** `SET ROLE`-based contexts (GUC only here), deep predicate diffing (policy bodies diff by name only — changing a body needs a rename or manual drop), per-role policies (`TO role`), and identity-map interaction (rows hidden by RLS are simply absent from reads; we do not cache negative lookups — call this out).

---

## Verified facts (from reading the current code)

- `Manifest.Entity` class has `cascadeRules :: [CascadeRule]` with `cascadeRules = []` default — the exact shape `rlsPolicies` will mirror.
- `Manifest.Query`: `data Expr t = Expr ByteString [SqlParam]` (opaque export); `class Projectable h where (^.) :: h e -> Column e t -> Expr t` with `Handle`/`OptHandle` instances; `(.==) :: Expr t -> Expr t -> Expr Bool` (= `binop "="`), `.&&`, etc.; `Column (..)` from `Manifest.Core.Query` is `Column { colName :: ByteString }`.
- `Manifest.Migrate`: `data ManagedTable = ManagedTable { mtName :: ByteString, mtColumns :: [ColumnMeta] }`; `managed :: Entity a => Proxy a -> ManagedTable = ManagedTable (tmTable tm) (tmColumns tm)`; `migrate :: [ManagedTable] -> Db MigrationPlan` (additive + destructive); `migrateUp` applies additive in a transaction; `liveColumns`/`tableExists` query `information_schema`; `execDb` runs+logs.
- `Manifest.Session`: `execDb :: ByteString -> [SqlParam] -> Db [[SqlParam]]`; `withTransaction :: Db a -> Db a` brackets BEGIN/COMMIT(/ROLLBACK) and flushes.
- **RLS bypass gotcha:** the test cluster connects as the `postgres` **superuser**, and superusers BYPASS RLS even with `FORCE`. So the e2e test must `SET LOCAL ROLE <non-superuser>` (a role created in the test, granted SELECT) inside the transaction for policies to apply. In real apps the connection is already a non-superuser app role, so this is a test-only concern.

---

### Task 1: Policy types + typed predicate DSL + `Entity.rlsPolicies`

**Files:** Create `src/Manifest/Core/Rls.hs`, `src/Manifest/Rls.hs`; Modify `src/Manifest/Query.hs`, `src/Manifest/Entity.hs`; Create `test/RlsSpec.hs`; Modify `test/Spec.hs`.

- [ ] **Step 1: Write the failing test.** Create `test/RlsSpec.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module RlsSpec (tests) where

import Fixtures (User)
import Manifest
import Manifest.Core.Rls (PolicyDef (..), policyDef)
import Harness

tests :: [Test]
tests = group "Rls"
  [ test "policy DSL renders the USING predicate to SQL" $ do
      let p = policy "org_isolation"
                `using` (\u -> u ^. #userName .== currentSetting "app.current_org")
              :: Policy User
          pd = policyDef p
      assertEqual "name" "org_isolation" (pdName pd)
      assertEqual "using" (Just "user_name = current_setting('app.current_org')") (pdUsing pd)
      assertEqual "check" Nothing (pdCheck pd)
  ]
```

Wire into `test/Spec.hs` (import `qualified RlsSpec`, append `RlsSpec.tests`).

- [ ] **Step 2: Run — fails** (`policy`/`using`/`currentSetting`/`Policy`/`Manifest.Core.Rls` missing).

- [ ] **Step 3: Create `src/Manifest/Core/Rls.hs`** (low; types only):
```haskell
module Manifest.Core.Rls
  ( PolicyCmd (..)
  , PolicyDef (..)
  , Policy (..)
  , policyDef
  ) where

import Data.ByteString (ByteString)

-- | Which commands a policy applies to.
data PolicyCmd = CmdAll | CmdSelect | CmdInsert | CmdUpdate | CmdDelete
  deriving (Eq, Show)

-- | An entity-erased policy: name, command, rendered USING / WITH CHECK SQL.
data PolicyDef = PolicyDef
  { pdName  :: ByteString
  , pdCmd   :: PolicyCmd
  , pdUsing :: Maybe ByteString
  , pdCheck :: Maybe ByteString
  } deriving (Eq, Show)

-- | A policy attached to entity @a@ (phantom). Built with the 'Manifest.Rls' DSL.
newtype Policy a = Policy PolicyDef

policyDef :: Policy a -> PolicyDef
policyDef (Policy pd) = pd
```

- [ ] **Step 4: Add the predicate primitives to `src/Manifest/Query.hs`.** Add to its export list: `Self (..), currentSetting, lit, renderPredicate`. Add:
```haskell
-- | A self-reference to the policy's own table: projects BARE column names
-- (no alias), because an RLS policy is already scoped to its table.
data Self e = Self

instance Projectable Self where
  Self ^. Column c = Expr c []

-- | @current_setting('name')@ — read a GUC the app set with 'withRlsContext'.
currentSetting :: Text -> Expr Text
currentSetting name = Expr ("current_setting(" <> quoteLit name <> ")") []

-- | An inline single-quoted SQL string literal (for DDL predicates; not a bound param).
lit :: Text -> Expr a
lit t = Expr (quoteLit t) []

quoteLit :: Text -> ByteString
quoteLit t = "'" <> BC.concatMap esc (TE.encodeUtf8 t) <> "'"
  where esc '\'' = "''"; esc c = BC.singleton c

-- | Render a predicate to SQL for a policy body. Errors if it carries bound
-- params (a 'val' is not allowed in DDL — use 'lit' / 'currentSetting').
renderPredicate :: Expr Bool -> ByteString
renderPredicate (Expr t ps)
  | null ps   = t
  | otherwise = error "Manifest.Query.renderPredicate: policy predicate may not use 'val'/bound params; use 'lit' or 'currentSetting'"
```
Add imports to `Manifest.Query`: `Data.Text (Text)`, `qualified Data.Text.Encoding as TE` (for `quoteLit`). `BC.concatMap`/`BC.singleton` are in `Data.ByteString.Char8` (already imported as `BC`).

> `Self`'s `Projectable` instance reuses the existing class, so `o ^. #userName` works with `o :: Self e`. `currentSetting`/`lit` build param-free `Expr`s; the existing `.==`/`.&&` combine them; `renderPredicate` extracts the text.

- [ ] **Step 5: Create `src/Manifest/Rls.hs`** (high; the builders):
```haskell
{-# LANGUAGE ScopedTypeVariables #-}

module Manifest.Rls
  ( policy
  , using
  , withCheck
  , forCommand
  ) where

import Manifest.Core.Rls (Policy (..), PolicyCmd (..), PolicyDef (..))
import Manifest.Query (Expr, Self (..), renderPredicate)
import qualified Data.Text.Encoding as TE
import Data.Text (Text)

-- | A bare policy (FOR ALL, no predicates). Refine with 'using'/'withCheck'/'forCommand'.
policy :: Text -> Policy a
policy name = Policy (PolicyDef (TE.encodeUtf8 name) CmdAll Nothing Nothing)

-- | Set the USING predicate. @policy "p" \`using\` (\\o -> o ^. #col .== currentSetting "app.x")@.
using :: forall a. Policy a -> (Self a -> Expr Bool) -> Policy a
using (Policy pd) f = Policy pd { pdUsing = Just (renderPredicate (f Self)) }

-- | Set the WITH CHECK predicate (for INSERT/UPDATE).
withCheck :: forall a. Policy a -> (Self a -> Expr Bool) -> Policy a
withCheck (Policy pd) f = Policy pd { pdCheck = Just (renderPredicate (f Self)) }

-- | Restrict the policy to one command (default 'CmdAll').
forCommand :: Policy a -> PolicyCmd -> Policy a
forCommand (Policy pd) c = Policy pd { pdCmd = c }
```

- [ ] **Step 6: Add `rlsPolicies` to `Manifest.Entity`.** Import `Manifest.Core.Rls (Policy)`; add to the class (after `cascadeRules`):
```haskell
  -- | Row-level-security policies for this entity (default: none). Built with the
  -- 'Manifest.Rls' DSL; applied by the migration engine.
  rlsPolicies :: [Policy a]
  rlsPolicies = []
```
Add `rlsPolicies` to the `Entity (..)` export (it is part of `Entity(..)` automatically). No existing instance changes (default `[]`).

- [ ] **Step 7: Re-export from the umbrella** (so the test's `import Manifest` sees them). In `src/Manifest.hs` add a `-- * Row-level security` export section + imports: `Policy`, `PolicyCmd (..)` (from `Manifest.Core.Rls`), `policy`, `using`, `withCheck`, `forCommand` (from `Manifest.Rls`), and `Self`, `currentSetting`, `lit` (from `Manifest.Query`). (`rlsPolicies` comes via `Entity(..)` already re-exported.)

- [ ] **Step 8: Run — passes.** `nix develop -c zinc test 2>&1 | tail -6` then `… .zinc/build/spec | tail -2`. Expected **110/110** (baseline 109 + 1). Confirm the existing 109 still pass (the `Entity` class gained a defaulted method; no instance breaks).

- [ ] **Step 9: -Wall** — `nix develop -c zinc build 2>&1 | grep -iE "warning|Rls.hs|Query.hs|Entity.hs" | tail`. None for the touched modules.

- [ ] **Step 10: Commit**
```bash
git add src/Manifest/Core/Rls.hs src/Manifest/Rls.hs src/Manifest/Query.hs src/Manifest/Entity.hs src/Manifest.hs test/RlsSpec.hs test/Spec.hs
git commit -m "feat(rls): typed policy DSL + Entity.rlsPolicies"
```

---

### Task 2: `withRlsContext` (pool-safe GUC session context)

**Files:** Modify `src/Manifest/Session.hs`, `src/Manifest.hs`, `test/RlsSpec.hs`.

- [ ] **Step 1: Write the failing test** — append to `RlsSpec`:
```haskell
  , test "withRlsContext sets a transaction-local GUC; it is cleared afterward" $
      withEmptyDb $ \pool -> withSession pool $ do
        inside <- withTransaction $ withRlsContext [("app.current_org", "acme")] $ do
          rows <- execDb "SELECT current_setting('app.current_org', true)" []
          pure (head (head rows))
        outside <- withTransaction $ do
          rows <- execDb "SELECT current_setting('app.current_org', true)" []
          pure (head (head rows))
        liftIO $ do
          assertEqual "inside the context" (Just "acme") inside
          assertEqual "cleared after the transaction" Nothing outside
```
Add imports to `RlsSpec`: `Manifest (execDb)` is via the umbrella? `execDb` is exported from `Manifest`? Confirm — if not, import `Manifest.Session (execDb)`. Also `Control.Monad.IO.Class (liftIO)`, `Fixtures (withEmptyDb)`.

> `current_setting('app.current_org', true)` uses the `missing_ok` form: returns the value when set, `NULL` (decoded `Nothing :: SqlParam`) when unset. After the first transaction commits, the LOCAL setting is gone, so the second transaction reads `Nothing` — proving no leak across the (same) pooled connection.

- [ ] **Step 2: Run — fails** (`withRlsContext` not in scope).

- [ ] **Step 3: Implement `withRlsContext`** in `src/Manifest/Session.hs`. Add `withRlsContext` to the export list. Add:
```haskell
-- | Set GUC variables for the enclosing transaction (LOCAL-scoped via set_config,
-- so they auto-clear at COMMIT/ROLLBACK and never leak to the next pool checkout).
-- Use inside 'withTransaction'. RLS policies read these with @current_setting(...)@.
withRlsContext :: [(Text, Text)] -> Db a -> Db a
withRlsContext settings body = do
  mapM_ setLocal settings
  body
  where
    setLocal (k, v) = void $ execDb "SELECT set_config($1, $2, true)"
                                     [Just (TE.encodeUtf8 k), Just (TE.encodeUtf8 v)]
```
Add imports to `Manifest.Session`: `Data.Text (Text)`, `qualified Data.Text.Encoding as TE`. (`void` is already imported.)

- [ ] **Step 4: Re-export `withRlsContext`** from `src/Manifest.hs` (add to the Row-level-security section + the `import Manifest.Session (...)` block).

- [ ] **Step 5: Run — passes.** `… .zinc/build/spec | tail -2`. Expected **111/111**.

- [ ] **Step 6: -Wall + Commit**
```bash
git add src/Manifest/Session.hs src/Manifest.hs test/RlsSpec.hs
git commit -m "feat(rls): withRlsContext — pool-safe transaction-local GUC context"
```

---

### Task 3: Declarative RLS migration (enable/force + reconcile policies)

**Files:** Modify `src/Manifest/Migrate.hs`, `test/RlsSpec.hs` (and `src/Manifest.hs` if new names are exported).

- [ ] **Step 1: Write the failing tests** — append to `RlsSpec`. First define a test entity with a policy (above `tests`):
```haskell
-- a tiny entity with an RLS policy, for the migration + e2e tests
data SecretT f = Secret
  { secretId  :: Col f (PrimaryKey (Serial Int))
  , secretOrg :: Col f Text
  , secretBody :: Col f Text
  } deriving GHC.Generics.Generic
type Secret = SecretT Data.Functor.Identity.Identity

instance Entity Secret where
  type PrimKey Secret = Int
  tableMeta  = genericTableMeta @SecretT "secrets"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = secretId
  rlsPolicies =
    [ policy "org_isolation" `using` (\s -> s ^. #secretOrg .== currentSetting "app.current_org") ]

secretsDDL :: Data.ByteString.ByteString
secretsDDL = "CREATE TABLE secrets ( secret_id BIGSERIAL PRIMARY KEY, secret_org TEXT NOT NULL, secret_body TEXT NOT NULL )"
```
(Add the needed imports/pragmas: `DeriveGeneric`, `TypeFamilies`, `FlexibleInstances`; `import qualified GHC.Generics`, `qualified Data.Functor.Identity`, `qualified Data.ByteString`, `Data.Text (Text)`; and `Manifest.Core.Table (Col, PrimaryKey, Serial)` if not via umbrella.) Tests:
```haskell
  , test "migrate emits ENABLE/FORCE RLS + CREATE POLICY for a policied entity" $
      withEmptyDb $ \pool -> withSession pool $ do
        liftIO . pure =<< pure ()   -- placeholder; real body below
        execDb_ secretsDDL
        plan <- migrate [managed (Proxy @Secret)]
        let rls = planRls plan
        liftIO $ do
          assertBool "enables RLS" (any ("ENABLE ROW LEVEL SECURITY" `isInfixOf'`) rls)
          assertBool "forces RLS"  (any ("FORCE ROW LEVEL SECURITY"  `isInfixOf'`) rls)
          assertBool "creates the policy"
            (any (\s -> "CREATE POLICY org_isolation ON secrets" `isInfixOf'` s) rls)
  , test "migrateUp applies RLS and is a no-op on re-run" $
      withEmptyDb $ \pool -> withSession pool $ do
        execDb_ secretsDDL
        _    <- migrateUp [managed (Proxy @Secret)]
        plan <- migrate  [managed (Proxy @Secret)]   -- after applying, nothing left to do
        liftIO $ assertEqual "idempotent RLS plan" [] (planRls plan)
```
Provide small helpers in the spec: `execDb_ s = void (execDb s [])`, `isInfixOf' a b = a `Data.ByteString.isInfixOf` b` (import `Data.ByteString (isInfixOf)`), and `void` from `Control.Monad`.

- [ ] **Step 2: Run — fails** (`planRls` / RLS plan not present).

- [ ] **Step 3: Implement RLS reconciliation in `src/Manifest/Migrate.hs`.**

(a) Add to exports: `renderCreatePolicy`, `renderDropPolicy`, `rlsPlan` (and keep `MigrationPlan(..)`). Import `Manifest.Core.Rls (PolicyDef (..), PolicyCmd (..))` and `Manifest.Entity (Entity, tableMeta, rlsPolicies)`.

(b) `ManagedTable` gains policies; `managed` captures them:
```haskell
data ManagedTable = ManagedTable
  { mtName     :: ByteString
  , mtColumns  :: [ColumnMeta]
  , mtPolicies :: [PolicyDef]
  } deriving (Eq, Show)

managed :: forall a. Entity a => Proxy a -> ManagedTable
managed _ = ManagedTable (tmTable tm) (tmColumns tm) (map Manifest.Core.Rls.policyDef (rlsPolicies @a))
  where tm = tableMeta @a
```
(Existing `ManagedTable` constructions elsewhere — there are none outside `managed` — so this is safe. If `ManagedTable` is pattern-matched positionally anywhere, update those.)

(c) Render helpers:
```haskell
cmdSql :: PolicyCmd -> ByteString
cmdSql CmdAll = "ALL"; cmdSql CmdSelect = "SELECT"; cmdSql CmdInsert = "INSERT"
cmdSql CmdUpdate = "UPDATE"; cmdSql CmdDelete = "DELETE"

renderCreatePolicy :: ByteString -> PolicyDef -> ByteString
renderCreatePolicy table pd =
  "CREATE POLICY " <> pdName pd <> " ON " <> table
    <> (if pdCmd pd == CmdAll then "" else " FOR " <> cmdSql (pdCmd pd))
    <> maybe "" (\u -> " USING (" <> u <> ")") (pdUsing pd)
    <> maybe "" (\c -> " WITH CHECK (" <> c <> ")") (pdCheck pd)

renderDropPolicy :: ByteString -> ByteString -> ByteString
renderDropPolicy table name = "DROP POLICY " <> name <> " ON " <> table
```

(d) Live introspection + reconciliation:
```haskell
-- live policy names on a table
livePolicies :: ByteString -> Db [ByteString]
livePolicies table = do
  rows <- execDb "SELECT policyname FROM pg_policies WHERE schemaname='public' AND tablename=$1" [Just table]
  pure [ n | [Just n] <- rows ]

-- live (rowsecurity, forcerowsecurity) flags
liveRlsFlags :: ByteString -> Db (Bool, Bool)
liveRlsFlags table = do
  rows <- execDb "SELECT relrowsecurity, relforcerowsecurity FROM pg_class \
                 \WHERE oid = ('public.' || $1)::regclass" [Just table]
  pure $ case rows of
    ([Just a, Just b] : _) -> (a == "t", b == "t")
    _                      -> (False, False)

-- DDL to make one table's live RLS match its declarations
rlsForTable :: ManagedTable -> Db [ByteString]
rlsForTable (ManagedTable name _ pols)
  | null pols = pure []
  | otherwise = do
      (rls, frc) <- liveRlsFlags name
      live       <- livePolicies name
      let declNames = map pdName pols
          enable = [ "ALTER TABLE " <> name <> " ENABLE ROW LEVEL SECURITY" | not rls ]
          force  = [ "ALTER TABLE " <> name <> " FORCE ROW LEVEL SECURITY"  | not frc ]
          create = [ renderCreatePolicy name pd | pd <- pols, pdName pd `notElem` live ]
          drop_  = [ renderDropPolicy name n    | n  <- live, n `notElem` declNames ]
      pure (enable ++ force ++ drop_ ++ create)

rlsPlan :: [ManagedTable] -> Db [ByteString]
rlsPlan = fmap concat . mapM rlsForTable
```
> Reconciliation is by policy NAME: create declared-but-absent, drop present-but-undeclared. A policy whose body changed but kept its name is NOT re-created (document: rename it or drop manually). `ENABLE`/`FORCE` emitted only when the live flag is off, so a fully-migrated table yields an empty plan (idempotent).

(e) Thread it through `MigrationPlan`/`migrate`/`migrateUp`:
```haskell
data MigrationPlan = MigrationPlan
  { planAdditive    :: [ByteString]
  , planDestructive :: [String]
  , planRls         :: [ByteString]   -- NEW: ENABLE/FORCE + CREATE/DROP POLICY
  } deriving (Eq, Show)
```
In `migrate`, after computing additive/destr, also `rls <- rlsPlan tables` and return `MigrationPlan additive destr rls`. **Order matters:** RLS reconciliation reads the live schema; for a brand-new table the columns are created by the additive plan first. So in `migrateUp`, run the additive statements, THEN recompute `rlsPlan` against the now-current schema and apply it (or: compute `rlsPlan` after additive is applied). Simplest correct approach in `migrateUp`: apply additive, then `r <- rlsPlan tables; forM_ r (execDb · [])`, all inside the one `withTransaction`. Update `migrateUp`:
```haskell
migrateUp tables = do
  ensureSchemaMigrations
  plan <- migrate tables
  unless (null (planDestructive plan)) $ liftIO (throwIO (DbException (OtherError …)))  -- unchanged
  withTransaction $ do
    forM_ (planAdditive plan) $ \s -> void (execDb s [])
    r <- rlsPlan tables                     -- recompute against the just-applied schema
    forM_ r $ \s -> void (execDb s [])
    unless (null (planAdditive plan) && null r) $
      void $ execDb "INSERT INTO schema_migrations (statements) VALUES ($1)"
                    [Just (BC.pack (show (length (planAdditive plan) + length r)))]
  pure plan
```
(Keep the destructive-abort check. The `withTransaction` now always wraps the apply; if both additive and rls are empty it still opens an empty transaction and skips the insert — harmless. Adjust so the transaction body is skipped when there is nothing to do, to preserve the "no-op" behaviour: guard the whole `withTransaction` on `not (null additive) || <rls non-empty>`. Since rls is computed inside, simplest: compute `rls0 <- rlsPlan tables` up front for the guard, and recompute after additive only if additive created tables. For the tests here the table pre-exists, so `rlsPlan tables` up front is accurate; use that for both guard and apply.)

> **Simplify for this task:** since the e2e/migration tests create the table's columns by hand (`secretsDDL`) before calling migrate, you can compute `rls <- rlsPlan tables` ONCE in `migrate` (table already exists) and have `migrateUp` apply `planAdditive ++ planRls` in the transaction, guarded by `not (null additive && null rls)`. The "recompute after additive" nuance only matters when migrate creates the table in the same run; note it as a follow-up if it complicates this task. Pick the simpler version that makes the tests pass and keeps re-run a no-op.

(f) Update `runMigrate` (the CLI `diff`) to also print `planRls` under an `-- rls:` banner.

- [ ] **Step 4: Run — passes.** `… .zinc/build/spec | tail -2`. Expected **113/113** (111 + 2). Fix the `MigrationPlan` 2-field vs 3-field mismatch anywhere it is constructed/pattern-matched (the existing `MigrationPlan additive destr` literals — there is one in `migrate` — must become 3-field). The existing `MigrateSpec.hs` tests may pattern-match `MigrationPlan`; update them to the 3-field form (or use field accessors) so they still compile and pass.

- [ ] **Step 5: -Wall + Commit**
```bash
git add src/Manifest/Migrate.hs test/RlsSpec.hs test/MigrateSpec.hs
git commit -m "feat(rls): declarative RLS migration (enable/force + reconcile policies)"
```

---

### Task 4: End-to-end tenant isolation + docs

**Files:** Modify `test/RlsSpec.hs`, `src/Manifest.hs` (verify exports), create `docs/rls.md`, modify `docs/index.md`/`docs/migrations.md`.

- [ ] **Step 1: Write the end-to-end test** — append to `RlsSpec`. This proves a policy hides another tenant's rows. Because the cluster connects as a superuser (which bypasses RLS), the test creates a non-privileged role and `SET LOCAL ROLE`s to it inside the transaction.

```haskell
  , test "RLS hides other tenants' rows within a Manifest session" $
      withEmptyDb $ \pool -> withSession pool $ do
        execDb_ secretsDDL
        -- seed both tenants (as superuser, before role switch)
        _ <- add (Secret { secretId = 0, secretOrg = "acme", secretBody = "a1" } :: Secret)
        _ <- add (Secret { secretId = 0, secretOrg = "globex", secretBody = "g1" } :: Secret)
        _ <- migrateUp [managed (Proxy @Secret)]            -- enable RLS + create policy
        -- a non-superuser role so RLS actually applies
        execDb_ "DROP ROLE IF EXISTS rls_tenant"
        execDb_ "CREATE ROLE rls_tenant NOLOGIN"
        execDb_ "GRANT SELECT ON secrets TO rls_tenant"
        let visibleFor org = withTransaction $ do
              execDb_ "SET LOCAL ROLE rls_tenant"
              withRlsContext [("app.current_org", org)] $ do
                rows <- execDb "SELECT secret_body FROM secrets ORDER BY secret_body" []
                pure [ b | [Just b] <- rows ]
        acme   <- visibleFor "acme"
        globex <- visibleFor "globex"
        liftIO $ do
          assertEqual "acme sees only its row"   ["a1"] acme
          assertEqual "globex sees only its row" ["g1"] globex
```
> `SET LOCAL ROLE rls_tenant` makes the effective role a non-superuser for that transaction, so the policy `secret_org = current_setting('app.current_org')` applies. `FORCE ROW LEVEL SECURITY` (from migrateUp) also covers the owner case. The two transactions (acme/globex) see disjoint rows, proving isolation. If a row leaks, the assertion fails.

- [ ] **Step 2: Run — passes.** `… .zinc/build/spec | tail -2`. Expected **114/114**. If both tenants see all rows, RLS is not applying: check that `migrateUp` actually emitted ENABLE+FORCE+CREATE (print `planRls`), and that `SET LOCAL ROLE` took effect (a superuser without the role switch will bypass RLS).

- [ ] **Step 3: Write `docs/rls.md`** (manual voice: no em-dashes, no SQLAlchemy, no positioning claims). `nav_order: 8` and bump later pages if needed (Queries is 8, Tutorials 9 — put RLS at e.g. `nav_order: 8` and Queries 7? Read the current nav_orders and pick a free slot after Migrations(7)/Queries; simplest: give RLS `nav_order: 8`, Queries stays where it is if distinct — verify no collision, adjust Tutorials if needed). Content:

````markdown
---
title: Row-level security
nav_order: 8
---

# Row-level security

Manifest can drive PostgreSQL Row-Level Security so multi-tenant access is enforced
by the database. You declare policies on the entity, the migration engine creates
them, and `withRlsContext` sets the per-request context the policies read.

## Declaring a policy

Policies are an entity method (`rlsPolicies`), with a typed predicate built from the
same `#label` columns the query builder uses. `currentSetting` reads a GUC variable;
`lit` is an inline literal:

```haskell
instance Entity Secret where
  -- … tableMeta / rowDecoder / rowEncode / primKey …
  rlsPolicies =
    [ policy "org_isolation"
        `using` (\s -> s ^. #secretOrg .== currentSetting "app.current_org") ]
```

`using` sets the `USING` predicate (SELECT/UPDATE/DELETE visibility); `withCheck`
sets `WITH CHECK` (INSERT/UPDATE); `forCommand` restricts a policy to one command.
Predicates use `lit` / `currentSetting`, not `val` (a policy is DDL, not a
parameterised query).

## Migrating policies

`migrate` / `migrateUp` reconcile the live database to the declared policies: they
`ENABLE` and `FORCE ROW LEVEL SECURITY` on policied tables, `CREATE` declared
policies that are absent, and `DROP` policies that are present but no longer
declared. Reconciliation is by policy name, so a fully-migrated schema is a no-op on
re-run.

## Setting the request context

`withRlsContext` sets GUC variables for the enclosing transaction with
`set_config(..., true)`, so they are LOCAL-scoped and cannot leak to the next pooled
connection. Use it inside `withTransaction`:

```haskell
withTransaction $ withRlsContext [("app.current_org", currentOrg)] $ do
  rows <- selectWhere []          -- only the current org's rows, enforced by Postgres
  ...
```

## Notes and limits

* RLS does not apply to superusers or roles with `BYPASSRLS`; connect as a normal
  application role. `FORCE ROW LEVEL SECURITY` makes policies apply to the table
  owner too.
* Policy bodies are reconciled by name. Changing a policy's predicate while keeping
  its name is not detected; rename the policy or drop it manually.
* Rows hidden by RLS are simply absent from reads. The identity map caches what was
  read; it does not cache negative lookups, so a row invisible under one context can
  be read under another.
* `SET ROLE`-based contexts and per-role policies (`TO role`) are not built; this is
  GUC-variable based.
````

- [ ] **Step 4: Link it.** Add a `[Row-level security](rls.md)` bullet to `docs/index.md`'s Pages list, and add one sentence + link from `docs/migrations.md` ("Migrations also reconcile row-level-security policies; see [Row-level security](rls.md)."). Resolve any `nav_order` collision (read the existing pages' `nav_order` and keep them distinct).

- [ ] **Step 5: Verify** — `… .zinc/build/spec | tail -2` (114/114); `grep -rniE "—|sqlalchemy" docs/rls.md` (nothing).

- [ ] **Step 6: Close the issue + commit.**
```bash
bd close manifest-yyb --reason "RLS shipped: typed policy DSL, declarative migration, withRlsContext, e2e tenant-isolation test." 2>/dev/null || true
bd export --output .beads/issues.jsonl 2>/dev/null || true
git add src/Manifest.hs docs/rls.md docs/index.md docs/migrations.md test/RlsSpec.hs .beads/issues.jsonl
git commit -m "feat(rls): end-to-end tenant isolation test; docs; close manifest-yyb"
```

---

## Self-Review

**1. Spec coverage** (issue acceptance: scope an RLS context guaranteed not to leak; migrations enable RLS and create/diff policies; a test proves a policy hides rows):
- Typed policy DSL on the entity → Task 1. `withRlsContext` (LOCAL set_config, leak-safe, with a leak-safety test) → Task 2. Declarative migration (enable/force + create/drop reconciliation) → Task 3. End-to-end isolation test → Task 4. Issue closed → Task 4. ✓

**2. Placeholder scan:** complete code per step. The genuine subtleties are called out with the fix: superuser RLS bypass (Task 4 uses `SET LOCAL ROLE`), DDL-can't-use-`val` (`renderPredicate` errors; `lit`/`currentSetting` provided), `MigrationPlan` arity change (Task 3 Step 4 flags updating `MigrateSpec`/the `migrate` literal), and migrate-creates-table-then-RLS ordering (Task 3 (e) notes the recompute-after-additive nuance and a simpler tests-pass path).

**3. Type consistency / layering:**
- `Policy a` (phantom newtype over `PolicyDef`); `policyDef :: Policy a -> PolicyDef`; `ManagedTable` holds `[PolicyDef]` (erased) — no phantom escapes into Migrate. ✓
- `Self e` + `Projectable Self` reuse the existing `(^.)`; `currentSetting`/`lit :: … -> Expr …`; `.==` from Query combine them; `renderPredicate :: Expr Bool -> ByteString`. The builders `policy`/`using`/`withCheck`/`forCommand :: … -> Policy a`. ✓
- Module deps are acyclic (Core.Rls is a leaf; Entity → Core.Rls; Query's additions use Core.Query/Core.Codec/Text only; Rls → Query + Core.Rls; Migrate → Entity + Core.Rls). ✓
- `MigrationPlan` 3-field everywhere (Task 3 Step 4 updates the one literal + MigrateSpec). `migrate`/`migrateUp`/`runMigrate` thread `planRls`. ✓

**Open risks (resolved under TDD):** (a) the superuser bypass — pinned by the Task 4 e2e using `SET LOCAL ROLE`; (b) `pg_class`/`pg_policies` introspection SQL (`('public.' || $1)::regclass`, `pg_policies.policyname`) — verified against PG docs, but the implementer confirms by running Task 3's tests; (c) `MigrationPlan` arity break — Task 3 explicitly updates all constructors/matches; (d) idempotency — `ENABLE`/`FORCE` guarded on live flags and policies diffed by name, pinned by the "no-op on re-run" test.
