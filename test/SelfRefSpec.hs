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
  , test "load #manager (nullable belongs-to self): Just below, Nothing at top" $
      withTestDb $ \pool -> do
        (mgrOfReport, mgrOfBoss) <- withSession pool $ do
          boss <- add (Employee { employeeId = 0, employeeManager = Nothing, employeeName = "Boss" } :: Employee)
          r1   <- add (Employee { employeeId = 0, employeeManager = Just (employeeId boss), employeeName = "R1" } :: Employee)
          m1   <- load #manager r1     -- Just Boss
          m2   <- load #manager boss   -- Nothing (no manager)
          pure (fmap employeeName m1, fmap employeeName m2)
        assertEqual "report's manager" (Just "Boss") mgrOfReport
        assertEqual "boss's manager"   Nothing        mgrOfBoss
  , test "load #manager on a NULL self-FK short-circuits — issues NO query" $
      withTestDb $ \pool -> do
        (mgr, nEmployeeSelects) <- withSession pool $ do
          boss <- add (Employee { employeeId = 0, employeeManager = Nothing, employeeName = "Boss" } :: Employee)
          m    <- load #manager boss   -- NULL FK → Nothing WITHOUT a round-trip
          l    <- statementLog
          -- the add is an INSERT (no "SELECT"); a non-short-circuiting loader would
          -- emit "SELECT ... FROM employees WHERE employee_id = $1" → count 1.
          pure (fmap employeeName m, length (filter (\s -> "SELECT" `isInfixOf` s && "employees" `isInfixOf` s) (stmts l)))
        assertEqual "no manager" Nothing mgr
        assertEqual "short-circuit issued zero employee SELECTs" 0 nEmployeeSelects
  ]
