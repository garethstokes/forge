{-# LANGUAGE DataKinds #-}

-- | Golden test for the @rel@ "not loaded" custom error.
--
-- NOTE on mechanism: the plan's first-choice approach was to let
-- @-fdefer-type-errors@ turn the @Unsatisfiable (NotLoaded ...)@ type error
-- into a runtime @Control.Exception.TypeError@ carrying the rendered message.
-- That does NOT work on GHC 9.10: under @-fdefer-type-errors@, an
-- @Unsatisfiable@ constraint is treated as a *satisfied* (deferred) constraint,
-- so @rel@'s body actually runs and hits its defensive @error@ rather than
-- throwing a @TypeError@ with the custom sentence. (Verified empirically.)
--
-- So we fall back to the task's specified compile-failure golden test: compile
-- a tiny standalone module that reads an unloaded relation, capture GHC's
-- stderr, and assert the rendered sentence's substrings appear in it. This
-- still observes the real custom message and regresses if the message changes
-- (design §5.2 mitigation #8). The PRODUCTION @Member@/@Unsatisfiable@ design
-- is unchanged — only the test *mechanism* differs.

module RelationErrorSpec (tests) where

import Data.List (isInfixOf)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)
import Harness

-- A standalone module that reads an unloaded relation. Compiling it must fail
-- with the custom 'NotLoaded' sentence. Kept as a string (written to a temp
-- file at test time) so it is never compiled as part of the test suite.
goldenSource :: String
goldenSource = unlines
  [ "{-# LANGUAGE DataKinds #-}"
  , "{-# LANGUAGE OverloadedLabels #-}"
  , "module RelGolden where"
  , "import Fixtures (User, UserT (..))"
  , "import Manifest.Relation.Loaded (manage, rel)"
  , "boom :: Int"
  , "boom = length (rel #posts (manage"
  , "  (User { userId = 1, userName = \"Ada\", userEmail = Nothing } :: User)))"
  ]

tests :: [Test]
tests = group "RelationError"
  [ test "reading an unloaded relation is a compile error with the custom 'not loaded' message" $ do
      tmp <- getTemporaryDirectory
      (path, h) <- openTempFile tmp "RelGolden.hs"
      hClose h
      writeFile path goldenSource
      (_code, _out, err) <-
        readProcessWithExitCode "ghc"
          [ "-fno-code", "-fforce-recomp"
          , "-package-db", ".zinc/pkgdb"
          , "-i.zinc/lib", "-itest"
          , "-XOverloadedStrings", "-XScopedTypeVariables", "-XTypeApplications"
          , "-XLambdaCase", "-XDataKinds", "-XOverloadedLabels"
          , path
          ]
          ""
      removeFile path
      -- GHC normalises whitespace/newlines in the rendered message, so compare
      -- against a whitespace-collapsed copy of the compiler output.
      let msg = unwords (words err)
      assertBool ("names the relation; output was:\n" <> err)
        ("posts" `isInfixOf` msg)
      assertBool ("says not loaded; output was:\n" <> err)
        ("is not loaded" `isInfixOf` msg)
      assertBool ("suggests with selectin; output was:\n" <> err)
        ("with (selectin #posts)" `isInfixOf` msg)
  ]
