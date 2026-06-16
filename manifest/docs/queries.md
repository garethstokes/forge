---
title: Queries
nav_order: 8
---

# Queries

The query builder assembles a typed query in a do-block and runs it with
`runQuery`. `from @User` binds a handle, `u ^. #userName` is a column bound to that
table and its alias, and combinators add conditions, ordering, joins, grouping, and
aggregates. The do-block returns the selection (a handle, an expression, or a tuple),
which determines the result type.

## Single table

```haskell
us <- runQuery $ do
  u <- from @User
  where_ (u ^. #userName .== val "Bob")
  orderBy [asc (u ^. #userName)]
  limit 20
  pure u                       -- :: Db [User]
```

`u ^. #userName` qualifies the column by the handle's alias and binds the label to
`User`, so a column from a table you have not brought into the query is a type
error. Expression comparisons are `.==`, `./=`, `.>`, `.<`, combined with `.&&`;
`val` lifts a literal. `runQuery` results are plain values, not identity-map entries;
use `get` or `selectWhere` for managed rows.

`u ?. #userName` is the typed projection: like `^.`, but it recovers the column's
Haskell type from the entity's record, so the expression's type is known without an
annotation (useful for the JSONB operators) and a misspelled field name is a compile
error. `^.` stays polymorphic in the column type; `?.` pins it.

## Joins

`innerJoin @Post` takes a function from the new handle to the join condition;
handles from earlier in the block are in scope:

```haskell
pairs <- runQuery $ do
  u <- from @User
  p <- innerJoin @Post (\p -> u ^. #userId .== p ^. #postAuthor)
  pure (u, p)                  -- :: Db [(User, Post)]
```

A `leftJoin` keeps rows from the left table even when the right side has no match;
the right side selects as `Maybe`:

```haskell
rows <- runQuery $ do
  u  <- from @User
  mp <- leftJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
  pure (u, mp)                 -- :: Db [(User, Maybe Post)]
```

`rightJoin` keeps all rows of the joined table (the previously-joined tables may be
NULL); `fullJoin` keeps unmatched rows on both sides. Use `opt` to select a table
that a right or full join can leave unmatched, so it decodes as `Maybe`:

```haskell
rows <- runQuery $ do
  u <- from @User
  p <- rightJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
  pure (opt u, p)              -- :: Db [(Maybe User, Post)]
```

## Aggregates and grouping

`countRows`, `sum_`, `avg_`, `min_`, `max_` are expressions you return in the
selection; `groupBy` sets the key:

```haskell
perAuthor <- runQuery $ do
  p <- from @Post
  groupBy (p ^. #postAuthor)
  pure (p ^. #postAuthor, countRows)   -- :: Db [(Int, Int)]

total <- runQuery $ do
  p <- from @Post
  pure (sum_ (p ^. #postAuthor))       -- :: Db [Maybe Int]
```

`having` filters groups (typically on an aggregate); `distinct` makes the query a
`SELECT DISTINCT`:

```haskell
prolific <- runQuery $ do
  p <- from @Post
  groupBy (p ^. #postAuthor)
  having (countRows .> val 1)
  pure (p ^. #postAuthor, countRows)   -- authors with more than one post
```

## Common table expressions

`withCte` registers a subquery (which selects a whole entity) as a `WITH` clause and
returns a reference; `fromCte` reads from it like a table:

```haskell
names <- runQuery $ do
  active <- withCte (do u <- from @User
                        where_ (u ^. #userName .> val "A")
                        pure u)
  h <- fromCte active
  orderBy [asc (h ^. #userName)]
  pure h                       -- :: Db [User]
```

## Status

Built and tested: `from`, `where_`, `orderBy`/`asc`/`desc`, `limit`/`offset`,
`innerJoin`, `leftJoin`, `rightJoin`/`fullJoin`/`opt`, `having`, `distinct`,
`withCte`/`fromCte`, `groupBy`,
`countRows`/`sum_`/`avg_`/`min_`/`max_`, tuple selections,
and `runQuery`. Columns are entity- and alias-bound through handles.

Planned, not built:

* **Recursive CTEs and non-CTE subqueries.** `INNER`/`LEFT`/`RIGHT`/`FULL` joins,
  aggregates, `HAVING`, `DISTINCT`, and non-recursive entity CTEs are built.
* **CTEs over non-entity selections.** A CTE's subquery selects a whole entity; a CTE
  whose selection is a tuple or expression is not supported.
* **Multiple `from` / cross joins**, and selection tuples wider than pairs beyond
  left-nesting.
* **Session-managed results.** Builder results are plain decoded values; `get` and
  `selectWhere` return managed rows.
