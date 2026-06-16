# Manifest Sub-project 1 — "Prove the UoW" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single-table, snapshot-diff Unit-of-Work end to end on Postgres, demonstrating the core claim — *edit a plain immutable Haskell value, hand it back via `save`, and the session emits a minimal `UPDATE` touching only the changed column.*

**Architecture:** A strict downward layer cake — borrowed Postgres transport (`postgresql-libpq`, text format) under an owned applicative codec; a thin HKD Core (markers + `Col` family + Generics-derived table metadata, query refs, and SQL generation); a bespoke `Db` monad wrapping `ReaderT Session IO`, holding an identity map (`(TypeRep, pk-bytes) → baseline encoded-column vector`) and a pending op set; a flush that diffs handed-back values against baselines column-by-column and emits minimal `INSERT`/`UPDATE`/`DELETE`. One hand-written example table (`UserT`) exercises the whole stack.

**Tech Stack:** GHC 9.6.5 · **zinc** build tool (`zinc.toml`, git-pinned deps, `zinc build`/`zinc test`/`zinc run`) · Nix flake devShell · `postgresql-libpq` (transport) · `GHC.Generics` (derive) · `stm` (pool) · `containers` · `bytestring`/`text`/`time` · **hspec** (tests) · **tmp-postgres** (hermetic ephemeral Postgres per test run).

---

## EXECUTION NOTES (2026-06-07, during build — these OVERRIDE the task text below)

The toolchain reality diverged from the original plan in four ways. Apply these everywhere:

1. **Test framework: NOT hspec — use `test/Harness.hs`** (a ~35-line zero-dependency harness). The
   hspec git-pin closure (colour/ansi-terminal/QuickCheck) fights zinc's resolver, so we dropped it.
   API: `runTests :: [Test] -> IO ()`, `group :: String -> [Test] -> [Test]`, `test :: String -> IO () -> Test`,
   `assertBool :: String -> Bool -> IO ()`, `assertEqual :: (Eq a,Show a) => String -> a -> a -> IO ()`
   (args are `expected actual`), `assertReturns :: (Eq a,Show a) => String -> a -> IO a -> IO ()`.
   Each spec module exports `tests :: [Test]`; `test/Spec.hs` aggregates: `main = runTests (concat [CodecSpec.tests, ...])`.
   Translate every `describe/it/shouldBe/shouldReturn` in the task text to this API. Failure = throw.
2. **Test DB: NOT tmp-postgres — thin initdb/pg_ctl harness.** Task 3's `withTestDb` shells out (via the
   `process` boot lib) to `initdb` + `pg_ctl` (from the devShell's `postgresql`) to spin an ephemeral
   cluster on a unix socket in a temp dir, run, and tear down. No tmp-postgres dependency.
3. **Transport: own libpq via the `postgresql-libpq` package**, pinned v0.11.0.0 with
   `flags = { use-pkg-config = true }` (Simple pkgconfig provider). The test target carries
   `ghc-options = ["-lpq"]` and the flake exports `LIBRARY_PATH=${pkgs.postgresql.lib}/lib` so the FFI links.
4. **Build/test commands:** `nix develop -c zinc build` / `nix develop -c zinc test` (NOT cabal). After
   editing `[dependencies]`, freeze with `nix develop -c zinc add <pkg> --yes`; the lock is `zinc.lock`.

Task 1 is DONE (commit f8a47d7). Module code in the task text below is framework-agnostic and still
correct — only the **test** blocks change to the Harness API.

---

## Resolved open questions (from design §9)

These were left open in `spec/manifest_design_v0_1.md` §9 and are **decided here** so the plan has no
placeholders. Each is the load-bearing commitment for SP1; SP2+ may revisit.

| §9 question | SP1 decision |
|---|---|
| `Col`/`Columnar` family encoding for marker erasure | Two instantiated contexts only: `Col Identity a = Base a` (markers erased → runtime type) and `Col Exposed a = Exposed a` (markers preserved for the deriver). Closed type family `Base` strips `PrimaryKey`/`Serial`. Query-context functor (`QExpr`) deferred to SP4 — SP1 uses value-level `Column a t` label refs, not an HKD query record. |
| Snapshot storage form | **Encoded column vector** (`[SqlParam]`, aligned to `tableMeta` column order). Diffing is a `ByteString` compare per column — no `Eq` on the record, no re-decode. |
| `Key a` representation | `newtype Key a = Key (PrimKey a)`; `PrimKey` is an associated type on `Entity`. Example uses `PrimKey User = Int`. Composite PKs deferred. |
| Transport | `postgresql-libpq` with **text-format** params/results; own the applicative codec and the STM pool on top. |

**Additional SP1 simplifications (documented deviations from the design's illustrative examples):**

- **Column naming:** field name → column name is **camelCase → snake_case with no prefix stripping**.
  So `userId → user_id`, `userName → user_name`, `userEmail → user_email`. (The design §4.6 wrote
  `id`/`name` using beam-style prefix stripping; SP1 omits stripping to keep the deriver and the
  `#label` path computing column names from one pure function. Prefix-stripping is a follow-up.)
- **`add` is eager:** `add` issues its `INSERT ... RETURNING` immediately and returns the persistent,
  PK-filled record (so `newP <- add Post{..}` has a real PK in-hand). Deferred/batched inserts at
  flush time are a follow-up. `save`/`delete` remain deferred to flush.
- **Read-refreshes-snapshot:** SP1 implements the simple rule — a load always (re)writes the baseline
  to the loaded value. The design's "pending wins" nuance (§4.7) is a documented follow-up.

---

## File Structure

All library modules live under `src/Manifest/` (zinc auto-discovers modules from `source-dirs`; no
explicit module list). Each file has one responsibility:

| File | Responsibility |
|---|---|
| `src/Manifest/Error.hs` | `DecodeError`, `DbError`, `DbException` (thrown internally, bracket-friendly). |
| `src/Manifest/Core/Codec.hs` | `SqlParam`, `ToField`/`FromField` (text codecs), applicative `RowDecoder`, `field`, `decodeRow`. |
| `src/Manifest/Postgres.hs` | libpq binding: `execText`; STM `Pool`, `newPool`, `withConnection`, `closePool`. |
| `src/Manifest/Core/Table.hs` | HKD markers `Serial`/`PrimaryKey`, context tags `Exposed`, `Base`/`Col` type families, `FieldMeta`. |
| `src/Manifest/Core/Meta.hs` | `ColumnMeta`, `TableMeta`, `camelToSnake`, generic `GColumns`, `genericTableMeta`. |
| `src/Manifest/Entity.hs` | `Entity` class, `Key`, generic `genericRowDecoder`/`genericRowEncode`, `identityKey`/`pkParam`. |
| `src/Manifest/Core/Query.hs` | `Column a t`, `Op`, `Cond`, `Assign`, operators `==.`/`/=.`/`>.`/`<.`/`=.`, `IsLabel` for `#col`. |
| `src/Manifest/Core/Sql.hs` | Pure SQL string + param rendering: `renderSelect`/`renderInsert`/`renderUpdate`/`renderDelete`. |
| `src/Manifest/Session.hs` | `Db`, `Session`, `SessionConfig`, `withSession`, `withTransaction`, `flush`, `get`/`selectWhere`/`add`/`save`/`delete`, `statementLog`. |
| `src/Manifest/Session/Command.hs` | `update`, `deleteWhere` (escape hatch, bypasses identity map). |
| `src/Manifest.hs` | Umbrella re-export. |

Tests live under `test/` (hspec; zinc auto-discovers `*Spec` modules; entrypoint `test/Spec.hs`):

| File | Responsibility |
|---|---|
| `test/Spec.hs` | hspec aggregator: `main = hspec $ do ...` calling each area `spec`. |
| `test/Fixtures.hs` | The example `UserT`/`User` table, its `Entity` instance, the `users` DDL, and `withTestDb`. |
| `test/CodecSpec.hs` | Pure codec round-trips. |
| `test/PostgresSpec.hs` | libpq + pool + `SELECT 1` against tmp-postgres. |
| `test/MetaSpec.hs` | `Base` reduction + `genericTableMeta` derived columns. |
| `test/SqlSpec.hs` | Pure SQL rendering. |
| `test/SessionSpec.hs` | Read path (`get`/`selectWhere`) and managed-entity baselines. |
| `test/FlushSpec.hs` | The heart: `add`/`save`/`delete`/`withTransaction`, minimal-UPDATE assertions, rollback. |
| `test/CommandSpec.hs` | `update`/`deleteWhere`. |
| `test/EndToEndSpec.hs` | The §4.6 worked example, one transaction, asserting emitted statements. |

**All commands run inside the Nix devShell** (`nix develop`, or `direnv allow` with the `.envrc` from
Task 1). zinc requires `ghc` on `PATH` and fails fast otherwise.

---

### Task 1: Zinc workspace scaffold + Nix devShell + hspec smoke

Stand up a building, testing zinc project with the toolchain (GHC + git + alex/happy + **postgresql**
for libpq headers and the `initdb`/`pg_ctl` binaries tmp-postgres drives + zlib/pkg-config).

**Files:**
- Create: `zinc.toml`
- Create: `flake.nix`
- Create: `.envrc`
- Create: `.gitignore`
- Create: `src/Manifest.hs`
- Create: `test/Spec.hs`

- [ ] **Step 1: Write the zinc manifest**

Create `zinc.toml`:

```toml
[workspace]
members = ["."]
ghc = "9.6.5"

[package]
name = "manifest"
version = "0.1.0.0"

[build.lib]
source-dirs = ["src"]
ghc-options = [
  "-Wall",
  "-XOverloadedStrings", "-XScopedTypeVariables", "-XTypeApplications",
  "-XLambdaCase", "-XTupleSections"
]
depends = [
  "base", "bytestring", "containers", "stm", "text", "time", "transformers",
  "postgresql-libpq"
]

[build.test.spec]
source-dirs = ["test"]
main = "Spec.hs"
ghc-options = [
  "-XOverloadedStrings", "-XScopedTypeVariables", "-XTypeApplications",
  "-XLambdaCase"
]
depends = [
  "base", "bytestring", "containers", "stm", "text", "time", "transformers",
  "process", "directory", "filepath",
  "postgresql-libpq", "tmp-postgres", "hspec", "manifest"
]

[dependencies]
```

- [ ] **Step 2: Write the flake (devShell)**

Create `flake.nix`. This pins GHC 9.6.5 and adds `postgresql` (provides `pg_config`/`libpq` headers
for building `postgresql-libpq`, and `initdb`/`postgres`/`pg_ctl` for tmp-postgres), `zlib`,
`pkg-config`:

```nix
{
  description = "Manifest — the Unit-of-Work layer Haskell never had.";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forAll (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.haskell.compiler.ghc965
              pkgs.git
              pkgs.haskellPackages.alex
              pkgs.haskellPackages.happy
              pkgs.pkg-config
              pkgs.postgresql      # libpq headers + initdb/postgres/pg_ctl
              pkgs.zlib
            ];
            shellHook = ''
              export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.zlib pkgs.postgresql ]}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            '';
          };
        });
    };
}
```

- [ ] **Step 3: Write `.envrc` and `.gitignore`**

Create `.envrc`:

```
use flake
```

Create `.gitignore`:

```
.zinc/
.direnv/
result
result-*
*.hi
*.o
```

- [ ] **Step 4: Write the umbrella library stub and the test entrypoint**

Create `src/Manifest.hs`:

```haskell
-- | Manifest — the Unit-of-Work layer Haskell never had.
module Manifest () where
```

Create `test/Spec.hs`:

```haskell
module Main (main) where

import Test.Hspec

main :: IO ()
main = hspec $
  describe "scaffold" $
    it "runs the test suite" $
      (1 + 1 :: Int) `shouldBe` 2
```

- [ ] **Step 5: Enter the devShell and pin external dependencies**

External (non-boot) packages are git-pinned by zinc. `base`, `bytestring`, `containers`, `stm`,
`text`, `time`, `transformers`, `process`, `directory`, `filepath` are GHC 9.6 **boot libraries** and
need no pin. Pin the three externals (`zinc add` resolves and freezes each + its closure into
`zinc.lock`):

Run:
```bash
nix develop
zinc add postgresql-libpq
zinc add hspec
zinc add tmp-postgres
```
Expected: each prints a `{ "zinc": ..., "ok": true, ... }` envelope and updates `zinc.toml`
`[dependencies]` + `zinc.lock`. If `zinc add` reports a missing transitive pin
(`ZINC_*` resolution error, exit 3), follow its `nextAction` to pin the named repo and re-run.

> Note: `hspec`'s known-good pin set already exists in the sibling `zinc` repo's `zinc.toml`
> (`hspec`, `hspec-core`, `hspec-discover`, `hspec-expectations`, `HUnit`, `QuickCheck`, `call-stack`,
> `quickcheck-io`, `random`, `splitmix`, `tf-random`, `primitive`). If `zinc add hspec` struggles,
> copy those `[dependencies.*]` blocks verbatim from `../zinc/zinc.toml`.

- [ ] **Step 6: Build and test to verify green**

Run:
```bash
zinc build
zinc test
```
Expected: `zinc build` ends with an `ok: true` envelope. `zinc test` runs hspec and prints
`1 example, 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add zinc.toml zinc.lock flake.nix .envrc .gitignore src/Manifest.hs test/Spec.hs
git commit -m "chore(sp1): scaffold zinc project, devShell, hspec smoke"
```

---

### Task 2: Errors and the applicative codec (pure)

The owned, arity-unlimited applicative codec over text-format values. `SqlParam = Maybe ByteString`
(`Nothing` = SQL `NULL`). No DB yet — fully pure.

**Files:**
- Create: `src/Manifest/Error.hs`
- Create: `src/Manifest/Core/Codec.hs`
- Test: `test/CodecSpec.hs`

- [ ] **Step 1: Write the errors module**

Create `src/Manifest/Error.hs`:

```haskell
module Manifest.Error
  ( DecodeError(..)
  , DbError(..)
  , DbException(..)
  ) where

import Control.Exception (Exception)
import Data.ByteString (ByteString)

-- | A column value could not be decoded into the requested Haskell type.
newtype DecodeError = DecodeError String
  deriving (Eq, Show)

-- | Errors surfaced from the database / session layer.
data DbError
  = QueryError ByteString          -- ^ libpq result error message
  | DecodeFailure DecodeError      -- ^ row decoding failed
  | UnmanagedSave String           -- ^ save/delete of an entity with no baseline in the identity map
  | OtherError String
  deriving (Eq, Show)

-- | Thrown internally so it composes with 'Control.Exception.bracket' for
-- automatic rollback; converted to 'Either' at the boundary by try-combinators (future).
newtype DbException = DbException DbError
  deriving (Show)

instance Exception DbException
```

- [ ] **Step 2: Write the failing codec test**

Create `test/CodecSpec.hs`:

```haskell
module CodecSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Manifest.Core.Codec
import Test.Hspec

data Row3 = Row3 Int Maybe' deriving (Eq, Show)
type Maybe' = Maybe String  -- placeholder; replaced below

spec :: Spec
spec = describe "Manifest.Core.Codec" $ do
  it "encodes scalars to text params" $ do
    toField (42 :: Int) `shouldBe` Just (BC.pack "42")
    toField ("hi" :: String) `shouldBe` Just (BC.pack "hi")
    toField (Nothing :: Maybe Int) `shouldBe` Nothing
    toField (Just (7 :: Int)) `shouldBe` Just (BC.pack "7")

  it "decodes scalars from text params" $ do
    fromField (Just (BC.pack "42")) `shouldBe` Right (42 :: Int)
    fromField Nothing `shouldBe` Right (Nothing :: Maybe Int)
    fromField (Just (BC.pack "x")) `shouldBe` (Left (DecodeError "expected Int, got \"x\"") :: Either DecodeError Int)

  it "runs an applicative RowDecoder left-to-right with no arity ceiling" $ do
    let dec = (,,,,) <$> field <*> field <*> field <*> field <*> field
        row = [ Just (BC.pack "1"), Just (BC.pack "a"), Nothing
              , Just (BC.pack "t"), Just (BC.pack "9") ]
    decodeRow dec row
      `shouldBe` Right ((1 :: Int, "a" :: String, Nothing :: Maybe String, True, 9 :: Int))
```

> Delete the `Row3`/`Maybe'` placeholder lines before committing — they were illustrative; the real
> test uses the tuple decoder above.

- [ ] **Step 3: Run the test to verify it fails**

Run: `zinc test`
Expected: FAIL — `Manifest.Core.Codec` does not exist (build error / module not found).

- [ ] **Step 4: Write the codec module**

Create `src/Manifest/Core/Codec.hs`:

```haskell
{-# LANGUAGE FlexibleInstances #-}

module Manifest.Core.Codec
  ( SqlParam
  , ToField(..)
  , FromField(..)
  , RowDecoder
  , field
  , decodeRow
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Manifest.Error (DecodeError(..))
import Text.Read (readMaybe)

-- | A single column value in libpq text format. 'Nothing' is SQL NULL.
type SqlParam = Maybe ByteString

-- | Encode a Haskell value to a text-format column value.
class ToField a where
  toField :: a -> SqlParam

-- | Decode a text-format column value into a Haskell value.
class FromField a where
  fromField :: SqlParam -> Either DecodeError a

instance ToField Int where
  toField = Just . BC.pack . show
instance FromField Int where
  fromField (Just bs) =
    maybe (Left (DecodeError ("expected Int, got " <> show (BC.unpack bs)))) Right
          (readMaybe (BC.unpack bs))
  fromField Nothing = Left (DecodeError "expected Int, got NULL")

instance ToField Text where
  toField = Just . TE.encodeUtf8
instance FromField Text where
  fromField (Just bs) = Right (TE.decodeUtf8 bs)
  fromField Nothing   = Left (DecodeError "expected Text, got NULL")

instance ToField String where
  toField = Just . TE.encodeUtf8 . T.pack
instance FromField String where
  fromField (Just bs) = Right (T.unpack (TE.decodeUtf8 bs))
  fromField Nothing   = Left (DecodeError "expected String, got NULL")

instance ToField Bool where
  toField b = Just (if b then BC.pack "t" else BC.pack "f")
instance FromField Bool where
  fromField (Just bs) = case BC.unpack bs of
    "t" -> Right True
    "f" -> Right False
    other -> Left (DecodeError ("expected Bool (t/f), got " <> show other))
  fromField Nothing = Left (DecodeError "expected Bool, got NULL")

instance ToField a => ToField (Maybe a) where
  toField Nothing  = Nothing
  toField (Just x) = toField x
instance FromField a => FromField (Maybe a) where
  fromField Nothing  = Right Nothing
  fromField (Just v) = Just <$> fromField (Just v)

-- | An applicative row decoder. Consumes columns left-to-right; no fixed-arity
-- combinators, so it has no @mapN@ ceiling.
newtype RowDecoder a =
  RowDecoder { runRowDecoder :: [SqlParam] -> Either DecodeError (a, [SqlParam]) }

instance Functor RowDecoder where
  fmap f (RowDecoder g) = RowDecoder $ \cs -> do
    (a, rest) <- g cs
    pure (f a, rest)

instance Applicative RowDecoder where
  pure x = RowDecoder $ \cs -> Right (x, cs)
  RowDecoder f <*> RowDecoder g = RowDecoder $ \cs -> do
    (h, cs')  <- f cs
    (a, cs'') <- g cs'
    pure (h a, cs'')

-- | Decode one column with its 'FromField' instance.
field :: FromField a => RowDecoder a
field = RowDecoder $ \cs -> case cs of
  (c:rest) -> (\a -> (a, rest)) <$> fromField c
  []       -> Left (DecodeError "ran out of columns while decoding row")

-- | Run a decoder against a full row, requiring all columns consumed.
decodeRow :: RowDecoder a -> [SqlParam] -> Either DecodeError a
decodeRow (RowDecoder g) cs = do
  (a, rest) <- g cs
  if null rest
    then Right a
    else Left (DecodeError ("row had " <> show (length rest) <> " unconsumed column(s)"))
```

- [ ] **Step 5: Wire the spec into the aggregator and run to verify it passes**

Replace `test/Spec.hs` with:

```haskell
module Main (main) where

import qualified CodecSpec
import Test.Hspec

main :: IO ()
main = hspec $
  describe "Manifest" $
    CodecSpec.spec
```

Run: `zinc test`
Expected: PASS — all CodecSpec examples green.

- [ ] **Step 6: Commit**

```bash
git add src/Manifest/Error.hs src/Manifest/Core/Codec.hs test/CodecSpec.hs test/Spec.hs
git commit -m "feat(sp1): errors + owned applicative text codec"
```

---

### Task 3: Postgres transport + STM pool + tmp-postgres harness

Bind libpq (`execText`), build the STM connection pool, and stand up the hermetic test database. Smoke
it with `SELECT 1`.

**Files:**
- Create: `src/Manifest/Postgres.hs`
- Create: `test/Fixtures.hs`
- Test: `test/PostgresSpec.hs`

- [ ] **Step 1: Write the transport + pool module**

Create `src/Manifest/Postgres.hs`:

```haskell
module Manifest.Postgres
  ( Connection
  , Pool
  , newPool
  , closePool
  , withConnection
  , execText
  ) where

import Control.Concurrent.STM
import Control.Exception (bracket, throwIO)
import Control.Monad (forM, replicateM, unless)
import Data.ByteString (ByteString)
import qualified Database.PostgreSQL.LibPQ as PQ
import Manifest.Core.Codec (SqlParam)
import Manifest.Error (DbError(..), DbException(..))

-- | A borrowed libpq connection.
type Connection = PQ.Connection

-- | A fixed-size STM connection pool.
data Pool = Pool
  { poolAvail :: TVar [Connection]
  , poolAll   :: [Connection]
  }

-- | Open @size@ connections to @conninfo@ (a libpq conninfo/URI string).
newPool :: ByteString -> Int -> IO Pool
newPool conninfo size = do
  conns <- replicateM size $ do
    c <- PQ.connectdb conninfo
    st <- PQ.status c
    unless (st == PQ.ConnectionOk) $ do
      msg <- maybe (pure (mempty :: ByteString)) pure =<< PQ.errorMessage c
      throwIO (DbException (QueryError msg))
    pure c
  avail <- newTVarIO conns
  pure (Pool avail conns)

-- | Close every connection in the pool.
closePool :: Pool -> IO ()
closePool = mapM_ PQ.finish . poolAll

-- | Borrow a connection for the duration of the action, returning it after.
withConnection :: Pool -> (Connection -> IO a) -> IO a
withConnection pool = bracket acquire release
  where
    acquire = atomically $ do
      cs <- readTVar (poolAvail pool)
      case cs of
        []     -> retry
        (c:rest) -> writeTVar (poolAvail pool) rest >> pure c
    release c = atomically $ modifyTVar' (poolAvail pool) (c :)

-- | Execute a parameterised statement (text format) and return result rows as
-- vectors of nullable text values. Throws 'DbException' on error.
execText :: Connection -> ByteString -> [SqlParam] -> IO [[SqlParam]]
execText conn sql params = do
  let pqParams = [ fmap (\bs -> (PQ.Oid 0, bs, PQ.Text)) p | p <- params ]
  mres <- PQ.execParams conn sql pqParams PQ.Text
  case mres of
    Nothing  -> throwIO (DbException (QueryError (sql <> " — no result")))
    Just res -> do
      st <- PQ.resultStatus res
      if st `elem` [PQ.TuplesOk, PQ.CommandOk]
        then readRows res
        else do
          msg <- maybe (pure (mempty :: ByteString)) pure =<< PQ.resultErrorMessage res
          throwIO (DbException (QueryError msg))

readRows :: PQ.Result -> IO [[SqlParam]]
readRows res = do
  PQ.Row nrows  <- PQ.ntuples res
  PQ.Col ncols  <- PQ.nfields res
  forM [0 .. nrows - 1] $ \r ->
    forM [0 .. ncols - 1] $ \c ->
      PQ.getvalue res (PQ.toRow r) (PQ.toColumn c)
```

> If the installed `postgresql-libpq` version exposes `Row`/`Col` without exported constructors,
> replace the destructuring with `n <- PQ.ntuples res` and iterate `[0 .. fromEnum n - 1]`, building
> `PQ.toRow`/`PQ.toColumn` from the loop index. Run `zinc repl` and `:info PQ.ntuples` to confirm the
> concrete types for the pinned version, then adjust this helper to match. The behaviour (rows of
> `Maybe ByteString`) is unchanged.

- [ ] **Step 2: Write the test fixtures (DDL + harness)**

Create `test/Fixtures.hs` (the `UserT` table is added in Task 4; for now this file holds only the DDL
constant and the tmp-postgres harness):

```haskell
module Fixtures
  ( withTestDb
  , usersDDL
  ) where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import qualified Database.Postgres.Temp as Temp
import Manifest.Postgres (Pool, closePool, execText, newPool, withConnection)

-- | DDL for the example table. Column order matches UserT's field order; names
-- are camelCase→snake_case with no prefix stripping (see plan §"Resolved open questions").
usersDDL :: ByteString
usersDDL =
  "CREATE TABLE users \
  \( user_id    BIGSERIAL PRIMARY KEY \
  \, user_name  TEXT NOT NULL \
  \, user_email TEXT \
  \)"

-- | Spin up an ephemeral, isolated Postgres for the duration of the action:
-- create the schema, hand the caller a 2-connection pool, then tear everything down.
withTestDb :: (Pool -> IO a) -> IO a
withTestDb body = do
  eresult <- Temp.with $ \db -> do
    let conninfo = Temp.toConnectionString db
    pool <- newPool conninfo 2
    withConnection pool $ \c -> mapM_ (\sql -> execText c sql []) [usersDDL]
    r <- body pool
    closePool pool
    pure r
  either throwIO pure eresult
```

- [ ] **Step 3: Write the failing transport smoke test**

Create `test/PostgresSpec.hs`:

```haskell
module PostgresSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Fixtures (withTestDb)
import Manifest.Postgres (execText, withConnection)
import Test.Hspec

spec :: Spec
spec = describe "Manifest.Postgres" $ do
  it "runs SELECT 1 against an ephemeral cluster" $
    withTestDb $ \pool ->
      withConnection pool $ \conn -> do
        rows <- execText conn "SELECT 1" []
        rows `shouldBe` [[Just (BC.pack "1")]]

  it "round-trips a parameterised value" $
    withTestDb $ \pool ->
      withConnection pool $ \conn -> do
        rows <- execText conn "SELECT $1::text" [Just (BC.pack "hello")]
        rows `shouldBe` [[Just (BC.pack "hello")]]

  it "applies DDL so the users table exists and is empty" $
    withTestDb $ \pool ->
      withConnection pool $ \conn -> do
        rows <- execText conn "SELECT count(*) FROM users" []
        rows `shouldBe` [[Just (BC.pack "0")]]
```

Add `import qualified PostgresSpec` and `PostgresSpec.spec` to `test/Spec.hs`.

- [ ] **Step 4: Run to verify it fails, then passes**

Run: `zinc test`
Expected first: FAIL — `Manifest.Postgres`/`Fixtures` not yet built, or (once built) the modules
resolve and the three examples go green. If libpq fails to link, confirm `pkg-config --libs libpq`
resolves inside the devShell (Task 1 flake provides `postgresql` + `pkg-config`).

- [ ] **Step 5: Commit**

```bash
git add src/Manifest/Postgres.hs test/Fixtures.hs test/PostgresSpec.hs test/Spec.hs
git commit -m "feat(sp1): libpq transport, STM pool, tmp-postgres harness"
```

---

### Task 4: HKD core — markers, `Base`/`Col` families, `FieldMeta`

The type-level machinery: phantom markers `PrimaryKey`/`Serial`, the `Exposed` metadata context, the
`Base` family that strips markers to the runtime type, the `Col` family that selects per-context, and
`FieldMeta` reflecting PK/serial flags from a field's marker structure.

**Files:**
- Create: `src/Manifest/Core/Table.hs`
- Modify: `test/Fixtures.hs` (add `UserT`/`User`)
- Test: `test/MetaSpec.hs` (the `Base`-reduction half)

- [ ] **Step 1: Write the HKD core module**

Create `src/Manifest/Core/Table.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE AllowAmbiguousTypes #-}

module Manifest.Core.Table
  ( Serial
  , PrimaryKey
  , Exposed
  , Base
  , Col
  , FieldMeta(..)
  ) where

import Data.Functor.Identity (Identity)
import Data.Kind (Type)

-- | Marker: an auto-incrementing serial column whose runtime type is @a@.
data Serial a

-- | Marker: a primary-key column wrapping inner marker/type @a@.
data PrimaryKey a

-- | The metadata context. @Col Exposed a = Exposed a@ keeps the marker visible
-- to the deriver, where @Col Identity a@ erases it.
data Exposed a

-- | Strip markers down to the runtime base type.
type family Base (a :: Type) :: Type where
  Base (PrimaryKey a) = Base a
  Base (Serial a)     = a
  Base a              = a

-- | Per-context column type. SP1 instantiates only Identity (runtime value) and
-- Exposed (metadata). The query-expression context is added in SP4.
type family Col (f :: Type -> Type) (a :: Type) :: Type where
  Col Identity a = Base a
  Col Exposed  a = Exposed a

-- | Reflect a field's PK/serial flags from its marker structure (used by the deriver).
class FieldMeta a where
  fieldIsPK     :: Bool
  fieldIsSerial :: Bool

instance FieldMeta a => FieldMeta (PrimaryKey a) where
  fieldIsPK     = True
  fieldIsSerial = fieldIsSerial @a

instance FieldMeta (Serial a) where
  fieldIsPK     = False
  fieldIsSerial = True

instance {-# OVERLAPPABLE #-} FieldMeta a where
  fieldIsPK     = False
  fieldIsSerial = False
```

- [ ] **Step 2: Add the example table to the fixtures**

Modify `test/Fixtures.hs` — add the imports and the table (keep `withTestDb`/`usersDDL`). Add to the
module export list `UserT(..)`, `User`:

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
```

```haskell
import Data.Functor.Identity (Identity)
import Data.Text (Text)
import GHC.Generics (Generic)
import Manifest.Core.Table (Col, PrimaryKey, Serial)
```

```haskell
-- | The example higher-kinded table. One declaration; @UserT Identity@ is the
-- clean runtime value, @UserT Exposed@ carries markers for the deriver.
data UserT f = User
  { userId    :: Col f (PrimaryKey (Serial Int))
  , userName  :: Col f Text
  , userEmail :: Col f (Maybe Text)
  } deriving Generic

-- | The runtime row type: @userId :: Int, userName :: Text, userEmail :: Maybe Text@.
type User = UserT Identity
```

- [ ] **Step 3: Write the failing `Base`-reduction test**

Create `test/MetaSpec.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module MetaSpec (spec) where

import Data.Functor.Identity (Identity)
import Data.Text (Text)
import Manifest.Core.Table (Base, Col, FieldMeta(..), PrimaryKey, Serial)
import Test.Hspec

-- Compile-time proofs that Base/Col reduce as intended. If these type equalities
-- did not hold, the module would not compile.
_pkReduces :: Base (PrimaryKey (Serial Int)) -> Int
_pkReduces = id

_colIdentityReduces :: Col Identity (PrimaryKey (Serial Int)) -> Int
_colIdentityReduces = id

_textPassesThrough :: Base Text -> Text
_textPassesThrough = id

spec :: Spec
spec = describe "Manifest.Core.Table" $ do
  it "reflects PK/serial flags from marker structure" $ do
    fieldIsPK @(PrimaryKey (Serial Int)) `shouldBe` True
    fieldIsSerial @(PrimaryKey (Serial Int)) `shouldBe` True
    fieldIsPK @Text `shouldBe` False
    fieldIsSerial @Text `shouldBe` False
    fieldIsSerial @(Serial Int) `shouldBe` True
    fieldIsPK @(Serial Int) `shouldBe` False
```

Add `import qualified MetaSpec` and `MetaSpec.spec` to `test/Spec.hs`.

- [ ] **Step 4: Run to verify it fails, then passes**

Run: `zinc test`
Expected: FAIL until `Manifest.Core.Table` exists and the `FieldMeta` instances resolve, then the
`MetaSpec` flag examples pass and the compile-time `Base`/`Col` proofs hold.

- [ ] **Step 5: Commit**

```bash
git add src/Manifest/Core/Table.hs test/Fixtures.hs test/MetaSpec.hs test/Spec.hs
git commit -m "feat(sp1): HKD markers, Base/Col families, FieldMeta"
```

---

### Task 5: `TableMeta` + Generics column deriver

Walk `Generic (UserT Exposed)` to produce ordered `[ColumnMeta]` (name + PK/serial flags), names via
`camelToSnake`.

**Files:**
- Create: `src/Manifest/Core/Meta.hs`
- Modify: `test/MetaSpec.hs`

- [ ] **Step 1: Write the metadata + deriver module**

Create `src/Manifest/Core/Meta.hs`:

```haskell
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Manifest.Core.Meta
  ( ColumnMeta(..)
  , TableMeta(..)
  , camelToSnake
  , pkColumn
  , GColumns(..)
  , genericTableMeta
  ) where

import Data.Char (isUpper, toLower)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Functor.Identity (Identity)
import Data.List (find)
import Data.Proxy (Proxy(..))
import GHC.Generics
import Manifest.Core.Table (Exposed, FieldMeta(..))

-- | One column's persistence metadata.
data ColumnMeta = ColumnMeta
  { cmName     :: ByteString
  , cmIsPK     :: Bool
  , cmIsSerial :: Bool
  } deriving (Eq, Show)

-- | A table's metadata. Phantom @a@ ties it to the runtime row type.
data TableMeta a = TableMeta
  { tmTable   :: ByteString
  , tmColumns :: [ColumnMeta]
  } deriving (Eq, Show)

-- | The single primary-key column (SP1 assumes exactly one).
pkColumn :: TableMeta a -> ColumnMeta
pkColumn tm = case find cmIsPK (tmColumns tm) of
  Just c  -> c
  Nothing -> error ("Manifest: table " <> BC.unpack (tmTable tm) <> " has no primary key")

-- | camelCase → snake_case, no prefix stripping. @userName@ → @user_name@.
camelToSnake :: String -> ByteString
camelToSnake = BC.pack . go
  where
    go [] = []
    go (c:cs)
      | isUpper c = '_' : toLower c : go cs
      | otherwise = c : go cs

-- | Derive @[ColumnMeta]@ from a Generic rep of @t Exposed@.
class GColumns (rep :: * -> *) where
  gColumns :: [ColumnMeta]

instance GColumns f => GColumns (D1 m f) where gColumns = gColumns @f
instance GColumns f => GColumns (C1 m f) where gColumns = gColumns @f
instance (GColumns a, GColumns b) => GColumns (a :*: b) where
  gColumns = gColumns @a ++ gColumns @b

instance (Selector m, FieldMeta t) => GColumns (S1 m (Rec0 (Exposed t))) where
  gColumns =
    [ ColumnMeta
        { cmName     = camelToSnake (selName (undefined :: S1 m (Rec0 (Exposed t)) p))
        , cmIsPK     = fieldIsPK @t
        , cmIsSerial = fieldIsSerial @t
        }
    ]

-- | Build a 'TableMeta' for @t Identity@ from the Generic rep of @t Exposed@.
genericTableMeta
  :: forall t. (Generic (t Exposed), GColumns (Rep (t Exposed)))
  => ByteString
  -> TableMeta (t Identity)
genericTableMeta name =
  TableMeta { tmTable = name, tmColumns = gColumns @(Rep (t Exposed)) }
```

- [ ] **Step 2: Write the failing deriver test**

Append to `test/MetaSpec.hs` (add imports `Manifest.Core.Meta` and `Fixtures (UserT)`; add a
`describe` for the table metadata):

```haskell
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..), genericTableMeta)
import Fixtures (UserT)
```

```haskell
  describe "genericTableMeta" $
    it "derives ordered columns with PK/serial flags from UserT" $ do
      let tm = genericTableMeta @UserT "users"
      tmTable tm `shouldBe` "users"
      tmColumns tm `shouldBe`
        [ ColumnMeta "user_id"    True  True
        , ColumnMeta "user_name"  False False
        , ColumnMeta "user_email" False False
        ]
```

- [ ] **Step 3: Run to verify it fails, then passes**

Run: `zinc test`
Expected: FAIL until `Manifest.Core.Meta` exists, then PASS — derived columns match in order/flags.

- [ ] **Step 4: Commit**

```bash
git add src/Manifest/Core/Meta.hs test/MetaSpec.hs
git commit -m "feat(sp1): TableMeta + Generics column deriver (camel→snake)"
```

---

### Task 6: `Entity` class + generic row codec + `Key`

The class the session operates over, with Generics-derived `rowDecoder`/`rowEncode`, plus `Key` and
identity-map helpers.

**Files:**
- Create: `src/Manifest/Entity.hs`
- Modify: `test/Fixtures.hs` (add the `Entity User` instance)
- Test: `test/MetaSpec.hs` (codec round-trip via the generic encoder/decoder)

- [ ] **Step 1: Write the Entity module**

Create `src/Manifest/Entity.hs`:

```haskell
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Manifest.Entity
  ( Entity(..)
  , Key(..)
  , genericRowDecoder
  , genericRowEncode
  , identityKey
  , pkParam
  , pkIndex
  ) where

import Data.List (findIndex)
import Data.Maybe (fromMaybe)
import Data.Typeable (Typeable, SomeTypeRep, someTypeRep)
import Data.Proxy (Proxy(..))
import GHC.Generics
import Manifest.Core.Codec (FromField, RowDecoder, SqlParam, ToField(..), field)
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..), pkColumn)

-- | The class the Unit-of-Work operates over. SP1 derives every method
-- generically except 'primKey' (the PK selector) and 'tableMeta' (the table name).
class Typeable a => Entity a where
  type PrimKey a
  tableMeta  :: TableMeta a
  rowDecoder :: RowDecoder a
  rowEncode  :: a -> [SqlParam]
  primKey    :: a -> PrimKey a

-- | A row's identity: a newtype over its primary-key value.
newtype Key a = Key { unKey :: PrimKey a }

-- Generic row decoder ---------------------------------------------------------

class GRowDecode (rep :: * -> *) where
  gRowDecode :: RowDecoder (rep p)

instance GRowDecode f => GRowDecode (D1 m f) where gRowDecode = M1 <$> gRowDecode
instance GRowDecode f => GRowDecode (C1 m f) where gRowDecode = M1 <$> gRowDecode
instance (GRowDecode a, GRowDecode b) => GRowDecode (a :*: b) where
  gRowDecode = (:*:) <$> gRowDecode <*> gRowDecode
instance FromField t => GRowDecode (S1 m (Rec0 t)) where
  gRowDecode = M1 . K1 <$> field

-- | Default 'rowDecoder' via Generics.
genericRowDecoder :: (Generic a, GRowDecode (Rep a)) => RowDecoder a
genericRowDecoder = to <$> gRowDecode

-- Generic row encoder ---------------------------------------------------------

class GRowEncode (rep :: * -> *) where
  gRowEncode :: rep p -> [SqlParam]

instance GRowEncode f => GRowEncode (D1 m f) where gRowEncode (M1 x) = gRowEncode x
instance GRowEncode f => GRowEncode (C1 m f) where gRowEncode (M1 x) = gRowEncode x
instance (GRowEncode a, GRowEncode b) => GRowEncode (a :*: b) where
  gRowEncode (a :*: b) = gRowEncode a ++ gRowEncode b
instance ToField t => GRowEncode (S1 m (Rec0 t)) where
  gRowEncode (M1 (K1 x)) = [toField x]

-- | Default 'rowEncode' via Generics. Produces one 'SqlParam' per column, in
-- 'tableMeta' column order.
genericRowEncode :: (Generic a, GRowEncode (Rep a)) => a -> [SqlParam]
genericRowEncode = gRowEncode . from

-- Identity helpers ------------------------------------------------------------

-- | Index of the primary-key column within 'tableMeta'/'rowEncode'.
pkIndex :: forall a. Entity a => Int
pkIndex = fromMaybe (error "Manifest: no primary key column")
                    (findIndex cmIsPK (tmColumns (tableMeta @a)))

-- | The encoded primary-key value of a record (its bytes in the identity map).
pkParam :: forall a. Entity a => a -> SqlParam
pkParam a = rowEncode a !! pkIndex @a

-- | The heterogeneous identity-map key for a record.
identityKey :: forall a. Entity a => a -> (SomeTypeRep, SqlParam)
identityKey a = (someTypeRep (Proxy @a), pkParam a)
```

- [ ] **Step 2: Add the Entity instance to the fixtures**

Modify `test/Fixtures.hs` — import and instantiate (add `Entity` machinery imports; the
`genericRowDecoder`/`genericRowEncode` defaults do the work):

```haskell
import Manifest.Entity (Entity(..), genericRowDecoder, genericRowEncode)
import Manifest.Core.Meta (genericTableMeta)
```

```haskell
instance Entity User where
  type PrimKey User = Int
  tableMeta  = genericTableMeta @UserT "users"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = userId
```

- [ ] **Step 3: Write the failing generic-codec round-trip test**

Append to `test/MetaSpec.hs` (import the fixture `User`, the `Entity` methods, and `decodeRow`):

```haskell
import Fixtures (User, UserT(..))
import Manifest.Entity (Entity(..), pkParam)
import Manifest.Core.Codec (decodeRow)
import qualified Data.ByteString.Char8 as BC
```

```haskell
  describe "generic row codec" $ do
    it "encodes a User to its column vector in table order" $ do
      let u = User { userId = 7, userName = "Bob", userEmail = Just "b@x.io" }
      rowEncode u `shouldBe`
        [ Just (BC.pack "7"), Just (BC.pack "Bob"), Just (BC.pack "b@x.io") ]

    it "encodes a NULL email as Nothing" $ do
      let u = User { userId = 7, userName = "Bob", userEmail = Nothing }
      rowEncode u `shouldBe` [ Just (BC.pack "7"), Just (BC.pack "Bob"), Nothing ]

    it "round-trips through decodeRow" $ do
      let u = User { userId = 7, userName = "Bob", userEmail = Just "b@x.io" }
      fmap (\u' -> (userId u', userName u', userEmail u'))
           (decodeRow (rowDecoder @User) (rowEncode u))
        `shouldBe` Right (7, "Bob", Just "b@x.io")

    it "extracts the PK bytes" $ do
      let u = User { userId = 7, userName = "Bob", userEmail = Nothing }
      pkParam u `shouldBe` Just (BC.pack "7")
```

- [ ] **Step 4: Run to verify it fails, then passes**

Run: `zinc test`
Expected: FAIL until `Manifest.Entity` + the instance exist, then PASS.

- [ ] **Step 5: Commit**

```bash
git add src/Manifest/Entity.hs test/Fixtures.hs test/MetaSpec.hs
git commit -m "feat(sp1): Entity class, generic row codec, Key + identity helpers"
```

---

### Task 7: Query refs, conditions, assignments, `#label`

Value-level column references resolved from `OverloadedLabels`, the condition/assignment vocabulary
the command path and `where_` use.

**Files:**
- Create: `src/Manifest/Core/Query.hs`
- Test: `test/SqlSpec.hs` (the operator-construction half; SQL rendering is Task 8)

- [ ] **Step 1: Write the query module**

Create `src/Manifest/Core/Query.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Manifest.Core.Query
  ( Column(..)
  , Op(..)
  , Cond(..)
  , Assign(..)
  , (==.), (/=.), (>.), (<.)
  , (=.)
  ) where

import Data.ByteString (ByteString)
import Data.Proxy (Proxy(..))
import GHC.OverloadedLabels (IsLabel(..))
import GHC.TypeLits (KnownSymbol, symbolVal)
import Manifest.Core.Codec (SqlParam, ToField(..))
import Manifest.Core.Meta (camelToSnake)

-- | A typed reference to column @t@ of table @a@. @#userName :: Column User Text@.
-- The column name is computed from the label via the same camel→snake rule the
-- deriver uses, so labels and metadata agree.
newtype Column a (t :: *) = Column { colName :: ByteString }

instance (KnownSymbol name) => IsLabel name (Column a t) where
  fromLabel = Column (camelToSnake (symbolVal (Proxy @name)))

-- | Comparison operators supported in SP1.
data Op = OpEq | OpNeq | OpGt | OpLt
  deriving (Eq, Show)

-- | A single condition: @column op value@. A list of conditions is ANDed.
data Cond a = Cond ByteString Op SqlParam
  deriving (Eq, Show)

-- | A single SET assignment in the command path.
data Assign a = Assign ByteString SqlParam
  deriving (Eq, Show)

infix 4 ==., /=., >., <.
(==.), (/=.), (>.), (<.) :: ToField t => Column a t -> t -> Cond a
Column n ==. v = Cond n OpEq  (toField v)
Column n /=. v = Cond n OpNeq (toField v)
Column n >.  v = Cond n OpGt  (toField v)
Column n <.  v = Cond n OpLt  (toField v)

infix 4 =.
(=.) :: ToField t => Column a t -> t -> Assign a
Column n =. v = Assign n (toField v)
```

- [ ] **Step 2: Write the failing operator-construction test**

Create `test/SqlSpec.hs` (only the condition/assignment portion now; rendering is Task 8). Note the
`-XOverloadedLabels` pragma:

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module SqlSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Fixtures (User)
import Manifest.Core.Query
import Test.Hspec

spec :: Spec
spec = describe "Manifest.Core.Query" $ do
  it "builds conditions from labels with camel→snake names" $ do
    (#userName ==. ("Bob" :: String) :: Cond User)
      `shouldBe` Cond "user_name" OpEq (Just (BC.pack "Bob"))
    (#userId <. (5 :: Int) :: Cond User)
      `shouldBe` Cond "user_id" OpLt (Just (BC.pack "5"))

  it "builds assignments from labels" $
    (#userName =. ("Bob" :: String) :: Assign User)
      `shouldBe` Assign "user_name" (Just (BC.pack "Bob"))
```

Add `import qualified SqlSpec` and `SqlSpec.spec` to `test/Spec.hs`.

- [ ] **Step 3: Run to verify it fails, then passes**

Run: `zinc test`
Expected: FAIL until `Manifest.Core.Query` exists, then PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Manifest/Core/Query.hs test/SqlSpec.hs test/Spec.hs
git commit -m "feat(sp1): column refs, conditions, assignments, #label"
```

---

### Task 8: Core SQL rendering (pure)

Pure functions turning metadata + conditions into parameterised Postgres SQL (`$1`, `$2`, …). No DB.

**Files:**
- Create: `src/Manifest/Core/Sql.hs`
- Modify: `test/SqlSpec.hs`

- [ ] **Step 1: Write the SQL rendering module**

Create `src/Manifest/Core/Sql.hs`:

```haskell
module Manifest.Core.Sql
  ( renderConds
  , renderSelect
  , renderInsert
  , renderUpdate
  , renderDelete
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.List (intercalate)
import Manifest.Core.Meta (ColumnMeta(..), TableMeta(..))
import Manifest.Core.Query (Cond(..), Op(..))

bcIntercalate :: ByteString -> [ByteString] -> ByteString
bcIntercalate sep = BC.intercalate sep

placeholder :: Int -> ByteString
placeholder n = BC.pack ('$' : show n)

renderOp :: Op -> ByteString
renderOp OpEq  = "="
renderOp OpNeq = "<>"
renderOp OpGt  = ">"
renderOp OpLt  = "<"

-- | Render a WHERE clause (ANDed) starting at placeholder index @start@.
-- Returns the clause text (empty if no conditions) and the next free index.
renderConds :: Int -> [Cond a] -> (ByteString, Int)
renderConds start [] = ("", start)
renderConds start conds =
  let go i (Cond col op _) = (col <> " " <> renderOp op <> " " <> placeholder i, i + 1)
      step (acc, i) c = let (txt, i') = go i c in (acc ++ [txt], i')
      (clauses, next) = foldl step ([], start) conds
  in (" WHERE " <> bcIntercalate " AND " clauses, next)

-- | @SELECT c1, c2, ... FROM t [WHERE ...]@
renderSelect :: TableMeta a -> [Cond a] -> ByteString
renderSelect tm conds =
  let cols = bcIntercalate ", " (map cmName (tmColumns tm))
      (whereTxt, _) = renderConds 1 conds
  in "SELECT " <> cols <> " FROM " <> tmTable tm <> whereTxt

-- | @INSERT INTO t (cols) VALUES ($1, ...) RETURNING all_cols@
renderInsert :: TableMeta a -> [ColumnMeta] -> ByteString
renderInsert tm insCols =
  let names  = map cmName insCols
      vals   = [ placeholder i | i <- [1 .. length insCols] ]
      ret    = bcIntercalate ", " (map cmName (tmColumns tm))
  in "INSERT INTO " <> tmTable tm
       <> " (" <> bcIntercalate ", " names <> ")"
       <> " VALUES (" <> bcIntercalate ", " vals <> ")"
       <> " RETURNING " <> ret

-- | @UPDATE t SET c1 = $1, ... WHERE pk = $n@
renderUpdate :: TableMeta a -> [ByteString] -> ByteString -> ByteString
renderUpdate tm setCols pkCol =
  let sets = [ c <> " = " <> placeholder i | (c, i) <- zip setCols [1 ..] ]
      pkPh = placeholder (length setCols + 1)
  in "UPDATE " <> tmTable tm
       <> " SET " <> bcIntercalate ", " sets
       <> " WHERE " <> pkCol <> " = " <> pkPh

-- | @DELETE FROM t WHERE pk = $1@
renderDelete :: TableMeta a -> ByteString -> ByteString
renderDelete tm pkCol =
  "DELETE FROM " <> tmTable tm <> " WHERE " <> pkCol <> " = " <> placeholder 1
```

> `intercalate` from `Data.List` is imported but `BC.intercalate` is used — drop the unused
> `Data.List` import to keep `-Wall` clean.

- [ ] **Step 2: Write the failing rendering test**

Append to `test/SqlSpec.hs` (import `Manifest.Core.Sql`, `Manifest.Core.Meta`, `Manifest.Entity (tableMeta)`):

```haskell
import Manifest.Core.Sql
import Manifest.Core.Meta (TableMeta, tmColumns, cmIsSerial, cmName)
import Manifest.Entity (Entity(tableMeta))
```

```haskell
  describe "Manifest.Core.Sql" $ do
    let tm = tableMeta @User
        nonSerial = filter (not . cmIsSerial) (tmColumns tm)

    it "renders SELECT with all columns and a WHERE" $
      renderSelect tm [Cond "user_id" OpEq (Just (BC.pack "42"))]
        `shouldBe` "SELECT user_id, user_name, user_email FROM users WHERE user_id = $1"

    it "renders SELECT without a WHERE when there are no conditions" $
      renderSelect tm []
        `shouldBe` "SELECT user_id, user_name, user_email FROM users"

    it "renders INSERT of non-serial columns RETURNING all columns" $
      renderInsert tm nonSerial
        `shouldBe` "INSERT INTO users (user_name, user_email) VALUES ($1, $2) \
                   \RETURNING user_id, user_name, user_email"

    it "renders a minimal UPDATE with the PK placeholder last" $
      renderUpdate tm ["user_name"] "user_id"
        `shouldBe` "UPDATE users SET user_name = $1 WHERE user_id = $2"

    it "renders DELETE by PK" $
      renderDelete tm "user_id"
        `shouldBe` "DELETE FROM users WHERE user_id = $1"

    it "ANDs multiple conditions and advances placeholders" $
      fst (renderConds 1 [ Cond "user_name" OpEq (Just (BC.pack "Bob"))
                         , Cond "user_id"   OpGt (Just (BC.pack "3")) ])
        `shouldBe` " WHERE user_name = $1 AND user_id > $2"
```

- [ ] **Step 3: Run to verify it fails, then passes**

Run: `zinc test`
Expected: FAIL until `Manifest.Core.Sql` exists, then PASS — every rendering matches exactly.

- [ ] **Step 4: Commit**

```bash
git add src/Manifest/Core/Sql.hs test/SqlSpec.hs
git commit -m "feat(sp1): pure parameterised SQL rendering"
```

---

### Task 9: Session, `Db` monad, identity map, read path

The bespoke `Db` monad, the `Session` (connection + identity map + pending ops + statement log), and
the read path (`get`/`selectWhere`) that records baselines.

**Files:**
- Create: `src/Manifest/Session.hs`
- Test: `test/SessionSpec.hs`

- [ ] **Step 1: Write the Session module (read path; flush/writes land in Task 10)**

Create `src/Manifest/Session.hs`:

```haskell
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Manifest.Session
  ( Db
  , Session(..)
  , SessionConfig(..)
  , defaultConfig
  , PendingOp(..)
  , IdentityMap
  , withSession
  , execDb
  , statementLog
  , setBaseline
  , lookupBaseline
  , get
  , selectWhere
  ) where

import Control.Monad.IO.Class (MonadIO(..))
import Control.Exception (throwIO)
import Control.Monad.Trans.Reader (ReaderT(..), ask, runReaderT)
import Data.ByteString (ByteString)
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Typeable (SomeTypeRep)
import Manifest.Core.Codec (SqlParam, decodeRow)
import Manifest.Core.Meta (TableMeta(..), pkColumn, cmName)
import Manifest.Core.Query (Cond(..), Op(..))
import Manifest.Core.Sql (renderSelect)
import Manifest.Entity
import Manifest.Error (DbError(..), DbException(..))
import Manifest.Postgres (Connection, Pool, execText, withConnection)

-- | (TypeRep, encoded-PK) → baseline encoded-column vector.
type IdentityMap = Map (SomeTypeRep, SqlParam) [SqlParam]

-- | A deferred write awaiting flush. (Adds are eager — see plan notes.)
data PendingOp where
  OpSave   :: Entity a => a -> PendingOp
  OpDelete :: Entity a => a -> PendingOp

data SessionConfig = SessionConfig
  { cfgAutoflush :: Bool   -- ^ flush pending writes before each query (default on)
  }

defaultConfig :: SessionConfig
defaultConfig = SessionConfig { cfgAutoflush = True }

data Session = Session
  { sessConn     :: Connection
  , sessIdentity :: IORef IdentityMap
  , sessPending  :: IORef [PendingOp]
  , sessLog      :: IORef [(ByteString, [SqlParam])]
  , sessConfig   :: SessionConfig
  }

-- | The session monad: sealed @ReaderT Session IO@.
newtype Db a = Db { unDb :: ReaderT Session IO a }
  deriving (Functor, Applicative, Monad, MonadIO)

-- | Acquire a connection, fresh per-session maps, run, release.
withSession :: Pool -> Db a -> IO a
withSession pool (Db r) =
  withConnection pool $ \conn -> do
    idMap <- newIORef Map.empty
    pend  <- newIORef []
    logr  <- newIORef []
    runReaderT r (Session conn idMap pend logr defaultConfig)

-- | Execute a data statement, appending it to the session statement log.
execDb :: ByteString -> [SqlParam] -> Db [[SqlParam]]
execDb sql params = Db $ do
  sess <- ask
  liftIO $ modifyIORef' (sessLog sess) (++ [(sql, params)])
  liftIO $ execText (sessConn sess) sql params

-- | The statements executed so far this session, in order.
statementLog :: Db [(ByteString, [SqlParam])]
statementLog = Db $ ask >>= liftIO . readIORef . sessLog

-- Identity-map helpers (used here and by flush in Task 10) --------------------

setBaseline :: forall a. Entity a => a -> Db ()
setBaseline a = Db $ do
  sess <- ask
  liftIO $ modifyIORef' (sessIdentity sess) (Map.insert (identityKey a) (rowEncode a))

lookupBaseline :: (SomeTypeRep, SqlParam) -> Db (Maybe [SqlParam])
lookupBaseline k = Db $ do
  sess <- ask
  liftIO $ Map.lookup k <$> readIORef (sessIdentity sess)

-- Read path -------------------------------------------------------------------

decodeRowDb :: forall a. Entity a => [SqlParam] -> Db a
decodeRowDb row = case decodeRow (rowDecoder @a) row of
  Right a  -> pure a
  Left err -> Db (liftIO (throwIO (DbException (DecodeFailure err))))

-- | flush hook — the real implementation is added in Task 10. Until then,
-- autoflush is a no-op (no writes can be pending yet).
autoflushHook :: Db ()
autoflushHook = pure ()

-- | Load by primary key; records a baseline snapshot for the loaded entity.
get :: forall a. (Entity a, ToField (PrimKey a)) => Key a -> Db (Maybe a)
get (Key k) = do
  autoflushHook
  let tm  = tableMeta @a
      sql = renderSelect tm [Cond (cmName (pkColumn tm)) OpEq (toField k)]
  rows <- execDb sql [toField k]
  case rows of
    []        -> pure Nothing
    (row : _) -> do
      a <- decodeRowDb @a row
      setBaseline a
      pure (Just a)

-- | Load all rows matching the (ANDed) conditions; each becomes managed.
selectWhere :: forall a. Entity a => [Cond a] -> Db [a]
selectWhere conds = do
  autoflushHook
  let tm  = tableMeta @a
      sql = renderSelect tm conds
      ps  = [ v | Cond _ _ v <- conds ]
  rows <- execDb sql ps
  mapM (\row -> do a <- decodeRowDb @a row; setBaseline a; pure a) rows
```

> `autoflushHook` is replaced by the real `flush` in Task 10 (Session and flush live in the same
> module after that task). Keeping it a no-op now lets the read path land and be tested independently.

- [ ] **Step 2: Write the failing read-path test**

Create `test/SessionSpec.hs`:

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module SessionSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Fixtures (User, UserT(..), withTestDb)
import Manifest.Core.Query
import Manifest.Entity (Key(..))
import Manifest.Postgres (execText, withConnection)
import Manifest.Session
import Test.Hspec

-- Seed a couple of rows directly so the read path has data.
seed :: Manifest.Postgres.Connection -> IO ()
seed conn = do
  _ <- execText conn
        "INSERT INTO users (user_name, user_email) VALUES ($1,$2),($3,$4)"
        [ Just (BC.pack "Ada"), Just (BC.pack "ada@x.io")
        , Just (BC.pack "Bob"), Nothing ]
  pure ()

spec :: Spec
spec = describe "Manifest.Session (read path)" $ do
  it "get returns Nothing for a missing key" $
    withTestDb $ \pool ->
      withSession pool (get @User (Key 999)) `shouldReturn` Nothing

  it "get loads a row by primary key" $
    withTestDb $ \pool -> do
      withConnection pool seed
      mu <- withSession pool (get @User (Key 1))
      fmap (\u -> (userId u, userName u, userEmail u)) mu
        `shouldBe` Just (1, "Ada", Just "ada@x.io")

  it "selectWhere filters by condition" $
    withTestDb $ \pool -> do
      withConnection pool seed
      us <- withSession pool (selectWhere [#userName ==. ("Bob" :: String)])
      map (\u -> (userName u, userEmail u)) us
        `shouldBe` [("Bob", Nothing)]
```

> The `Manifest.Postgres.Connection` reference needs `import qualified Manifest.Postgres` or a direct
> import of `Connection`; add `import Manifest.Postgres (Connection, execText, withConnection)` and use
> `Connection` unqualified in `seed`.

Add `import qualified SessionSpec` and `SessionSpec.spec` to `test/Spec.hs`.

- [ ] **Step 3: Run to verify it fails, then passes**

Run: `zinc test`
Expected: FAIL until `Manifest.Session` exists, then PASS — get/selectWhere behave.

- [ ] **Step 4: Commit**

```bash
git add src/Manifest/Session.hs test/SessionSpec.hs test/Spec.hs
git commit -m "feat(sp1): Db monad, Session, identity map, read path"
```

---

### Task 10: Snapshot-diff, flush, `add`/`save`/`delete`, `withTransaction`

The heart of SP1. `save`/`delete` defer to flush; `add` is eager; flush diffs handed-back values
against baselines column-by-column and emits a **minimal** `UPDATE`. `withTransaction` brackets
BEGIN/COMMIT with ROLLBACK-on-exception and flushes before commit.

**Files:**
- Modify: `src/Manifest/Session.hs`
- Test: `test/FlushSpec.hs`

- [ ] **Step 1: Add writes, flush, and transactions to the Session module**

Edit `src/Manifest/Session.hs`. Extend the export list with `withTransaction, flush, add, save, delete`.
Add imports:

```haskell
import Control.Exception (SomeException, try)
import Manifest.Core.Meta (ColumnMeta(..), cmIsSerial, cmIsPK)
import Manifest.Core.Sql (renderInsert, renderUpdate, renderDelete)
```

Replace the placeholder `autoflushHook` with a call to the real `flush`, and add the write/flush
functions:

```haskell
-- Replace: autoflushHook = pure ()
autoflushHook :: Db ()
autoflushHook = do
  on <- Db (cfgAutoflush . sessConfig <$> ask)
  if on then flush else pure ()

-- | Stash a desired post-edit value; the diff is deferred to flush.
save :: Entity a => a -> Db ()
save a = pushPending (OpSave a)

-- | Stash a delete; emitted at flush.
delete :: Entity a => a -> Db ()
delete a = pushPending (OpDelete a)

pushPending :: PendingOp -> Db ()
pushPending op = Db $ do
  sess <- ask
  liftIO $ modifyIORef' (sessPending sess) (++ [op])

-- | Insert a transient value now (eager), returning the persistent, PK-filled
-- record. The row enters the identity map with its baseline snapshot.
add :: forall a. Entity a => a -> Db a
add a = do
  let tm        = tableMeta @a
      insCols   = filter (not . cmIsSerial) (tmColumns tm)
      vals      = [ v | (c, v) <- zip (tmColumns tm) (rowEncode a), not (cmIsSerial c) ]
      sql       = renderInsert tm insCols
  rows <- execDb sql vals
  case rows of
    (row : _) -> do
      a' <- decodeRowDb @a row
      setBaseline a'
      pure a'
    [] -> Db (liftIO (throwIO (DbException (OtherError "INSERT returned no row"))))

-- | Apply pending writes: saves first, then deletes (adds were eager).
flush :: Db ()
flush = do
  ops <- Db $ do
    sess <- ask
    liftIO $ atomicModifyIORef' (sessPending sess) (\xs -> ([], xs))
  mapM_ flushSave   [ a' | op <- ops, OpSave   a' <- [op] ]
  mapM_ flushDelete [ a' | op <- ops, OpDelete a' <- [op] ]

flushSave :: forall a. Entity a => a -> Db ()
flushSave a = do
  let tm    = tableMeta @a
      cols  = tmColumns tm
      newCs = rowEncode a
  mbase <- lookupBaseline (identityKey a)
  case mbase of
    Nothing ->
      Db (liftIO (throwIO (DbException
            (UnmanagedSave "save of an entity with no baseline (load it first)"))))
    Just base -> do
      let changed = [ (cmName c, v)
                    | (c, v, b) <- zip3 cols newCs base
                    , not (cmIsPK c)
                    , v /= b ]
      if null changed
        then pure ()                              -- no-op save emits nothing
        else do
          let sql = renderUpdate tm (map fst changed) (cmName (pkColumn tm))
          _ <- execDb sql (map snd changed ++ [pkParam a])
          setBaseline a                           -- refresh baseline to the saved state

flushDelete :: forall a. Entity a => a -> Db ()
flushDelete a = do
  let tm  = tableMeta @a
      sql = renderDelete tm (cmName (pkColumn tm))
  _ <- execDb sql [pkParam a]
  Db $ do
    sess <- ask
    liftIO $ modifyIORef' (sessIdentity sess) (Map.delete (identityKey a))

-- | BEGIN; run body; flush; COMMIT. ROLLBACK + rethrow on any exception.
-- BEGIN/COMMIT/ROLLBACK are issued raw (not in the statement log) so the log
-- reflects only data statements.
withTransaction :: Db a -> Db a
withTransaction (Db body) = Db $ do
  sess <- ask
  let conn = sessConn sess
  liftIO $ do _ <- execText conn "BEGIN" []; pure ()
  ea <- liftIO $ try (runReaderT (body >> unDb flush) sess)
  case ea of
    Left (e :: SomeException) -> liftIO $ do
      _ <- execText conn "ROLLBACK" []
      throwIO e
    Right a -> liftIO $ do
      _ <- execText conn "COMMIT" []
      pure a
```

> After this edit `flush` is defined, so `autoflushHook` calling it is well-typed. Confirm the import
> of `cmIsPK`/`cmIsSerial` from `Manifest.Core.Meta` (export them from that module if not already —
> they are record selectors on `ColumnMeta`, exported via `ColumnMeta(..)`).

- [ ] **Step 2: Write the failing flush test**

Create `test/FlushSpec.hs`:

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module FlushSpec (spec) where

import Control.Exception (try, evaluate, SomeException, throwIO, ErrorCall(..))
import qualified Data.ByteString.Char8 as BC
import Data.List (isPrefixOf)
import Fixtures (User, UserT(..), withTestDb)
import Manifest.Entity (Key(..))
import Manifest.Postgres (execText, withConnection)
import Manifest.Session
import Test.Hspec

dataStmts :: [(BC.ByteString, [Maybe BC.ByteString])] -> [String]
dataStmts = map (BC.unpack . fst)

spec :: Spec
spec = describe "Manifest.Session (flush / UoW)" $ do
  it "add inserts eagerly and returns the PK-filled record" $
    withTestDb $ \pool -> do
      u <- withSession pool $
             add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" })
      userId u `shouldSatisfy` (> 0)
      userName u `shouldBe` "Ada"

  it "save of a changed field emits a MINIMAL update (only that column)" $
    withTestDb $ \pool -> do
      log' <- withSession pool $ do
        u <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" })
        withTransaction $ save (u { userName = "Bob" })
        statementLog
      -- the UPDATE touches only user_name (plus the PK in WHERE)
      let updates = filter ("UPDATE" `isPrefixOf`) (dataStmts log')
      updates `shouldBe` ["UPDATE users SET user_name = $1 WHERE user_id = $2"]

  it "save with no change emits no UPDATE" $
    withTestDb $ \pool -> do
      log' <- withSession pool $ do
        u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing })
        withTransaction $ save u            -- identical value
        statementLog
      filter ("UPDATE" `isPrefixOf`) (dataStmts log') `shouldBe` []

  it "the saved change is persisted (re-load sees it)" $
    withTestDb $ \pool -> do
      reloaded <- withSession pool $ do
        u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing })
        withTransaction $ save (u { userName = "Bob" })
        get @User (Key (userId u))
      fmap userName reloaded `shouldBe` Just "Bob"

  it "delete removes the row" $
    withTestDb $ \pool -> do
      after <- withSession pool $ do
        u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing })
        withTransaction $ delete u
        get @User (Key (userId u))
      after `shouldBe` Nothing

  it "rolls back the transaction on exception" $
    withTestDb $ \pool -> do
      _ <- (try :: IO a -> IO (Either SomeException a)) $ withSession pool $ do
             u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing })
             withTransaction $ do
               save (u { userName = "Bob" })
               _ <- Db (error "boom")   -- abort mid-transaction
               pure ()
      -- a fresh session sees the pre-transaction value (Ada), proving rollback
      mu <- withSession pool (selectWhere [] :: Db [User])
      map userName mu `shouldBe` ["Ada"]
```

> The `Db (error "boom")` line needs `Db` and the `ReaderT` import exposed; simpler: add a tiny
> `liftIO (throwIO (userError "boom"))` using `MonadIO`. Replace that line with
> `_ <- liftIO (ioError (userError "boom"))` and import `Control.Monad.IO.Class (liftIO)` +
> `System.IO.Error (ioError, userError)`. Adjust the test accordingly so it compiles.

Add `import qualified FlushSpec` and `FlushSpec.spec` to `test/Spec.hs`.

- [ ] **Step 3: Run to verify it fails, then passes**

Run: `zinc test`
Expected: FAIL until the write/flush functions exist, then PASS — crucially, the minimal-UPDATE
assertion proves the core thesis.

- [ ] **Step 4: Commit**

```bash
git add src/Manifest/Session.hs test/FlushSpec.hs test/Spec.hs
git commit -m "feat(sp1): snapshot-diff flush, add/save/delete, withTransaction"
```

---

### Task 11: Command escape hatch — `update`/`deleteWhere`

Blind/bulk writes that bypass the identity map (path C), in the same Session.

**Files:**
- Create: `src/Manifest/Session/Command.hs`
- Test: `test/CommandSpec.hs`

- [ ] **Step 1: Write the command module**

Create `src/Manifest/Session/Command.hs`:

```haskell
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Manifest.Session.Command
  ( update
  , deleteWhere
  ) where

import qualified Data.ByteString.Char8 as BC
import Manifest.Core.Codec (ToField(..))
import Manifest.Core.Meta (TableMeta(..), pkColumn, cmName)
import Manifest.Core.Query (Assign(..), Cond(..))
import Manifest.Core.Sql (renderConds, renderUpdate, renderDelete)
import Manifest.Entity (Entity(..), Key(..))
import Manifest.Session (Db, execDb)

-- | Blind @UPDATE t SET .. WHERE pk = ..@. Does not touch the identity map.
update :: forall a. (Entity a, ToField (PrimKey a)) => Key a -> [Assign a] -> Db ()
update (Key k) assigns = do
  let tm     = tableMeta @a
      cols   = [ c | Assign c _ <- assigns ]
      vals   = [ v | Assign _ v <- assigns ]
      sql    = renderUpdate tm cols (cmName (pkColumn tm))
  _ <- execDb sql (vals ++ [toField k])
  pure ()

-- | Bulk @DELETE FROM t WHERE ..@, no per-row identity. Conditions are ANDed.
deleteWhere :: forall a. Entity a => [Cond a] -> Db ()
deleteWhere conds = do
  let tm = tableMeta @a
      (whereTxt, _) = renderConds 1 conds
      sql = "DELETE FROM " <> tmTable tm <> whereTxt
      ps  = [ v | Cond _ _ v <- conds ]
  _ <- execDb sql ps
  pure ()
```

> `renderDelete` is imported but unused here (`deleteWhere` builds a multi-condition DELETE via
> `renderConds`); drop the unused import for `-Wall`.

- [ ] **Step 2: Write the failing command test**

Create `test/CommandSpec.hs`:

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module CommandSpec (spec) where

import Fixtures (User, UserT(..), withTestDb)
import Manifest.Core.Query
import Manifest.Entity (Key(..))
import Manifest.Session
import Manifest.Session.Command
import Test.Hspec

spec :: Spec
spec = describe "Manifest.Session.Command" $ do
  it "update blind-writes a column by key" $
    withTestDb $ \pool -> do
      name <- withSession pool $ do
        u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing })
        update (Key (userId u)) [ #userName =. ("Zed" :: String) ]
        mu <- get @User (Key (userId u))
        pure (fmap userName mu)
      name `shouldBe` Just "Zed"

  it "deleteWhere bulk-deletes matching rows" $
    withTestDb $ \pool -> do
      remaining <- withSession pool $ do
        _ <- add (User { userId = 0, userName = "Ada", userEmail = Nothing })
        _ <- add (User { userId = 0, userName = "Bob", userEmail = Nothing })
        deleteWhere [ #userName ==. ("Ada" :: String) ]
        us <- selectWhere ([] :: [Cond User])
        pure (map userName us)
      remaining `shouldBe` ["Bob"]
```

Add `import qualified CommandSpec` and `CommandSpec.spec` to `test/Spec.hs`.

- [ ] **Step 3: Run to verify it fails, then passes**

Run: `zinc test`
Expected: FAIL until `Manifest.Session.Command` exists, then PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Manifest/Session/Command.hs test/CommandSpec.hs test/Spec.hs
git commit -m "feat(sp1): command escape hatch (update/deleteWhere)"
```

---

### Task 12: Umbrella re-export + end-to-end worked example

Tie the public surface together and prove the §4.6 worked example end-to-end, asserting the exact
statements the flush emits.

**Files:**
- Modify: `src/Manifest.hs`
- Test: `test/EndToEndSpec.hs`

- [ ] **Step 1: Write the umbrella module**

Replace `src/Manifest.hs`:

```haskell
-- | Manifest — the Unit-of-Work layer Haskell never had. Public surface for SP1.
module Manifest
  ( -- * Session
    Db
  , withSession
  , withTransaction
  , flush
  , statementLog
    -- * Unit-of-Work
  , get
  , selectWhere
  , add
  , save
  , delete
    -- * Command escape hatch
  , update
  , deleteWhere
    -- * Entities & keys
  , Entity(..)
  , Key(..)
    -- * Query vocabulary
  , Column(..)
  , Cond(..)
  , Assign(..)
  , (==.), (/=.), (>.), (<.)
  , (=.)
    -- * Schema markers
  , Serial
  , PrimaryKey
  , Col
    -- * Errors
  , DbError(..)
  , DbException(..)
  ) where

import Manifest.Core.Query
import Manifest.Core.Table
import Manifest.Entity
import Manifest.Error
import Manifest.Session
import Manifest.Session.Command
```

- [ ] **Step 2: Write the failing end-to-end test**

Create `test/EndToEndSpec.hs`:

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

module EndToEndSpec (spec) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isPrefixOf)
import Fixtures (User, UserT(..), withTestDb)
import Manifest
import Test.Hspec

stmtTexts :: [(BC.ByteString, [Maybe BC.ByteString])] -> [String]
stmtTexts = map (BC.unpack . fst)

spec :: Spec
spec = describe "Manifest end-to-end (the worked example)" $
  it "edit a plain value → minimal UPDATE, in one transaction, both paths" $
    withTestDb $ \pool -> do
      (finalName, finalEmail, log') <- withSession pool $ do
        -- Arrange: a persistent user.
        u0 <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" })
        -- Act: one transaction exercising snapshot-diff + command path.
        withTransaction $ do
          save (u0 { userName = "Bob" })                 -- snapshot-diff: minimal UPDATE
          update (Key (userId u0)) [ #userEmail =. ("bob@x.io" :: String) ]  -- command path
        reloaded <- get @User (Key (userId u0))
        l <- statementLog
        pure (fmap userName reloaded, fmap userEmail reloaded, l)

      finalName  `shouldBe` Just "Bob"
      finalEmail `shouldBe` Just (Just "bob@x.io")

      -- The flush emitted a minimal, single-column UPDATE for the snapshot-diff save.
      let updates = filter ("UPDATE" `isPrefixOf`) (stmtTexts log')
      updates `shouldContain` ["UPDATE users SET user_name = $1 WHERE user_id = $2"]
      -- And the command path emitted its own blind UPDATE of user_email.
      updates `shouldContain` ["UPDATE users SET user_email = $1 WHERE user_id = $2"]
```

Add `import qualified EndToEndSpec` and `EndToEndSpec.spec` to `test/Spec.hs`.

- [ ] **Step 3: Run to verify it fails, then passes**

Run: `zinc test`
Expected: FAIL until the umbrella module exports line up, then PASS — the full SP1 thesis demonstrated.

- [ ] **Step 4: Final full build + test**

Run:
```bash
zinc build
zinc test
```
Expected: clean build (no `-Wall` warnings after the noted unused-import cleanups) and all specs green
across Codec, Postgres, Meta, Sql, Session, Flush, Command, EndToEnd.

- [ ] **Step 5: Commit**

```bash
git add src/Manifest.hs test/EndToEndSpec.hs test/Spec.hs
git commit -m "feat(sp1): umbrella export + end-to-end worked example"
```

---

## Spec coverage check (self-review)

| Design §  | Requirement | Where covered |
|---|---|---|
| §3 Core | Thin owned HKD: `Col`/`Columnar` collapse under Identity | Task 4 (`Base`/`Col`, `FieldMeta`) |
| §3 Core | Conditions `==. /=. >. <.` | Task 7 |
| §3 Core | Applicative codec, no `mapN` ceiling | Task 2 (`RowDecoder` Applicative, 5-tuple test) |
| §3 Core | SQL generation, Backend-parameterised placeholders | Task 8 (`$n`) |
| §4.1 | `Db` monad = sealed `ReaderT Session IO`; `withSession`/`withTransaction` on bracket | Tasks 9, 10 |
| §4.1 | Identity map keyed `(TypeRep, PKBytes)`, type-erased | Task 6 (`identityKey`), Task 9 (`IdentityMap`) |
| §4.2 | Lifecycle: get/select → Persistent (snapshot); add → Pending→Persistent w/ RETURNING PK | Tasks 9, 10 |
| §4.3 | Identity = the primary key; `save` finds baseline by PK | Task 10 (`flushSave`, `identityKey`) |
| §4.4 | Flush: adds → INSERT RETURNING; saves → minimal UPDATE; deletes → DELETE; order inserts→updates→deletes | Task 10 (adds eager; saves-then-deletes flush) |
| §4.4 | PK never a diff target | Task 10 (`not (cmIsPK c)` filter) |
| §4.5 | Command path `update`/`deleteWhere`, bypasses identity map | Task 11 |
| §4.6 | Worked example, both paths, one transaction | Task 12 |
| §4.7 | Autoflush before queries (toggleable) | Task 10 (`autoflushHook`/`cfgAutoflush`) |
| §6.1 | HKD ↔ plain record: `type User = UserT Identity` | Task 4 (fixture) |
| §6.2 | Generics derives table metadata, codec, Entity, column labels | Tasks 5, 6, 7 |
| §9 | All four open questions | Resolved table at top |

**Deviations explicitly recorded** (top of plan): eager `add`; no prefix-stripping in column names;
simple read-refreshes-snapshot (no "pending wins"). These are SP1 scope controls, each a noted
follow-up.

**Out of SP1 scope (per design §7/§8), intentionally not covered:** relationships/loading (`Ent`,
selectin/joined) → SP2; migrations → SP3; joins/aggregates + TH front-end → SP4; FK-aware flush
ordering; `save`-cascade/`delete-orphan`; non-Postgres backends; `effectful`/`MonadDb` adapters.
