---
title: Relationships
nav_order: 5
---

# Relationships

A `User` has many `Post`s; a `Post` belongs to a `User`. Relationships are not
stored columns on the HKD record (they don't live in the table), so Manifest
handles them separately: declared as `HasRelation` instances and loaded explicitly.
There are two ways to load related rows. The A-path (`load`) returns the children
directly. The D-path (`Ent` plus `with` / `rel`) carries a value together with its
loaded relations as one typed bundle, with compile-time guarantees about what is
loaded.

This page covers declaring relations, both load paths, the `selectin` vs `joined`
strategies, one-level nesting, self-referential relations, and how loaded children
integrate with the Unit of Work. The runnable companion is the
[Relationships tutorial](tutorials/Tutorial/Relationships.lhs). Everything described
here is **built** (Sub-project 2 and its follow-ups); the *Status* section at the end
is precise about the two pieces that are deferred.

## Concepts

Field access in Haskell is pure, so `user.posts` cannot run a query the way lazy
loading does in a mutable-object ORM. Loading is explicit. The A-path is the minimal
form: `load #posts user` returns `Db [Post]` with no type-level machinery. The
D-path adds load-tracking: a phantom load-set on a wrapper (`Ent loaded a`) lets the
type system guarantee, at compile time, that you only read a relation you actually
loaded, while the bare value `a` never carries that phantom. You can drop to the
A-path at any point: `load #posts (entVal e)`.

## Declaring a relation

A relation is a `HasRelation` instance naming the target type, the cardinality, and
the foreign-key spec:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

instance HasRelation User "posts" where
  type Target      User "posts" = [Post]
  type Cardinality User "posts" = 'Many
  relSpec = hasMany (Proxy @"postAuthor")    -- FK column on the child
```

The three cardinalities, and the builders that declare them:

| Card | `Target` shape | Builder | Meaning |
|---|---|---|---|
| `'Many` | `[Post]` | `hasMany (Proxy @"postAuthor")` | reverse FK: children whose FK = parent's PK |
| `'Opt` | `Maybe Profile` | `hasOpt (Proxy @"profileUser")` | optional reverse FK (at most one child) |
| `'One` | `User` | `belongsTo (Proxy @"postAuthor")` | forward FK: the target whose PK = self's FK |
| `'Opt` | `Maybe Employee` | `belongsToMaybe (Proxy @"employeeManager")` | nullable forward FK |

The `Target` and `Cardinality` type families drive the result types totally:
`'Many` gives `[Post]`, `'Opt` gives `Maybe Profile`, `'One` gives `User`. The FK
column name is computed from the label by the same `camelCase` to `snake_case` rule
the deriver uses, so it agrees with the table metadata.

## The A-path: `load`

`load` takes a relation reference and a bare value and returns the `Target`,
directly:

```hs
load :: HasRelation a name => Rel a name -> a -> Db (Target a name)
```

```haskell
posts <- load #posts user        -- :: Db [Post]
```

No wrapper, no phantom, no type annotations. The result is an ordinary `[Post]` of
managed values you can edit and `save`. The same call shape covers the other
cardinalities, the result type following `Target`:

```hs
author   <- load #author post     -- :: Db User          (belongs-to, 'One)
mProfile <- load #profile user    -- :: Db (Maybe Profile) (optional, 'Opt)
```

## The D-path: `Ent` / `with` / `rel`

The D-path keeps a value and its loaded relations together in a typed bundle:

```hs
data Ent (loaded :: [Symbol]) a = Ent { entVal :: a, entRels :: RelMap }

manage :: a -> Ent '[] a                                  -- wrap, nothing loaded
getEnt :: (Entity a, DbType (PrimKey a))
       => Key a -> Db (Maybe (Ent '[] a))                 -- load by PK, nothing loaded
with   :: HasRelation a name
       => Strategy name -> Ent l a -> Db (Ent (Insert name l) a)   -- load a relation in
rel    :: (HasRelation a name, Member name loaded a)
       => Rel a name -> Ent loaded a -> Target a name      -- total read-back
```

`manage u` wraps a bare value with an empty load-set; `with (selectin #posts)` loads
the relation and records `"posts"` in the phantom load-set; `rel #posts e` reads it
back. `rel` only type-checks when the relation is in the load-set. The phantom rides
on `Ent loaded a` only, never on the bare `a`, on `Db`, or in queries:

```haskell
e <- with (selectin #posts) (manage user)
let ps = rel #posts e            -- :: [Post]; type-checks because #posts was loaded
```

Reading an unloaded relation is the one user-visible failure, and the message is a
written sentence rather than a type-list dump. The `Member` constraint reduces to an
`Unsatisfiable` message:

> Relation 'posts' is not loaded on this User. Add `with (selectin #posts)`, or call
> `load #posts value` for the bare A-path.

## Strategies: `selectin` vs `joined`

Both `selectin` and `joined` are real and produce the same result via different SQL:

* **`selectin`** (the default): load the parent, then a separate
  `SELECT … WHERE fk = $1` (or `… IN (…)` when batching many parents). Two queries,
  no row multiplication.
* **`joined`**: a single `LEFT JOIN`, decoded NULL-aware (LEFT-JOIN misses, where the
  child PK column is `NULL`, are skipped). Fewer round-trips; multiplies rows for
  collections.

```haskell
e1 <- with (selectin #posts) (manage user)    -- separate SELECT
e2 <- with (joined   #posts) (manage user)     -- internal LEFT JOIN
```

> The `joined` relationship-loading strategy is an internal `LEFT JOIN` and is
> **built**. It is distinct from general-purpose joins in the query Core, which are
> **Planned** (see *Status*). `joined` only ever joins a parent to one declared
> relation's target; it is not a user-facing join DSL.

## One-level nesting

You can load a relation and then a relation on its children, one level deep, with
the path operator `./` and `loadNested`:

```hs
(./)       :: Rel a n1 -> Rel mid n2 -> Path a n1 mid n2
loadNested :: (HasRelation a n1, Target a n1 ~ [mid], …)
           => Path a n1 mid n2 -> a -> Db [(mid, [leaf])]
```

```haskell
postsWithComments <- loadNested (#posts ./ #comments) user
--   :: Db [(Post, [Comment])]
```

`loadNested` loads the mids (`#posts`), then issues a single batched
`… WHERE leafFk IN (…)` query for all their leaves (`#comments`) and groups each
leaf under its parent, so a user's posts and all their comments come back in two
queries, not one per post. In this MVP both levels must be to-many (`'Many`); a
non-`Many` leaf is rejected at runtime.

## Self-referential relations

A table can relate to itself. The `Employee` fixture has a nullable self-FK
`employeeManager :: Field f (Nullable Int)` referencing `employee_id`, giving both a
forward and a reverse relation on the same type:

```haskell
-- forward FK (nullable belongs-to self): the employee's manager, or Nothing at the top
instance HasRelation Employee "manager" where
  type Target      Employee "manager" = Maybe Employee
  type Cardinality Employee "manager" = 'Opt
  relSpec = belongsToMaybe (Proxy @"employeeManager")

-- reverse FK (has-many self): the employees who report to this one
instance HasRelation Employee "reports" where
  type Target      Employee "reports" = [Employee]
  type Cardinality Employee "reports" = 'Many
  relSpec = hasMany (Proxy @"employeeManager")
```

Both load through the ordinary paths (`load #manager e`, `load #reports e`, or their
D-path equivalents) with no special handling at the call site.

## Many-to-many

There is no implicit junction. A many-to-many relationship is modelled as an explicit
join entity: a table whose rows are the pairings, with a foreign key to each side. The
join row is a first-class entity, so it can carry its own data (an enrolment date, a
role) and is loaded and saved like any other.

A student takes many courses and a course has many students, joined by `Enrollment`:

```haskell
data EnrollmentT f = Enrollment
  { enrollmentId      :: Field f (Pk Int)
  , enrollmentStudent :: Field f Int        -- FK -> students.student_id
  , enrollmentCourse  :: Field f Int        -- FK -> courses.course_id
  } deriving Generic
```

Each side `hasMany` the join entity, and the join entity `belongsTo` each side:

```haskell
instance HasRelation Student "enrollments" where
  type Target      Student "enrollments" = [Enrollment]
  type Cardinality Student "enrollments" = 'Many
  relSpec = hasMany (Proxy @"enrollmentStudent")   -- enrolments whose student FK = this student

instance HasRelation Enrollment "course" where
  type Target      Enrollment "course" = Course
  type Cardinality Enrollment "course" = 'One
  relSpec = belongsTo (Proxy @"enrollmentCourse")  -- the course this enrolment points at
```

To read a student's courses, load the enrolments, then the course each belongs to
(`load #enrollments student`, then `load #course` on each). `Course` declares the mirror
side (`hasMany (Proxy @"enrollmentCourse")`) to walk it the other way.

## Unit-of-Work integration

Loaded children are managed. Whether you obtain them via `load`, `with`,
`loadNested`, `selectin`, or `joined`, each loaded row is decoded and registered in
the identity map with its own baseline snapshot, so a fetched `Post` is immediately a
Persistent entity. Edit one and `save` it, and it flows through the same
snapshot-diff path as anything else, emitting a minimal `UPDATE`. See
[Unit of Work](unit-of-work.md). Cascades on delete are declared per-parent and
honoured at flush; see [Cascades](cascades.md).

## Examples

The [Relationships tutorial](tutorials/Tutorial/Relationships.lhs) demonstrates the
A-path (`load #posts`), the D-path (`with (selectin #posts)` then `rel #posts`), and
proves `joined #posts` emits a `LEFT JOIN` by inspecting the statement log, all as
live tests against Postgres. The shapes generalise across the cardinalities and the
self-referential case shown above; the load path is the same, only the result type
changes with `Target`.

## Status

Everything on this page is **built** and tested (Sub-project 2 and its follow-ups
2.5 / 2.6 / 2.7): A-path `load`, the D-path `Ent` / `with` / `rel`, both `selectin`
and `joined` strategies, one-level nesting via `loadNested`, self-referential
relations, and Unit-of-Work integration of loaded children.

Two pieces are **deferred**, and this page does not show them as working:

* **Arbitrary-depth nesting.** `loadNested` does exactly one level
  (`#posts ./ #comments`). Deeper paths are a follow-up.
* **D-path nested `Ent`s.** `with` loads a relation's values into the `Ent`; it does
  not recursively wrap loaded children in their own `Ent`s with their own load-set
  phantoms. Nested relations come back as plain managed values, read via `rel`.

Separately, **general-purpose joins and aggregates in the query Core** are
**Planned**, not built (Core Sub-project 4); the relationship-loading `joined`
strategy above is a distinct, working internal `LEFT JOIN`, not that Core join
surface. See [Entities](entities.md) for the same note on the query DSL.
