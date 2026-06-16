---
title: Cascades
parent: Tutorials
nav_order: 3
---

# Cascades: delete a parent, its children go too

> Runnable: this page is `docs/tutorials/Tutorial/Cascades.lhs`, compiled and run
> by `zinc test` against a real Postgres. The Haskell you read below is the
> Haskell that runs; if it stopped being true, this page would stop compiling.

## What this shows

A `User` has many `Post`s. When you delete the user, its posts need an on-delete
policy. Manifest lets you declare that policy once, on the parent entity, and
applies it when the Unit-of-Work session flushes the parent's `delete`. You do not
write the child `DELETE` by hand.

This is **built** (SP2.6). The policy lives in the parent `Entity`'s `cascadeRules`
and is applied at flush time, in the session rather than by the database, so the
same rule works whether or not the Postgres schema has a matching `ON DELETE`
foreign key.

## What

Each rule names a child entity, the foreign-key label on that child that points
back at this parent, and an `OnDelete` policy. In the fixtures used by this
suite, `User` declares (illustrative; this is the declaration shape, not compiled
here):

```hs
instance Entity User where
  -- …
  cascadeRules =
    [ cascade (Proxy @Post)    (Proxy @"postAuthor")  Cascade
    , cascade (Proxy @Profile) (Proxy @"profileUser") SetNull
    , cascade (Proxy @Tag)     (Proxy @"tagUser")     Restrict
    ]
```

The three `OnDelete` policies:

* **`Cascade`**: delete the children too. (This page demonstrates it.)
* **`SetNull`**: keep the children but null their foreign key (the FK column must be
  nullable); the rows survive, parentless.
* **`Restrict`**: refuse the delete if any children exist; the whole flush is aborted
  before anything mutates.

This tutorial demonstrates the `Cascade` rule, `cascade (Proxy @Post) (Proxy
@"postAuthor") Cascade`, end to end through the public API.

## How

The module below is a single literate Haskell module. The first `haskell` block
carries the language pragmas, the `module` header, and the imports; the later
block adds the test body. They concatenate into one `Tutorial.Cascades` module.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Tutorial.Cascades (tests) where

import Fixtures (Post, PostT (..), User, UserT (..), withTestDb)
import Manifest
import Harness
```

### Delete the user, the posts cascade away

We `add` a user and a couple of posts authored by them, then `delete` the user
inside a transaction. `User`'s `cascadeRules` carry
`cascade (Proxy @Post) (Proxy @"postAuthor") Cascade`, so when the session
flushes the parent delete it first deletes the children. We then count the posts
with `selectWhere`; there should be none left.

```haskell
tests :: [Test]
tests = group "Tutorial.Cascades"
  [ test "Cascade: deleting a user cascade-deletes their posts" $
      withTestDb $ \pool -> do
        remaining <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          withTransaction $ delete u            -- cascadeRules delete the posts at flush
          length <$> selectWhere ([] :: [Cond Post])
        assertEqual "posts cascaded away" 0 remaining
  ]
```

## Examples

The other two policies follow the same declaration shape; only the `OnDelete`
constructor changes. Illustrative only (this block renders but is not compiled):

```hs
-- SetNull: keep the child, null its (nullable) FK; the row survives, parentless.
cascade (Proxy @Profile) (Proxy @"profileUser") SetNull

-- Restrict: refuse the parent delete while any child exists; the flush aborts
-- before any mutation, so nothing is partially deleted.
cascade (Proxy @Tag) (Proxy @"tagUser") Restrict
```

Declare the on-delete policy once, on the parent entity's `cascadeRules`, and the
session enforces it at flush — across the whole tree: `Cascade` removes the
children and recurses into THEIR cascade rules (grandchildren and deeper follow),
`SetNull` orphans them, `Restrict` blocks the delete from anywhere in the tree
before anything is mutated. You do not write the child `DELETE`s by hand. One
caveat: on a self-referential cascade the walk stops after one level per
declared edge, and rules of the rows deleted at that cut — including
`Restrict` — are not applied.
