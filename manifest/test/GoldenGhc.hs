-- | Resolve the @ghc@ arguments (package database + include directories) that
-- the golden compile-tests pass when they shell out to the compiler, as
-- ABSOLUTE paths derived from the running spec binary's own location.
--
-- This keeps the golden tests working regardless of the process's CWD. A
-- standalone single-package checkout runs the suite from the repo root (where
-- @.zinc/pkgdb@ and @test/@ both sit), but a zinc workspace runs a member's
-- test from the workspace root — so the shared package db lives a directory up
-- from the member's own @test/@ sources, and no single relative CWD reaches
-- both. Walking up from the test executable finds both reliably.
module GoldenGhc
  ( goldenGhcArgs
  ) where

import System.Directory (doesDirectoryExist)
import System.Environment (getExecutablePath)
import System.FilePath (takeDirectory, (</>))

-- | @-package-db@ plus @-i@ include flags pointing at this member's built
-- library, its @test@ source dir, and the package db. The executable lives at
-- @\<member\>/.zinc/build/spec@, so the member directory is three levels up;
-- the package db is then searched for upward, since zinc keeps a single shared
-- db at the workspace root.
goldenGhcArgs :: IO [String]
goldenGhcArgs = do
  exe <- getExecutablePath
  let memberDir = takeDirectory (takeDirectory (takeDirectory exe))
  dbRoot <- findPkgDbRoot memberDir
  pure
    [ "-package-db", dbRoot </> ".zinc" </> "pkgdb"
    , "-i" ++ (memberDir </> ".zinc" </> "lib")
    , "-i" ++ (memberDir </> "test")
    ]

-- | Walk upward from @start@ until a directory containing @.zinc/pkgdb@ is
-- found; fall back to @start@ if the filesystem root is reached.
findPkgDbRoot :: FilePath -> IO FilePath
findPkgDbRoot start = go start
  where
    go d = do
      found <- doesDirectoryExist (d </> ".zinc" </> "pkgdb")
      if found
        then pure d
        else let up = takeDirectory d
             in if up == d then pure start else go up
