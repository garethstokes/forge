---
title: Entities
nav_order: 3
---

# Entities

An entity is a table, expressed as one Haskell record. That declaration serves
three roles: the runtime value you read and edit, the typed column references the
query layer uses, and (via `deriving Generic` plus an `Entity` instance) the table
metadata, the row codec, and the generic CRUD the session drives. For a plain
entity the `Entity` instance is one `deriving via` line (see
[Deriving the Entity instance](#deriving-the-entity-instance) below); entities with
cascade rules or row-level-security policies write a short explicit instance.

This page covers the shape of that record (Higher-Kinded Data), how `Col` erases
its markers in `Identity` context, what the `Entity` instance derives, and how
keys and `#label` column references work. Every example matches the real
`test/Fixtures.hs`, the same surface the [tutorials](tutorials/index.md) compile
and run as tests.

## Concepts

A relational row has three representations. At runtime it is a plain value:
`userId :: Int, userName :: Text`. To the schema deriver it is a set of columns
with names, SQL types, and primary-key and serial flags. To the query layer it is
a namespace of typed column references (`#userName :: Column User Text`).

Manifest derives all three from one declaration. A higher-kinded record,
parameterized by a functor `f`, is read in different contexts (`Identity` for the
value, `Exposed` for the metadata), and the field labels double as the column
references.

## The record

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
data constructor is `User`. The field types carry markers (`PrimaryKey`, `Serial`)
that the deriver reads but the runtime value never sees.

### `Col f` and `Identity` erasure

`Col` is a closed type family with two instantiations today:

```hs
type family Col (f :: Type -> Type) (a :: Type) :: Type where
  Col Identity a = Base a       -- the runtime value: markers stripped
  Col Exposed  a = Exposed a    -- the metadata view: markers preserved
```

In `Identity` context, `Col` strips the markers down to the base type:
`Col Identity (PrimaryKey (Serial Int))` reduces to `Int`,
`Col Identity (Maybe Text)` to `Maybe Text`. So the runtime value is a type synonym
applying `Identity`:

```haskell
-- The clean runtime value: userId :: Int, userName :: Text, userEmail :: Maybe Text
type User = UserT Identity
```

That `User` is an ordinary record. You build it, read its fields, and edit it with
normal record-update syntax, `u { userName = "Bob" }`. The
`PrimaryKey (Serial Int)` marker is invisible here; it exists only so the metadata
deriver (which reads the record as `UserT Exposed`) can see that `userId` is the
primary key and an auto-incrementing serial.

> The query-expression context (`Col` in a third, expression functor) is part of
> the design but tied to Core joins/aggregates, which are **Planned**, not built.
> Today `Col` has exactly the two cases above. The typed column references you use
> in `where_`/`update` come from the field labels (`#userName`), described below,
> not from a query-functor instantiation of `Col`.

### The `Entity` instance

`deriving Generic` plus one `Entity` instance is everything the session needs. For
a plain entity that instance is a single `deriving via` line (see
[Deriving the Entity instance](#deriving-the-entity-instance)):

```haskell
deriving via (Table "users" UserT) instance Entity User
```

`Entity` is the class the Unit-of-Work operates over. Its members:

| Member | What it is | How it's provided |
|---|---|---|
| `tableMeta` | table name plus per-column metadata (name, SQL type, PK/serial flags, nullability) | derived from the `Exposed` view; the `"users"` in `Table "users" UserT` supplies the table name |
| `rowDecoder` | row to value codec | derived |
| `rowEncode` | value to one `SqlParam` per column, in column order | derived |
| `primKey` | the PK value | derived (reads the primary-key column, which is the first field) |
| `cascadeRules` | onDelete policies (optional) | defaults to `[]`; see [Cascades](cascades.md) |
| `rlsPolicies` | row-level-security policies (optional) | defaults to `[]`; see [Row-level security](rls.md) |

The deriver walks the `Generic` rep of `UserT Exposed` and reads each field's
markers: it computes the column name by `camelCase` to `snake_case` (`userName` to
`user_name`, no prefix stripping), the SQL type, and the PK/serial flags, and it
derives the row codec the same way. The primary-key value comes from the first
field, which is the primary key by convention. The session's `get` / `add` /
`save` / `delete` are all generic over the `Entity` class, so defining the instance
is all it takes to make a record persistable.

The only thing Generics cannot infer is the table name (it is not in the record).
The `deriving via` carrier supplies it as the `"users"` type-level string, so a
plain entity needs no hand-written members at all. There is no `type PrimKey` line
to write: the primary-key type is computed from the first field's marker.

### Keys

A row's identity is its primary key, wrapped in `Key`:

```hs
newtype Key a = Key { unKey :: PrimKey a }
```

`get` takes a `Key`:

```haskell
mu <- get (Key 42)        -- :: Db (Maybe User)
```

`Key User` wraps an `Int` (because the primary key, `userId`, is an `Int`). The session's identity
map is keyed by `(type, encoded-PK)`, so identity is value-based via the primary
key, which is the row's identity. See [Unit of Work](unit-of-work.md) for how that
drives change tracking.

### `#label` column references

The field labels double as typed column references via `OverloadedLabels`.
`#userName` elaborates to a `Column User Text` whose column name is computed by the
same `camelCase` to `snake_case` rule the deriver uses, so labels and metadata
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

The same `#label` syntax names relations (`#posts :: Rel User "posts"`); see
[Relationships](relationships.md). A `Column`'s phantom is the column's value type;
a `Rel`'s phantom is the relation-name `Symbol`. The label elaborates to whichever
the context expects.

> The query builder (joins, ordering, pagination, aggregates) is built; see
> [Queries](queries.md). It binds columns to a table through handles
> (`u ^. #userName`). Still Planned: outer joins, `HAVING`, subqueries, and CTEs.
> Relationship loading uses a `LEFT JOIN` internally (the `joined` strategy); that is
> a separate path.

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

deriving via (Table "users" UserT) instance Entity User
```

The primary-key type is read from the first field's marker, so `PrimaryKey (Serial
UserId)` makes the key a `UserId` with no extra declaration. Now `userId ::
UserId`, `Key User` wraps a `UserId`, and `postAuthor` is a `UserId`
you cannot fill from a `PostId`. The id flows through `add` (the `RETURNING` serial is
decoded back into `UserId`), `get (Key (UserId 1))`, and the query builder
(`#postAuthor ==. val someUserId`). The column is still `BIGSERIAL`/`BIGINT`, so the
schema and migrations are unchanged.

> The field type is what gives the safety. Manifest does not yet check, at the
> relationship level, that a foreign key points at the right entity's id type (so a
> mis-declared relationship is not rejected), and it does not auto-generate id
> newtypes. Both are planned follow-ups.

## Adding a table

The full recipe for adding a table:

1. **Declare the HKD record** `data XT f = X { … :: Col f … } deriving Generic`,
   marking the primary key with `PrimaryKey` (and `Serial` if it auto-increments).
   The primary key must be the first field.
2. **Add the runtime synonym** `type X = XT Identity`.
3. **Derive the `Entity` instance** with one `deriving via` line,
   `deriving via (Table "table_name" XT) instance Entity X`, which supplies the
   table name and derives everything else. An entity with cascade rules or RLS
   policies writes a short explicit instance instead (see
   [Deriving the Entity instance](#deriving-the-entity-instance)).
4. **Optionally declare relations** (`HasRelation` instances) and **cascade rules**
   (`cascadeRules`); see [Relationships](relationships.md) and
   [Cascades](cascades.md).

The column order in `tableMeta` (and therefore in `rowEncode`/`rowDecoder`) matches
the record's field order, so the database column order must match too. The
fixtures' DDL shows the correspondence: `userId`/`userName`/`userEmail` map to
`user_id BIGSERIAL PRIMARY KEY, user_name TEXT NOT NULL, user_email TEXT`.

## Examples

The fixtures (`test/Fixtures.hs`) define a small connected schema entirely in this
style: `User`, `Post`, `Profile`, `Tag`, `Employee` (self-referential), and
`Comment`. A second table, `Post`, in full:

```haskell
data PostT f = Post
  { postId     :: Col f (PrimaryKey (Serial Int))
  , postAuthor :: Col f Int
  , postTitle  :: Col f Text
  } deriving Generic

type Post = PostT Identity

deriving via (Table "posts" PostT) instance Entity Post
```

A non-serial, nullable column (`Profile`'s `profileUser :: Col f (Maybe Int)`) is
declared the same way; the `Maybe` makes the column nullable, which the deriver
reads off the base type. From here, the worked examples are the
[tutorials](tutorials/index.md): each is a literate Haskell page the suite compiles
and runs against Postgres, so the entities on the page are the entities that
round-trip. Start with [Getting started](getting-started.md) for a first `add` /
`get` / `save`, then [Unit of Work](unit-of-work.md) for how editing a value
becomes a minimal `UPDATE`.

## Deriving the Entity instance

`tableMeta`, the row codec, and `primKey` all follow mechanically from the record,
so the `Entity` instance for a plain entity is a single `deriving via` line. You
write the HKD record (with the primary key as its first field) and derive the
instance through a `Table` carrier that supplies the table name as a type-level
string:

```haskell
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeFamilies #-}

data PostT f = Post
  { postId     :: Col f (PrimaryKey (Serial Int))   -- primary key: the first field
  , postAuthor :: Col f Int
  , postTitle  :: Col f Text
  } deriving Generic
type Post = PostT Identity

deriving via (Table "posts" PostT) instance Entity Post
```

That one line derives `tableMeta` (the table name comes from the `"posts"`
string), the row codec, and `primKey`. There is no `type PrimKey` line to write:
the primary-key type is computed from the record's first field. The form needs the
`DerivingVia` and `StandaloneDeriving` extensions.

The primary key must be the first field of the record. This is a real constraint
of the derivation, not just a convention: the primary-key type and value are read
off the first field, so an entity whose primary key is not first will not compile.

### Cascade rules and row-level security

An entity that needs `onDelete` cascade rules or row-level-security policies writes
a short explicit instance instead of the `deriving via` line, supplying only the
table name and the policy. The row codec and `primKey` still default
generically, so you do not repeat them:

```haskell
instance Entity User where
  tableMeta    = genericTableMeta @UserT "users"
  cascadeRules =
    [ cascade (Proxy @Post)    (Proxy @"postAuthor")  Cascade
    , cascade (Proxy @Profile) (Proxy @"profileUser") SetNull
    , cascade (Proxy @Tag)     (Proxy @"tagUser")     Restrict
    ]
```

`genericTableMeta @UserT "users"` builds `tableMeta` from the `Exposed` view, the
same value the `deriving via` form produces; you supply the table name. The
`cascadeRules` field lists the dependents and their delete behaviour; see
[Cascades](cascades.md). Row-level-security policies go in `rlsPolicies` the same
way; see [Row-level security](rls.md). Everything you do not mention (`rowDecoder`,
`rowEncode`, `primKey`) keeps its generic default.
