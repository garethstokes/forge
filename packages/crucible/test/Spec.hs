{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
module Main (main) where
import Harness (check, runChecks)
import Crucible.Json.Value (Value(..))
import Crucible.Json.Parse (parse)
import Crucible.Json.Encode (encode)
import Data.Text (Text)
import Crucible.Json.Decode as D
import Crucible.Json.Decode (Error(..), Crumb(..))
import Crucible.Schema (Schema(..), renderSchema)
import qualified Crucible.Codec as C
import Crucible.Codec (Codec(..))
import GHC.Generics (Generic)
import Crucible.Codec.Generic (HasCodec(..), genericCodec)

-- Sample types for M3 tests

data Sky = Clear | Cloudy | Storm deriving (Eq, Show, Generic)

skyCodec :: Codec Sky
skyCodec = C.enum [("clear", Clear), ("cloudy", Cloudy), ("storm", Storm)]

instance HasCodec Sky  -- derived via genericCodec (capitalised constructor-name tags)

data Forecast = Forecast { city :: Text, tempC :: Double, rainy :: Bool } deriving (Eq, Show, Generic)

instance HasCodec Forecast  -- derived via genericCodec

forecastCodec :: Codec Forecast
forecastCodec = C.object $
  Forecast
    <$> C.field "city"  city  C.str
    <*> C.field "tempC" tempC C.float
    <*> C.field "rainy" rainy C.bool

data Shape = Circle Double | Rect Double Double deriving (Eq, Show)

circleCodec :: Codec Double
circleCodec = C.object (C.field "r" id C.float)

rectCodec :: Codec (Double, Double)
rectCodec = C.object ((,) <$> C.field "w" fst C.float <*> C.field "h" snd C.float)

shapeCodec :: Codec Shape
shapeCodec = C.oneOfC
  [ C.Variant (codecSchema circleCodec)
              (Circle <$> codecDecode circleCodec)
              (\s -> case s of Circle r -> Just (codecEncode circleCodec r); _ -> Nothing)
  , C.Variant (codecSchema rectCodec)
              (uncurry Rect <$> codecDecode rectCodec)
              (\s -> case s of Rect w h -> Just (codecEncode rectCodec (w, h)); _ -> Nothing)
  ]

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
  -- Task 5: decode checks
  , check "decode field"
      (Right ("Brisbane", 27.5))
      (D.decodeString ((,) <$> D.field "city" D.string <*> D.field "tempC" D.float)
                      "{\"city\":\"Brisbane\",\"tempC\":27.5}")
  , check "decode list"
      (Right [1,2,3 :: Int])
      (D.decodeString (D.list D.int) "[1,2,3]")
  , check "decode missing field is Left"
      True
      (either (const True) (const False)
        (D.decodeString (D.field "nope" D.string) "{\"a\":1}"))
  , check "decode error path"
      (Left (Error [AtField "days", AtIndex 0, AtField "city"] "expected string, got number"))
      (D.decodeString (D.field "days" (D.list (D.field "city" D.string)))
                      "{\"days\":[{\"city\":7}]}")
  , check "oneOf picks first match"
      (Right (Left 5 :: Either Int Text))
      (D.decodeString (D.oneOf [Left <$> D.int, Right <$> D.string]) "5")
  -- Task 1: Schema renderSchema
  , check "render string"   "string"                             (renderSchema SStr)
  , check "render number"   "number"                             (renderSchema SNum)
  , check "render boolean"  "boolean"                            (renderSchema SBool)
  , check "render optional" "string | null"                      (renderSchema (SOpt SStr))
  , check "render array"    "[number]"                           (renderSchema (SArr SNum))
  , check "render enum"     "\"clear\" | \"cloudy\" | \"storm\"" (renderSchema (SEnum ["clear","cloudy","storm"]))
  , check "render object"   "{\"city\": string, \"tempC\": number}"
      (renderSchema (SObj [("city", SStr), ("tempC", SNum)]))
  , check "render oneOf"    "number | string"                    (renderSchema (SOneOf [SNum, SStr]))
  -- Task 2: Codec primitives + list'/nullable'/enum
  , check "prim schema str"  SStr            (codecSchema C.str)
  , check "prim encode int"  (JNumber 5.0)   (codecEncode C.int 5)
  , check "prim decode bool" (Right True)    (D.decodeValue (codecDecode C.bool) (JBool True))
  , check "list schema"      (SArr SNum)     (codecSchema (C.list' C.float))
  , check "list encode"      (JArray [JNumber 1.0, JNumber 2.0]) (codecEncode (C.list' C.float) [1, 2])
  , check "nullable schema"  (SOpt SStr)     (codecSchema (C.nullable' C.str))
  , check "nullable encode Nothing" JNull    (codecEncode (C.nullable' C.str) Nothing)
  , check "enum schema"      (SEnum ["clear","cloudy","storm"]) (codecSchema skyCodec)
  , check "enum encode"      (JString "storm") (codecEncode skyCodec Storm)
  , check "enum decode"      (Right Cloudy)  (D.decodeValue (codecDecode skyCodec) (JString "cloudy"))
  , check "enum decode bad"  True            (either (const True) (const False)
                                                (D.decodeValue (codecDecode skyCodec) (JString "nope")))
  -- Task 3: ObjectCodec + field/object (record round-trip)
  , check "record schema"
      (SObj [("city", SStr), ("tempC", SNum), ("rainy", SBool)])
      (codecSchema forecastCodec)
  , check "record encode"
      (JObject [("city", JString "Brisbane"), ("tempC", JNumber 27.5), ("rainy", JBool False)])
      (codecEncode forecastCodec (Forecast "Brisbane" 27.5 False))
  , check "record decode"
      (Right (Forecast "Brisbane" 27.5 False))
      (D.decodeValue (codecDecode forecastCodec)
        (JObject [("city", JString "Brisbane"), ("tempC", JNumber 27.5), ("rainy", JBool False)]))
  , check "record round-trips through text"
      (Right (Forecast "Hobart" 9.0 True))
      (D.decodeString (codecDecode forecastCodec)
        (encode (codecEncode forecastCodec (Forecast "Hobart" 9.0 True))))
  -- Task 4: Variant + oneOfC (sum round-trip)
  , check "sum schema"
      (SOneOf [SObj [("r", SNum)], SObj [("w", SNum), ("h", SNum)]])
      (codecSchema shapeCodec)
  , check "sum encode circle" (JObject [("r", JNumber 2.0)]) (codecEncode shapeCodec (Circle 2))
  , check "sum decode rect"
      (Right (Rect 3.0 4.0))
      (D.decodeValue (codecDecode shapeCodec) (JObject [("w", JNumber 3), ("h", JNumber 4)]))
  , check "sum round-trips"
      (Right (Circle 2.0))
      (D.decodeValue (codecDecode shapeCodec) (codecEncode shapeCodec (Circle 2)))
  -- M4 Task 1: HasCodec base instances
  , check "HasCodec Text schema"   SStr          (codecSchema (codec :: Codec Text))
  , check "HasCodec Int encode"    (JNumber 7.0) (codecEncode (codec :: Codec Int) 7)
  , check "HasCodec [Bool] schema" (SArr SBool)  (codecSchema (codec :: Codec [Bool]))
  , check "HasCodec Maybe schema"  (SOpt SNum)   (codecSchema (codec :: Codec (Maybe Double)))
  -- M4 Task 2: derived record matches hand-written + round-trips
  , check "derived record schema == hand-written"
      (codecSchema forecastCodec)
      (codecSchema (codec :: Codec Forecast))
  , check "derived record round-trips"
      (Right (Forecast "Cairns" 31.0 True))
      (decodeValue (codecDecode (codec :: Codec Forecast))
                   (codecEncode (codec :: Codec Forecast) (Forecast "Cairns" 31.0 True)))
  -- M4 Task 3: derived enum (constructor names, capitalised — cf. lowercase skyCodec)
  , check "derived enum schema"  (SEnum ["Clear","Cloudy","Storm"]) (codecSchema (codec :: Codec Sky))
  , check "derived enum encode"  (JString "Storm")                  (codecEncode (codec :: Codec Sky) Storm)
  , check "derived enum decode"  (Right Cloudy)                     (decodeValue (codecDecode (codec :: Codec Sky)) (JString "Cloudy"))
  ]
