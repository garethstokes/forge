# forge-2am — Per-field read/write policy → distinct Read/Create/Update projections

**Status:** Approved design (brainstorm complete) · **Date:** 2026-06-19
**Bead:** forge-2am · **Depends on:** forge-i14 (barbies → keep hand-rolled)
**Follow-up:** relationships-as-markers (`References`/FK) — separate bead

---

## 0. Thesis

One record declaration projects into the shapes each direction actually needs:
a **Read** value carries every column; a **Create** value omits DB-owned columns;
an **Update** value is a partial patch. The projection is computed by the existing
`Field` type family — no new dependency, no Template Haskell.

## 1. Two axes: direction + markers

**Direction** (default = readwrite):
- **readwrite** — app reads and writes (the default; no annotation).
- **read** — app reads, never writes; the DB owns it. Usually *implied* by a
  marker (`Pk`/`Serial`/`Generated`); explicit `Read` is the escape hatch for a
  plain column the app does not write.

**Markers** (compose on the payload, orthogonal to direction, stripped by
`Base`/reflected by `FieldMeta` — same grammar as today's `Pk`/`Serial`/`Nullable`):

| Marker | Meaning |
|---|---|
| `PrimaryKey a` | identity, NOT NULL (exists). Composes with `Serial`/`Generated` for the key's fill |
| `Serial a` | DB auto-increment ⇒ generated-on-insert (exists) |
| `Generated a` | DB-filled (serial / DEFAULT / flush-stamp); read-only; value back via RETURNING |
| `Default a` | DB default but app *may* supply ⇒ **optional** on Create |
| `Nullable a` = `Maybe a` | nullable (exists) |
| `Secret a` | **serialization-only**: masked in JSON/`Show`/logs. NOT a DB-presence policy |
| `References T` | FK relationship — **parked to a follow-up bead**, listed for completeness |

**No `Pk` abbreviation** (the `Pk a = PrimaryKey (Serial a)` alias is dropped).
`PrimaryKey` and `Serial` stay orthogonal composable markers; the everyday serial
PK is spelled in full as `PrimaryKey (Serial Int)`. A PK's presence in the Create
projection follows its *fill*, not its PK-ness: `PrimaryKey (Serial Int)` and
`PrimaryKey (Generated UUID)` are DB-assigned ⇒ omitted from Create, whereas an
app-supplied `PrimaryKey UUID` is required on Create. (The old `Pk` alias
hard-wired serial and could not express an app-supplied PK; orthogonality fixes
that for free.) This is the smallest change to the existing `Table.hs` — both
markers and the `Base` family already handle the composition.

`Secret` replaces the rejected `WriteOnly`: a password hash is a normal readwrite
field (you `SELECT` it to verify on login); secrecy is an *exposure* concern at the
serialization layer, not a DB-projection concern. Consequence accepted: the hash
lives in the in-memory Read value; it is kept out of JSON/`Show`/logs by `Secret`.

### Example
```haskell
data UserT f = User
  { userId       :: Field f (PrimaryKey (Serial Int)) -- read-only + serial
  , userName     :: Field f Text                -- readwrite (default)
  , userEmail    :: Field f (Nullable Text)     -- readwrite, nullable
  , userPassword :: Field f (Secret Text)       -- readwrite; masked at encode
  , userStatus   :: Field f (Default Text)      -- readwrite, optional-on-create
  , userCreated  :: Field f (Generated UTCTime) -- read-only, DB fills
  , userUpdated  :: Field f (Generated UTCTime) -- read-only, flush-stamped
  }
```
Every field is `Field f X` — one field-former (**scheme M**).

## 2. Projection — fork (a), uniform shape with `Omitted` fillers

Chosen over fork (b) (genuinely distinct types): fork (b) needs codegen (a `Field`
*type family* cannot add/remove record fields), and avoiding Template Haskell is
worth the `Omitted` fillers — which, with generic neutral-skeleton constructors
(§4), barely surface.

```haskell
data Omitted = Omitted   -- "this field doesn't apply in this context"

type family Field (f :: Type -> Type) (a :: Type) :: Type where
  -- Read: full row, nothing pruned (no field is write-only anymore)
  Field Read   a             = ReadVal a
  -- Create: DB-assigned keys/cols absent; Default optional; app-supplied present
  Field Create (PrimaryKey (Serial a))    = Omitted   -- serial PK: DB assigns
  Field Create (PrimaryKey (Generated a)) = Omitted   -- DB-generated PK
  Field Create (Generated a)              = Omitted
  Field Create (Read a)                   = Omitted
  Field Create (Default a)                = Maybe (Base a)
  Field Create (PrimaryKey a)             = Base a     -- app-supplied PK: required
  Field Create a                          = Base a
  -- Update: PK is the key (WHERE, never SET); DB-owned absent; rest → Patch
  Field Update (PrimaryKey a) = Omitted
  Field Update (Generated a)  = Omitted
  Field Update (Read a)       = Omitted
  Field Update a              = Patch (Base a)
  -- existing contexts
  Field Exposed  a = Exposed a     -- metadata: sees ALL columns (incl. Secret)
  Field Identity a = Base a

type User       = UserT Read       -- all columns present
type UserCreate = UserT Create
type UserUpdate = UserT Update
```

`Omitted` appears **only** in Create/Update, never Read. `Read ≈ Identity` (the
current full-row decode fold barely changes). Metadata stays on `Exposed`, which
sees every column including `Secret` ones (the password column is real in the
schema).

## 3. Patch + the two update paths converge on one executor

```haskell
data Patch a = Keep | Set a          -- Set Nothing :: Patch (Maybe a) ⇒ SET NULL
type Assignment = (ByteString, SqlParam)

-- The whole update mechanism. Both front-ends produce [Assignment] and call this.
runUpdate :: forall a. Entity a => SqlParam -> [Assignment] -> Db ()
runUpdate _   []   = pure ()                         -- nothing to set → no statement
runUpdate key cols = do
  let tm    = tableMeta @a
      cols' = cols ++ touchGenerated tm              -- flush-stamp updated_at
  _ <- execDb (renderUpdate tm (map fst cols') (cmName (pkColumn tm)))
              (map snd cols' ++ [key])
  emitChange @a key
  -- refinement: ... RETURNING <generated> so callers can refresh updated_at
```

**Path A — API endpoints — explicit Patch, stateless (no load, no baseline).**
A new generic fold emits `Set` fields only; `Omitted`/`Keep` contribute nothing.
```haskell
class GPatchEncode rep where gPatchEncode :: rep p -> [Assignment]
instance (Selector m, DbType t) => GPatchEncode (S1 m (Rec0 (Patch t))) where
  gPatchEncode s@(M1 (K1 p)) = case p of
    Keep  -> []
    Set x -> [(camelToSnake (selName s), encode x)]
instance GPatchEncode (S1 m (Rec0 Omitted)) where gPatchEncode _ = []
-- D1/C1/(:*:) thread/concatenate as usual

update :: forall a u. (Entity a, DbType (PrimKey a), Generic u, GPatchEncode (Rep u))
       => Key a -> u -> Db ()
update (Key k) patch = runUpdate @a (encode k) (gPatchEncode (from patch))
```

**Path B — data pipelines — mutate-and-flush, the existing diff, refined.**
Route through `runUpdate`; skip `Generated` columns (flush-stamped, not diffed).
Operates on the Read projection.
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
        , not (cmIsPK c)             -- PK is the key, never SET
        , not (cmIsGenerated c)      -- generated cols flush-stamped, not diffed
        , v /= b ]
      setBaseline a                  -- refresh baseline for repeated flushes
```

Convergence properties:
- **One executor, two adapters.** `gPatchEncode` (Path A) and the `zip3` diff
  (Path B) both yield `[Assignment]`; rendering, `updated_at` stamping, and
  `emitChange` live in `runUpdate` only.
- **`Set Nothing` / mutate-to-`Nothing`** both express SET NULL; the double-`Maybe`
  ambiguity exists only in Path A and is dissolved by `Patch (Maybe a)`.
- **Identity-map is pipeline-only.** Path A is stateless (no baseline).
- **`Secret` is symmetric.** Password is readwrite, so both paths can update it; the
  `WriteOnly`-era "API-only" asymmetry is gone.

## 4. Ergonomics — generic neutral skeletons

Avoids hand-writing `Omitted`/`Keep` at construction sites; derivable, no per-entity
boilerplate (every projection shares one Generic shape).
```haskell
blankCreate :: UserCreate   -- Omitted / Nothing prefilled
noChange    :: UserUpdate   -- all-Keep prefilled (= "change nothing")

ada  = blankCreate { userName = "Ada", userEmail = Just "ada@x.io", userPassword = "…" }
bump = noChange    { userEmail = Set (Just "new@x.io"), userPassword = Set "…" }
```
The all-`Keep` skeleton is the natural partial-patch starting point.

## 5. Profunctors

- **Leaf `Codec a b` (per-column / `DbType`): unchanged.** `dimap`/`lmap`/`rmap`
  still earn their keep for newtype reuse. `profunctors` stays.
- **No `product-profunctors`.** A profunctor has two type params (encode/decode);
  there are **three** projected shapes (Create encode, Read decode, Update/Patch
  encode). Three shapes can't fit a 2-param straddling codec, so the record level
  keeps the existing split: covariant `RowDecoder` fold + contravariant encode fold.
- **Encode fold generalizes** from positional `[SqlParam]` to named/partial
  `[(ColumnName, SqlParam)]` (Create omits DB-owned cols; Patch omits `Keep`),
  unified by the `Omitted`/`Keep` leaves above.

## 6. Required machinery changes
- `Manifest.Core.Table`: add `Read`/`Create`/`Update` contexts to `Field`; add
  `Generated`/`Default`/`Secret`/`Read` markers; extend `Base`/`FieldMeta`.
- `Manifest.Core.Meta`: add `cmIsGenerated :: Bool` to `ColumnMeta` (and surface
  `Secret`/`Default` flags as needed); `FieldMeta` reflects the new markers.
- `Manifest.Entity`: `Omitted` leaf instances for `GRowEncode`/`GRowDecode`;
  new `GPatchEncode` fold; generic neutral-skeleton class.
- `Manifest.Session`: `runUpdate`; refine `flushSave`; `touchGenerated`; `update`.
- Serialization layer: `Secret` masking in JSON/`Show`/logs.

## 7. Open / deferred
- `Generated` insert-vs-update nuance (`created_at` once vs `updated_at` every
  write) — likely a touch-on-update flag, not a new marker.
- `References`/FK relationship markers — **separate follow-up bead** (ties to the
  existing `Manifest.Core.Cascade`).
- `RETURNING`-driven refresh of `Generated` values into the in-memory entity after
  `runUpdate` (noted as a refinement in §3).

## Acceptance criteria — settled
- **Modifier set:** direction (readwrite/read) + markers `Generated`/`Default`/
  `Secret` (+ existing `PrimaryKey`/`Serial`/`Nullable`); `WriteOnly` dropped;
  `Pk` abbreviation dropped — `PrimaryKey`/`Serial` stay orthogonal, spelled in full.
- **Context model:** Read / Create / Update.
- **Absent representation:** fork (a), uniform shape + `Omitted` (Create/Update only).
- **Read/Write types + codecs:** `Field`-family projections; folds unified over
  `Omitted`; new `GPatchEncode`.
- **Unit-of-Work:** Patch (API) + diff (pipeline) converge on `runUpdate`;
  `updated_at` flush-stamped; `Generated` excluded from the diff.
