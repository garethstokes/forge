{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
module Main (main) where
import Harness (check, runChecks)
import Crucible.Json.Value (Value(..))
import Crucible.Json.Parse (parse)
import Crucible.Json.Encode (encode)
import Data.Text (Text)
import qualified Data.Text
import Crucible.Json.Decode as D
import Crucible.Json.Decode (Error(..), Crumb(..))
import Crucible.Schema (Schema(..), renderSchema)
import qualified Crucible.Codec as C
import Crucible.Codec (Codec(..))
import GHC.Generics (Generic)
import Crucible.Codec.Generic (HasCodec(..), genericCodec)
import Crucible.SAP (stripToJson, decodeLLM)
import Crucible.Decision (Decision(..), decisionCodec, Step(..), reduce)
import Crucible.LLM (MonadLLM(..), Message(..), Role(..))
import Crucible.LLM.Scripted (ScriptedM, runScripted)
import Crucible.Agent (AgentState, startAgent, runAgent)
import qualified Crucible.Tool as Tl

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

data Station = Station { name :: Text, latest :: Forecast, conditions :: Sky }
  deriving (Eq, Show, Generic)
instance HasCodec Station

stationVal :: Station
stationVal = Station "Eagle Farm" (Forecast "Brisbane" 26.0 False) Cloudy

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

-- Sample types for M6 tests
data ToolCall = GetWeather Text | AddNums Int Int deriving (Eq, Show)
newtype Answer = Answer Text deriving (Eq, Show)

getWeatherCodec :: Codec Text                 -- {"city": string}
getWeatherCodec = C.object (C.field "city" id C.str)

addNumsCodec :: Codec (Int, Int)              -- {"a": int, "b": int}
addNumsCodec = C.object ((,) <$> C.field "a" fst C.int <*> C.field "b" snd C.int)

toolCallCodec :: Codec ToolCall
toolCallCodec = C.oneOfC
  [ C.Variant (codecSchema getWeatherCodec) (GetWeather <$> codecDecode getWeatherCodec)
      (\tc -> case tc of GetWeather city -> Just (codecEncode getWeatherCodec city); _ -> Nothing)
  , C.Variant (codecSchema addNumsCodec) (uncurry AddNums <$> codecDecode addNumsCodec)
      (\tc -> case tc of AddNums a b -> Just (codecEncode addNumsCodec (a, b)); _ -> Nothing) ]

answerCodec :: Codec Answer
answerCodec = C.object (Answer <$> C.field "answer" (\(Answer t) -> t) C.str)

decCodec :: Codec (Decision ToolCall Answer)
decCodec = decisionCodec toolCallCodec answerCodec

-- M7 Task 2: agent test helpers
toolRunner :: ToolCall -> ScriptedM Text
toolRunner (GetWeather c)  = pure ("sunny in " <> c)
toolRunner (AddNums a b)   = pure (Data.Text.pack (show (a + b)))

agentRun :: Answer
agentRun = runScripted
  [ "{\"city\":\"Brisbane\"}"
  , "{\"answer\":\"It is sunny in Brisbane\"}" ]
  (runAgent decCodec toolRunner (startAgent decCodec "What's the weather in Brisbane?"))

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
  -- M4 Task 4: nested derive (composition) — no new implementation needed
  , check "nested derived schema"
      (SObj [ ("name", SStr)
            , ("latest", SObj [("city", SStr), ("tempC", SNum), ("rainy", SBool)])
            , ("conditions", SEnum ["Clear","Cloudy","Storm"]) ])
      (codecSchema (codec :: Codec Station))
  , check "nested derived round-trips"
      (Right stationVal)
      (decodeValue (codecDecode (codec :: Codec Station))
                   (codecEncode (codec :: Codec Station) stationVal))
  -- M5 Task 1: stripToJson
  , check "strip bare"     "{\"a\":1}" (stripToJson "{\"a\":1}")
  , check "strip fenced"   "{\"a\":1}" (stripToJson "```json\n{\"a\":1}\n```")
  , check "strip prose"    "{\"a\":1}" (stripToJson "Sure, here you go: {\"a\":1} hope that helps!")
  , check "strip array"    "[1,2]"     (stripToJson "prefix [1,2] suffix")
  , check "strip brace-in-string"
      "{\"msg\":\"a } b\"}"
      (stripToJson "noise {\"msg\":\"a } b\"} more")
  -- M5 Task 2: decodeLLM
  , check "decodeLLM fenced"
      (Right (Forecast "Brisbane" 27.5 False))
      (decodeLLM forecastCodec
        "Sure!\n```json\n{ \"city\": \"Brisbane\", \"tempC\": 27.5, \"rainy\": false }\n```\nlet me know")
  , check "decodeLLM prose"
      (Right (Forecast "Hobart" 9.0 True))
      (decodeLLM forecastCodec
        "Here is the forecast: { \"city\": \"Hobart\", \"tempC\": 9, \"rainy\": true } -- done.")
  , check "decodeLLM rejects junk"
      True
      (either (const True) (const False) (decodeLLM forecastCodec "no json here"))
  -- M6 Task 1: Decision + decisionCodec
  , check "decode tool-call -> CallTool"
      (Right (CallTool (GetWeather "Brisbane")))
      (decodeLLM decCodec "{\"city\":\"Brisbane\"}")
  , check "decode answer -> Done"
      (Right (Done (Answer "all set")))
      (decodeLLM decCodec "{\"answer\":\"all set\"}")
  , check "decision round-trips (tool)"
      (Right (CallTool (AddNums 2 3)))
      (decodeValue (codecDecode decCodec) (codecEncode decCodec (CallTool (AddNums 2 3))))
  -- M6 Task 2: Step + reduce
  , check "reduce CallTool -> Continue"
      (Continue (GetWeather "Brisbane"))
      (reduce (CallTool (GetWeather "Brisbane") :: Decision ToolCall Answer))
  , check "reduce Done -> Halt"
      (Halt (Answer "all set"))
      (reduce (Done (Answer "all set") :: Decision ToolCall Answer))
  -- M7 Task 1: MonadLLM + ScriptedM
  , check "scripted pops canned replies in order"
      ["a", "b"]
      (runScripted ["a", "b"] ((do x <- complete ([] :: [Message]); y <- complete ([] :: [Message]); pure [x, y]) :: ScriptedM [Text]))
  -- M7 Task 2: agent control loop
  , check "agent loops tool->answer to a final Answer"
      (Answer "It is sunny in Brisbane") agentRun
  , check "agent halts immediately on a Done reply"
      (Answer "hi")
      (runScripted ["{\"answer\":\"hi\"}"]
        (runAgent decCodec toolRunner (startAgent decCodec "say hi")))
  -- M9 Task 1: Crucible.Tool
  , check "toolCallCodec decodes name+args"
      (Right (Tl.ToolCall "get_weather" (JObject [("city", JString "Hobart")])))
      (D.decodeValue (codecDecode Tl.toolCallCodec)
        (JObject [("tool", JString "get_weather"), ("args", JObject [("city", JString "Hobart")])]))
  , check "toolsHelp lists tools"
      "- echo(args: {\"msg\": string})"
      (Tl.toolsHelp [Tl.Tool "echo" (SObj [("msg", SStr)]) (\_ -> Just JNull)])
  ]
