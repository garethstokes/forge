-- | A tiny zero-dependency test harness (no hspec — keeps the test target's
-- dependency closure to boot libs + the library under test). A test is a named
-- 'IO' action that signals failure by throwing; assertions throw 'userError'.
module Harness
  ( Test
  , test
  , group
  , runTests
  , assertBool
  , assertEqual
  , assertReturns
  ) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

-- | A named test: its label (group-qualified) and the action to run.
data Test = Test String (IO ())

-- | A single test case.
test :: String -> IO () -> Test
test = Test

-- | Prefix a batch of tests with a group label (e.g. a module name).
group :: String -> [Test] -> [Test]
group name = map (\(Test n a) -> Test (name <> " — " <> n) a)

-- | Fail with a message unless the condition holds.
assertBool :: String -> Bool -> IO ()
assertBool msg ok = if ok then pure () else ioError (userError msg)

-- | Fail unless @actual == expected@, reporting both.
assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual msg expected actual =
  if expected == actual
    then pure ()
    else ioError (userError (msg <> ": expected " <> show expected <> " but got " <> show actual))

-- | Fail unless an IO action returns the expected value.
assertReturns :: (Eq a, Show a) => String -> a -> IO a -> IO ()
assertReturns msg expected act = act >>= assertEqual msg expected

-- | Run all tests; print one line each, a summary, and exit non-zero on any failure.
runTests :: [Test] -> IO ()
runTests ts = do
  results <- forM ts $ \(Test name act) -> do
    r <- try (act >>= evaluate) :: IO (Either SomeException ())
    case r of
      Right () -> putStrLn ("  ok   " <> name) >> pure True
      Left e -> do
        hPutStrLn stderr ("  FAIL " <> name <> "\n         " <> show e)
        pure False
  let passed = length (filter id results)
      total = length results
  putStrLn (show passed <> "/" <> show total <> " tests passed")
  if passed == total then exitSuccess else exitFailure
