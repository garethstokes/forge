# Manifest DerivingVia Entity (remove Template Haskell) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `mkEntity` Template Haskell front-end and replace it with a fully-derivable `Entity`: a plain entity becomes one `deriving via (Table "users" UserT) instance Entity User` line, cascade/RLS entities a short explicit instance.

**Architecture:** `PrimKey` moves from an associated type to a standalone closed family computed from the record's metadata Rep; `Entity` gains `DefaultSignatures` (`rowDecoder`/`rowEncode`/`primKey` default generically; `tableMeta` has no default); a `Table (name :: Symbol) t` newtype carrier supplies the table name via the `Symbol` and is the `deriving via` target. `genericPrimKey` is just "decode the PK column" (`fromField (rowEncode a !! pkIndex)`) — no hard generic projection. **Convention adopted: the primary-key field is the first field** (true for every existing entity), which keeps the `PrimKey` type family a simple first-field lookup. The whole type-level plumbing (standalone family matching `t Identity` + the carrier, `deriving via` coercing through it) was scratch-verified before this plan.

**Tech Stack:** GHC 9.10.1 via zinc. `DerivingVia`/`DefaultSignatures`/`StandaloneDeriving`. Existing `Manifest.Core.Codec` (`ToField`/`FromField`/`SqlParam`/`decodeRow`), `Manifest.Core.Table` (`Col`/`Exposed`/`Base`/`PrimaryKey`/`Serial`/`FieldMeta`), `Manifest.Core.Meta` (`genericTableMeta`/`ColumnMeta`/`TableMeta`/`pkColumn`/`cmIsPK`/`tmColumns`). Custom `test/Harness.hs`.

**Spec:** `docs/superpowers/specs/2026-06-09-deriving-via-entity-design.md` (issue `manifest-czu`).

**Baseline:** `main` is at **119/119**. Removing `THSpec` drops its 4 tests; Task 2 adds 1. Net target after the slice: **116/116**. (Confirm the start count with `nix develop -c .zinc/build/spec`.)

---

## File Structure

- **`src/Manifest/Entity.hs`** — the core change: standalone `PrimKey` family, `GPrimKeyType`, `genericPrimKey`, `DefaultSignatures`; drop the associated `type PrimKey a`. (Keeps the existing `GRowDecode`/`GRowEncode`/`genericRowDecoder`/`genericRowEncode`/`Key`/`pkIndex`/`pkParam`/`identityKey`.)
- **`src/Manifest/Derive.hs`** (NEW) — the `Table name t` carrier + its `Entity` instance (the `deriving via` target). Replaces the deleted `Manifest.Derive.TH`.
- **`src/Manifest.hs`** — drop `mkEntity`/`field`; export `Table`.
- **Deleted:** `src/Manifest/Derive/TH.hs`, `test/THSpec.hs`.
- **`zinc.toml`** — drop `template-haskell` from `[build.lib].depends`.
- **Migrated entity declarations:** `test/Fixtures.hs`, `test/RlsSpec.hs`, `test/TypedFieldsSpec.hs`, `app/Main.hs`, `test/Spec.hs` (drop THSpec).
- **`docs/entities.md`** — remove the TH section; add a "Deriving the Entity instance" section.

---

### Task 1: Replace TH with derivable `Entity` (atomic refactor + migration)

This task is necessarily atomic: removing the associated `type PrimKey` breaks every entity instance at once, so the class change, the carrier, the migration of all entities, and the TH removal land in one commit. The regression oracle is the existing suite (minus THSpec).

**Files:** Modify `src/Manifest/Entity.hs`, `src/Manifest.hs`, `zinc.toml`, `test/Fixtures.hs`, `test/RlsSpec.hs`, `test/TypedFieldsSpec.hs`, `app/Main.hs`, `test/Spec.hs`; Create `src/Manifest/Derive.hs`; Delete `src/Manifest/Derive/TH.hs`, `test/THSpec.hs`.

- [ ] **Step 1: Rewrite the `Entity` class machinery in `src/Manifest/Entity.hs`**

Read the current `Manifest/Entity.hs` first. Add these language pragmas if missing: `DataKinds`, `DefaultSignatures`, `FlexibleContexts`, `TypeFamilies`, `TypeOperators`, `UndecidableInstances`. Add imports: `Manifest.Core.Table (Exposed, Base, PrimaryKey, Serial, Col)` (whichever aren't already imported), `Manifest.Core.Codec (FromField (..))`, `Manifest.Core.Meta (cmIsPK, tmColumns, ...)`, `GHC.Generics` (already imported), `Data.Functor.Identity (Identity)`, `Data.Kind (Type)`.

(a) **The standalone `PrimKey` family + `GPrimKeyType`** (replacing the associated `type PrimKey a`). Add at top level:
```haskell
-- | The runtime type of an entity's primary key, computed from its record: the
-- @Base@ of the FIRST field's marker (the primary key is, by convention, the
-- first field). Works for a real entity (@t Identity@) and the deriving carrier
-- (@Table name t@).
type PrimKey a = GPrimKeyType (Rep (HkdExposed a))

-- | Recover @t Exposed@ from an entity or the carrier, so we can read the markers.
type family HkdExposed a where
  HkdExposed (t Identity) = t Exposed
  -- the carrier case is added in Manifest.Derive via a second equation? No — keep it here:
type family GPrimKeyType (rep :: Type -> Type) :: Type where
  GPrimKeyType (D1 m f) = GPrimKeyType f
  GPrimKeyType (C1 m f) = GPrimKeyType f
  GPrimKeyType ((S1 m (Rec0 (Exposed inner))) :*: rest) = Base inner
  GPrimKeyType (S1 m (Rec0 (Exposed inner)))            = Base inner
```

> **Implementer note on the carrier case.** `PrimKey` must also reduce for the carrier `Table name t` so `deriving via` typechecks (`PrimKey User ~ PrimKey (Table "users" UserT)`). The cleanest single definition is to make `HkdExposed` cover both shapes. Since `Manifest.Derive.Table` is defined in another module, define `HkdExposed` as a closed family with both equations *here* but referencing `Table` would create an import cycle. Instead, make `PrimKey` itself the family with both equations and inline the Rep lookup (no `HkdExposed`):
> ```haskell
> type family PrimKey a where
>   PrimKey (t Identity) = GPrimKeyType (Rep (t Exposed))
> ```
> and give the carrier its own matching `PrimKey (Table name t) = GPrimKeyType (Rep (t Exposed))` equation **in the same closed family** — which means `Table` must be in scope here. To avoid the cycle, **move the `Table` newtype's *type* into `Entity.hs`** (just the `newtype Table … = Table …` declaration), and put only its `Entity` *instance* in `Manifest.Derive`. Then `PrimKey` is one closed family with both equations, defined alongside `Table`, in `Entity.hs`. Use that structure (it was validated in the scratch: a single closed family with `PK (Tbl name t)` and `PK (t Identity)` equations both reducing through the same `GPrimKeyType`). Drop the `HkdExposed` helper.

So, concretely in `Entity.hs`:
```haskell
import Data.Kind (Type)
import GHC.TypeLits (Symbol)

newtype Table (name :: Symbol) (t :: (Type -> Type) -> Type) = Table (t Identity)

type family PrimKey a where
  PrimKey (Table name t) = GPrimKeyType (Rep (t Exposed))
  PrimKey (t Identity)   = GPrimKeyType (Rep (t Exposed))
```

(b) **The class with `DefaultSignatures`** (drop the associated `type PrimKey a`):
```haskell
class Typeable a => Entity a where
  tableMeta  :: TableMeta a                       -- no default (needs the table name)

  rowDecoder :: RowDecoder a
  default rowDecoder :: (Generic a, GRowDecode (Rep a)) => RowDecoder a
  rowDecoder = genericRowDecoder

  rowEncode  :: a -> [SqlParam]
  default rowEncode :: (Generic a, GRowEncode (Rep a)) => a -> [SqlParam]
  rowEncode = genericRowEncode

  primKey :: a -> PrimKey a
  default primKey :: FromField (PrimKey a) => a -> PrimKey a
  primKey = genericPrimKey

  cascadeRules :: [CascadeRule]
  cascadeRules = []

  rlsPolicies :: [Policy a]
  rlsPolicies = []
```

(c) **`genericPrimKey`** — decode the PK column (no generic projection):
```haskell
-- | Default 'primKey': re-encode the row, take the primary-key column, and decode
-- it back to the key type. Reuses 'rowEncode' + the PK column index.
genericPrimKey :: forall a. (Entity a, FromField (PrimKey a)) => a -> PrimKey a
genericPrimKey a =
  case fromField (rowEncode a !! pkIndex @a) of
    Right v  -> v
    Left err -> error ("Manifest.genericPrimKey: " <> show err)
```
(`pkIndex @a` already exists in this module; it finds the `cmIsPK` column index from `tableMeta @a`.)

(d) Update the export list: remove the associated `PrimKey` (it's now a standalone family — export `PrimKey` as a name, `GPrimKeyType`, `genericPrimKey`, `Table`). Keep `Entity (..)`, `Key (..)`, `genericRowDecoder`, `genericRowEncode`, `identityKey`, `pkParam`, `pkIndex`.

- [ ] **Step 2: Create `src/Manifest/Derive.hs`** (the carrier's `Entity` instance)

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Manifest.Derive
  ( Table (..)
  ) where

import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.Kind (Type)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic, Rep)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Type.Reflection (Typeable)
import Manifest.Core.Codec (FromField, RowDecoder, SqlParam)
import Manifest.Core.Meta (GColumns, TableMeta (..), genericTableMeta)
import Manifest.Core.Table (Exposed)
import Manifest.Entity
  ( Entity (..), GRowDecode, GRowEncode, PrimKey, Table (..)
  , genericRowDecoder, genericRowEncode, genericPrimKey )

instance
  ( KnownSymbol name
  , Typeable (t Identity)
  , Generic (t Exposed), GColumns (Rep (t Exposed))
  , Generic (t Identity), GRowDecode (Rep (t Identity)), GRowEncode (Rep (t Identity))
  , FromField (PrimKey (Table name t))
  ) => Entity (Table name t) where
  tableMeta  = retag (genericTableMeta @t (BC.pack (symbolVal (Proxy @name))))
    where retag (TableMeta n cs) = TableMeta n cs   -- TableMeta's phantom is free; rebuild to retype
  rowDecoder = coerceDecoder (genericRowDecoder @(t Identity))
  rowEncode  (Table x) = genericRowEncode x
  primKey    = genericPrimKey
```

> **Implementer notes:** `TableMeta a`/`RowDecoder a` are phantom in `a`, so re-typing them across the `Table name t` ↔ `t Identity` boundary is a no-op rebuild or a `Data.Coerce.coerce` (`import Data.Coerce (coerce)`); use whichever the types accept (`coerce` is cleanest: `tableMeta = coerce (genericTableMeta @t (BC.pack (symbolVal (Proxy @name))))`, `rowDecoder = coerce (genericRowDecoder @(t Identity))`). Export `GRowDecode`/`GRowEncode`/`GColumns` from their modules if not already exported (they are needed in this instance's context). `genericTableMeta @t` already takes the `ByteString` table name. The `primKey = genericPrimKey` default-style definition works because the carrier satisfies `FromField (PrimKey (Table name t))`.

- [ ] **Step 3: Update `src/Manifest.hs`**

Remove the `mkEntity`/`field` exports and the `import Manifest.Rls`? No — keep RLS. Remove only: the `mkEntity`/`field` entries from the export list and the `import Manifest.Derive.TH (mkEntity, field)` import. Add `Table` to the exports and `import Manifest.Derive (Table (..))` (and `Table` is also re-exported from `Manifest.Entity`; export it once). Keep all other exports.

- [ ] **Step 4: Delete TH**

```bash
git rm src/Manifest/Derive/TH.hs test/THSpec.hs
```
Remove `import qualified THSpec` and `THSpec.tests` from `test/Spec.hs`. Remove `"template-haskell",` from `[build.lib].depends` in `zinc.toml`.

- [ ] **Step 5: Migrate the entities** (apply the pattern to every entity)

The pattern, by example. **Plain entity** (e.g. `Post` in `test/Fixtures.hs`) — drop the explicit instance + `type PrimKey` and replace with one `deriving via` line (needs `DerivingVia`/`StandaloneDeriving` pragmas in the module):
```haskell
data PostT f = Post { postId :: Col f (PrimaryKey (Serial Int)), postAuthor :: Col f Int, postTitle :: Col f Text } deriving Generic
type Post = PostT Identity
deriving via (Table "posts" PostT) instance Entity Post
```

**Cascade entity** (`User` in `Fixtures.hs`) — short explicit instance (drop `type PrimKey`; `rowDecoder`/`rowEncode`/`primKey` now default; keep `tableMeta` + `cascadeRules`):
```haskell
instance Entity User where
  tableMeta    = genericTableMeta @UserT "users"
  cascadeRules =
    [ cascade (Proxy @Post)    (Proxy @"postAuthor")  Cascade
    , cascade (Proxy @Profile) (Proxy @"profileUser") SetNull
    , cascade (Proxy @Tag)     (Proxy @"tagUser")     Restrict ]
```

**RLS entity** (`Secret`/`Vault` in `test/RlsSpec.hs`) — same shape, `rlsPolicies` instead of/in addition to `cascadeRules`:
```haskell
instance Entity Secret where
  tableMeta   = genericTableMeta @SecretT "secrets"
  rlsPolicies = [ policy "org_isolation" `using` (\s -> s ^. #secretOrg .== currentSetting "app.current_org") ]
```

Apply to **all** entities, adding `{-# LANGUAGE DerivingVia #-}` + `{-# LANGUAGE StandaloneDeriving #-}` to each module that uses the one-liner:
- `test/Fixtures.hs`: `Post`, `Profile`, `Tag`, `Employee`, `Comment` → `deriving via`; `User` → explicit (cascades).
- `test/RlsSpec.hs`: `Secret`, `Vault` → explicit (rlsPolicies); the demo entities for migration tests → `deriving via` if plain.
- `test/TypedFieldsSpec.hs`: `Account`, `Note` → `deriving via (Table "accounts" AccountT)` / `(Table "notes" NoteT)`. (The newtype-id PKs flow through `GPrimKeyType` → `Base (PrimaryKey (Serial AccountId)) = AccountId`, and `genericPrimKey` decodes via `FromField AccountId`, which the newtype derives.)
- `app/Main.hs`: the `manifest-migrate` schema entity → `deriving via`.

In every entity, delete the `type PrimKey X = …` line.

- [ ] **Step 6: Build and make the suite green**

Run: `nix develop -c zinc test 2>&1 | tail -30`, then `nix develop -c .zinc/build/spec 2>&1 | tail -2`.
Expected: **116/116** (119 baseline − 4 THSpec). Work through compile errors: the usual ones are a module missing `DerivingVia`/`StandaloneDeriving`, an un-exported `GColumns`/`GRowDecode`/`GRowEncode` needed by the carrier instance, or a `FromField (PrimKey X)` not in scope (every PK type — `Int`, `AccountId` — has `FromField`). The suite passing is the proof: `get`/`save`/the identity map all route through `primKey`, cascades through `cascadeRules`, RLS through `rlsPolicies`, so green means the derived instances behave identically to the old hand-written ones.

- [ ] **Step 7: -Wall check**

Run: `nix develop -c zinc build 2>&1 | grep -iE "warning|Entity.hs|Derive.hs" | tail -20`
Expected: no warnings for the touched library modules.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(core): replace mkEntity TH with DerivingVia/Generics Entity"
```
(`git add -A` is acceptable here because this task includes deletions; confirm `git status` shows only the intended files.)

---

### Task 2: New-entity deriving-via round-trip test

Prove a brand-new plain entity works end to end via the one-liner (not just the migrated fixtures).

**Files:** Modify `test/TypedFieldsSpec.hs` (or a small new spec; reuse `TypedFieldsSpec` which already has the DB harness).

- [ ] **Step 1: Write the test**

Add a plain entity declared ONLY with `deriving via`, and a round-trip. Append to `TypedFieldsSpec.hs` (it already imports `Manifest`, `withEmptyDb`, `execText`/`withConnection`):

```haskell
data GadgetT f = Gadget
  { gadgetId   :: Col f (PrimaryKey (Serial Int))
  , gadgetName :: Col f Text
  } deriving Generic
type Gadget = GadgetT Identity
deriving via (Table "gadgets" GadgetT) instance Entity Gadget

gadgetsDDL :: BC.ByteString
gadgetsDDL = "CREATE TABLE gadgets ( gadget_id BIGSERIAL PRIMARY KEY, gadget_name TEXT NOT NULL )"
```

Add `{-# LANGUAGE DerivingVia #-}` and `{-# LANGUAGE StandaloneDeriving #-}` to the module header (if not added in Task 1). Test case (append to the `group`):

```haskell
  , test "a deriving-via entity round-trips (add/get/selectWhere)" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c gadgetsDDL [])
        out <- withSession pool $ do
          g  <- add (Gadget { gadgetId = 0, gadgetName = "wrench" } :: Gadget)
          mg <- get @Gadget (Key (gadgetId g))             -- primKey/Key derived
          gs <- selectWhere [ #gadgetName ==. ("wrench" :: String) ]
          pure (fmap gadgetName mg, map gadgetName (gs :: [Gadget]))
        assertEqual "got by key"   (Just "wrench") (fst out)
        assertEqual "found by col" ["wrench"]      (snd out)
```

- [ ] **Step 2: Run**

`nix develop -c .zinc/build/spec 2>&1 | tail -2`. Expected **117/117**. The deliberate-break check (change `"wrench"` expectation to `"WRONG"`, see FAIL, restore) confirms it is a real round-trip.

- [ ] **Step 3: Commit**

```bash
git add test/TypedFieldsSpec.hs
git commit -m "test(core): deriving-via entity round-trips end to end"
```

---

### Task 3: Docs

**Files:** Modify `docs/entities.md`.

- [ ] **Step 1: Remove the TH section and add a deriving section**

In `docs/entities.md`, delete the "Deriving entities with Template Haskell" section (the `mkEntity` material). In its place (and updating any earlier mention that the instance is hand-written), add a section in the manual voice (no em-dashes, no SQLAlchemy):

````markdown
## Deriving the Entity instance

The `Entity` instance is derived, not hand-written. Declare the record (with the
primary key as the first field) and derive the instance through a `Table` carrier that
supplies the table name:

```haskell
data PostT f = Post
  { postId     :: Col f (PrimaryKey (Serial Int))   -- primary key: the first field
  , postAuthor :: Col f Int
  , postTitle  :: Col f Text
  } deriving Generic
type Post = PostT Identity

deriving via (Table "posts" PostT) instance Entity Post
```

That one line derives `tableMeta` (from the `"posts"` name), the row codec, and
`primKey`. The primary key must be the first field; its runtime type is computed from
the record, so there is no `type PrimKey` to write.

An entity with cascade rules or row-level-security policies writes a short explicit
instance instead, supplying the table name and the policy (the codec and `primKey`
still default):

```haskell
instance Entity User where
  tableMeta    = genericTableMeta @UserT "users"
  cascadeRules = [ cascade (Proxy @Post) (Proxy @"postAuthor") Cascade, … ]
```
````

Update the intro line if it claims an `mkEntity` macro exists.

- [ ] **Step 2: Verify**

`nix develop -c .zinc/build/spec 2>&1 | tail -2` (117/117); `grep -nE "—|sqlalchemy|mkEntity" docs/entities.md` (no em-dashes/sqlalchemy; no stale `mkEntity` references).

- [ ] **Step 3: Commit**

```bash
git add docs/entities.md
git commit -m "docs(core): deriving-via entity section; drop mkEntity"
```

---

## Self-Review

**1. Spec coverage** (against `2026-06-09-deriving-via-entity-design.md`):
- §1 Removed (TH.hs, THSpec, dep, umbrella exports, TH docs) → Task 1 Steps 3-4, Task 3. ✓
- §2.1 standalone `PrimKey` family → Task 1 Step 1(a). §2.2 `DefaultSignatures` → 1(b). §2.3 `Table` carrier → 1(a)/Step 2. `genericPrimKey` (decode-the-PK-column) → 1(c). ✓
- §3 end state (plain `deriving via`; cascade/RLS explicit) → Task 1 Step 5. ✓
- §4 migration of all entities → Task 1 Step 5 (Fixtures/RlsSpec/TypedFieldsSpec/app listed). ✓
- §5 feasibility — the plumbing + `genericPrimKey` approach were verified before this plan; the "PK is first field" convention replaces the harder marker-finding `GPrimKeyType`, documented in Task 3. ✓
- §6 testing — existing suite as oracle (Task 1 Step 6) + new-entity round-trip (Task 2). ✓

**2. Placeholder scan:** Complete code/commands per step. The one genuinely fiddly area (where `PrimKey`/`Table` live to avoid an import cycle) is resolved explicitly: the `Table` *newtype* and the `PrimKey` closed family live together in `Entity.hs`; only the carrier's `Entity` *instance* is in `Manifest.Derive`. No TBD/TODO.

**3. Type consistency:**
- `PrimKey` is one closed family with `(Table name t)` and `(t Identity)` equations, both `GPrimKeyType (Rep (t Exposed))` — verified in scratch to make `deriving via` coerce (`PrimKey User ~ PrimKey (Table "users" UserT)`). ✓
- `genericPrimKey :: (Entity a, FromField (PrimKey a)) => a -> PrimKey a` matches the `default primKey :: FromField (PrimKey a) => …` signature; the carrier instance lists `FromField (PrimKey (Table name t))` in its context. ✓
- `Table (name :: Symbol) (t :: (Type -> Type) -> Type) = Table (t Identity)` — the kind `(Type -> Type) -> Type` was the fix found in the scratch (HKD constructor kind). Used consistently in the family, the carrier, and every `deriving via (Table "x" XT)`. ✓
- Migration examples (Post plain, User cascades, Secret RLS, Gadget new) all drop `type PrimKey` and either `deriving via` or write `tableMeta` + policy. Consistent. ✓
