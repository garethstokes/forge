# Manifest Typed Fields (newtype columns + typed PK/FK) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let entity fields be distinct newtypes — typed primary keys, typed-by-convention foreign keys, and general domain newtypes (`Email`/`Money`) — so a `UserId` cannot be confused with a `PostId` or filled from the wrong id.

**Architecture:** The existing `Col`/`Base`/`Serial`/`PrimaryKey` families and the codec are already type-generic, and a newtype over a base type gets all three column capabilities (`ToField`, `FromField`, `ScalarMeta`) from one `deriving newtype` clause (**verified to compile** against the built library). So this slice adds almost no library code: it re-exports the column-type classes from the umbrella (so a typed column can be declared against `import Manifest` alone), then dogfoods and documents the capability with a typed-id demo entity, a compile-failure golden proving the ids actually don't unify, and a manual section.

**Tech Stack:** GHC 9.10.1 via zinc. Existing `Manifest.Core.Codec` (`ToField`/`FromField`), `Manifest.Core.Table` (`ScalarMeta`, `Col`/`Serial`/`PrimaryKey`/`Base`), `Manifest.Core.Meta` (`SqlType`), `Manifest.Entity` (`Entity`/`Key`/`PrimKey`), `Manifest.Postgres` (`withConnection`/`execText`). Custom `test/Harness.hs`; `Fixtures.withEmptyDb`; the `RelationErrorSpec` shell-out-to-ghc compile-failure pattern.

**Spec:** `docs/superpowers/specs/2026-06-09-typed-fields-newtypes-design.md` (issue `manifest-29q`).

**Baseline:** `main` is at **116/116** (confirm with `nix develop -c .zinc/build/spec`). This slice adds 3 tests → **119/119**.

---

## File Structure

- **Modify `src/Manifest.hs`** — re-export `ToField(..)`, `FromField(..)`, `ScalarMeta(..)`, `SqlType(..)` so a typed-column newtype can be declared against `import Manifest` alone. (The only library change.)
- **Create `test/TypedFieldsSpec.hs`** — the enabler round-trip, the typed-id demo entity (`Account`/`Note` with `AccountId`/`NoteId` newtype PKs + a typed FK), the DB round-trip, and the compile-failure golden.
- **Modify `test/Spec.hs`** — wire in `TypedFieldsSpec`.
- **Modify `docs/entities.md`** — a "Typed fields" section.

---

### Task 1: Re-export column-type classes + enabler round-trip

**Files:**
- Modify: `src/Manifest.hs`
- Create: `test/TypedFieldsSpec.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: Write the failing test**

Create `test/TypedFieldsSpec.hs`. The test declares a domain newtype against `import Manifest` *only* (proving the re-exports suffice) and asserts it round-trips through the codec.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module TypedFieldsSpec (tests) where

import Data.Functor.Identity (Identity)
import Data.Text (Text)
import GHC.Generics (Generic)
import Manifest
import Manifest.Postgres (execText, withConnection)
import Fixtures (withEmptyDb)
import Harness

-- A domain newtype declared with ONLY `import Manifest` in scope: proves the
-- column-type classes are re-exported from the umbrella.
newtype Email = Email Text
  deriving stock (Eq, Show)
  deriving newtype (ToField, FromField, ScalarMeta)

tests :: [Test]
tests = group "TypedFields"
  [ test "a newtype column round-trips through the codec" $
      assertEqual "Email round-trip"
        (Right (Email "ada@x.io"))
        (fromField (toField (Email "ada@x.io")))
  ]
```

Wire into `test/Spec.hs`: add `import qualified TypedFieldsSpec` alongside the other spec imports and append `TypedFieldsSpec.tests` to the `++` chain in `main`.

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop -c zinc test 2>&1 | tail -20`
Expected: compile failure — `ToField`/`FromField`/`ScalarMeta` not in scope from `Manifest` (the umbrella doesn't re-export them yet), and/or `toField`/`fromField` not in scope.

- [ ] **Step 3: Add the re-exports to `src/Manifest.hs`**

In the export list, add a section:

```haskell
    -- * Column-type classes (for newtype columns)
  , ToField (..)
  , FromField (..)
  , ScalarMeta (..)
  , SqlType (..)
```

Add the imports. `Manifest.hs` already imports from `Manifest.Core.Table` (for `Serial`/`PrimaryKey`/`Col`) and `Manifest.Core.Meta` (for `genericTableMeta`); extend those and add a `Manifest.Core.Codec` import:

```haskell
import Manifest.Core.Codec
  ( ToField (..)
  , FromField (..)
  )
```
and add `ScalarMeta (..)` to the existing `import Manifest.Core.Table ( … )` block, and `SqlType (..)` to the existing `import Manifest.Core.Meta ( … )` block.

> `Manifest.Core.Meta` re-exports `SqlType (..)`; `Manifest.Core.Table` exports `ScalarMeta (..)`; `Manifest.Core.Codec` exports `ToField (..)`/`FromField (..)`. These four give a user everything needed to write `deriving newtype (ToField, FromField, ScalarMeta)` and, if ever needed, a manual `instance ScalarMeta Foo where { scalarType = SqlBigInt; scalarNullable = False }` — all against `import Manifest`.

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop -c zinc test 2>&1 | tail -6` then `nix develop -c .zinc/build/spec 2>&1 | tail -2`
Expected: green; total **117/117** (baseline 116 + 1).

- [ ] **Step 5: -Wall check on the umbrella**

Run: `nix develop -c zinc build 2>&1 | grep -iE "warning|Manifest.hs" | tail -10`
Expected: builds clean (re-exports don't warn).

- [ ] **Step 6: Commit**

```bash
git add src/Manifest.hs test/TypedFieldsSpec.hs test/Spec.hs
git commit -m "feat(types): re-export column-type classes for newtype columns"
```

---

### Task 2: Typed-id demo entity + DB round-trip

Dogfood the typed PK + typed FK end to end. The demo entities live in the test module (additive, not a migration of the existing fixtures).

**Files:**
- Modify: `test/TypedFieldsSpec.hs`

- [ ] **Step 1: Write the failing test**

Add the demo entities + DDL above `tests`, and a new test case.

Entities (add after the `Email` newtype):

```haskell
newtype AccountId = AccountId Int
  deriving stock (Eq, Show)
  deriving newtype (ToField, FromField, ScalarMeta)

newtype NoteId = NoteId Int
  deriving stock (Eq, Show)
  deriving newtype (ToField, FromField, ScalarMeta)

data AccountT f = Account
  { accountId   :: Col f (PrimaryKey (Serial AccountId))   -- runtime AccountId; column BIGSERIAL
  , accountName :: Col f Text
  } deriving Generic
type Account = AccountT Identity

instance Entity Account where
  type PrimKey Account = AccountId
  tableMeta  = genericTableMeta @AccountT "accounts"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = accountId

data NoteT f = Note
  { noteId      :: Col f (PrimaryKey (Serial NoteId))
  , noteAccount :: Col f AccountId          -- typed FK to accounts.account_id
  , noteBody    :: Col f Text
  } deriving Generic
type Note = NoteT Identity

instance Entity Note where
  type PrimKey Note = NoteId
  tableMeta  = genericTableMeta @NoteT "notes"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = noteId

accountsDDL, notesDDL :: BC.ByteString
accountsDDL = "CREATE TABLE accounts ( account_id BIGSERIAL PRIMARY KEY, account_name TEXT NOT NULL )"
notesDDL    = "CREATE TABLE notes ( note_id BIGSERIAL PRIMARY KEY, note_account BIGINT NOT NULL, note_body TEXT NOT NULL )"
```

Add the import `import qualified Data.ByteString.Char8 as BC` to the module header.

New test case (append to the `group "TypedFields" [ … ]` list):

```haskell
  , test "typed PK and typed FK round-trip end to end" $
      withEmptyDb $ \pool -> do
        withConnection pool (\c -> execText c accountsDDL [] >> execText c notesDDL [])
        (name, body) <- withSession pool $ do
          acc <- add (Account { accountId = AccountId 0, accountName = "Ada" } :: Account)
          -- the typed FK is filled from the parent's typed id (AccountId):
          _   <- add (Note { noteId = NoteId 0, noteAccount = accountId acc, noteBody = "hi" } :: Note)
          got <- get @Account (Key (accountId acc))         -- Key wraps an AccountId
          ns  <- selectWhere [ #noteAccount ==. accountId acc ]   -- query by the typed FK column
          pure (fmap accountName got, map noteBody (ns :: [Note]))
        assertEqual "account decoded by its typed Key" (Just "Ada") name
        assertEqual "note found via the typed FK" ["hi"] body
```

> Why this proves the slice: `add (Account …)` performs `INSERT … RETURNING account_id` and decodes the serial id back into `AccountId` (its `FromField`); `accountId acc :: AccountId` is the real assigned id; the `Note`'s `noteAccount` field is an `AccountId` (you could not put a `NoteId` there — Task 3 proves that); `get @Account (Key (accountId acc))` round-trips through `Key Account` (which wraps `AccountId`); and `#noteAccount ==. accountId acc` builds a `Cond Note` over the typed column, needing only `ToField AccountId`.

- [ ] **Step 2: Run to verify it fails**

Run: `nix develop -c zinc test 2>&1 | tail -20`
Expected: compiles only after the entities exist; the new test then runs. (If it fails to compile, read the GHC error — most likely a missing import. The entities should typecheck: the verified deriving + the type-generic markers carry `AccountId`/`NoteId` through.)

- [ ] **Step 3: (No production code)**

This task is pure dogfood: the demo entities and the test are the deliverable; no `src/` change. The capability already exists (Task 1 re-exported what's needed). If anything fails to typecheck, that is a real gap — fix it in `src/` and note it, but the verified scratch build says it should not.

- [ ] **Step 4: Run to verify it passes**

Run: `nix develop -c .zinc/build/spec 2>&1 | tail -2`
Expected: green; total **118/118**.

- [ ] **Step 5: Commit**

```bash
git add test/TypedFieldsSpec.hs
git commit -m "test(types): typed-id PK + typed FK round-trip (dogfood)"
```

---

### Task 3: Compile-failure golden — the ids don't unify

Prove the types actually distinguish ids: filling a `Col f AccountId` field with a `NoteId` must fail to compile. Reuses the `RelationErrorSpec` shell-out-to-ghc pattern.

**Files:**
- Modify: `test/TypedFieldsSpec.hs`

- [ ] **Step 1: Write the failing test**

Add these imports to `TypedFieldsSpec.hs`:

```haskell
import Data.List (isInfixOf)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)
```

Add a standalone source (kept as a string so it is only compiled by the test) and a test case:

```haskell
-- A module that fills a typed-AccountId field with a NoteId. Compiling it must fail.
wrongIdSource :: String
wrongIdSource = unlines
  [ "{-# LANGUAGE DataKinds #-}"
  , "{-# LANGUAGE DerivingStrategies #-}"
  , "{-# LANGUAGE GeneralizedNewtypeDeriving #-}"
  , "module WrongId where"
  , "import Data.Functor.Identity (Identity)"
  , "import Manifest (Col)"
  , "import Manifest.Core.Codec (ToField, FromField)"
  , "import Manifest.Core.Table (ScalarMeta)"
  , "newtype AccountId = AccountId Int deriving newtype (ToField, FromField, ScalarMeta)"
  , "newtype NoteId    = NoteId Int    deriving newtype (ToField, FromField, ScalarMeta)"
  , "data R f = R { rAcc :: Col f AccountId }"
  , "boom :: R Identity"
  , "boom = R { rAcc = NoteId 1 }"           -- type error: AccountId vs NoteId
  ]
```

```haskell
  , test "a typed FK rejects the wrong id newtype at compile time" $ do
      tmp <- getTemporaryDirectory
      (path, h) <- openTempFile tmp "WrongId.hs"
      hClose h
      writeFile path wrongIdSource
      (_code, _out, err) <-
        readProcessWithExitCode "ghc"
          [ "-fno-code", "-fforce-recomp"
          , "-package-db", ".zinc/pkgdb"
          , "-i.zinc/lib"
          , path
          ]
          ""
      removeFile path
      let msg = unwords (words err)
      assertBool ("mentions AccountId; output was:\n" <> err) ("AccountId" `isInfixOf` msg)
      assertBool ("mentions NoteId; output was:\n" <> err)    ("NoteId"    `isInfixOf` msg)
  ]
```

> `Col Identity AccountId = Base AccountId = AccountId`, so `rAcc :: AccountId` at the value level; assigning `NoteId 1` is a `Couldn't match AccountId with NoteId` error. The probe is self-contained (defines its own newtypes), so it needs only `-package-db .zinc/pkgdb -i.zinc/lib`. This mirrors `test/RelationErrorSpec.hs` (which uses the same `readProcessWithExitCode "ghc" … -fno-code` mechanism for a type-error golden).

- [ ] **Step 2: Run to verify it passes**

Run: `nix develop -c zinc build` (so `.zinc/pkgdb`/`.zinc/lib` are current), then `nix develop -c .zinc/build/spec 2>&1 | grep -iA1 "wrong id"`
Expected: PASS — compiling `wrongIdSource` fails and its stderr names both `AccountId` and `NoteId`. If it FAILs because ghc can't find `Manifest`, confirm `.zinc/pkgdb`/`.zinc/lib` exist (run `zinc build` first) and that the flags match `RelationErrorSpec`.

- [ ] **Step 3: Full suite**

Run: `nix develop -c .zinc/build/spec 2>&1 | tail -2`
Expected: **119/119**.

- [ ] **Step 4: Commit**

```bash
git add test/TypedFieldsSpec.hs
git commit -m "test(types): golden — typed FK rejects the wrong id at compile time"
```

---

### Task 4: Manual section

**Files:**
- Modify: `docs/entities.md`

- [ ] **Step 1: Add a "Typed fields" section**

Append a section to `docs/entities.md` (manual voice: no em-dashes, no SQLAlchemy, no positioning claims). Place it after the existing column/label material:

````markdown
## Typed fields

Fields do not have to be bare base types. Any newtype over a supported base type
(`Int`, `Text`, `Bool`) is a first-class column once it derives the three column
capabilities, in one clause:

```haskell
newtype Email = Email Text
  deriving newtype (ToField, FromField, ScalarMeta)
```

`ToField`/`FromField` are the codec; `ScalarMeta` supplies the SQL type and
nullability. The same pattern gives type-safe identifiers. Use the newtype as the
primary key and as foreign keys that point at it:

```haskell
newtype UserId = UserId Int deriving newtype (ToField, FromField, ScalarMeta)
newtype PostId = PostId Int deriving newtype (ToField, FromField, ScalarMeta)

data UserT f = User
  { userId   :: Col f (PrimaryKey (Serial UserId))   -- runtime UserId; column BIGSERIAL
  , userName :: Col f Text
  } deriving Generic

data PostT f = Post
  { postId     :: Col f (PrimaryKey (Serial PostId))
  , postAuthor :: Col f UserId                        -- typed foreign key to users.user_id
  , postTitle  :: Col f Text
  } deriving Generic

instance Entity User where
  type PrimKey User = UserId
  -- … tableMeta / rowDecoder / rowEncode / primKey = userId
```

Now `userId :: UserId`, `Key User` wraps a `UserId`, and `postAuthor` is a `UserId`
you cannot fill from a `PostId`. The id flows through `add` (the `RETURNING` serial is
decoded back into `UserId`), `get (Key (UserId 1))`, and the query builder
(`#postAuthor ==. val someUserId`). The column is still `BIGSERIAL`/`BIGINT`, so the
schema and migrations are unchanged.

> The field type is what gives the safety. Manifest does not yet check, at the
> relationship level, that a foreign key points at the right entity's id type (so a
> mis-declared relationship is not rejected), and it does not auto-generate id
> newtypes. Both are planned follow-ups.
````

- [ ] **Step 2: Verify**

Run: `nix develop -c .zinc/build/spec 2>&1 | tail -2` (still 119/119) and `grep -nE "—|sqlalchemy" docs/entities.md` (nothing).

- [ ] **Step 3: Commit**

```bash
git add docs/entities.md
git commit -m "docs(types): manual section on typed fields (newtype columns, typed PK/FK)"
```

---

## Self-Review

**1. Spec coverage** (against `2026-06-09-typed-fields-newtypes-design.md`):
- §1 Enabler (newtype columns via deriving) → Task 1 (re-export + `Email` round-trip; deriving verified to compile). ✓
- §2 Typed PKs (`PrimaryKey (Serial newtype)`, `PrimKey = newtype`, `Key` wraps it, `add` decodes `RETURNING`) → Task 2 (`Account` entity + round-trip). ✓
- §3 Typed FKs by convention (`Col f UserId`, flows through `#col ==. …` / `Key`) → Task 2 (`Note.noteAccount` + `selectWhere [#noteAccount ==. …]`). ✓
- §5 Validation: dogfood demo entity → Task 2; compile-safety golden → Task 3; domain newtype → Task 1 (`Email`). ✓
- §5.1 Library change: re-export the classes → Task 1. (No other library change — the deriving was verified to compile, so the enabler needs nothing more.) ✓
- §6 Testing: round-trip (Task 2), compile-failure golden (Task 3), domain newtype (Task 1). ✓
- Manual section → Task 4. ✓
- Deferred (relationship-enforced FK↔PK; auto-gen ids) → documented as follow-ups in the manual note (Task 4) and out of scope here. ✓

**2. Placeholder scan:** Every step has complete code or an exact command + expected output. The one "no production code" note (Task 2 Step 3) is justified — the scratch build verified the deriving and the markers are type-generic — with an explicit "if it fails to typecheck, fix in src and note it" fallback. No TBD/TODO.

**3. Type consistency:**
- `Email`/`AccountId`/`NoteId` newtypes use the identical `deriving stock (Eq, Show)` + `deriving newtype (ToField, FromField, ScalarMeta)` shape throughout (Tasks 1–3). ✓
- `Account`/`Note` Entity instances match the standard shape (`genericTableMeta @T`, `genericRowDecoder`/`genericRowEncode`, `primKey`), with `PrimKey Account = AccountId` / `PrimKey Note = NoteId`. The DDL column types (`BIGSERIAL`/`BIGINT`) match the `Serial …`/plain-newtype markers. ✓
- `accountId acc :: AccountId` used consistently for the FK fill, the `Key`, and the `#noteAccount ==.` filter. ✓
- The re-exports (`ToField(..)`, `FromField(..)`, `ScalarMeta(..)`, `SqlType(..)`) are the exact class names the deriving clauses and the `Email` round-trip use. ✓
