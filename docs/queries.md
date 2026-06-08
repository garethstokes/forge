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

## Inner joins

`innerJoin @Post` takes a function from the new handle to the join condition;
handles from earlier in the block are in scope:

```haskell
pairs <- runQuery $ do
  u <- from @User
  p <- innerJoin @Post (\p -> u ^. #userId .== p ^. #postAuthor)
  pure (u, p)                  -- :: Db [(User, Post)]
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

## Status

Built and tested: `from`, `where_`, `orderBy`/`asc`/`desc`, `limit`/`offset`,
`innerJoin`, `groupBy`, `countRows`/`sum_`/`avg_`/`min_`/`max_`, tuple selections,
and `runQuery`. Columns are entity- and alias-bound through handles.

Planned, not built:

* **Outer joins, `HAVING`, `DISTINCT`, subqueries, and CTEs.** Only `INNER JOIN`
  and the aggregates above are built.
* **Multiple `from` / cross joins**, and selection tuples wider than pairs beyond
  left-nesting.
* **Session-managed results.** Builder results are plain decoded values; `get` and
  `selectWhere` return managed rows.
