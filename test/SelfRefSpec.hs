{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module SelfRefSpec (tests) where

import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Fixtures (Employee, EmployeeT (..), withTestDb)
import Manifest.Relation (load)
import Manifest.Relation.Loaded
import Manifest.Session
import Harness

stmts :: [(BC.ByteString, [Maybe BC.ByteString])] -> [String]
stmts = map (BC.unpack . fst)

tests :: [Test]
tests = group "SelfRef"
  [ test "load #reports (reverse self-FK) returns the manager's reports" $
      withTestDb $ \pool -> do
        names <- withSession pool $ do
          boss <- add (Employee { employeeId = 0, employeeManager = Nothing, employeeName = "Boss" } :: Employee)
          _    <- add (Employee { employeeId = 0, employeeManager = Just (employeeId boss), employeeName = "R1" } :: Employee)
          _    <- add (Employee { employeeId = 0, employeeManager = Just (employeeId boss), employeeName = "R2" } :: Employee)
          rs   <- load #reports boss
          pure (map employeeName rs)
        assertEqual "reports" ["R1", "R2"] names
  , test "joined #reports self-joins employees (aliased, unambiguous)" $
      withTestDb $ \pool -> do
        (names, usedJoin) <- withSession pool $ do
          boss <- add (Employee { employeeId = 0, employeeManager = Nothing, employeeName = "Boss" } :: Employee)
          _    <- add (Employee { employeeId = 0, employeeManager = Just (employeeId boss), employeeName = "R1" } :: Employee)
          e    <- with (joined #reports) (manage boss)
          l    <- statementLog
          pure (map employeeName (rel #reports e), any ("employees AS self_t" `isInfixOf`) (stmts l))
        assertEqual "reports" ["R1"] names
        assertBool "self-aliased join" usedJoin
  , test "load #manager (belongs-to self) returns the report's manager" $
      withTestDb $ \pool -> do
        nm <- withSession pool $ do
          boss <- add (Employee { employeeId = 0, employeeManager = Nothing, employeeName = "Boss" } :: Employee)
          r1   <- add (Employee { employeeId = 0, employeeManager = Just (employeeId boss), employeeName = "R1" } :: Employee)
          m    <- load #manager r1
          pure (employeeName m)
        assertEqual "manager" "Boss" nm
  ]
