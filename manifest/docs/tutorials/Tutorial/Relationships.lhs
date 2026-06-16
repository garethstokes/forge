---
title: Relationships
parent: Tutorials
nav_order: 2
---

# Relationships: load related rows two ways

> Runnable: this page is `docs/tutorials/Tutorial/Relationships.lhs`, compiled
> and run by `zinc test` against a real Postgres. The Haskell you read below is
> the Haskell that runs; if it stopped being true, this page would stop
> compiling.

## What this shows

A `User` has many `Post`s; a `Post` belongs to a `User`. Manifest knows these
relationships from the table records and gives you two ways to pull related rows.
The A-path (`load`) returns a list of children directly. The D-path
(`Ent` plus `with`/`rel`) carries a value together with its loaded relations as a
single typed bundle. Both go through the Unit-of-Work session, so anything they
return is managed: edit it and the flush emits a minimal write, as in the Unit of
Work tutorial.

The two paths and the two strategies:

* **A-path, `load`.** `load #posts user :: Db [Post]` runs one query keyed on the
  foreign key (`post_author`) and hands you back the children directly.
* **D-path, `Ent`.** `manage user` wraps the value in an `Ent` with an empty
  load-set; `with (selectin #posts)` loads a relation into it; `rel #posts e` reads
  it back. The `Ent` is a typed record of "this value plus the relations I've
  loaded".
* **Strategies, `selectin` vs `joined`.** `selectin` loads children with a separate
  `SELECT … WHERE fk IN (…)`; `joined` folds them in with a `LEFT JOIN`. Same result,
  different SQL; pick the one that suits your access pattern.

## How

The module below is a single literate Haskell module. The first `haskell` block
carries the language pragmas, the `module` header, and the imports; later blocks
add the test body. They concatenate into one `Tutorial.Relationships` module.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Tutorial.Relationships (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Fixtures (Post, PostT (..), User, UserT (..), withTestDb)
import Manifest
import Harness
```

### The A-path: `load #posts`

We `add` a user and two posts authored by them, then `load #posts u`. The result
is an ordinary `[Post]` of managed values you could go on to edit and `save`. We
assert on the titles.

```haskell
tests :: [Test]
tests = group "Tutorial.Relationships"
  [ test "A-path: load #posts returns the user's posts" $
      withTestDb $ \pool -> do
        titles <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          ps <- load #posts u
          pure (map postTitle ps)
        assertEqual "titles" ["P1", "P2"] titles
```

### The D-path: `with (selectin #posts)` then `rel #posts`

Here we keep the value and its children together. `manage u` produces an
`Ent User` with nothing loaded; `with (selectin #posts)` loads the posts into it;
`rel #posts e` reads them back. The bundle is typed: `rel #posts` only type-checks
because `#posts` was loaded into `e`.

```haskell
  , test "D-path: with (selectin #posts) then rel #posts" $
      withTestDb $ \pool -> do
        titles <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          e <- with (selectin #posts) (manage u)
          pure (map postTitle (rel #posts e))
        assertEqual "titles" ["P1", "P2"] titles
```

### Choosing a strategy: `joined #posts` emits a `LEFT JOIN`

Swapping `selectin` for `joined` changes the SQL without changing the result. We
load the same relation with `joined #posts`, read it back the same way, and then
inspect the session's `statementLog` to prove a `LEFT JOIN` was used.

```haskell
  , test "joined #posts loads children via a LEFT JOIN" $
      withTestDb $ \pool -> do
        (titles, log') <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          e <- with (joined #posts) (manage u)
          l <- statementLog
          pure (map postTitle (rel #posts e), l)
        assertEqual "titles" ["P1", "P2"] titles
        assertBool "used a LEFT JOIN"
          (any ("LEFT JOIN" `isInfixOf`) (map (BC.unpack . fst) log'))
  ]
```

## Examples

The same shapes work for the belongs-to and has-one directions. A sketch
(illustrative only; this block renders but is not compiled, so it can elide the
session plumbing):

```hs
-- belongs-to: a Post's author (RelOne, keyed on post_author)
author <- load #author post        -- :: Db User

-- has-one (optional): a User's profile (RelOpt)
mProfile <- load #profile user     -- :: Db (Maybe Profile)

-- D-path, optional relation via a LEFT JOIN, read back as Maybe:
e <- with (joined #profile) (manage user)
case rel #profile e of
  Just p  -> useProfile p
  Nothing -> noProfile
```

Use `load` when you want children in hand, and `Ent` plus `with`/`rel` when you
want a value and its relations as one typed bundle, with `selectin` vs `joined` to
pick the SQL shape. Everything you get back is managed by the session.
