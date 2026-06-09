{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module QueryBuilderSpec (tests) where

import Data.List (sort, sortOn)
import Fixtures (Post, PostT (..), User, UserT (..), withTestDb)
import Manifest
import Manifest.Query
import Harness

tests :: [Test]
tests = group "QueryBuilder"
  [ test "single-table select renders SELECT alias.cols FROM table AS t0" $
      assertEqual "sql"
        "SELECT t0.user_id, t0.user_name, t0.user_email FROM users AS t0"
        (fst (renderQueryM (do u <- from @User; pure u)))
  , test "where_ renders an alias-qualified, numbered condition" $
      assertEqual "sql"
        "SELECT t0.user_id, t0.user_name, t0.user_email FROM users AS t0 WHERE t0.user_name = $1"
        (fst (renderQueryM (do u <- from @User
                               where_ (u ^. #userName .== val ("Bob" :: String))
                               pure u)))
  , test "runQuery returns all rows" $
      withTestDb $ \pool -> do
        names <- withSession pool $ do
          _ <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (User { userId = 0, userName = "Bob", userEmail = Nothing } :: User)
          us <- runQuery (do u <- from @User; pure u)
          pure (sort (map userName us))
        assertEqual "names" ["Ada", "Bob"] names
  , test "where_ filters rows at runtime" $
      withTestDb $ \pool -> do
        names <- withSession pool $ do
          _ <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (User { userId = 0, userName = "Bob", userEmail = Nothing } :: User)
          us <- runQuery (do u <- from @User
                             where_ (u ^. #userName .== val ("Bob" :: String))
                             pure u)
          pure (map userName us)
        assertEqual "names" ["Bob"] names
  , test "orderBy + limit + offset render in order" $
      assertEqual "sql"
        "SELECT t0.user_id, t0.user_name, t0.user_email FROM users AS t0 ORDER BY t0.user_name DESC LIMIT 2 OFFSET 1"
        (fst (renderQueryM (do u <- from @User
                               orderBy [desc (u ^. #userName)]
                               limit 2
                               offset 1
                               pure u)))
  , test "orderBy + limit return rows in order, paginated" $
      withTestDb $ \pool -> do
        names <- withSession pool $ do
          mapM_ (\n -> add (User { userId = 0, userName = n, userEmail = Nothing } :: User))
                ["Ada","Bob","Cay","Dee"]
          us <- runQuery (do u <- from @User
                             orderBy [asc (u ^. #userName)]
                             limit 2
                             pure u)
          pure (map userName us)
        assertEqual "first two by name" ["Ada","Bob"] names
  , test "innerJoin renders an aliased INNER JOIN selecting both tables" $
      assertEqual "sql"
        ( "SELECT t0.user_id, t0.user_name, t0.user_email, t1.post_id, t1.post_author, t1.post_title"
       <> " FROM users AS t0 INNER JOIN posts AS t1 ON t0.user_id = t1.post_author" )
        (fst (renderQueryM (do u <- from @User
                               p <- innerJoin @Post (\p -> u ^. #userId .== p ^. #postAuthor)
                               pure (u, p))))
  , test "innerJoin returns (User, Post) pairs" $
      withTestDb $ \pool -> do
        pairs <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          rows <- runQuery (do usr <- from @User
                               pst <- innerJoin @Post (\pst -> usr ^. #userId .== pst ^. #postAuthor)
                               pure (usr, pst))
          pure [ (userName a, postTitle b) | (a, b) <- rows ]
        assertEqual "pairs" [("Ada","P1"),("Ada","P2")] pairs
  , test "groupBy + countRows counts children per key" $
      withTestDb $ \pool -> do
        grouped <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          runQuery (do p <- from @Post
                       groupBy (p ^. #postAuthor)
                       pure (p ^. #postAuthor, countRows))
        assertEqual "posts per author" [(1 :: Int, 2 :: Int)] grouped
  , test "sum_ aggregates a column" $
      withTestDb $ \pool -> do
        total <- withSession pool $ do
          u <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P1" } :: Post)
          _ <- add (Post { postId = 0, postAuthor = userId u, postTitle = "P2" } :: Post)
          runQuery (do p <- from @Post; pure (sum_ (p ^. #postAuthor)))
        assertEqual "sum of author ids" [Just (2 :: Int)] total
  , test "a val in the selection numbers before the WHERE param" $
      let (sql, params) =
            renderQueryM (do u <- from @User
                             where_ (u ^. #userName .== val ("Bob" :: String))
                             pure (u, val (5 :: Int)))
      in do
        assertEqual "select val is $1, where val is $2"
          "SELECT t0.user_id, t0.user_name, t0.user_email, $1 FROM users AS t0 WHERE t0.user_name = $2"
          sql
        assertEqual "params in SQL order: selection then where"
          [Just "5", Just "Bob"] params
  , test "leftJoin renders a LEFT JOIN selecting both tables" $
      assertEqual "sql"
        ( "SELECT t0.user_id, t0.user_name, t0.user_email, t1.post_id, t1.post_author, t1.post_title"
       <> " FROM users AS t0 LEFT JOIN posts AS t1 ON t1.post_author = t0.user_id" )
        (fst (renderQueryM (do u <- from @User
                               mp <- leftJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                               pure (u, mp))))
  , test "leftJoin yields Nothing for unmatched rows, Just for matched" $
      withTestDb $ \pool -> do
        rows <- withSession pool $ do
          _   <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)  -- no posts
          bob <- add (User { userId = 0, userName = "Bob", userEmail = Nothing } :: User)
          _   <- add (Post { postId = 0, postAuthor = userId bob, postTitle = "B1" } :: Post)
          runQuery (do u  <- from @User
                       mp <- leftJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                       orderBy [asc (u ^. #userName)]
                       pure (u, mp))
        assertEqual "Ada has no post, Bob has B1"
          [("Ada", Nothing), ("Bob", Just "B1")]
          [ (userName u, fmap postTitle mp) | (u, mp) <- rows ]
  , test "withCte + fromCte render a WITH clause and select from it" $
      assertEqual "sql"
        ( "WITH cte0 AS (SELECT t0.user_id, t0.user_name, t0.user_email FROM users AS t0"
       <> " WHERE t0.user_name = $1) SELECT t0.user_id, t0.user_name, t0.user_email FROM cte0 AS t0" )
        (fst (renderQueryM (do c <- withCte (do u <- from @User
                                                where_ (u ^. #userName .== val ("Bob" :: String))
                                                pure u)
                               h <- fromCte c
                               pure h)))
  , test "CTE param numbers before the outer WHERE param" $
      assertEqual "params + numbering"
        ( "WITH cte0 AS (SELECT t0.user_id, t0.user_name, t0.user_email FROM users AS t0"
       <> " WHERE t0.user_name > $1) SELECT t0.user_id, t0.user_name, t0.user_email FROM cte0 AS t0"
       <> " WHERE t0.user_name < $2"
        , [Just "A", Just "C"] )
        (renderQueryM (do c <- withCte (do u <- from @User
                                           where_ (u ^. #userName .> val ("A" :: String))
                                           pure u)
                          h <- fromCte c
                          where_ (h ^. #userName .< val ("C" :: String))
                          pure h))
  , test "fromCte over a filtered CTE returns the filtered rows" $
      withTestDb $ \pool -> do
        names <- withSession pool $ do
          mapM_ (\n -> add (User { userId = 0, userName = n, userEmail = Nothing } :: User))
                ["Ada","Bob","Cay"]
          runQuery (do c <- withCte (do u <- from @User
                                        where_ (u ^. #userName .> val ("Ada" :: String))
                                        pure u)
                       h <- fromCte c
                       orderBy [asc (h ^. #userName)]
                       pure h)
        assertEqual "names > Ada" ["Bob","Cay"] (map userName names)
  , test "rightJoin renders RIGHT JOIN; opt selects the left table as Maybe" $
      assertEqual "sql"
        ( "SELECT t0.user_id, t0.user_name, t0.user_email, t1.post_id, t1.post_author, t1.post_title"
       <> " FROM users AS t0 RIGHT JOIN posts AS t1 ON t1.post_author = t0.user_id" )
        (fst (renderQueryM (do u <- from @User
                               p <- rightJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                               pure (opt u, p))))
  , test "fullJoin renders FULL JOIN; both sides select as Maybe" $
      assertEqual "sql"
        ( "SELECT t0.user_id, t0.user_name, t0.user_email, t1.post_id, t1.post_author, t1.post_title"
       <> " FROM users AS t0 FULL JOIN posts AS t1 ON t1.post_author = t0.user_id" )
        (fst (renderQueryM (do u  <- from @User
                               fp <- fullJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                               pure (opt u, fp))))
  , test "rightJoin keeps unmatched right rows (orphan post -> Nothing user)" $
      withTestDb $ \pool -> do
        rows <- withSession pool $ do
          ada <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _   <- add (Post { postId = 0, postAuthor = userId ada, postTitle = "A1" } :: Post)
          _   <- add (Post { postId = 0, postAuthor = 999, postTitle = "Orphan" } :: Post)
          runQuery (do u <- from @User
                       p <- rightJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                       pure (opt u, p))
        assertEqual "every post kept; orphan has no user"
          [(Just "Ada", "A1"), (Nothing, "Orphan")]
          (sortOn snd [ (fmap userName mu, postTitle p) | (mu, p) <- rows ])
  , test "fullJoin keeps unmatched rows on both sides" $
      withTestDb $ \pool -> do
        rows <- withSession pool $ do
          ada <- add (User { userId = 0, userName = "Ada", userEmail = Nothing } :: User)
          _   <- add (User { userId = 0, userName = "Bob", userEmail = Nothing } :: User)
          _   <- add (Post { postId = 0, postAuthor = userId ada, postTitle = "A1" } :: Post)
          _   <- add (Post { postId = 0, postAuthor = 999, postTitle = "Orphan" } :: Post)
          runQuery (do u  <- from @User
                       fp <- fullJoin @Post (\p -> p ^. #postAuthor .== u ^. #userId)
                       pure (opt u, fp))
        assertEqual "matched, user-without-post, post-without-user"
          (sort [ (Just "Ada", Just "A1"), (Just "Bob", Nothing), (Nothing, Just "Orphan") ])
          (sort [ (fmap userName mu, fmap postTitle mp) | (mu, mp) <- rows ])
  , test "having renders after GROUP BY; param numbers after WHERE" $
      assertEqual "sql + params"
        ( "SELECT t0.post_author, COUNT(*) FROM posts AS t0 WHERE t0.post_title <> $1"
       <> " GROUP BY t0.post_author HAVING COUNT(*) > $2"
        , [Just "x", Just "1"] )
        (renderQueryM (do p <- from @Post
                          where_ (p ^. #postTitle ./= val ("x" :: String))
                          groupBy (p ^. #postAuthor)
                          having (countRows .> val (1 :: Int))
                          pure (p ^. #postAuthor :: Expr Int, countRows)))
  , test "distinct renders SELECT DISTINCT" $
      assertEqual "sql"
        "SELECT DISTINCT t0.post_author FROM posts AS t0"
        (fst (renderQueryM (do distinct; p <- from @Post; pure (p ^. #postAuthor :: Expr Int))))
  , test "having filters groups at runtime" $
      withTestDb $ \pool -> do
        authors <- withSession pool $ do
          u1 <- add (User { userId = 0, userName = "A", userEmail = Nothing } :: User)
          u2 <- add (User { userId = 0, userName = "B", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u1, postTitle = "p1" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u1, postTitle = "p2" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u2, postTitle = "p3" } :: Post)
          runQuery (do p <- from @Post
                       groupBy (p ^. #postAuthor)
                       having (countRows .> val (1 :: Int))
                       pure (p ^. #postAuthor))
        assertEqual "only the author with >1 post" [1 :: Int] authors
  , test "distinct dedups rows at runtime" $
      withTestDb $ \pool -> do
        authors <- withSession pool $ do
          u1 <- add (User { userId = 0, userName = "A", userEmail = Nothing } :: User)
          u2 <- add (User { userId = 0, userName = "B", userEmail = Nothing } :: User)
          _  <- add (Post { postId = 0, postAuthor = userId u1, postTitle = "p1" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u1, postTitle = "p2" } :: Post)
          _  <- add (Post { postId = 0, postAuthor = userId u2, postTitle = "p3" } :: Post)
          runQuery (do distinct
                       p <- from @Post
                       pure (p ^. #postAuthor :: Expr Int))
        assertEqual "distinct authors (3 posts, 2 authors)" [1, 2] (sort authors)
  ]
