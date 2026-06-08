---
title: Entities
nav_order: 3
---

# Entities

An *entity* is a table, expressed as one Haskell record. That single declaration
serves three jobs: the clean runtime value you read and edit, the typed column
references the query layer uses, and — via `deriving Generic` plus an `Entity`
instance — the table metadata, the row codec, and the generic CRUD the session
drives. No Template Haskell, no per-table boilerplate beyond the record and the
instance.

This page covers the shape of that record (Higher-Kinded Data), how `Col` erases
its markers in `Identity` context, what the `Entity` instance derives, and how
keys and `#label` column references work. Every example matches the real
`test/Fixtures.hs` — the same surface the [tutorials](tutorials/index.md) compile
and run as tests.

## Why

A relational row has three faces. At runtime it is a plain value:
`userId :: Int, userName :: Text`. To the schema deriver it is a set of *columns*
with names, SQL types, primary-key and serial flags. To the query layer it is a
namespace of typed column references (`#userName :: Column User Text`). Most ORMs
either duplicate that across three declarations (record + schema DSL + query
helpers) or hide it behind codegen you can't read.

Manifest writes it once. A *higher-kinded* record — parameterized by a functor
`f` — is read in different contexts (`Identity` for the value, `Exposed` for the
metadata), and the field labels double as the column references. One declaration,
three faces, all derived.

## What

### The HKD record

A table is a record parameterized by a functor `f`, with each field wrapped in
`Col f`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

import Data.Functor.Identity (Identity)
import Data.Text (Text)
import GHC.Generics (Generic)
import Manifest

data UserT f = User
  { userId    :: Col f (PrimaryKey (Serial Int))
  , userName  :: Col f Text
  , userEmail :: Col f (Maybe Text)
  } deriving Generic
```

The `T` suffix (`UserT`) is the convention for the higher-kinded constructor; the
data constructor is `User`. The field types carry *markers* — `PrimaryKey`,
`Serial` — that the deriver reads but the runtime value never sees.

### `Col f` and `Identity` erasure

`Col` is a closed type family with two instantiations today:

```hs
type family Col (f :: Type -> Type) (a :: Type) :: Type where
  Col Identity a = Base a       -- the runtime value: markers stripped
  Col Exposed  a = Exposed a    -- the metadata view: markers preserved
```

In `Identity` context, `Col` strips the markers down to the *base* type:
`Col Identity (PrimaryKey (Serial Int))` reduces to `Int`,
`Col Identity (Maybe Text)` to `Maybe Text`. So the clean runtime value is a type
synonym applying `Identity`:

```haskell
-- The clean runtime value: userId :: Int, userName :: Text, userEmail :: Maybe Text
type User = UserT Identity
```

That `User` is an ordinary record. You build it, read its fields, and edit it
with normal record-update syntax — `u { userName = "Bob" }`. The
`PrimaryKey (Serial Int)` marker is invisible here; it exists only so the
metadata deriver (which reads the record as `UserT Exposed`) can see that
`userId` is the primary key and an auto-incrementing serial.

> The query-expression context (`Col` in a third, expression functor) is part of
> the design but tied to Core joins/aggregates, which are **Planned**, not built.
> Today `Col` has exactly the two cases above. The typed column references you use
> in `where_`/`update` come from the field *labels* (`#userName`), described
> below — not from a query-functor instantiation of `Col`.

### The `Entity` instance

`deriving Generic` plus one `Entity` instance is everything the session needs:

```haskell
instance Entity User where
  type PrimKey User = Int
  tableMeta  = genericTableMeta @UserT "users"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = userId
```

`Entity` is the class the Unit-of-Work operates over. Its methods:

| Member | What it is | How it's provided |
|---|---|---|
| `type PrimKey a` | the primary-key column's runtime type | declared (`Int`) |
| `tableMeta` | table name + per-column metadata (name, SQL type, PK/serial flags, nullability) | `genericTableMeta @UserT "users"` — derived from the `Exposed` view; you supply the table name |
| `rowDecoder` | row → value codec | `genericRowDecoder` — derived |
| `rowEncode` | value → one `SqlParam` per column, in column order | `genericRowEncode` — derived |
| `primKey` | the PK selector | the field accessor (`userId`) |
| `cascadeRules` | onDelete policies (optional) | defaults to `[]`; see [Cascades](cascades.md) |

`genericTableMeta` walks the `Generic` rep of `UserT Exposed` and reads each
field's markers: it computes the column name by `camelCase → snake_case`
(`userName → user_name`, no prefix stripping), the SQL type, and the PK/serial
flags. `genericRowDecoder`/`genericRowEncode` derive the row codec the same way.
The session's `get` / `add` / `save` / `delete` are all generic over the `Entity`
class — defining the instance is all it takes to make a record persistable.

The two members you write by hand — `tableMeta`'s table name and `primKey`'s
selector — are the only things Generics can't infer (the table name isn't in the
record, and which field is the PK is, but the selector function isn't reflected as
a value). Everything else is derived.

### Keys

A row's identity is its primary key, wrapped in `Key`:

```hs
newtype Key a = Key { unKey :: PrimKey a }
```

`get` takes a `Key`:

```haskell
mu <- get (Key 42)        -- :: Db (Maybe User)
```

`Key User` wraps an `Int` (because `PrimKey User = Int`). The session's identity
map is keyed by `(type, encoded-PK)`, so identity is *value-based via the primary
key* — exactly right, because the PK **is** the row's identity. See
[Unit of Work](unit-of-work.md) for how that drives change tracking.

### `#label` column references

The field labels double as typed column references via `OverloadedLabels`.
`#userName` elaborates to a `Column User Text` whose column name is computed by
the same `camelCase → snake_case` rule the deriver uses — so labels and metadata
always agree:

```hs
#userName    :: Column User Text       -- column "user_name"
#postAuthor  :: Column Post Int        -- column "post_author"
```

These feed the command path and the condition operators:

```haskell
update (Key 42) [ #userName =. "Bob" ]               -- command-path UPDATE
deleteWhere @Post [ #postAuthor ==. 42 ]             -- bulk DELETE
```

The same `#label` syntax names *relations* (`#posts :: Rel User "posts"`) — see
[Relationships](relationships.md). A `Column`'s phantom is the column's value
type; a `Rel`'s phantom is the relation-name `Symbol`. The label elaborates to
whichever the context expects.

> **Planned:** the design's full query DSL — `select $ from @User & where_ (…)`
> with joins and aggregates — lives in Core Sub-project 4 and is **not built**.
> What works today is single-table reads (`get`, `selectWhere [Cond …]`), the
> command path (`update`, `deleteWhere`), and the condition operators
> (`==.`, `/=.`, `>.`, `<.`). Relationship loading uses a `LEFT JOIN` internally
> (the `joined` strategy), but that is a separate, working path — not the
> general-purpose Core join surface.

## How

The full recipe for adding a table:

1. **Declare the HKD record** `data XT f = X { … :: Col f … } deriving Generic`,
   marking the primary key with `PrimaryKey` (and `Serial` if it auto-increments).
2. **Add the runtime synonym** `type X = XT Identity`.
3. **Write the `Entity` instance** — declare `PrimKey`, point `tableMeta` at
   `genericTableMeta @XT "table_name"`, use `genericRowDecoder` /
   `genericRowEncode`, and set `primKey` to the PK field accessor.
4. **Optionally declare relations** (`HasRelation` instances) and
   **cascade rules** (`cascadeRules`) — see [Relationships](relationships.md) and
   [Cascades](cascades.md).

The column order in `tableMeta` (and therefore in `rowEncode`/`rowDecoder`)
matches the record's field order, so the database column order must match too.
The fixtures' DDL shows the correspondence: `userId/userName/userEmail` ↔
`user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL, user_email TEXT`.

## Examples

The fixtures (`test/Fixtures.hs`) define a small connected schema entirely in this
style — `User`, `Post`, `Profile`, `Tag`, `Employee` (self-referential), and
`Comment`. A second table, `Post`, in full:

```haskell
data PostT f = Post
  { postId     :: Col f (PrimaryKey (Serial Int))
  , postAuthor :: Col f Int
  , postTitle  :: Col f Text
  } deriving Generic

type Post = PostT Identity

instance Entity Post where
  type PrimKey Post = Int
  tableMeta  = genericTableMeta @PostT "posts"
  rowDecoder = genericRowDecoder
  rowEncode  = genericRowEncode
  primKey    = postId
```

A non-serial, nullable column (`Profile`'s `profileUser :: Col f (Maybe Int)`) is
declared exactly the same way — the `Maybe` makes the column nullable, which the
deriver reads off the base type. From here, the worked examples are the
[tutorials](tutorials/index.md): each is a literate Haskell page the suite
compiles and runs against Postgres, so the entities on the page are the entities
that round-trip. Start with [Getting started](getting-started.md) for a first
`add` / `get` / `save`, then [Unit of Work](unit-of-work.md) for how editing a
value becomes a minimal `UPDATE`.
