{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Harness (check, runChecks)
import Crucible.Json.Value (Value(..))

main :: IO ()
main = runChecks
  [ check "harness self-test" (2 + 2 :: Int) 4
  , check "value Eq/Show sanity"
      (JObject [("a", JArray [JNumber 1, JNull]), ("b", JBool True)])
      (JObject [("a", JArray [JNumber 1, JNull]), ("b", JBool True)])
  ]
