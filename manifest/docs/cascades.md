---
title: Cascades
nav_order: 6
---

# Cascades

A `User` has many `Post`s. When you delete the user, its posts need an on-delete
policy: delete them too, orphan them, or refuse the delete. Manifest lets you
declare that policy once, on the parent entity, and applies it when the Unit-of-Work
session flushes the parent's `delete`. You do not hand-write the child `DELETE`.

This page covers the three `onDelete` policies, how they are declared in an entity's
`cascadeRules`, and how the session honours them at flush. Everything here is
**built** (Sub-project 2.6). The runnable companion is the
[Cascades tutorial](tutorials/Tutorial/Cascades.lhs), a literate page the suite
compiles and runs against Postgres.

## Concepts

A foreign key in the database can carry an `ON DELETE` action, but relying on it ties
the delete semantics to the physical schema and hides them from the code reading and
writing the data. Manifest applies cascades in the session, at flush, not by the
database. The rule is declared next to the entity it belongs to, works whether or not
the Postgres schema has a matching `ON DELETE` foreign key, and runs through the same
Unit-of-Work path as every other mutation. The policy is part of the entity's
definition.

## The three policies

`onDelete` is one of three policies, the `OnDelete` type:

```haskell
data OnDelete = Cascade | SetNull | Restrict
```

* **`Cascade`**: delete the children too. The parent's `delete` triggers a
  `DELETE FROM child WHERE fk = $parent` at flush.
* **`SetNull`**: keep the children but null their foreign key (the FK column must be
  nullable); the rows survive, parentless. Emits
  `UPDATE child SET fk = NULL WHERE fk = $parent`.
* **`Restrict`**: refuse the delete if any children exist. The check runs before any
  mutation, so a blocked delete aborts the whole flush cleanly, with nothing
  partially applied.

## Declaring rules: `cascadeRules`

A rule names a child entity, the foreign-key label on that child that points back at
this parent, and an `OnDelete` policy. It is built with `cascade` and declared in the
parent `Entity` instance's `cascadeRules`:

```hs
cascade :: (Entity c, KnownSymbol fk)
        => Proxy c -> Proxy fk -> OnDelete -> CascadeRule
```

The `User` fixture used by the test suite declares all three policies at once:

```haskell
instance Entity User where
  -- … tableMeta / rowDecoder / rowEncode / primKey …
  cascadeRules =
    [ cascade (Proxy @Post)    (Proxy @"postAuthor")  Cascade
    , cascade (Proxy @Profile) (Proxy @"profileUser") SetNull
    , cascade (Proxy @Tag)     (Proxy @"tagUser")     Restrict
    ]
```

The first `Proxy` is the child entity type; the second is the child's FK label
(`"postAuthor"`). The label is reduced to the physical column name by the same
`camelCase` to `snake_case` rule the deriver uses (`postAuthor` to `post_author`), so
the cascade SQL agrees with the table metadata. `cascadeRules` defaults to `[]` on
`Entity`, so an entity with no children needs no declaration.

## Honoured at flush: Restrict first, then mutating

When the session flushes a parent `delete`, it runs the parent's `cascadeRules` in
two passes:

1. **All `Restrict` checks first.** Each `Restrict` rule issues a `SELECT` for the
   child rows; if any child exists, the delete is aborted (it throws) before anything
   mutates. Doing all the checks up front means a `Restrict` violation never leaves a
   half-applied cascade behind.
2. **Then the mutating policies.** With the restrict checks passed, `Cascade` rules
   emit their child `DELETE`s and `SetNull` rules emit their child
   `UPDATE … SET fk = NULL`. (`Restrict` is a no-op in this pass; it was already
   handled.)

Because this runs inside the same `withTransaction` flush as the parent delete, the
parent and all its cascaded child writes commit or roll back together.

## Examples

The [Cascades tutorial](tutorials/Tutorial/Cascades.lhs) demonstrates the `Cascade`
policy end to end against Postgres: it `add`s a user and two posts, `delete`s the
user inside a transaction, and asserts that `selectWhere @Post` returns nothing, so
the children cascaded away. `SetNull` and `Restrict` follow the same declaration
shape; only the `OnDelete` constructor changes.

## Status

`onDelete` cascades are **built and tested** (Sub-project 2.6): all three policies
(`Cascade` / `SetNull` / `Restrict`), declared per-parent in `cascadeRules`, honoured
at flush with `Restrict` checks before any mutation.

Some follow-ups are **Planned**, and this page does not show them as working:

* **Multi-level / recursive cascade.** A cascade deletes a parent's direct children;
  it does not yet recurse into the children's own `cascadeRules` (grandchildren).
  Chains beyond one level are a follow-up.
* **Save-cascade and delete-orphan.** Cascading on save (persisting a graph by saving
  the root) and delete-orphan (removing a child detached from its parent collection)
  are not built; cascades apply on delete only.
* **Identity-map pruning of cascaded children.** Children removed by a `Cascade`
  delete are deleted in the database, but the session does not yet evict the
  corresponding rows from the in-memory identity map; don't rely on a cascaded child
  being pruned from the map within the same session.
