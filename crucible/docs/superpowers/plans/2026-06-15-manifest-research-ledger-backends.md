# Postgres Backends for Research + Ledger — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** `ledgerStoreManifest` and `researchStoreManifest` in `crucible-manifest`, proven against ephemeral Postgres, following the shipped Memory backend template.

**Architecture:** Ledger = full HKD `WorkItemT` in core + generic `Entity` + atomic `execDb` CAS claim. Research = concrete `PageRow` entity in crucible-manifest (slug text PK, title/body columns, links/meta as JSON text) + JSONCodec mapping (Page stays flat in core). Both reuse crucible kernels (`matchesQuery`) and the Memory backend's `DbType`/migration/test patterns.

**Tech Stack:** GHC 9.12.2, zinc workspace, manifest rev `62f097c…`, ephemeral Postgres.
**Build/test:** `nix develop . --command timeout -s KILL 300 zinc build` / `... -s KILL 600 zinc test` (137 → retry once).

**Reference template (READ before coding):** `crucible-manifest/src/Crucible/Manifest/Memory.hs` (Entity via Table, DbType via `refine`/`lmap`, `memoryStoreManifest`, `migrateMemory`) and `crucible-manifest/test/Spec.hs` (withEphemeralDb harness). Manifest API confirmed: CAS via `execDb "... RETURNING ..."` (non-empty = matched); `selectWhere [#col ==. v]`; `get (Key k)`; `add`; `save`; `update (Key k) [#col =. v]`; natural PK via `Field f (PrimaryKey Text)`; `Maybe` nullable built-in.

---

### Task 1: Ledger backend (full HKD, like Memory)

**Files:** `src/Crucible/Ledger.hs`, `crucible-manifest/src/Crucible/Manifest/Ledger.hs` (new), `crucible-manifest/test/Spec.hs`, `crucible-manifest/zinc.toml`, `test/Spec.hs` (import fix).

- [ ] **Step 1: HKD-migrate `src/Crucible/Ledger.hs`.** Add pragmas `StandaloneDeriving`, `DeriveGeneric`; imports `GHC.Generics (Generic)`, `Data.Functor.Identity (Identity)`, `Manifest.Core.Table (Field, Pk)`. Replace:
```haskell
data WorkItem = WorkItem { wid :: WorkId, payload :: Text, state :: WorkState, claimant :: Maybe Text }
  deriving (Eq, Show)
```
with:
```haskell
data WorkItemT f = WorkItem
  { wid      :: Field f (Pk WorkId)
  , payload  :: Field f Text
  , state    :: Field f WorkState
  , claimant :: Field f (Maybe Text)
  } deriving Generic
type WorkItem = WorkItemT Identity
deriving instance Eq   WorkItem
deriving instance Show WorkItem
```
(If `deriving instance Eq WorkItem` fails, use `Eq (WorkItemT Identity)`.) Add `Ord` to `WorkId`'s deriving (`newtype WorkId = WorkId Int deriving (Eq, Show, Ord)`). Export list: change `WorkItem (..)` → `WorkItemT (..)` and `, WorkItem`.

- [ ] **Step 2: fix the one consumer** — `test/Spec.hs:84` `WorkItem (..)` → `WorkItemT (..), WorkItem`.

- [ ] **Step 3: build crucible-core + hermetic test.** `zinc build` then `zinc test` — existing Ledger tests must pass unchanged (non-breaking gate). Fix any `(.field)` annotation minimally.

- [ ] **Step 4: `crucible-manifest/src/Crucible/Manifest/Ledger.hs`.** Mirror `Memory.hs`:
  - `deriving via (Table "work_items" WorkItemT) instance Entity WorkItem`.
  - `DbType WorkId` (dimap over Int — `dimap (\(WorkId i) -> i) WorkId (dbType @Int)`).
  - `DbType WorkState` via `refine dec (lmap enc (dbType @Text))`: enc Ready="ready"/Claimed="claimed"/Done="done"; dec the three, else `Left (DecodeError ...)`. (`WorkState`'s constructors `Ready/Claimed/Done` are exported via `WorkState (..)` — confirm; import what's needed.)
  - `migrateLedger :: Pool -> IO ()` = `withSession pool (migrateUp [managed (Proxy @WorkItem)])`.
  - `ledgerStoreManifest :: Pool -> LedgerStore`:
    - `doRecord p` = `withSession pool $ do { it <- add (WorkItem (WorkId 0) p Ready Nothing); pure it.wid }`.
    - `doClaim w who` = `withSession pool $ do { rows <- execDb "UPDATE work_items SET state=$1, claimant=$2 WHERE wid=$3 AND state=$4 RETURNING wid" [enc Claimed, enc who, enc w, enc Ready]; pure (not (null rows)) }` — use the manifest `encode`/`enc` that produces `SqlParam` for each (encode WorkState, Text, WorkId). VERIFY the column names by checking `genericTableMeta`/camelToSnake (expected `wid`,`state`,`claimant`). `Just who` for the nullable claimant param (encode `Just who :: Maybe Text`).
    - `doComplete w` = `withSession pool (update (Key w) [#state =. Done])` (or an `execDb` UPDATE if the Assign API is fiddly).
    - `doListReady` = `withSession pool (selectWhere [#state ==. Ready])`.
  - Export `ledgerStoreManifest`, `migrateLedger`.
  Read manifest's `Session.Command` (`update`/`=.`), `Session.execDb`, and `Core.Codec.encode` for exact signatures before writing.

- [ ] **Step 5: zinc.toml dep.** Add `mtl`/nothing new likely; ensure `crucible-manifest`'s lib `depends` already covers what Ledger needs (base/text/crucible/manifest/manifest-core/effectful — same as Memory). No change expected.

- [ ] **Step 6: extend `crucible-manifest/test/Spec.hs`** with Ledger checks (in the same `withEphemeralDb`/harness): migrate; record 3 → distinct increasing ids; listReady → 3 Ready; claim one → True; claim same again → **False**; claimed drops from listReady; complete one → drops from listReady. `exitFailure` on any failed check.

- [ ] **Step 7: build + test.** `zinc build` then `zinc test` (hermetic + ephemeral-pg) all green.

- [ ] **Step 8: commit.**
```bash
git add src/Crucible/Ledger.hs test/Spec.hs crucible-manifest/
git commit -m "feat(crucible-manifest): ledgerStoreManifest — Postgres LedgerStore (HKD WorkItem, atomic CAS)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Research backend (concrete row + JSONCodec)

**Files:** `src/Crucible/Research.hs` (export widening only), `crucible-manifest/src/Crucible/Manifest/Research.hs` (new), `crucible-manifest/test/Spec.hs`.

- [ ] **Step 1: widen `Crucible.Research` exports** — add `matchesQuery` and `unSlug` to the export list. NO other core change to Research (Page stays flat). Build to confirm.

- [ ] **Step 2: `crucible-manifest/src/Crucible/Manifest/Research.hs`.**
  - Entities (concrete, all-Text fields → no custom DbType needed):
    ```haskell
    data PageRowT f = PageRow
      { slug :: Field f (PrimaryKey Text), title :: Field f Text, body :: Field f Text
      , links :: Field f Text, meta :: Field f Text } deriving Generic
    type PageRow = PageRowT Identity
    deriving via (Table "pages" PageRowT) instance Entity PageRow
    data ActivityRowT f = ActivityRow { actId :: Field f (Pk Int), line :: Field f Text } deriving Generic
    type ActivityRow = ActivityRowT Identity
    deriving via (Table "research_activity" ActivityRowT) instance Entity ActivityRow
    ```
  - `migrateResearch :: Pool -> IO ()` = `withSession pool (migrateUp [managed (Proxy @PageRow), managed (Proxy @ActivityRow)])`.
  - `researchStoreManifest :: forall meta. JSONCodec meta -> Pool -> ResearchStore meta` (needs `ScopedTypeVariables`, maybe `AllowAmbiguousTypes`):
    - encode helpers: `encLinks = encodeText (list' linkCodec)`, `encMeta = encodeText mc`; decode: `decodeLLM (list' linkCodec)`, `decodeLLM mc` (from `Crucible.Codec`/`Crucible.Decode`; `list'`, `encodeText` are in `Crucible.Codec`).
    - `toRow :: Page meta -> PageRow` = `PageRow (unSlug p.slug) p.title p.body (encLinks p.links) (encMeta p.meta)`.
    - `fromRow :: PageRow -> Maybe (Page meta)` = decode links + meta; on either `Left`, `Nothing` (tolerant); else `Just (Page (Slug r.slug) r.title <links> r.body <meta>)`.
    - `doRead s` = `withSession pool (get (Key (unSlug s)))` → `>>= maybe (pure Nothing) (pure . fromRow)` (note: `fromRow` is pure; wrap accordingly).
    - `doWrite p` = `withSession pool $ do { let row = toRow p; m <- get (Key (unSlug p.slug)); maybe (add row >> pure ()) (\_ -> save row) m }`.
    - `doIndex` = `withSession pool (selectWhere [])` → `pure . sort . map (Slug . (.slug))` (the `[PageRow]` all-rows form).
    - `doSearch q` = `withSession pool (selectWhere [])` → in Haskell: `sort [ Slug r.slug | r <- rows, Just pg <- [fromRow r], matchesQuery q pg ]`.
    - `doLog ln` = `withSession pool (add (ActivityRow 0 ln) >> pure ())`.
  - Export `researchStoreManifest`, `migrateResearch`.
  Add module pragmas as needed (DataKinds, DerivingVia, OverloadedRecordDot, ScopedTypeVariables, TypeApplications, etc. — mirror Memory.hs); `-Wno-orphans` already set in zinc.toml.

- [ ] **Step 3: extend `crucible-manifest/test/Spec.hs`** with Research checks: migrate; write page "a" (title/body/link to "b", meta) and "b"; `doRead (Slug "a")` round-trips title/links/body/meta; overwrite "a" with new body → `doRead` shows new body; `doIndex` == sorted [Slug "a", Slug "b"]; `doSearch` greps body. Use a concrete `meta` (e.g. `Text` with `C.str`, or `()` if `C` has a unit codec — prefer `Text`/`C.str` like the existing Research tests). `exitFailure` on failure.

- [ ] **Step 4: build + test.** `zinc build` then `zinc test` — all green (hermetic + ephemeral-pg Memory/Ledger/Research).

- [ ] **Step 5: commit.**
```bash
git add src/Crucible/Research.hs crucible-manifest/
git commit -m "feat(crucible-manifest): researchStoreManifest — Postgres ResearchStore (concrete PageRow)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review
- **Spec coverage:** Task 1 = Ledger (HKD + Entity + CAS + tests); Task 2 = Research (export widen + concrete PageRow + mapping + tests). Both reuse the Memory template + crucible kernels (`matchesQuery`).
- **Type consistency:** `WorkItemT`/`WorkItem`, `ledgerStoreManifest`/`migrateLedger`; `PageRowT`/`ActivityRowT`, `researchStoreManifest`/`migrateResearch`. Exports widened: Ledger `WorkItemT (..),WorkItem`; Research `matchesQuery,unSlug`.
- **Placeholder scan:** none.
- **Risk:** CAS column names (verify camelToSnake); `save` baseline (get-then-save provides it; fallback raw ON CONFLICT). Both fail loudly at test time.
