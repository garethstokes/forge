{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Harness (check, runChecks)
import Crucible.Json.Value (Value(..))
import Crucible.Json.Parse (parse)
import Crucible.Json.Encode (encode)

main :: IO ()
main = runChecks
  [ check "harness self-test" (2 + 2 :: Int) 4
  , check "value Eq/Show sanity"
      (JObject [("a", JArray [JNumber 1, JNull]), ("b", JBool True)])
      (JObject [("a", JArray [JNumber 1, JNull]), ("b", JBool True)])
  -- Task 3 Step 1: primitive parse tests
  , check "parse null"   (Right JNull)             (parse "null")
  , check "parse bool"   (Right (JBool True))      (parse "true")
  , check "parse number" (Right (JNumber 27.5))    (parse "27.5")
  , check "parse string" (Right (JString "hi"))    (parse "\"hi\"")
  -- Task 3 Step 4: composite + escape + whitespace golden tests
  , check "parse array"  (Right (JArray [JNumber 1, JNumber 2]))                  (parse "[1, 2]")
  , check "parse object" (Right (JObject [("a", JNumber 1), ("b", JBool False)])) (parse "{ \"a\": 1, \"b\": false }")
  , check "parse nested" (Right (JObject [("xs", JArray [JString "y"])]))         (parse "{\"xs\":[\"y\"]}")
  , check "parse escape" (Right (JString "a\nb"))                                 (parse "\"a\\nb\"")
  , check "parse unicode"(Right (JString "A"))                                    (parse "\"\\u0041\"")
  , check "parse empties"(Right (JObject []))                                     (parse "{}")
  -- Task 4: encode checks
  , check "encode compact"
      "{\"a\":1.0,\"b\":[true,null]}"
      (encode (JObject [("a", JNumber 1), ("b", JArray [JBool True, JNull])]))
  , check "encode->parse round-trips"
      (Right (JObject [("x", JString "hi")]))
      (parse (encode (JObject [("x", JString "hi")])))
  ]
