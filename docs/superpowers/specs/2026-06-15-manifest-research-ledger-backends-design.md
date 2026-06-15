# Postgres Backends for Research + Ledger — Design

**Date:** 2026-06-15
**Status:** Committed spec (extends the Memory slice; design basis:
`2026-06-15-crucible-manifest-memory-slice-design.md`)
**Beads:** crucible-691 (Research), crucible-ezd (Ledger) — follow-ons of crucible-gjm.
**Depends on:** the manifest-core split (rev `62f097c…`, already pinned) and the
shipped Memory backend (the template).

## The problem this solves

Completes the Postgres backend trio so all three persistent effects can run
against the same store. Memory proved the pattern (HKD domain type → generic
`Entity` → store-assigned identity → ephemeral-Postgres tests). Ledger is a clean
repeat of that pattern. Research differs in two ways that shape its design: its
key is a caller-chosen **natural text PK** (the slug), and its `Page meta` is
**polymorphic** — which blocks a fully-generic HKD `Entity` (the generic deriver
needs a static `DbType` per field, but `meta` carries a runtime `JSONCodec`).

## Ledger backend (crucible-ezd) — full HKD, like Memory

### Core change (crucible-core)
HKD-migrate `WorkItem` (non-breaking; `Identity` field types unchanged):
```haskell
import Manifest.Core.Table (Field, Pk)
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
At `Identity`: `wid :: WorkId`, `payload :: Text`, `state :: WorkState`,
`claimant :: Maybe Text` — identical to today, so `foldItems`, `workItemCodec`,
record-dot, and callers compile unchanged. Export change: `WorkItem (..)` →
`WorkItemT (..), WorkItem`. Add `Ord` to `WorkId`'s deriving if the manifest PK
codec needs it (Memory needed it for `MemoryId`). Fix the one consumer importing
`WorkItem (..)` (`test/Spec.hs`).

### Backend (crucible-manifest)
- `deriving via (Table "work_items" WorkItemT) instance Entity WorkItem`.
- `DbType` orphans (-Wno-orphans): `WorkId` (BIGINT via `dimap` over Int),
  `WorkState` (Text enum "ready"/"claimed"/"done" via `refine`/`lmap`, structured
  `DecodeError` on unknown — same pattern as the Memory `MemoryKind` decoder).
  `Maybe Text` is built-in nullable.
- `ledgerStoreManifest :: Pool -> LedgerStore` (rows, not events — a faithful
  relational model of the same observable semantics):
  - `doRecord p` = `add (WorkItem (WorkId 0) p Ready Nothing)`; return the
    assigned `.wid` (serial).
  - `doClaim w who` = **atomic CAS** via raw SQL (the genuine win over the
    file/pure read-then-append): `execDb "UPDATE work_items SET state=$1,
    claimant=$2 WHERE wid=$3 AND state=$4 RETURNING wid" [enc Claimed, enc who,
    enc w, enc Ready]`; return `not (null rows)`. (Use the real column names from
    `camelToSnake` of the field names — `wid`/`state`/`claimant`; verify.)
  - `doComplete w` = `update (Key w) [#state =. Done]` (or `execDb` UPDATE).
  - `doListReady` = `selectWhere [#state ==. Ready]`.
- Migration: `migrateUp [managed (Proxy @WorkItem)]` (mirror the Memory backend's
  `migrateMemory`).

## Research backend (crucible-691) — concrete row + JSONCodec

### Core change (crucible-core)
**None to `Page`** (it stays a flat record). Only widen exports: add
`matchesQuery` and `unSlug` to `Crucible.Research`'s export list (the backend
reuses them for search parity and slug↔text).

### Backend (crucible-manifest)
A concrete (non-polymorphic) row entity; the polymorphic `meta` and the structured
`links` are stored as JSON via the existing codecs:
```haskell
data PageRowT f = PageRow
  { slug  :: Field f (PrimaryKey Text)   -- natural text PK (the slug's text)
  , title :: Field f Text
  , body  :: Field f Text
  , links :: Field f Text                -- JSON: encodeText (list' linkCodec)
  , meta  :: Field f Text                -- JSON: encodeText (the caller's codec)
  } deriving Generic
type PageRow = PageRowT Identity
deriving via (Table "pages" PageRowT) instance Entity PageRow
```
`slug`/`title`/`body` are real typed columns (queryable; future search pushdown);
`links`/`meta` are Text columns holding JSON (jsonb-column upgrade deferred — Text
round-trips identically). No custom `DbType` needed (all fields are `Text`).

A second tiny entity for the activity log:
```haskell
data ActivityRowT f = ActivityRow { actId :: Field f (Pk Int), line :: Field f Text } deriving Generic
deriving via (Table "research_activity" ActivityRowT) instance Entity ActivityRow
```

`researchStoreManifest :: JSONCodec meta -> Pool -> ResearchStore meta`:
- `doRead s` = `get (Key (unSlug s)) :: Db (Maybe PageRow)` → on hit, decode to
  `Page meta` (links via `decodeLLM (list' linkCodec)`, meta via `decodeLLM mc`;
  a decode failure reads as absent, matching `runResearchDir`'s tolerance).
- `doWrite p` = upsert by slug: `get (Key (unSlug p.slug))` then `save`/`add` the
  `PageRow` built from `p` (title, body, encoded links, encoded meta). (Overwrite
  semantics match `writePage`.)
- `doIndex` = `selectWhere [] :: Db [PageRow]` → `sort (map (Slug . (.slug)) rows)`.
- `doSearch q` = fetch all rows → decode to `Page meta` → keep those satisfying
  `matchesQuery q` → `sort` their slugs. Reuses crucible's `matchesQuery` so
  search semantics match the other interpreters.
- `doLog ln` = `add (ActivityRow 0 ln)`.
- Migration: `migrateUp [managed (Proxy @PageRow), managed (Proxy @ActivityRow)]`.

(No `safeSlug` refusal — there is no filesystem to escape; the slug is just a key,
as in the pure `runResearchState`.)

## Testing (crucible-manifest/test, ephemeral Postgres)

Extend the existing `crucible-manifest/test/Spec.hs` (it already runs
`withEphemeralDb` for Memory). Add:

- **Ledger:** migrate; `doRecord` three → assert distinct increasing ids;
  `doListReady` → all three Ready; `doClaim` one (assert True) then claim the SAME
  again (assert **False** — CAS works); claimed item drops from `doListReady`;
  `doComplete` one → drops from `doListReady`.
- **Research:** migrate; `doWrite` two pages (one linking the other) → `doRead`
  round-trips title/links/body/meta; overwrite a slug via `doWrite` → `doRead`
  shows the new body; `doIndex` lists both slugs sorted; `doSearch` greps body.

Assert on observable content/flags, not raw ids. crucible's hermetic `zinc test`
must still pass (proves the Ledger HKD migration is non-breaking).

## Out of scope
- Cross-backend conformance suite (crucible-m0b) — compares file/pure/manifest.
- jsonb-column upgrade + SQL-side search pushdown for Research.
- `withRecursive` graph combinator (shaping Part 2).

## Risks / notes
- **Raw column names in the CAS SQL** — derive from `camelToSnake` of field names
  (`wid`/`state`/`claimant`); verify against `genericTableMeta` output. A wrong
  column name fails loudly at test time.
- **Ledger rows vs events** — the manifest backend is row-based (mutating state),
  the file/pure handles are event-sourced. Observable semantics match; m0b will
  confirm. History-of-claims audit (which the event log gives) is not preserved by
  the row backend — acceptable and noted.
- **save vs add on upsert** — if manifest's `save` (snapshot-diff update) needs a
  baseline from a prior `get` in the same session, the get-then-save path provides
  it; otherwise fall back to raw `INSERT … ON CONFLICT DO UPDATE` via `execDb`.
