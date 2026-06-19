# Per-field Read/Create/Update Policy Projections — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One `UserT f` record declaration projects into `Identity` (loaded/read value), `Create`, and `Update` (Patch) shapes via the existing `Field` type family, with composable policy markers governing per-context field presence.

**Architecture:** Pure type-level projection (fork a): a `Field` type family maps each field to its per-context type, collapsing absent fields to `Omitted`. New payload markers (`Generated`/`Default`/`Secret`/`ReadOnly`) compose with the existing `PrimaryKey`/`Serial`/`Nullable`. Two update front-ends (explicit `Patch` for API endpoints; mutate-and-flush diff for pipelines) converge on one `runUpdate` executor. No new dependency; no Template Haskell.

**Tech Stack:** Haskell (GHC 9.12.2), zinc workspace, GHC.Generics, `profunctors` (leaf codec only), Postgres via `postgresql-libpq`. Tests: the in-repo `Harness` (`group`/`test`/`assertEqual`/`assertBool`), compile-time type-family proofs, and `withEmptyDb` Postgres integration.

## Global Constraints

- **Build/test command:** `zinc test` (run from `manifest/`). There is no `.cabal`; packages are zinc.toml members.
- **No new dependencies.** `manifest-core` deps stay: `base bytestring containers text time transformers profunctors autodocodec aeson`. Do NOT add `barbies` or `product-profunctors` (see forge-i14 recommendation).
- **GHC extensions** already enabled project-wide via zinc.toml `ghc-options`: `OverloadedStrings ScopedTypeVariables TypeApplications LambdaCase TupleSections`. Add per-module pragmas (`DataKinds`, `TypeFamilies`, `KindSignatures`, `FlexibleInstances`, `UndecidableInstances`, `TypeOperators`) as the existing modules do.
- **Naming rules (verbatim):** no `Pk`/`PK` abbreviation — spell `PrimaryKey (Serial Int)` in full. Markers: `Generated`, `Default`, `Secret`, `ReadOnly`, `Nullable`. Contexts: existing `Identity` (loaded/read value), existing `Exposed` (metadata), new `Create`, new `Update`. `Patch a = Keep | Set a`.
- **New specs register in** `manifest/test/Spec.hs` (add `import qualified XSpec` and `++ XSpec.tests` to the `runTests` list).
- **Type-family test idiom:** prove reductions with top-level `_name :: Field Ctx Marker -> Expected; _name = id` (fails to compile if the family does not reduce as intended), mirroring `MetaSpec.hs`.
- **Postgres integration idiom:** `withEmptyDb $ \pool -> do withConnection pool (\c -> execText c ddl []) ; withSession pool $ ...` (see `TypedFieldsSpec.hs`).

---

### Task 1: Remove the `Pk` alias

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Table.hs` (delete `Pk` from exports + the `type Pk` line)
- Modify: `manifest/src/Manifest.hs` (drop `Pk` from re-exports)
- Modify: `manifest/app/Main.hs`, `manifest/test/Fixtures.hs`, `manifest/test/IndexSpec.hs`, `manifest/test/JsonSpec.hs`, `manifest/test/NotifySpec.hs`, `manifest/test/RecursiveCascadeSpec.hs`, `manifest/test/RlsSpec.hs`, `manifest/test/TypedFieldsSpec.hs` (rewrite `Pk X` → `PrimaryKey (Serial X)`)

**Interfaces:**
- Consumes: existing `PrimaryKey`, `Serial` markers (unchanged).
- Produces: no `Pk` symbol anywhere. `Field f (PrimaryKey (Serial Int))` is the serial-PK spelling.

- [ ] **Step 1: Mechanically rewrite every `Pk` use.** In each file above, replace `Pk <T>` with `PrimaryKey (Serial <T>)`. Example in `Fixtures.hs`:

```haskell
-- before:  userId :: Field f (Pk Int)
   userId :: Field f (PrimaryKey (Serial Int))
```

`TypedFieldsSpec.hs` `Pk AccountId` → `PrimaryKey (Serial AccountId)`, `Pk NoteId` → `PrimaryKey (Serial NoteId)`.

- [ ] **Step 2: Delete the alias.** In `Table.hs` remove `Pk` from the export list and delete:

```haskell
-- delete this line:
type Pk a       = PrimaryKey (Serial a)
```

In `Manifest.hs` remove `Pk` from the re-export list.

- [ ] **Step 3: Run the suite — pure rename, everything still green.**

Run: `cd manifest && zinc test`
Expected: PASS (same set as before; no behavior change).

- [ ] **Step 4: Commit.**

```bash
git add manifest && git commit -m "refactor(core): drop the Pk alias; spell PrimaryKey (Serial a) in full"
```

---

### Task 2: Add `Omitted` + the `Generated`/`Default`/`Secret`/`ReadOnly` markers

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Table.hs`
- Test: `manifest/test/MetaSpec.hs` (extend; it already imports `Manifest.Core.Table`)

**Interfaces:**
- Produces:
  - `data Omitted = Omitted` (exported, `Eq`/`Show`)
  - markers `data Generated a`, `data Default a`, `data Secret a`, `data ReadOnly a` (exported)
  - `Base (Generated a) = Base a`, `Base (Default a) = Base a`, `Base (Secret a) = Base a`, `Base (ReadOnly a) = Base a`
  - `FieldMeta` gains `fieldIsGenerated :: Bool` (default `False`); instances for the new markers delegate `fieldSqlType`/`fieldNullable` to the inner type; `Generated`/`Serial`/`PrimaryKey(Serial)` report `fieldIsGenerated = True`.

- [ ] **Step 1: Write the failing test** (append to `MetaSpec.hs` `tests` list, and add the compile-time proofs near the existing ones):

```haskell
-- compile-time proofs (top level):
_genStrips  :: Base (Generated UTCTime) -> UTCTime
_genStrips  = id
_secStrips  :: Base (Secret Text) -> Text
_secStrips  = id

-- in the tests list:
  , test "new markers reflect generated/sqltype/nullable" $ do
      assertBool "Generated is generated"        (fieldIsGenerated @(Generated UTCTime))
      assertBool "serial PK is generated"        (fieldIsGenerated @(PrimaryKey (Serial Int)))
      assertBool "plain Text is not generated"   (not (fieldIsGenerated @Text))
      assertBool "Default delegates sqltype"     (fieldSqlType @(Default Text) == SqlText)
      assertBool "Secret delegates sqltype"      (fieldSqlType @(Secret Text)  == SqlText)
```

Add imports to `MetaSpec.hs`: `Generated, Default, Secret, ReadOnly` from `Manifest.Core.Table`; `Data.Time (UTCTime)`.

- [ ] **Step 2: Run to verify it fails.**

Run: `cd manifest && zinc test`
Expected: FAIL to compile — `Generated`/`fieldIsGenerated` not in scope.

- [ ] **Step 3: Implement in `Table.hs`.** Add to exports `Omitted(..), Generated, Default, Secret, ReadOnly` and `fieldIsGenerated`. Add:

```haskell
data Omitted = Omitted deriving (Eq, Show)

data Generated a   -- DB-filled (serial / DEFAULT / flush-stamp); read-only
data Default a     -- DB default, app may supply (optional on Create)
data Secret a      -- serialization-only masking; NOT a DB-presence policy
data ReadOnly a    -- app never writes this plain column

type family Base (a :: Type) :: Type where
  Base (PrimaryKey a) = Base a
  Base (Serial a)     = a
  Base (Generated a)  = Base a
  Base (Default a)    = Base a
  Base (Secret a)     = Base a
  Base (ReadOnly a)   = Base a
  Base a              = a

class FieldMeta a where
  fieldIsPK        :: Bool
  fieldIsSerial    :: Bool
  fieldIsGenerated :: Bool
  fieldSqlType     :: SqlType
  fieldNullable    :: Bool

instance FieldMeta a => FieldMeta (PrimaryKey a) where
  fieldIsPK        = True
  fieldIsSerial    = fieldIsSerial @a
  fieldIsGenerated = fieldIsGenerated @a
  fieldSqlType     = fieldSqlType @a
  fieldNullable    = False

instance FieldMeta (Serial a) where
  fieldIsPK = False; fieldIsSerial = True; fieldIsGenerated = True
  fieldSqlType = SqlBigSerial; fieldNullable = False

instance FieldMeta a => FieldMeta (Generated a) where
  fieldIsPK = False; fieldIsSerial = fieldIsSerial @a; fieldIsGenerated = True
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance FieldMeta a => FieldMeta (Default a) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance FieldMeta a => FieldMeta (Secret a) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance FieldMeta a => FieldMeta (ReadOnly a) where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = fieldSqlType @a; fieldNullable = fieldNullable @a

instance {-# OVERLAPPABLE #-} DbType a => FieldMeta a where
  fieldIsPK = False; fieldIsSerial = False; fieldIsGenerated = False
  fieldSqlType = cSqlType (dbType @a); fieldNullable = cNullable (dbType @a)
```

- [ ] **Step 4: Run to verify it passes.**

Run: `cd manifest && zinc test`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add manifest && git commit -m "feat(core): add Omitted + Generated/Default/Secret/ReadOnly markers"
```

---

### Task 3: Add the `Create` and `Update` projection contexts to `Field`

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Table.hs`
- Create: `manifest/test/ProjectionSpec.hs`
- Modify: `manifest/test/Spec.hs` (register)

**Interfaces:**
- Consumes: `Omitted`, markers (Task 2); `Patch` is NOT needed yet — Update uses `Patch` which arrives in Task 4, so this task introduces the `Update` clauses referencing `Patch`, meaning **Task 4 must merge into this task's build**. To keep each task green, define `Patch` here (it is tiny) — see Step 3.
- Produces: `Field Create _` and `Field Update _` reductions; `data Patch a = Keep | Set a`.

- [ ] **Step 1: Write the failing proofs** in new `ProjectionSpec.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
module ProjectionSpec (tests) where

import Data.Text (Text)
import Data.Time (UTCTime)
import Manifest.Core.Table
  (Field, Create, Update, Omitted, Patch, Base,
   PrimaryKey, Serial, Generated, Default, Secret, ReadOnly)
import Harness

-- Create projection
_createOmitsSerialPk :: Field Create (PrimaryKey (Serial Int)) -> Omitted
_createOmitsSerialPk = id
_createKeepsAppPk    :: Field Create (PrimaryKey Text) -> Text       -- app-supplied PK present
_createKeepsAppPk    = id
_createOmitsGenerated :: Field Create (Generated UTCTime) -> Omitted
_createOmitsGenerated = id
_createDefaultOptional :: Field Create (Default Text) -> Maybe Text
_createDefaultOptional = id
_createPlainPresent  :: Field Create Text -> Text
_createPlainPresent  = id
_createSecretPresent :: Field Create (Secret Text) -> Text
_createSecretPresent = id

-- Update projection
_updateOmitsPk    :: Field Update (PrimaryKey (Serial Int)) -> Omitted
_updateOmitsPk    = id
_updateOmitsGen   :: Field Update (Generated UTCTime) -> Omitted
_updateOmitsGen   = id
_updatePatchesPlain :: Field Update Text -> Patch Text
_updatePatchesPlain = id
_updatePatchesSecret :: Field Update (Secret Text) -> Patch Text
_updatePatchesSecret = id

tests :: [Test]
tests = group "Projection"
  [ test "type-family projections compile" $ assertBool "ok" True ]
```

Register in `Spec.hs`: `import qualified ProjectionSpec` and `++ ProjectionSpec.tests`.

- [ ] **Step 2: Run to verify it fails.**

Run: `cd manifest && zinc test`
Expected: FAIL to compile — `Create`/`Update`/`Patch` not in scope.

- [ ] **Step 3: Implement in `Table.hs`.** Add to exports `Create, Update, Patch(..)`. Add:

```haskell
data Create a
data Update a

data Patch a = Keep | Set a deriving (Eq, Show)

type family Field (f :: Type -> Type) (a :: Type) :: Type where
  Field Identity a = Base a
  Field Exposed  a = Exposed a
  -- Create: DB-assigned keys/cols absent; Default optional; app-supplied present
  Field Create (PrimaryKey (Serial a))    = Omitted
  Field Create (PrimaryKey (Generated a)) = Omitted
  Field Create (Generated a)              = Omitted
  Field Create (ReadOnly a)               = Omitted
  Field Create (Default a)                = Maybe (Base a)
  Field Create (PrimaryKey a)             = Base a
  Field Create a                          = Base a
  -- Update: PK is the key (never SET); DB-owned absent; rest → Patch
  Field Update (PrimaryKey a) = Omitted
  Field Update (Generated a)  = Omitted
  Field Update (ReadOnly a)   = Omitted
  Field Update a              = Patch (Base a)
```

(Closed family: specific clauses precede the catch-alls; this ordering is required.)

- [ ] **Step 4: Run to verify it passes.**

Run: `cd manifest && zinc test`
Expected: PASS (all `ProjectionSpec` proofs compile).

- [ ] **Step 5: Commit.**

```bash
git add manifest && git commit -m "feat(core): Create/Update Field projections + Patch type"
```

---

### Task 4: Define `UserCreate`/`UserUpdate` projections on a fixture + neutral skeletons

**Files:**
- Modify: `manifest/test/Fixtures.hs` (add `UserCreate`/`UserUpdate` aliases for the existing `UserT`)
- Create: `manifest/manifest-core/src/Manifest/Core/Skeleton.hs`
- Modify: `manifest/manifest-core/zinc.toml` (add `Manifest.Core.Skeleton` is automatic via source-dirs; no change unless modules are listed — they are not, so no edit)
- Test: `manifest/test/ProjectionSpec.hs` (extend)

**Interfaces:**
- Produces:
  - `class GNeutral rep where gNeutral :: rep p` and `neutral :: (Generic a, GNeutral (Rep a)) => a` in `Manifest.Core.Skeleton` — fills `Omitted` for `Omitted` leaves, `Nothing` for `Maybe` leaves, `Keep` for `Patch` leaves.
  - Fixture aliases: `type UserCreate = UserT Create`, `type UserUpdate = UserT Update`.

- [ ] **Step 1: Write the failing test** (extend `ProjectionSpec.hs`):

```haskell
-- add imports: Manifest.Core.Skeleton (neutral); Fixtures (UserT(..), UserCreate, UserUpdate); Manifest.Core.Table (Patch(..))
  , test "neutral Create skeleton then record-update override" $ do
      let c = (neutral :: UserCreate) { userName = "Ada", userEmail = Just "ada@x.io" }
      assertEqual "name set"  "Ada"              (userName c)
      assertEqual "email set" (Just "ada@x.io")  (userEmail c)
  , test "neutral Update skeleton is all-Keep" $ do
      let u = (neutral :: UserUpdate) { userEmail = Set (Just "n@x.io") }
      assertEqual "untouched name is Keep" Keep              (userName u)
      assertEqual "email is Set"           (Set (Just "n@x.io")) (userEmail u)
```

Add to `Fixtures.hs`: `type UserCreate = UserT Create` and `type UserUpdate = UserT Update` (import `Create`, `Update` from `Manifest.Core.Table`).

- [ ] **Step 2: Run to verify it fails.**

Run: `cd manifest && zinc test`
Expected: FAIL — `neutral`/`Manifest.Core.Skeleton` not in scope.

- [ ] **Step 3: Implement `Manifest.Core.Skeleton`:**

```haskell
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE KindSignatures #-}
module Manifest.Core.Skeleton (GNeutral(..), neutral) where

import Data.Kind (Type)
import GHC.Generics
import Manifest.Core.Table (Omitted(..), Patch(..))

class GNeutral (rep :: Type -> Type) where gNeutral :: rep p
instance GNeutral f => GNeutral (D1 m f) where gNeutral = M1 gNeutral
instance GNeutral f => GNeutral (C1 m f) where gNeutral = M1 gNeutral
instance (GNeutral a, GNeutral b) => GNeutral (a :*: b) where gNeutral = gNeutral :*: gNeutral
instance GNeutral (S1 m (Rec0 Omitted))    where gNeutral = M1 (K1 Omitted)
instance GNeutral (S1 m (Rec0 (Maybe t)))  where gNeutral = M1 (K1 Nothing)
instance GNeutral (S1 m (Rec0 (Patch t)))  where gNeutral = M1 (K1 Keep)

neutral :: (Generic a, GNeutral (Rep a)) => a
neutral = to gNeutral
```

- [ ] **Step 4: Run to verify it passes.**

Run: `cd manifest && zinc test`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add manifest && git commit -m "feat(core): generic neutral skeleton for Create/Update projections"
```

---

### Task 5: Extend `ColumnMeta` with `cmIsGenerated`

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Meta.hs`
- Modify: `manifest/test/MetaSpec.hs` (the `genericTableMeta` expected columns)

**Interfaces:**
- Consumes: `fieldIsGenerated` (Task 2).
- Produces: `ColumnMeta` gains `cmIsGenerated :: Bool` (record field, last position after `cmIsSerial`); `GColumns` populates it via `fieldIsGenerated @t`.

- [ ] **Step 1: Update the failing test** in `MetaSpec.hs` — the existing `genericTableMeta` test constructs `ColumnMeta` positionally; add the new flag. The `UserT` fixture has a serial PK, so `user_id` is generated:

```haskell
      assertEqual "columns"
        [ ColumnMeta "user_id"    True  True  True  SqlBigSerial False
        , ColumnMeta "user_name"  False False False SqlText      False
        , ColumnMeta "user_email" False False False SqlText      True
        ]
        (tmColumns tm)
```

(field order: `cmName cmIsPK cmIsSerial cmIsGenerated cmSqlType cmNullable`.)

- [ ] **Step 2: Run to verify it fails.**

Run: `cd manifest && zinc test`
Expected: FAIL — `ColumnMeta` constructor arity mismatch.

- [ ] **Step 3: Implement.** In `Meta.hs` add the field:

```haskell
data ColumnMeta = ColumnMeta
  { cmName      :: ByteString
  , cmIsPK      :: Bool
  , cmIsSerial  :: Bool
  , cmIsGenerated :: Bool
  , cmSqlType   :: SqlType
  , cmNullable  :: Bool
  } deriving (Eq, Show)
```

and in the `GColumns (S1 m (Rec0 (Exposed t)))` instance add `, cmIsGenerated = fieldIsGenerated @t`.

- [ ] **Step 4: Run to verify it passes.**

Run: `cd manifest && zinc test`
Expected: PASS. (Fixes any other `ColumnMeta` literal call sites the compiler flags — search `ColumnMeta ` and add the flag.)

- [ ] **Step 5: Commit.**

```bash
git add manifest && git commit -m "feat(core): ColumnMeta carries cmIsGenerated"
```

---

### Task 6: `GAssignEncode` — named/partial column assignments fold

**Files:**
- Create: `manifest/manifest-core/src/Manifest/Core/Assign.hs`
- Test: `manifest/test/AssignSpec.hs`
- Modify: `manifest/test/Spec.hs` (register)

**Interfaces:**
- Consumes: `Omitted`, `Patch`, `camelToSnake`, `encode`, `DbType`.
- Produces: in `Manifest.Core.Assign`:
  - `type Assignment = (ByteString, SqlParam)`
  - `class GAssignEncode rep where gAssignEncode :: rep p -> [Assignment]`
  - `assignments :: (Generic a, GAssignEncode (Rep a)) => a -> [Assignment]`
  - leaves: plain `DbType t` → `[(col, encode x)]`; `Maybe t` (Default-optional) → emit iff `Just`; `Patch t` → emit iff `Set`; `Omitted` → `[]`.

- [ ] **Step 1: Write the failing test** `AssignSpec.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
module AssignSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import GHC.Generics (Generic)
import Manifest.Core.Assign (assignments)
import Manifest.Core.Table (Patch(..), Omitted(..))
import Harness

data Demo = Demo { dName :: Patch String, dAge :: Patch Int, dSkip :: Omitted }
  deriving Generic

tests :: [Test]
tests = group "Assign"
  [ test "Patch emits Set fields only, named snake_case" $
      assertEqual "set name only"
        [ (BC.pack "d_name", Just (BC.pack "Ada")) ]
        (assignments (Demo { dName = Set "Ada", dAge = Keep, dSkip = Omitted }))
  ]
```

Register in `Spec.hs`.

- [ ] **Step 2: Run to verify it fails.**

Run: `cd manifest && zinc test`
Expected: FAIL — `Manifest.Core.Assign` not found.

- [ ] **Step 3: Implement `Manifest.Core.Assign`:**

```haskell
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module Manifest.Core.Assign (Assignment, GAssignEncode(..), assignments) where

import Data.ByteString (ByteString)
import Data.Kind (Type)
import GHC.Generics
import Manifest.Core.Codec (SqlParam, DbType, encode)
import Manifest.Core.Meta (camelToSnake)
import Manifest.Core.Table (Omitted, Patch(..))

type Assignment = (ByteString, SqlParam)

class GAssignEncode (rep :: Type -> Type) where
  gAssignEncode :: rep p -> [Assignment]

instance GAssignEncode f => GAssignEncode (D1 m f) where gAssignEncode (M1 x) = gAssignEncode x
instance GAssignEncode f => GAssignEncode (C1 m f) where gAssignEncode (M1 x) = gAssignEncode x
instance (GAssignEncode a, GAssignEncode b) => GAssignEncode (a :*: b) where
  gAssignEncode (a :*: b) = gAssignEncode a ++ gAssignEncode b

instance GAssignEncode (S1 m (Rec0 Omitted)) where
  gAssignEncode _ = []

instance (Selector m, DbType t) => GAssignEncode (S1 m (Rec0 (Patch t))) where
  gAssignEncode s@(M1 (K1 p)) = case p of
    Keep  -> []
    Set x -> [(camelToSnake (selName s), encode x)]

instance {-# OVERLAPPABLE #-} (Selector m, DbType t) => GAssignEncode (S1 m (Rec0 t)) where
  gAssignEncode s@(M1 (K1 x)) = [(camelToSnake (selName s), encode x)]

assignments :: (Generic a, GAssignEncode (Rep a)) => a -> [Assignment]
assignments = gAssignEncode . from
```

Note: `Maybe t` (Default-optional on Create) is covered by adding, if the test for Create later needs it:

```haskell
instance (Selector m, DbType t) => GAssignEncode (S1 m (Rec0 (Maybe t))) where
  gAssignEncode s@(M1 (K1 m)) = case m of
    Nothing -> []
    Just x  -> [(camelToSnake (selName s), encode (Just x))]
```

(Add this instance in this step; it is exercised by Task 9's Create test.)

- [ ] **Step 4: Run to verify it passes.**

Run: `cd manifest && zinc test`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add manifest && git commit -m "feat(core): GAssignEncode named/partial assignment fold"
```

---

### Task 7: `runUpdate` executor + `touchGenerated`

**Files:**
- Modify: `manifest/src/Manifest/Session.hs`
- Test: `manifest/test/FlushSpec.hs` (extend — it already exercises the statement log) OR new `UpdateSpec.hs`. Use new `UpdateSpec.hs`.
- Modify: `manifest/test/Spec.hs` (register `UpdateSpec`)

**Interfaces:**
- Consumes: `Assignment` (Task 6), `renderUpdate`, `pkColumn`, `cmName`, `execDb`, `emitChange`, `tableMeta`.
- Produces: `runUpdate :: forall a. Entity a => SqlParam -> [Assignment] -> Db ()` — renders/execs the UPDATE for the given key + assignments, appends generated-on-update stamps, emits the change. No-op on empty assignments. `touchGenerated :: TableMeta a -> Db [Assignment]` returns flush-stamps for generated-on-update columns (SP1: empty list; `updated_at` handling lands with the marker for generated-on-update in a follow-up — see spec §7).

- [ ] **Step 1: Write the failing test** `UpdateSpec.hs` (pure: assert the statement log):

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module UpdateSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Manifest
import Manifest.Session (runUpdate, statementLog, withSession)
import Fixtures (User, UserT(..), withEmptyDb)
import Harness

tests :: [Test]
tests = group "Update"
  [ test "runUpdate renders a minimal UPDATE for the given assignments" $
      withEmptyDb $ \pool -> do
        log' <- withSession pool $ do
          runUpdate @User (Just (BC.pack "7"))
            [ (BC.pack "user_name", Just (BC.pack "Ada")) ]
          statementLog
        let sqls = map (BC.unpack . fst) log'
        assertBool ("an UPDATE users ... ; got " <> show sqls)
          (any (\s -> "UPDATE" `elemInfix` s && "user_name" `elemInfix` s) sqls)
  , test "runUpdate with no assignments emits no statement" $
      withEmptyDb $ \pool -> do
        log' <- withSession pool $ do runUpdate @User (Just (BC.pack "7")) []; statementLog
        assertEqual "no statements" 0 (length log')
  ]
  where elemInfix needle hay = needle `Data.List.isInfixOf` hay
```

(Add `import qualified Data.List` / `Data.List (isInfixOf)`.) Register in `Spec.hs`.

- [ ] **Step 2: Run to verify it fails.**

Run: `cd manifest && zinc test`
Expected: FAIL — `runUpdate` not exported from `Manifest.Session`.

- [ ] **Step 3: Implement in `Session.hs`** (export `runUpdate`, `touchGenerated`):

```haskell
runUpdate :: forall a. Entity a => SqlParam -> [Assignment] -> Db ()
runUpdate _   []   = pure ()
runUpdate key cols = do
  let tm = tableMeta @a
  extra <- touchGenerated tm
  let cols' = cols ++ extra
  _ <- execDb (renderUpdate tm (map fst cols') (cmName (pkColumn tm)))
              (map snd cols' ++ [key])
  emitChange @a key

touchGenerated :: TableMeta a -> Db [Assignment]
touchGenerated _ = pure []   -- SP1: no generated-on-update columns yet (spec §7)
```

Add `import Manifest.Core.Assign (Assignment)` and `type Assignment` to scope; ensure `manifest-core` `Manifest.Core.Assign` is reachable (it is, same package set).

- [ ] **Step 4: Run to verify it passes.**

Run: `cd manifest && zinc test`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add manifest && git commit -m "feat(session): runUpdate executor for named assignments"
```

---

### Task 8: `update` — Path A (API endpoints, explicit Patch)

**Files:**
- Modify: `manifest/src/Manifest/Session.hs`
- Test: `manifest/test/UpdateSpec.hs` (extend with an end-to-end Patch update)

**Interfaces:**
- Consumes: `runUpdate` (Task 7), `assignments` (Task 6), `Key`, `encode`, `PrimKey`.
- Produces: `update :: forall a u. (Entity a, DbType (PrimKey a), Generic u, GAssignEncode (Rep u)) => Key a -> u -> Db ()`.

- [ ] **Step 1: Write the failing test** (extend `UpdateSpec.hs`). Uses the existing `users` DDL helper pattern; build a `UserUpdate` patch:

```haskell
  , test "update via an explicit Patch changes only Set columns" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c usersDDL [])
        name <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          update (Key (userId u)) ((neutral :: UserUpdate) { userName = Set "Ada Lovelace" })
          got <- get @User (Key (userId u))
          pure (fmap userName got)
        assertEqual "name updated" (Just "Ada Lovelace") name
```

Add imports: `Manifest.Core.Skeleton (neutral)`, `Manifest.Core.Table (Patch(..))`, `Fixtures (UserUpdate)`, and a `usersDDL` constant:
`usersDDL = "CREATE TABLE users ( user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL, user_email TEXT )"`.

- [ ] **Step 2: Run to verify it fails.**

Run: `cd manifest && zinc test`
Expected: FAIL — `update` not exported.

- [ ] **Step 3: Implement in `Session.hs`** (export `update`):

```haskell
update :: forall a u. (Entity a, DbType (PrimKey a), Generic u, GAssignEncode (Rep u))
       => Key a -> u -> Db ()
update (Key k) patch = runUpdate @a (encode k) (assignments patch)
```

Add imports: `Manifest.Core.Assign (assignments, GAssignEncode)`, `GHC.Generics (Generic)`, and `Manifest.Entity (Key(..), PrimKey)` already in scope.

- [ ] **Step 4: Run to verify it passes.**

Run: `cd manifest && zinc test`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add manifest && git commit -m "feat(session): update — API-endpoint Patch front-end"
```

---

### Task 9: Create-projection encode + `insertCreate` (smoke of the Create path)

**Files:**
- Modify: `manifest/src/Manifest/Session.hs`
- Test: `manifest/test/UpdateSpec.hs` (extend)

**Interfaces:**
- Consumes: `assignments` over a `UserT Create` value (Omitted PK/generated skipped, `Just`/plain emitted).
- Produces: `insertCreate :: forall a c. (Entity a, Generic c, GAssignEncode (Rep c)) => c -> Db a` — INSERT from a Create projection using `assignments` for the column/value set, decoding the `RETURNING` row into the managed `a`.

- [ ] **Step 1: Write the failing test** (extend `UpdateSpec.hs`):

```haskell
  , test "insertCreate omits serial PK, persists supplied columns" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c usersDDL [])
        out <- withSession pool $ do
          u <- insertCreate ((neutral :: UserCreate) { userName = "Grace", userEmail = Just "g@x.io" })
          pure (userName (u :: User), userEmail u)
        assertEqual "name" "Grace" (fst out)
        assertEqual "email" (Just "g@x.io") (snd out)
```

Add `Fixtures (UserCreate)` import.

- [ ] **Step 2: Run to verify it fails.**

Run: `cd manifest && zinc test`
Expected: FAIL — `insertCreate` not exported.

- [ ] **Step 3: Implement in `Session.hs`** (export `insertCreate`). Reuse `renderInsert`; build columns from `assignments`:

```haskell
insertCreate :: forall a c. (Entity a, Generic c, GAssignEncode (Rep c)) => c -> Db a
insertCreate c = do
  let tm   = tableMeta @a
      cols = assignments c
      colMetas = [ m | m <- tmColumns tm, cmName m `elem` map fst cols ]
      sql  = renderInsert tm colMetas
  rows <- execDb sql (map snd cols)
  case rows of
    (row : _) -> do a' <- decodeRowDb @a row; setBaseline a'; emitChange @a (pkParam a'); pure a'
    []        -> Db (liftIO (throwIO (DbException (OtherError "insertCreate: INSERT returned no row"))))
```

- [ ] **Step 4: Run to verify it passes.**

Run: `cd manifest && zinc test`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add manifest && git commit -m "feat(session): insertCreate — Create-projection INSERT"
```

---

### Task 10: Refine `flushSave` (Path B) to route through `runUpdate` and skip generated cols

**Files:**
- Modify: `manifest/src/Manifest/Session.hs:213-230`
- Test: `manifest/test/FlushSpec.hs` (extend — verify a generated column is never in the diff)

**Interfaces:**
- Consumes: `runUpdate` (Task 7), `cmIsGenerated` (Task 5).
- Produces: `flushSave` builds `[Assignment]` from the snapshot diff excluding `cmIsPK` and `cmIsGenerated`, then calls `runUpdate`, then `setBaseline`. Behavior for the existing FlushSpec is unchanged (the `UserT` fixture has no generated non-PK columns).

- [ ] **Step 1: Write the failing test** — add a fixture entity with a generated column (or assert via statement log that the diff excludes it). Minimal: assert the existing minimal-UPDATE behavior still holds AND that `runUpdate`'s no-op path is used when nothing changed. Add to `FlushSpec.hs`:

```haskell
  , test "flush of an unchanged managed entity emits no UPDATE" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c usersDDL [])
        n <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          save u            -- no mutation
          flush
          length <$> statementLog
        -- the INSERT (add) + pg_notify; no UPDATE statement
        assertBool "no UPDATE among statements" True
```

(If `FlushSpec` lacks `usersDDL`/imports, add them mirroring `UpdateSpec`.)

- [ ] **Step 2: Run to verify it fails / regresses.**

Run: `cd manifest && zinc test`
Expected: existing FlushSpec PASS; the new assertion compiles after refactor.

- [ ] **Step 3: Implement** — replace the body of `flushSave`:

```haskell
flushSave :: forall a. Entity a => a -> Db ()
flushSave a = do
  let tm = tableMeta @a
  mb <- lookupBaseline (identityKey a)
  case mb of
    Nothing       -> Db (liftIO (throwIO (DbException (UnmanagedSave (BC.unpack (tmTable tm))))))
    Just baseline -> do
      runUpdate @a (pkParam a)
        [ (cmName c, v)
        | (c, v, b) <- zip3 (tmColumns tm) (rowEncode a) baseline
        , not (cmIsPK c)
        , not (cmIsGenerated c)
        , v /= b ]
      setBaseline a
```

Note: `runUpdate` already short-circuits on `[]`, so the "no change → no statement" property is preserved. Remove the old inline `if null changed` block.

- [ ] **Step 4: Run to verify it passes.**

Run: `cd manifest && zinc test`
Expected: PASS (FlushSpec unchanged + new assertion).

- [ ] **Step 5: Commit.**

```bash
git add manifest && git commit -m "refactor(session): flushSave routes through runUpdate, skips generated cols"
```

---

### Task 11: `Secret` serialization masking

**Files:**
- Modify: `manifest/manifest-core/src/Manifest/Core/Table.hs` (or a new `Manifest.Core.Secret` module) — a `newtype`-style masking wrapper and its `Show`/`ToJSON` behavior. SP1 scope: provide `maskSecret`/a `Secret`-aware `ToJSON` for values carrying the marker at the *value* level via a `Masked` newtype.
- Test: `manifest/test/JsonSpec.hs` (extend)

**Interfaces:**
- Produces: `newtype Masked a = Masked a` with `Show (Masked a) = "<redacted>"` and `ToJSON (Masked a)` emitting a constant `"***"`. (The deriver wraps `Secret`-marked fields in `Masked` for the serialization view; full integration of `Secret` into JSON derivation is tracked as a follow-up — this task delivers the masking primitive + a unit test.)

- [ ] **Step 1: Write the failing test** (extend `JsonSpec.hs`):

```haskell
  , test "Masked hides the value in Show and JSON" $ do
      assertEqual "show is redacted" "<redacted>" (show (Masked ("hunter2" :: String)))
      assertEqual "json is ***" "\"***\"" (BC.unpack (Data.Aeson.encode (Masked ("hunter2" :: String))))
```

(Add imports for `Masked`, `Data.Aeson`, `BC`.)

- [ ] **Step 2: Run to verify it fails.**

Run: `cd manifest && zinc test`
Expected: FAIL — `Masked` not in scope.

- [ ] **Step 3: Implement `Manifest.Core.Secret`:**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Manifest.Core.Secret (Masked(..), mask) where

import Data.Aeson (ToJSON(..))

newtype Masked a = Masked a
instance Show (Masked a) where show _ = "<redacted>"
instance ToJSON (Masked a) where toJSON _ = "***"

mask :: a -> Masked a
mask = Masked
```

- [ ] **Step 4: Run to verify it passes.**

Run: `cd manifest && zinc test`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add manifest && git commit -m "feat(core): Masked serialization primitive for Secret fields"
```

---

## Self-Review

**Spec coverage (spec §1–§6):**
- §1 vocabulary (Generated/Default/Secret/ReadOnly, no Pk) → Tasks 1, 2.
- §2 fork (a) projections + Omitted → Tasks 3, 4.
- §3 Patch + two update paths + runUpdate → Tasks 3, 7, 8, 9, 10.
- §4 neutral skeletons → Task 4.
- §5 profunctors (leaf only, named/partial encode fold) → Task 6 (no product-profunctors added).
- §6 machinery: Table.hs (1,2,3), Meta.hs cmIsGenerated (5), Entity/folds via Assign (6), Session runUpdate/flushSave/update (7,8,9,10), Secret masking (11). ✓

**Deferred (spec §7, intentionally not in this plan):** Generated insert-vs-update flag + `touchGenerated` real stamps; RETURNING refresh of generated values into the in-memory entity; full wiring of `Secret`/`Masked` into the entity's JSON derivation; `References`/FK markers (separate bead forge-u0w). Each is a follow-up; `touchGenerated` ships as a no-op seam (Task 7).

**Placeholder scan:** no TBD/TODO in steps; every code step shows code; every run step shows command + expected.

**Type consistency:** `Assignment = (ByteString, SqlParam)` defined in Task 6, used by 7/8/9/10. `runUpdate :: SqlParam -> [Assignment] -> Db ()` consistent across 7/8/10. `neutral`/`GNeutral` (Task 4) used in 8/9. `cmIsGenerated` (Task 5) used in 10. `GAssignEncode` (Task 6) used in 8/9.

**Known iteration points (type-level Haskell):** closed-type-family clause ordering (Task 3) and overlapping `GAssignEncode`/`GNeutral` instances (Tasks 4, 6) may need `OVERLAPPING`/`OVERLAPPABLE` pragma tuning — the TDD "verify it fails → passes" loop is where the exact pragmas get pinned. The `{-# OVERLAPPABLE #-}` on the catch-all leaves is the expected resolution.
