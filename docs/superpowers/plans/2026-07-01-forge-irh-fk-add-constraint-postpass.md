# FK `ADD CONSTRAINT` post-pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move FK constraint emission out of inline `CREATE TABLE` into an `ALTER TABLE … ADD CONSTRAINT` post-pass that runs after all tables are created, removing the migrate table-ordering requirement.

**Architecture:** Mirror the engine's existing index/RLS reconciliation exactly — `foreignKeysForTable`/`foreignKeyPlan` compute create-if-absent `ADD CONSTRAINT` statements against the live DB, applied inside the migrate transaction after all `CREATE TABLE`/`ADD COLUMN`s. `renderCreateTable` and `renderAddColumn` stop emitting FKs inline.

**Tech Stack:** Haskell (GHC 9.12.2), custom `Harness` test runner (no hspec), ephemeral Postgres via `withEmptyDb`/`migrateUp`. Build tool: `zinc` (workspace monorepo).

## Global Constraints

- **manifest-core is a dependency of crucible and manifest-evals.** After changing it, build the WHOLE workspace from the repo root: `zinc build`. (This bead changes `manifest/src/Manifest/Migrate.hs`, which is in the `manifest` package, not `manifest-core` — but still run `zinc build` before committing.)
- **Run the manifest suite from the REPO ROOT** as `zinc test manifest:spec`. Do NOT `cd manifest`. Bare `zinc test manifest` matches the wrong member.
- The test harness is the project's own `Harness` module (`group`/`test`/`assertEqual`/`assertBool`); there is no hspec.
- FK constraints are named `<table>_<column>_fkey` (Postgres's own default convention) so they are reconcilable by name.
- Reconciliation is **create-if-absent, never drop** — consistent with the index policy.
- No `ON DELETE` (that is the separate `ReferencesOnDelete` bead).
- Spec: `docs/superpowers/specs/2026-07-01-forge-irh-fk-add-constraint-postpass-design.md`.

---

### Task 1: Move FK emission to the `ADD CONSTRAINT` post-pass

Replace inline FK emission with the reconciled post-pass, and update every affected test so the suite stays green. This is one atomic behavioural change (splitting production from its dependent tests would leave a red suite).

**Files:**
- Modify: `manifest/src/Manifest/Migrate.hs`
- Modify: `manifest/test/MigrateSqlSpec.hs` (revert `renderAddColumn` calls to 2-arg)
- Modify: `manifest/test/ReferencesSpec.hs` (render tests + rewrite the 3 integration tests to `migrateUp`)
- Modify: `docs/superpowers/specs/2026-06-29-forge-u0w-references-fk-markers-design.md` (resolve the "Known limitation" section)

**Interfaces:**
- Consumes: `ForeignKey(..)` (`fkColumn`/`fkRefTable`/`fkRefPkColumn`), `ManagedTable(..)`/`mtForeignKeys`/`mtName`, `tableExists`, `execDb`.
- Produces (new, exported from `Manifest.Migrate`): `renderAddForeignKey :: ByteString -> ForeignKey -> ByteString`; `liveForeignKeys :: ByteString -> Db [ByteString]`; `foreignKeysForTable :: ManagedTable -> Db [ByteString]`; `foreignKeyPlan :: [ManagedTable] -> Db [ByteString]`; `MigrationPlan` field `planForeignKeys :: [ByteString]`. Changed: `renderCreateTable` no longer emits FKs; `renderAddColumn :: ByteString -> ColumnMeta -> ByteString` (2-arg again); `fkDDL` removed.

- [ ] **Step 1: Update the render-level tests (RED)** — `MigrateSqlSpec.hs` and `ReferencesSpec.hs`.

In `manifest/test/MigrateSqlSpec.hs`, revert the two `renderAddColumn` calls to the 2-arg form (drop the `[]`):
```haskell
        (renderAddColumn "users" (ColumnMeta "nickname" False False False False SqlText True))
```
```haskell
        (renderAddColumn "users" (ColumnMeta "age" False False False False SqlBigInt False))
```
(The expected strings are unchanged.)

In `manifest/test/ReferencesSpec.hs`, replace the two FK render tests (currently "renderCreateTable appends FK constraints" and "renderAddColumn emits the FK inline") with these three:
```haskell
  , test "renderCreateTable emits columns only (no inline FK)" $
      assertEqual "create"
        "CREATE TABLE docs (doc_id BIGSERIAL PRIMARY KEY, doc_author BIGINT NOT NULL, doc_editor BIGINT)"
        (renderCreateTable (managed (Proxy @Doc)))
  , test "renderAddColumn emits no inline FK (2-arg)" $
      assertEqual "add"
        "ALTER TABLE docs ADD COLUMN doc_author BIGINT NOT NULL"
        (renderAddColumn "docs" (ColumnMeta "doc_author" False False False False SqlBigInt False))
  , test "renderAddForeignKey renders the ALTER TABLE ADD CONSTRAINT statement" $
      assertEqual "addfk"
        "ALTER TABLE docs ADD CONSTRAINT docs_doc_author_fkey FOREIGN KEY (doc_author) REFERENCES users(user_id)"
        (renderAddForeignKey "docs" (ForeignKey "doc_author" "users" "user_id"))
```
Update the `Manifest.Migrate` import in `ReferencesSpec.hs` to add `renderAddForeignKey` and `migrateUp` (and keep `ManagedTable(..)`, `managed`, `renderCreateTable`, `renderAddColumn`). `mtForeignKeys` is no longer referenced by the render tests — leave it imported only if the integration tests below use it (they don't); drop it if it becomes unused.

- [ ] **Step 2: Run the suite to verify the render tests fail**

Run: `zinc test manifest:spec`
Expected: COMPILE FAILURE (`renderAddForeignKey` not in scope) and/or assertion failures — the current `renderCreateTable` still emits inline FKs.

- [ ] **Step 3: Rewrite `renderCreateTable`, `renderAddColumn`; add the post-pass functions** in `manifest/src/Manifest/Migrate.hs`.

Remove `fkDDL` entirely. Change `renderCreateTable` to emit columns only:
```haskell
-- | @CREATE TABLE name (col1 …, col2 …, …)@ from the managed schema. Foreign-key
-- constraints are NOT emitted here — they are added by the post-pass
-- ('foreignKeyPlan') after all tables exist, so table order is irrelevant.
renderCreateTable :: ManagedTable -> ByteString
renderCreateTable (ManagedTable name cols _ _ _) =
  "CREATE TABLE " <> name <> " (" <> BC.intercalate ", " (map columnDDL cols) <> ")"
```
Revert `renderAddColumn` to 2-arg (no FK list, no inline `REFERENCES`):
```haskell
-- | @ALTER TABLE name ADD COLUMN col …@ (additive). Added columns are never PK.
-- FK constraints for added columns are handled by the post-pass, not inline.
renderAddColumn :: ByteString -> ColumnMeta -> ByteString
renderAddColumn table c =
  "ALTER TABLE " <> table <> " ADD COLUMN " <> cmName c <> " " <> sqlTypeDDL (cmSqlType c)
    <> (if cmNullable c then "" else " NOT NULL")
```
Add a Foreign-key DDL section (place it near the Index DDL section, mirroring it):
```haskell
-- Foreign-key DDL -------------------------------------------------------------

-- | @ALTER TABLE child ADD CONSTRAINT child_col_fkey FOREIGN KEY (col) REFERENCES tgt(pk)@.
renderAddForeignKey :: ByteString -> ForeignKey -> ByteString
renderAddForeignKey table fk =
  "ALTER TABLE " <> table <> " ADD CONSTRAINT "
    <> table <> "_" <> fkColumn fk <> "_fkey"
    <> " FOREIGN KEY (" <> fkColumn fk <> ") REFERENCES "
    <> fkRefTable fk <> "(" <> fkRefPkColumn fk <> ")"

-- | The FK constraint names live on a table (in the @public@ schema).
liveForeignKeys :: ByteString -> Db [ByteString]
liveForeignKeys table = do
  rows <- execDb "SELECT constraint_name FROM information_schema.table_constraints \
                 \WHERE table_schema='public' AND table_name=$1 AND constraint_type='FOREIGN KEY'"
                 [Just table]
  pure [ n | [Just n] <- rows ]

-- | DDL to add one table's declared FK constraints that are not already live.
-- Empty if the table has no FKs or does not exist yet (reconciled after creation).
-- CREATE-ONLY — never drops (consistent with the index policy).
foreignKeysForTable :: ManagedTable -> Db [ByteString]
foreignKeysForTable mt
  | null (mtForeignKeys mt) = pure []
  | otherwise = do
      exists <- tableExists (mtName mt)
      if not exists then pure [] else do
        live <- liveForeignKeys (mtName mt)
        pure [ renderAddForeignKey (mtName mt) fk
             | fk <- mtForeignKeys mt
             , (mtName mt <> "_" <> fkColumn fk <> "_fkey") `notElem` live ]

-- | The FK reconciliation DDL across all managed tables.
foreignKeyPlan :: [ManagedTable] -> Db [ByteString]
foreignKeyPlan = fmap concat . mapM foreignKeysForTable
```

- [ ] **Step 4: Add `planForeignKeys` and wire `migrate`/`migrateUp`/`runMigrate`.**

Add the field to `MigrationPlan`:
```haskell
data MigrationPlan = MigrationPlan
  { planAdditive    :: [ByteString]
  , planDestructive :: [String]
  , planRls         :: [ByteString]
  , planIndexes     :: [ByteString]
  , planForeignKeys :: [ByteString]
  } deriving (Eq, Show)
```
In `migrate`, compute and include it, and revert the `toAdditive` `AlterTable` caller to 2-arg `renderAddColumn`:
```haskell
migrate tables = do
  diffs <- mapM diffTable tables
  let additive = concatMap toAdditive (zip tables diffs)
      destr    = concatMap toDestr diffs
  rls  <- rlsPlan tables
  idxs <- indexPlan tables
  fks  <- foreignKeyPlan tables
  pure (MigrationPlan additive destr rls idxs fks)
  where
    toAdditive (mt, CreateTable _)       = [renderCreateTable mt]
    toAdditive (_,  AlterTable t adds _) = [renderAddColumn t c | c <- adds]
    toAdditive (_,  UpToDate)            = []
    toDestr (AlterTable _ _ d) = d
    toDestr _                  = []
```
In `migrateUp`, apply the FK post-pass inside the transaction after `additive`, extend the empty-work guard, and include FK statements in the count. Also **delete the "table ordering is load-bearing" haddock paragraph** above `migrateUp`:
```haskell
migrateUp :: [ManagedTable] -> Db MigrationPlan
migrateUp tables = do
  ensureSchemaMigrations
  plan <- migrate tables
  unless (null (planDestructive plan)) $
    liftIO (throwIO (DbException (OtherError
      ("migrate up aborted: destructive changes need review: " <> show (planDestructive plan)))))
  let additive = planAdditive plan
  rls0  <- rlsPlan tables
  idxs0 <- indexPlan tables
  fks0  <- foreignKeyPlan tables
  unless (null additive && null rls0 && null idxs0 && null fks0) $
    withTransaction $ do
      forM_ additive $ \s -> void (execDb s [])
      fks <- foreignKeyPlan tables                 -- recompute: all target tables now exist
      forM_ fks $ \s -> void (execDb s [])
      rls <- rlsPlan tables                        -- recompute: any just-created table now exists
      forM_ rls $ \s -> void (execDb s [])
      idxs <- indexPlan tables                     -- recompute: index a just-created table
      forM_ idxs $ \s -> void (execDb s [])
      void $ execDb "INSERT INTO schema_migrations (statements) VALUES ($1)"
                    [Just (BC.pack (show (length additive + length fks + length rls + length idxs)))]
  pure plan
```
In `runMigrate`'s `["diff"]` branch, add a foreign-keys section after the indexes section:
```haskell
    unless (null (planForeignKeys plan)) $ do
      BC.putStrLn "-- foreign keys:"
      mapM_ BC.putStrLn (planForeignKeys plan)
```

- [ ] **Step 5: Update the module export list.**

In `Manifest.Migrate`'s export list, add `renderAddForeignKey`, `liveForeignKeys`, `foreignKeysForTable`, `foreignKeyPlan` (near the index exports). Keep `renderAddColumn`. Do not remove any existing export.

- [ ] **Step 6: Rewrite the 3 `ReferencesSpec` integration tests to use `migrateUp`.**

The existing integration tests build tables by hand with `renderCreateTable`, which no longer adds the FK — so they must migrate via the real `migrateUp` path (which also proves the post-pass creates the constraint). Replace the FK-enforcement, nullable-valid-insert, and cascade-compatibility tests' schema setup. Example for the FK-enforcement test:
```haskell
  , test "DB rejects an FK-violating insert" $
      withEmptyDb $ \pool -> do
        r <- try $ withSession pool $ do
               _ <- migrateUp [managed (Proxy @User), managed (Proxy @Doc)]
               add (Doc { docId = 0, docAuthor = 999, docEditor = Nothing } :: Doc)
        case (r :: Either SomeException Doc) of
          Left e  -> assertBool ("expected FK violation, got: " <> show e)
                                ("foreign key" `isInfixOf` show e)
          Right _ -> assertBool "expected FK violation for author=999" False
```
Apply the same pattern to the other two: migrate the needed entities via `migrateUp [...]` at the top of the `withSession` block instead of `withConnection`/`execText`/`renderCreateTable`. For the cascade test use `migrateUp [managed (Proxy @Owner), managed (Proxy @Item)]`. Confirm the entity fixtures and field names against the live `ReferencesSpec.hs`. After the rewrite, prune any now-unused imports (`usersDDL`, `execText`, `withConnection`, `renderCreateTable` if unused, `mtForeignKeys`) so the output is pristine — but keep `renderCreateTable`/`renderAddColumn`/`renderAddForeignKey` if the render tests still use them (they do).

- [ ] **Step 7: Resolve the forge-u0w spec's "Known limitation" section.**

In `docs/superpowers/specs/2026-06-29-forge-u0w-references-fk-markers-design.md`, replace the body of the "## Known limitation — FK table-creation ordering" section with a one-line note that it was resolved by forge-irh (FK emission moved to an `ALTER TABLE … ADD CONSTRAINT` post-pass, so table order no longer matters), and remove the "FK emission via `ALTER TABLE … ADD CONSTRAINT` post-pass" bullet from that spec's "Out of scope / follow-up" list (it is now done).

- [ ] **Step 8: Run the suite to verify GREEN**

Run: `zinc test manifest:spec`
Expected: PASS — render tests match the new strings; the rewritten integration tests migrate via `migrateUp` and the FK is enforced; `MigrateSqlSpec` green with 2-arg `renderAddColumn`; existing `MigrateSpec`/`MigrateMetaSpec` unaffected (unmarked entities have no FKs).

- [ ] **Step 9: Whole-workspace build**

Run: `zinc build`
Expected: SUCCESS.

- [ ] **Step 10: Commit**

```bash
git add manifest/src/Manifest/Migrate.hs manifest/test/MigrateSqlSpec.hs manifest/test/ReferencesSpec.hs docs/superpowers/specs/2026-06-29-forge-u0w-references-fk-markers-design.md
git commit -m "feat(manifest): emit FK constraints via ALTER TABLE ADD CONSTRAINT post-pass"
```

---

### Task 2: Prove ordering-independence + idempotency

Add the integration tests that lock the new guarantees the post-pass provides — the exact cases inline emission could not survive.

**Files:**
- Modify: `manifest/test/ReferencesSpec.hs`

**Interfaces:**
- Consumes: `migrateUp`, `foreignKeyPlan`, `managed`, the `Doc`/`User` fixtures, session API (`withSession`, `add`), `Fixtures (withEmptyDb)`, `Manifest.Entity (Key(..))` if needed.
- Produces: nothing downstream.

- [ ] **Step 1: Write the ordering-independence test**

Pass the tables in **child-before-parent** order (`Doc` before `User`, where `Doc` references `User`) and assert `migrateUp` succeeds and the FK is enforced. Add to the `tests` list:
```haskell
  , test "migrateUp succeeds with child listed before parent (ordering-independent)" $
      withEmptyDb $ \pool -> do
        r <- try $ withSession pool $ do
               _ <- migrateUp [managed (Proxy @Doc), managed (Proxy @User)]   -- child first
               u <- add (User { userId = 0, userName = "u", userEmail = Nothing } :: User)
               _ <- add (Doc { docId = 0, docAuthor = userId u, docEditor = Nothing } :: Doc)  -- valid FK
               badR <- try (add (Doc { docId = 0, docAuthor = 999, docEditor = Nothing } :: Doc))
               pure (badR :: Either SomeException Doc)
        case (r :: Either SomeException (Either SomeException Doc)) of
          Right (Left e)  -> assertBool ("FK enforced: " <> show e) ("foreign key" `isInfixOf` show e)
          Right (Right _) -> assertBool "FK constraint was not enforced" False
          Left e          -> assertBool ("migrateUp failed with child-first order: " <> show e) False
```
Confirm `User`'s field names/types against the live `Fixtures.hs` (`userId`/`userName`/`userEmail`). If `try` nesting is awkward, an acceptable simpler form is: `migrateUp [Doc, User]` succeeds (no exception), then a single FK-violating `add` caught and asserted `foreign key` — the key assertion is that migrate did not fail on the reversed order.

- [ ] **Step 2: Write the idempotency test**

Run `migrateUp` twice; the second run must add no FK constraint. Assert via `foreignKeyPlan` being empty after the first migrate:
```haskell
  , test "FK post-pass is idempotent (second migrate adds no constraint)" $
      withEmptyDb $ \pool -> do
        pending <- withSession pool $ do
          _ <- migrateUp [managed (Proxy @User), managed (Proxy @Doc)]
          foreignKeyPlan [managed (Proxy @User), managed (Proxy @Doc)]   -- after: should be empty
        assertEqual "no pending FK statements after first migrate" [] pending
```
Add `foreignKeyPlan` to the `Manifest.Migrate` import.

- [ ] **Step 3: Run the suite**

Run: `zinc test manifest:spec`
Expected: PASS — both new tests green (reversed-order migrate succeeds + FK enforced; second migrate has no pending FK work).

- [ ] **Step 4: Whole-workspace build**

Run: `zinc build`
Expected: SUCCESS.

- [ ] **Step 5: Commit**

```bash
git add manifest/test/ReferencesSpec.hs
git commit -m "test(manifest): FK post-pass is ordering-independent and idempotent"
```

---

## Self-Review

**Spec coverage:**
- Stop inline FK (`renderCreateTable` columns-only; `renderAddColumn` 2-arg) → Task 1 Steps 3-4. ✓
- Post-pass (`renderAddForeignKey`, `liveForeignKeys`, `foreignKeysForTable`, `foreignKeyPlan`, `<table>_<col>_fkey` naming, create-if-absent) → Task 1 Step 3. ✓
- Orchestration (`MigrationPlan.planForeignKeys`, `migrate`, `migrateUp` post-pass + guard + count, `runMigrate` diff section, drop ordering haddock) → Task 1 Step 4. ✓
- Exports → Task 1 Step 5. ✓
- Render tests + integration rewrite to `migrateUp` + `MigrateSqlSpec` revert → Task 1 Steps 1, 6. ✓
- forge-u0w doc cleanup → Task 1 Step 7. ✓
- Ordering-independence + idempotency tests → Task 2. ✓
- Regression (unmarked entities unchanged; existing migrate specs) → Task 1 Step 8. ✓

**Placeholder scan:** clean — full code for every production step and the render tests; the integration-test rewrites give complete example code and name the exact `migrateUp` calls, with a directive to verify fixture field names against the live file (a normal implementer check, not a placeholder).

**Type consistency:** `renderAddForeignKey`/`liveForeignKeys`/`foreignKeysForTable`/`foreignKeyPlan`/`planForeignKeys` and the `<table>_<col>_fkey` name are used identically in Tasks 1-2. `renderAddColumn`'s 2-arg signature is consistent across `migrate`, `MigrateSqlSpec`, and the render test.

**Note on the one risk:** Task 1 is broad (production + several test files) because the FK move and its dependent tests are one atomic green-keeping change. The `Circular FK` spec test (#4) is intentionally omitted — the child-before-parent ordering test (Task 2 Step 1) proves the ordering property, and a clean circular fixture is impractical with the current single-PK fixtures; this matches the spec's "note the omission" allowance.
