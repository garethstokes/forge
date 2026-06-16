# Codec-Primary Core (`Field` / `Codec` / `DbType`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three single-variance column-codec classes (`ToField`/`FromField`/`ScalarMeta`) with one profunctor codec value (`Codec a b`) carried by one class (`DbType a`), and rename the HKD field wrapper `Col` to `Field` with `Pk`/`Nullable` marker aliases.

**Architecture:** Add `Codec`/`DbType` *alongside* the old classes (additive), migrate every call site module-by-module so the suite stays green throughout, then delete the three old classes once nothing references them, then do the pure `Col`→`Field` rename. The HKD + Generics derivation stays the row builder; `Codec` is column-level only.

**Tech Stack:** GHC 9.10.1 via zinc (NOT cabal). `GeneralizedNewtypeDeriving`. Existing `Manifest.Core.Codec` (`RowDecoder`/`SqlParam`/`decodeRow`/`DecodeError`), `Manifest.Core.Table` (`Base`/`Exposed`/`PrimaryKey`/`Serial`/`Col`/`FieldMeta`), `Manifest.Core.Meta` (`GColumns`/`genericTableMeta`). Custom `test/Harness.hs` (`test`/`group`/`assertEqual`).

**Spec:** `docs/superpowers/specs/2026-06-09-codec-primary-core-design.md`.

**Baseline:** `main` is at **116/116**. Confirm with `nix develop -c zinc test` then `nix develop -c .zinc/build/spec`.

**Build/test commands:**
- `nix develop -c zinc build` — build the library (does NOT rebuild tests).
- `nix develop -c zinc test` — rebuild + run tests.
- `nix develop -c .zinc/build/spec` — re-run the built test binary (summary line `N/N tests passed`).

**Pre-verified (scratch):** `deriving newtype DbType` works (GND coerces `Codec`'s representational params — `Email` over `Text` keeps `SqlText`, `UserId` over `Int` keeps `SqlBigInt`); `dimap`, and `lmap`+`refine` for a validated newtype, round-trip. So the design's headline (`deriving newtype DbType`) holds; no fallback needed.

---

## File Structure

- **`src/Manifest/Core/Codec.hs`** — gains `Codec a b`, the combinators, `DbType` + scalar instances, `encode`/`decodeCol`; later loses `ToField`/`FromField`/`field`. Keeps `RowDecoder`/`decodeRow`/`SqlParam`/`DecodeError` re-export.
- **`src/Manifest/Core/Table.hs`** — `ScalarMeta` deleted; base `FieldMeta` instance reads the codec; `Col` renamed to `Field`; `Pk`/`Nullable` aliases added.
- **`src/Manifest/Core/Meta.hs`** — unchanged (its `GColumns` reads SQL type via `FieldMeta`, not `ScalarMeta`).
- **`src/Manifest/Entity.hs`**, **`Derive.hs`**, **`Core/Query.hs`**, **`Query.hs`**, **`Relation/Loaded.hs`**, **`Session.hs`**, **`Session/Command.hs`** — constraint sites migrate `ToField`/`FromField` → `DbType`, `toField`→`encode`, `field`→`decodeCol`.
- **`src/Manifest.hs`** — umbrella re-exports swap `ToField`/`FromField`/`ScalarMeta` for `DbType`/`Codec`/combinators/`encode`; `Col`→`Field`/`Pk`/`Nullable`.
- **`test/CodecSpec.hs`** (NEW) — pure unit tests for the codec; registered in `test/Spec.hs`.
- **`zinc.toml`** — add `profunctors` (gated on it building).
- Entities (`test/Fixtures.hs`, `test/RlsSpec.hs`, `test/TypedFieldsSpec.hs`, `app/Main.hs`) — newtype deriving → `DbType`; `Col`→`Field`, markers → `Pk`.
- Docs (`docs/entities.md`, `getting-started.md`, `index.md`) — `Field`/`Pk`, `deriving newtype DbType`.

---

### Task 1: Add `Codec` + `DbType` (additive; old classes untouched)

**Files:** Modify `src/Manifest/Core/Codec.hs`, `zinc.toml`; Create `test/CodecSpec.hs`; Modify `test/Spec.hs`.

- [ ] **Step 1: Add `profunctors` to the library deps and confirm it builds**

In `zinc.toml`, add `"profunctors",` to `[build.lib].depends`. Then `nix develop -c zinc build 2>&1 | tail -20`.
- Expected: builds (no "unknown package" / solver error).
- **Fallback:** if zinc cannot resolve `profunctors`, REMOVE it from `zinc.toml` and, in Step 3, define `dimap`/`lmap`/`rmap` as local functions instead of using `Data.Profunctor` (see the note in Step 3). The rest of the plan is unaffected. Record which path you took.

- [ ] **Step 2: Write the failing unit test**

Create `test/CodecSpec.hs`:

```haskell
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeApplications #-}

module CodecSpec (tests) where

import Data.Text (Text)
import qualified Data.Text as T
import Harness (Tree, group, test, assertEqual, assertBool)
import Manifest.Core.Codec
  ( Codec (..), DbType (..), dimap, lmap, refine, nullable, encode )

newtype Email = Email Text deriving newtype DbType            -- GND over Text
newtype Money = Money Int                                     -- explicit dimap
instance DbType Money where dbType = dimap (\(Money n) -> n) Money (dbType @Int)
newtype Age = Age Int                                         -- validated: lmap encode + refine decode
instance DbType Age where
  dbType = refine (\n -> if n >= 0 then Right (Age n) else Left (DecodeErr)) (lmap (\(Age n) -> n) (dbType @Int))
  -- NOTE: use the real DecodeError constructor exported from the module; see Step 3.

tests :: Tree
tests = group "Codec"
  [ test "deriving newtype DbType reuses the base column type + encode" $ do
      assertEqual "Email sqltype is Text's" (cSqlType (dbType @Email)) (cSqlType (dbType @Text))
      assertEqual "Email encodes via Text"  (encode (Email (T.pack "ada"))) (encode (T.pack "ada"))
  , test "dimap builds a domain column over Int" $
      assertEqual "Money encodes its Int" (encode (Money 100)) (encode (100 :: Int))
  , test "nullable maps NULL <-> Nothing and flags nullable" $ do
      assertEqual "Nothing -> NULL" (encode (Nothing :: Maybe Int)) Nothing
      assertBool  "Maybe is nullable" (cNullable (dbType @(Maybe Int)))
  , test "refine rejects invalid decodes" $ do
      assertBool "accepts 5"   (either (const False) (const True) (cDecode (dbType @Age) (Just (T.encodeUtf8 (T.pack "5")))))
      assertBool "rejects -1"  (either (const True) (const False) (cDecode (dbType @Age) (Just (T.encodeUtf8 (T.pack "-1")))))
  ]
```

> The exact `assertEqual`/`Tree`/`group` names must match `test/Harness.hs` — read it first and adjust (the other spec modules, e.g. `TypedFieldsSpec`, show the exact API). The `Age` decode test passes a `SqlParam` (`Maybe ByteString`); use the same `ByteString` construction the codebase uses (`Data.ByteString.Char8.pack`). Replace the placeholder `DecodeErr` with the real `DecodeError` constructor.

Register it in `test/Spec.hs`: add `import qualified CodecSpec` and `CodecSpec.tests` to the list of test trees (mirror how the other `*Spec` modules are wired).

- [ ] **Step 3: Run the test to verify it fails**

`nix develop -c zinc test 2>&1 | tail -20`.
Expected: compile failure — `Codec`/`DbType`/`dimap`/etc. not in scope (not yet defined).

- [ ] **Step 4: Implement `Codec` + `DbType` in `src/Manifest/Core/Codec.hs`**

Read the current module first. ADD the following (do NOT remove `ToField`/`FromField`/`field` yet — they stay until Task 4). Add to the export list: `Codec(..)`, `DbType(..)`, `dimap`, `lmap`, `rmap`, `refine`, `nullable`, `encode`, `decodeCol`. Add `{-# LANGUAGE FlexibleInstances #-}` (already present) and `{-# LANGUAGE TypeApplications #-}`, `{-# LANGUAGE ScopedTypeVariables #-}`.

```haskell
-- The column codec: contravariant in the encoded value, covariant in the decoded one.
data Codec a b = Codec
  { cEncode   :: a -> SqlParam
  , cDecode   :: SqlParam -> Either DecodeError b
  , cSqlType  :: SqlType
  , cNullable :: Bool
  }

-- Profunctor vocabulary. cSqlType/cNullable ride along unchanged (newtype reuse).
-- If `profunctors` is available, replace these with `import Data.Profunctor (Profunctor(..))`
-- + `instance Profunctor Codec where dimap f g (Codec e d s n) = Codec (e . f) (fmap g . d) s n`
-- and re-export dimap/lmap/rmap from Data.Profunctor (delete the three definitions below).
dimap :: (a' -> a) -> (b -> b') -> Codec a b -> Codec a' b'
dimap f g (Codec e d s n) = Codec (e . f) (fmap g . d) s n
lmap :: (a' -> a) -> Codec a b -> Codec a' b
lmap f = dimap f id
rmap :: (b -> b') -> Codec a b -> Codec a b'
rmap = dimap id

-- A failing/validated decode (no Profunctor-class equivalent).
refine :: (b -> Either DecodeError c) -> Codec a b -> Codec a c
refine k (Codec e d s n) = Codec e (\p -> d p >>= k) s n

-- Lift a non-null codec to a nullable one.
nullable :: Codec a a -> Codec (Maybe a) (Maybe a)
nullable (Codec e d s _) =
  Codec (maybe Nothing e)
        (\p -> case p of Nothing -> Right Nothing; Just v -> Just <$> d (Just v))
        s True

-- The single leaf codec class.
class DbType a where
  dbType :: Codec a a

instance DbType Int where
  dbType = Codec (Just . BC.pack . show)
                 (\p -> case p of
                          Just bs -> maybe (Left (DecodeError ("expected Int, got " <> show (BC.unpack bs)))) Right (readMaybe (BC.unpack bs))
                          Nothing -> Left (DecodeError "expected Int, got NULL"))
                 SqlBigInt False

instance DbType Text where
  dbType = Codec (Just . TE.encodeUtf8)
                 (\p -> case p of Just bs -> Right (TE.decodeUtf8 bs); Nothing -> Left (DecodeError "expected Text, got NULL"))
                 SqlText False

instance DbType Bool where
  dbType = Codec (\b -> Just (if b then BC.pack "t" else BC.pack "f"))
                 (\p -> case p of
                          Just bs -> case BC.unpack bs of "t" -> Right True; "f" -> Right False; o -> Left (DecodeError ("expected Bool (t/f), got " <> show o))
                          Nothing -> Left (DecodeError "expected Bool, got NULL"))
                 SqlBool False

instance DbType String where
  dbType = dimap T.pack T.unpack (dbType :: Codec Text Text)

instance DbType a => DbType (Maybe a) where
  dbType = nullable dbType

-- Replacements for toField / `field`, off the codec.
encode :: DbType a => a -> SqlParam
encode = cEncode dbType

decodeCol :: forall a. DbType a => RowDecoder a
decodeCol = RowDecoder $ \cs -> case cs of
  (c:rest) -> (\a -> (a, rest)) <$> cDecode (dbType @a) c
  []       -> Left (DecodeError "ran out of columns while decoding row")
```

Ensure imports for `SqlType(..)` (from `Manifest.Core.SqlType`), `readMaybe`, `BC`, `TE`, `T` are present (the module already imports most). `SqlType` constructors used: `SqlBigInt`, `SqlText`, `SqlBool`.

- [ ] **Step 5: Run tests to verify they pass**

`nix develop -c zinc test 2>&1 | tail -20` then `nix develop -c .zinc/build/spec 2>&1 | tail -3`.
Expected: **120/120** (116 + 4 new Codec tests). The old suite is untouched (additive), the 4 new tests pass.

- [ ] **Step 6: Deliberate-failure check + commit**

Temporarily change `assertEqual "Money encodes its Int" (encode (Money 100)) (encode (100 :: Int))` to `(encode (101 :: Int))`, rerun, confirm FAIL, restore, confirm 120/120. Then:
```bash
git add src/Manifest/Core/Codec.hs test/CodecSpec.hs test/Spec.hs zinc.toml
git status   # if .beads/issues.jsonl staged: git restore --staged .beads/issues.jsonl
git commit -m "feat(core): add Codec profunctor + DbType class (additive)"
```

---

### Task 2: Migrate the generic engine (metadata + row codec) to `DbType`

Now route the derivation through `DbType`. Old classes still exist but the engine stops using them.

**Files:** Modify `src/Manifest/Core/Table.hs`, `src/Manifest/Entity.hs`, `src/Manifest/Derive.hs`.

- [ ] **Step 1: `Core/Table.hs` — base `FieldMeta` reads the codec**

The base instance currently is (lines ~77-81):
```haskell
instance {-# OVERLAPPABLE #-} ScalarMeta a => FieldMeta a where
  fieldIsPK     = False
  fieldIsSerial = False
  fieldSqlType  = scalarType @a
  fieldNullable = scalarNullable @a
```
Change it to read the codec (do NOT delete the `ScalarMeta` class yet — that is Task 4):
```haskell
instance {-# OVERLAPPABLE #-} DbType a => FieldMeta a where
  fieldIsPK     = False
  fieldIsSerial = False
  fieldSqlType  = cSqlType  (dbType @a)
  fieldNullable = cNullable (dbType @a)
```
Add `import Manifest.Core.Codec (DbType(..), Codec(..))` (or extend the existing import). The `PrimaryKey`/`Serial` `FieldMeta` instances are unchanged.

- [ ] **Step 2: `Entity.hs` — generic codec leaves + `genericPrimKey` use `DbType`**

Change the import line 39 from `import Manifest.Core.Codec (FromField, fromField, RowDecoder, SqlParam, ToField(..), field)` to `import Manifest.Core.Codec (DbType(..), Codec(..), RowDecoder, SqlParam, encode, decodeCol)`.

Leaf instances (lines ~103, 119-120):
```haskell
instance DbType t => GRowDecode (S1 m (Rec0 t)) where
  gRowDecode = M1 . K1 <$> decodeCol
...
instance DbType t => GRowEncode (S1 m (Rec0 t)) where
  gRowEncode (M1 (K1 x)) = [encode x]
```

`genericPrimKey` (line ~129) and the `default primKey` signature (line ~79): replace `FromField (PrimKey a)` with `DbType (PrimKey a)`, and its body's `fromField` with `cDecode (dbType @(PrimKey a))`:
```haskell
genericPrimKey :: forall a. (Entity a, DbType (PrimKey a)) => a -> PrimKey a
genericPrimKey a =
  case cDecode (dbType @(PrimKey a)) (rowEncode a !! pkIndex @a) of
    Right v  -> v
    Left err -> error ("Manifest.genericPrimKey: " <> show err)
```
```haskell
  default primKey :: DbType (PrimKey a) => a -> PrimKey a
```

- [ ] **Step 3: `Derive.hs` — carrier constraint uses `DbType`**

Change `import Manifest.Core.Codec (FromField)` to `import Manifest.Core.Codec (DbType)`, and the carrier instance constraint (line ~35) `FromField (PrimKey (Table name t))` → `DbType (PrimKey (Table name t))`.

- [ ] **Step 4: Build + test**

`nix develop -c zinc test 2>&1 | tail -20` then `nix develop -c .zinc/build/spec 2>&1 | tail -3`.
Expected: **120/120** unchanged. The derivation now flows through `DbType`; identical bytes/types, so every existing entity/CRUD/migration test still passes.

- [ ] **Step 5: Commit**
```bash
git add src/Manifest/Core/Table.hs src/Manifest/Entity.hs src/Manifest/Derive.hs
git status   # unstage .beads/issues.jsonl if needed
git commit -m "refactor(core): route the generic engine through DbType"
```

---

### Task 3: Migrate the query / session / command call sites to `DbType`

**Files:** Modify `src/Manifest/Core/Query.hs`, `src/Manifest/Query.hs`, `src/Manifest/Relation/Loaded.hs`, `src/Manifest/Session.hs`, `src/Manifest/Session/Command.hs`.

- [ ] **Step 1: `Core/Query.hs` — comparison + assignment operators**

Import (line 24): `import Manifest.Core.Codec (SqlParam, ToField(..))` → `import Manifest.Core.Codec (SqlParam, DbType, encode)`.
Operators (lines 60-68):
```haskell
(==.), (/=.), (>.), (<.) :: DbType t => Column a t -> t -> Cond a
Column n ==. v = Cond n OpEq  (encode v)
Column n /=. v = Cond n OpNeq (encode v)
Column n >.  v = Cond n OpGt  (encode v)
Column n <.  v = Cond n OpLt  (encode v)

(=.) :: DbType t => Column a t -> t -> Assign a
Column n =. v = Assign n (encode v)
```

- [ ] **Step 2: `Query.hs` — builder `val` + `Selectable (Expr t)`**

Import (line 43): replace `ToField (..)`/`FromField`/`field` with `DbType`, `encode`, `decodeCol` (keep `RowDecoder(..)`, `SqlParam`, `decodeRow`).
```haskell
val :: DbType t => t -> Expr t
val x = Expr "?" [encode x]
```
`Selectable (Expr t)` instance (line ~306): `instance FromField t => Selectable (Expr t)` → `instance DbType t => Selectable (Expr t)`; wherever its body uses `field`, use `decodeCol`.

- [ ] **Step 3: `Relation/Loaded.hs` — `getEnt`**

Import (line 39): `ToField` → `DbType`. Constraint (line 64): `getEnt :: (Entity a, DbType (PrimKey a)) => Key a -> Db (Maybe (Ent '[] a))`.

- [ ] **Step 4: `Session.hs` — `get`**

Import (line 43): `ToField(..)` → `DbType`, `encode` (keep `SqlParam`, `decodeRow`). Constraint (line 124): `get :: forall a. (Entity a, DbType (PrimKey a)) => Key a -> Db (Maybe a)`. Body (lines 128-129): `toField k` → `encode k` (both occurrences).

- [ ] **Step 5: `Session/Command.hs` — `update`**

Import (line 14): `ToField(..)` → `DbType`, `encode`. Constraint (line 23): `update :: forall a. (Entity a, DbType (PrimKey a)) => Key a -> [Assign a] -> Db ()`. Body (line 27): `toField (unKey key)` → `encode (unKey key)`.

- [ ] **Step 6: Build + test**

`nix develop -c zinc test 2>&1 | tail -20` then `nix develop -c .zinc/build/spec 2>&1 | tail -3`.
Expected: **120/120**. After this, the only references to `ToField`/`FromField`/`ScalarMeta` are their own definitions, the umbrella re-exports, and entity `deriving newtype` clauses. Verify: `nix develop -c grep -rnE "ToField|FromField|ScalarMeta" src | grep -v "Core/Codec.hs\|Core/Table.hs\|Manifest.hs"` returns nothing.

- [ ] **Step 7: Commit**
```bash
git add src/Manifest/Core/Query.hs src/Manifest/Query.hs src/Manifest/Relation/Loaded.hs src/Manifest/Session.hs src/Manifest/Session/Command.hs
git status   # unstage .beads if needed
git commit -m "refactor(core): migrate query/session/command codec sites to DbType"
```

---

### Task 4: Migrate newtype entities, delete the three old classes

**Files:** Modify `test/TypedFieldsSpec.hs` (and any other newtype-deriving site), `src/Manifest/Core/Codec.hs`, `src/Manifest/Core/Table.hs`, `src/Manifest.hs`.

- [ ] **Step 1: Migrate newtype deriving clauses**

Find them: `nix develop -c grep -rnE "deriving newtype \(?.*(ToField|FromField|ScalarMeta)" test app src`. In `test/TypedFieldsSpec.hs`, change each `deriving newtype (ToField, FromField, ScalarMeta)` (e.g. on `AccountId`, `NoteId`, `Email`) to `deriving newtype DbType`. Apply to every match found.

- [ ] **Step 2: Delete `ToField`/`FromField`/`field` from `Core/Codec.hs`**

Remove the `ToField` class + all its instances, the `FromField` class + all its instances, and the `field` function. Remove `ToField(..)`, `FromField(..)`, `field` from the export list. KEEP `SqlParam`, `RowDecoder(..)`, `decodeRow`, `DecodeError` re-export, and everything added in Task 1.

- [ ] **Step 3: Delete `ScalarMeta` from `Core/Table.hs`**

Remove the `ScalarMeta` class + its 4 instances (`Int`/`Text`/`Bool`/`Maybe`). Remove `ScalarMeta(..)` from the export list. The base `FieldMeta` instance (now `DbType a => FieldMeta a` from Task 2) stays.

- [ ] **Step 4: Fix umbrella re-exports in `Manifest.hs`**

There are two places (lines ~93-95 and ~184-191) that re-export `ToField(..)`/`FromField(..)`/`ScalarMeta(..)`. Replace those entries with `DbType(..)`, `Codec(..)`, `dimap`, `lmap`, `rmap`, `refine`, `nullable`, `encode`. Keep `SqlType(..)`. Update the corresponding `import Manifest.Core.Codec (...)` / `import Manifest.Core.Table (...)` lines in `Manifest.hs` accordingly.

- [ ] **Step 5: Build + test**

`nix develop -c zinc test 2>&1 | tail -25` then `nix develop -c .zinc/build/spec 2>&1 | tail -3`.
Expected: **120/120**. The typed-fields DB round-trip tests now prove `deriving newtype DbType` works end to end through Postgres. Verify the classes are gone: `nix develop -c grep -rnE "\b(ToField|FromField|ScalarMeta)\b" src test app` returns nothing.

- [ ] **Step 6: Commit**
```bash
git add -A
git status   # confirm only intended files; unstage .beads/issues.jsonl if staged
git commit -m "refactor(core): remove ToField/FromField/ScalarMeta; DbType is the only codec class"
```

---

### Task 5: Rename `Col` → `Field` + `Pk`/`Nullable` aliases

**Files:** Modify `src/Manifest/Core/Table.hs`, `src/Manifest.hs`, all entity decls (`test/Fixtures.hs`, `test/RlsSpec.hs`, `test/TypedFieldsSpec.hs`, `app/Main.hs`), docs.

- [ ] **Step 1: Rename the family + add aliases in `Core/Table.hs`**

Rename the `Col` type family to `Field` and add the aliases:
```haskell
type family Field (f :: Type -> Type) (a :: Type) :: Type where
  Field Identity a = Base a
  Field Exposed  a = Exposed a

type Pk a       = PrimaryKey (Serial a)
type Nullable a = Maybe a
```
Export list: `Col` → `Field`; add `Pk`, `Nullable`.

- [ ] **Step 2: Update the umbrella + every entity declaration**

In `Manifest.hs`: re-export `Field`, `Pk`, `Nullable` where `Col` was exported. In each entity module, mechanically change `Col f` → `Field f`, and `PrimaryKey (Serial T)` → `Pk T` (and nullable `Maybe T` columns may use `Nullable T`, optional). Find sites: `nix develop -c grep -rnE "Col f|PrimaryKey \(Serial" test app src`. This is a pure spelling change: at `Exposed`, `Field Exposed a` reduces to `Exposed a`, so the generic walks and `GPrimKeyType` (which match `Rec0 (Exposed t)`) are untouched.

- [ ] **Step 3: Build + test**

`nix develop -c zinc test 2>&1 | tail -20` then `nix develop -c .zinc/build/spec 2>&1 | tail -3`.
Expected: **120/120**. Verify the old name is gone: `nix develop -c grep -rnE "\bCol f|type Col\b" src test app` returns nothing.

- [ ] **Step 4: Update docs**

In `docs/entities.md`, `docs/getting-started.md`, `docs/index.md`: change `Col f` → `Field f`, `PrimaryKey (Serial …)` → `Pk …`, and update the typed-fields section to show `deriving newtype DbType` and a `dimap` domain column. Manual voice: no em-dashes, no other-ORM names, no positioning claims. Verify: `nix develop -c grep -rnE "Col f|deriving newtype \(.*ToField" docs` returns nothing; `grep -n "—" docs/entities.md` finds none in edited sections.

- [ ] **Step 5: Commit**
```bash
git add -A
git status   # unstage .beads/issues.jsonl if staged
git commit -m "feat(core): rename Col to Field; add Pk/Nullable aliases; docs"
```

---

### Task 6: Custom-column DB round-trip test (new capability)

The unit tests (Task 1) cover the codec at the value level; the typed-fields DB tests (Task 4) cover `deriving newtype DbType` through Postgres. Add a DB round-trip for a `dimap` domain column to prove that path end to end.

**Files:** Modify `test/TypedFieldsSpec.hs`.

- [ ] **Step 1: Write the test**

Add a domain newtype defined via `dimap` (not GND) and a column using it. Read the file for the exact harness API (`withEmptyDb`/`withConnection`/`execText`/`withSession`/`add`/`get`/`selectWhere`/`==.`).
```haskell
newtype Cents = Cents Int deriving (Eq, Show)
instance DbType Cents where dbType = dimap (\(Cents n) -> n) Cents (dbType @Int)

data ItemT f = Item
  { itemId    :: Field f (Pk Int)
  , itemPrice :: Field f Cents
  } deriving Generic
type Item = ItemT Identity
deriving via (Table "items" ItemT) instance Entity Item

itemsDDL :: BC.ByteString
itemsDDL = "CREATE TABLE items ( item_id BIGSERIAL PRIMARY KEY, item_price BIGINT NOT NULL )"
```
Test case (append to the group):
```haskell
  , test "a dimap-defined domain column round-trips through the DB" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c itemsDDL [])
        out <- withSession pool $ do
          i  <- add (Item { itemId = 0, itemPrice = Cents 1999 } :: Item)
          mi <- get @Item (Key (itemId i))
          is <- selectWhere [ #itemPrice ==. Cents 1999 ]
          pure (fmap itemPrice mi, map itemPrice (is :: [Item]))
        assertEqual "got price by key" (Just (Cents 1999)) (fst out)
        assertEqual "found by typed col" [Cents 1999] (snd out)
```

- [ ] **Step 2: Run + deliberate-failure check**

`nix develop -c .zinc/build/spec 2>&1 | tail -3` → **121/121**. Change `Cents 1999` expectation to `Cents 2000`, confirm FAIL, restore, confirm 121/121.

- [ ] **Step 3: Commit**
```bash
git add test/TypedFieldsSpec.hs
git commit -m "test(core): dimap domain column round-trips through the DB"
```

---

## Self-Review

**1. Spec coverage** (against `2026-06-09-codec-primary-core-design.md`):
- §1 `Codec` + `dimap`/`lmap`/`rmap`/`refine`/`nullable` + `Profunctor` → Task 1 Step 4 (with the `profunctors`-or-functions fallback at Step 1). ✓
- §2 `DbType` + scalar instances + `encode`/`decodeCol` → Task 1 Step 4. ✓
- §3 removal of the three classes + all constraint sites migrated → Tasks 2-4 (every site from the grep sweep is listed: Query ops, Entity leaves, Derive, Query builder, Loaded, Session, Command, FieldMeta, umbrella). ✓
- §3.1 `deriving newtype DbType` idiom → Task 4 Step 1 + Task 1 unit test. ✓
- §4 `Col`→`Field` + `Pk`/`Nullable` + docs → Task 5. ✓
- §6 feasibility — pre-verified by scratch before this plan (noted in the header); §7 testing (suite as oracle + dimap/GND/refine tests) → Tasks 1 & 6, plus the existing typed-fields DB tests exercising GND after Task 4. ✓
- §7 out-of-scope (JSONB/autodocodec, ProductProfunctor, table mappings) — not touched. ✓

**2. Placeholder scan:** Concrete code/commands per step. The two genuinely environment-dependent spots are called out with explicit handling, not left vague: the `profunctors` availability (Task 1 Step 1 fallback to local functions) and the exact `Harness` API names (Task 1 Step 2 instructs reading `test/Harness.hs`). No TBD/TODO.

**3. Type consistency:** `Codec`/`DbType`/`dbType`/`cEncode`/`cDecode`/`cSqlType`/`cNullable`/`encode`/`decodeCol`/`dimap`/`lmap`/`rmap`/`refine`/`nullable` are used identically across Tasks 1-6. `genericPrimKey`'s constraint `DbType (PrimKey a)` matches the `default primKey` signature and the carrier instance constraint in `Derive.hs`. `Field`/`Pk`/`Nullable` (Task 5) match the spec's §4/§5. Counts thread consistently: 116 → 120 (Task 1, +4 unit) → held through Tasks 2-5 → 121 (Task 6, +1).
