---
title: Unit of Work
parent: Tutorials
nav_order: 1
---

# Unit of Work — edit a plain value, get a minimal UPDATE

> Runnable: this page is `docs/tutorials/Tutorial/UnitOfWork.lhs`, compiled and
> run by `zinc test` against a real Postgres. The Haskell you read below is the
> Haskell that runs — if it stopped being true, this page would stop compiling.

## Why

In a Unit-of-Work session you work with **plain records**. You load (or create)
a value, you edit a field with ordinary record-update syntax, and at flush time
Manifest works out the *minimal* SQL needed to make the database match. You never
hand-write an `UPDATE`; you never tell it which columns changed. It diffs the
record you saved against the snapshot it took when the value entered the session,
and emits an `UPDATE` touching **only** the columns that actually differ.

This is the same idea SQLAlchemy's Unit of Work gives Python, sitting on top of a
thin higher-kinded-data core (design §4.6).

## What

The session keeps an *identity map* and, for every managed value, a *snapshot* of
its column values at the moment it became managed. `save` re-registers the value;
the flush compares snapshot-vs-current per column and generates the smallest
write. Change one field of a three-column row and you get a one-column `UPDATE`.

## How

The module below is a single literate Haskell module. The first `haskell` block
carries the language pragmas, the `module` header, and the imports; later blocks
add the test body. They concatenate into one `Tutorial.UnitOfWork` module.

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Tutorial.UnitOfWork (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isPrefixOf)
import Fixtures (User, UserT (..), withTestDb)
import Manifest
import Harness
```

We open a session over the test pool, `add` a fresh `User` (an eager `INSERT`
that returns the row with its assigned primary key), then inside a transaction
`save` the same value with **one** field changed — `userName` from `"Ada"` to
`"Bob"`. Autoflush turns that into SQL as the transaction commits; we capture the
session's `statementLog` and pick out the `UPDATE` it produced.

Because `userEmail` and `userId` are unchanged, the diff names a single column:

```haskell
tests :: [Test]
tests = group "Tutorial.UnitOfWork"
  [ test "edit a plain value -> minimal UPDATE" $
      withTestDb $ \pool -> do
        log' <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Just "ada@x.io" } :: User)
          withTransaction $ save (u { userName = "Bob" } :: User)
          statementLog
        assertEqual "minimal update"
          ["UPDATE users SET user_name = $1 WHERE user_id = $2"]
          (filter ("UPDATE" `isPrefixOf`) (map (BC.unpack . fst) log'))
  ]
```

The assertion is exact: the only `UPDATE` issued is

```sql
UPDATE users SET user_name = $1 WHERE user_id = $2
```

— `user_name` only, keyed by primary key. Had we changed two fields, two columns
would appear in the `SET`; had we changed none, no `UPDATE` would be emitted at
all.

## Examples

The same snapshot-diff applies however you obtain the value. A sketch (this block
is illustrative-only — it renders but is **not** compiled, so it can elide the
session plumbing):

```hs
u <- get @User (Key 1)          -- becomes managed, snapshot taken here
case u of
  Just user -> withTransaction $
    save (user { userEmail = Just "new@x.io" })   -- diff -> UPDATE users SET user_email = $1 ...
  Nothing -> pure ()
```

Change the email instead of the name and the minimal `UPDATE` shifts to
`user_email`; the mechanism is identical. The lesson: you edit values, Manifest
writes the minimal SQL.
