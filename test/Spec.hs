{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module Main (main) where
import Harness (check, runChecks)
import Data.Aeson (Value(..), object, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as AT
import qualified Data.Vector as V
import Autodocodec (toJSONVia, parseJSONVia)
import qualified Crucible.Codec as C
import Crucible.Codec (JSONCodec, schemaValue, schemaText)
import Crucible.Codec.Generic (HasCodec(..), genericCodec)
import Crucible.Skill (Skill (..), Instruction (..), skill, skillWith, withPreamble, withConstraints, withRetries, withTests, withExamples, examplesFromTests, withReasoning, prompt, call, testSkill)
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text as T
import GHC.Generics (Generic)
import Crucible.Decode (stripToJson, decodeLLM, DecodeError (..))
import Crucible.Decision (Decision(..), decisionCodec, Step(..), reduce)
import Effectful (Eff, runEff, runPureEff)
import qualified Data.Text.IO as TIO
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text.Encoding as TE
import Crucible.LLM (LLM, complete, Message(..), Role(..), runLLMScripted)
import Crucible.Agent (startAgent, runAgent)
import qualified Crucible.Tool as Tl
import Crucible.Tool (runTools)
import Crucible.Example (demoAgent)
import Crucible.Tool.Generic (tools)
import Crucible.Eval (Case(..), Expectation(..), Criterion(..), criterion, Score(..), score, Result(..), Report(..), runEval, runEvalN, scoreM, judge, judgeN, renderReport, groundingCheck, judgeWith, runEvalWith)
import Crucible.Skill.Improve (ImproveStep (..), improveSkill)
import Crucible.Eval.Judge (Verdict(..), verdictCodec, JudgeExample(..), JudgeOpts(..), defaultJudgeOpts, balanceExamples, judgePrompt, ratePrompt)
import Crucible.Eval.Calibrate (CalibrationReport (..), calibrate, renderCalibration, calibrateWith, bootstrapKappa)
import Crucible.LLM.Anthropic (AnthropicConfig(..), AnthropicError(..), isRetryable, defaultAnthropicConfig, chatRequestJson, parseTurn, parseUsage, turnContentJson)
import qualified Crucible.LLM.Anthropic as Anthropic
import Crucible.LLM.OpenAI (OpenAIError(..), defaultOpenAIConfig)
import qualified Crucible.LLM.OpenAI as OpenAI
import qualified Crucible.LLM.OpenAI.Stream as OS
import qualified Crucible.Chat as Chat
import Crucible.Chat
  (converse, runChatScripted, runToolAgent, runToolAgentN, Turn(..), Block(..), ToolUse(..), ChatError(..))
import Crucible.Emit (emit, runEmitList, ignoreEmit)
import Crucible.Rows (splitRows, runRows)
import Crucible.Usage (Usage(..), usTotalTokens, Rates(..), estimateCost)
import qualified Data.ByteString.Char8 as BC
import Control.Concurrent (threadDelay)
import Control.Exception (try, throwIO, fromException, SomeException, SomeAsyncException (..))
import Crucible.LLM.Anthropic.Stream
  (splitFrames, StreamEvent(..), parseEvent, StreamAcc(..), emptyAcc, stepAcc, timedRead)
import Data.List (foldl')
import qualified Data.List
import Data.IORef (IORef, newIORef, modifyIORef', readIORef)
import Crucible.LLM.Provider (Provider (..))
import qualified Crucible.LLM.Fallback as Fallback
import Crucible.Eval.Metrics (normMatch, tokenF1, rougeL)

-- Sample types for codec tests

data Sky = Clear | Cloudy | Storm deriving (Eq, Show, Generic)

instance HasCodec Sky where codec = genericCodec

data Forecast = Forecast { city :: Text, tempC :: Double, rainy :: Bool } deriving (Eq, Show, Generic)

instance HasCodec Forecast where codec = genericCodec

forecastCodec :: JSONCodec Forecast
forecastCodec = C.object $
  Forecast
    <$> C.field "city"  city  C.str
    <*> C.field "tempC" tempC C.float
    <*> C.field "rainy" rainy C.bool

data Station = Station { name :: Text, latest :: Forecast, conditions :: Sky }
  deriving (Eq, Show, Generic)
instance HasCodec Station where codec = genericCodec

-- crucible-1im: a record with an optional field, for required-list assertions
data OptRec = OptRec { reqF :: Text, optF :: Maybe Int }
  deriving (Eq, Show, Generic)
instance HasCodec OptRec where codec = genericCodec

stationVal :: Station
stationVal = Station "Eagle Farm" (Forecast "Brisbane" 26.0 False) Cloudy

-- Sample types for M6 tests
data ToolCall = GetWeather Text | AddNums Int Int deriving (Eq, Show)
newtype Answer = Answer Text deriving (Eq, Show)

-- Sample type for type-driven tool constructor test
data Loc = Loc { locCity :: Text } deriving (Show, Generic)
instance HasCodec Loc where codec = genericCodec

-- crucible typed-tool overhaul: record toolbox fixture
data DemoBox es = DemoBox
  { demo_weather :: Loc -> Eff es Text
  , demo_time    :: Eff es Text
  } deriving (Generic)

demoBox :: DemoBox es
demoBox = DemoBox
  { demo_weather = \(Loc c) -> pure ("sunny in " <> c)
  , demo_time    = pure "noon"
  }

-- crucible-3sj: fake providers for fallback tests (count invocations)
goodProvider :: Text -> IORef Int -> Text -> Provider
goodProvider nm c out = Provider nm
  (\_ -> modifyIORef' c (+ 1) >> pure (out, Usage 1 2))
  (\_ _ -> modifyIORef' c (+ 1) >> pure (Turn out [], Usage 1 2))

badProvider :: Text -> IORef Int -> Provider
badProvider nm c = Provider nm
  (\_ -> modifyIORef' c (+ 1) >> ioError (userError "down"))
  (\_ _ -> modifyIORef' c (+ 1) >> ioError (userError "down"))

-- M12 Task 3: runToolAgent fixture
-- Tool's schema field is an aeson Value (JSON Schema object)
weatherToolSchema :: A.Value
weatherToolSchema = A.object
  [ "type" A..= A.String "object"
  , "properties" A..= A.object
      [ "city" A..= A.object [ "type" A..= A.String "string" ] ]
  , "required" A..= A.toJSON [A.String "city"]
  ]

weatherToolC :: Tl.Tool es
weatherToolC = Tl.rawTool "get_weather" weatherToolSchema (\_ -> pure (A.String "Sunny in Brisbane!"))

-- M11 Task 1: Crucible.Skill fixtures
classifyFn :: Skill T.Text T.Text
classifyFn = skill "classify" C.str C.str (\s -> "Classify the sentiment of: " <> s)

-- M7 Task 2: agent test helpers — the effectful agent runs over the LLM + Tools
-- effects, dispatching tools by name from a toolbox via the Tools effect.
agentCodec :: JSONCodec (Decision Tl.ToolCall Text)
agentCodec = decisionCodec Tl.toolCallCodec (C.object (C.field "answer" id C.str))

agentTools :: [Tl.Tool es]
agentTools =
  [ Tl.rawTool "get_weather" weatherToolSchema $ \args ->
      pure $ case AT.parseMaybe (A.withObject "" (\o -> o A..: "city")) args of
               Just c  -> A.String ("sunny in " <> c)
               Nothing -> A.String "unknown city"
  , Tl.rawTool "add" (A.object
        [ "type" A..= A.String "object"
        , "properties" A..= A.object
            [ "a" A..= A.object [ "type" A..= A.String "number" ]
            , "b" A..= A.object [ "type" A..= A.String "number" ] ]
        , "required" A..= A.toJSON [A.String "a", A.String "b"] ]) $ \args ->
      pure $ case AT.parseMaybe (\v -> A.withObject "" (\o -> (,) <$> o A..: "a" <*> o A..: "b") v) args of
               Just (a, b) -> A.String (Data.Text.pack (show (a + b :: Int)))
               Nothing     -> A.String "bad args"
  ]

runAgentScripted :: [Text] -> JSONCodec (Decision Tl.ToolCall Text) -> Text -> Text
runAgentScripted replies codec q =
  runPureEff . runTools agentTools . runLLMScripted replies
    $ runAgent codec (startAgent codec q)

agentRun :: Text
agentRun = runAgentScripted
  [ "{\"tool\":\"get_weather\",\"args\":{\"city\":\"Brisbane\"}}"
  , "{\"answer\":\"It is sunny in Brisbane\"}" ]
  agentCodec "What's the weather in Brisbane?"

-- Build an SSE frame ("data: <json>") as a ByteString from a Value.
sseFrame :: Value -> BC.ByteString
sseFrame v = LBS.toStrict (LBS.fromStrict "data: " <> A.encode v)

-- Assemble a full SSE body (frames joined by blank lines, trailing blank line).
sseBody :: [Value] -> BC.ByteString
sseBody vs = BC.intercalate "\n\n" (map (\v -> "data: " <> LBS.toStrict (A.encode v)) vs) <> "\n\n"

-- Run a full body through the pure core to a final StreamAcc.
runBody :: BC.ByteString -> StreamAcc
runBody body = let (frames, _) = splitFrames body
               in foldl' stepAcc emptyAcc (map parseEvent frames)

-- crucible-39v: a row codec for the JSONL streaming tests
rowCodec :: JSONCodec Int
rowCodec = C.object (C.field "n" id C.int)

-- Helper: extract the "type" field from a JSON Schema Value (for robust schema checks).
schemaType :: Value -> Maybe Value
schemaType v = AT.parseMaybe (A.withObject "" (\o -> o A..: "type")) v

-- | Encode a value via its codec to aeson Value.
encodeVia :: JSONCodec a -> a -> Value
encodeVia c = toJSONVia c

-- | Decode a value from an aeson Value via its codec.
decodeVia :: JSONCodec a -> Value -> Either String a
decodeVia c v = AT.parseEither (parseJSONVia c) v

main :: IO ()
main = runChecks
  [ check "harness self-test" (2 + 2 :: Int) 4
  -- Task 3 Step 4: parse/encode replaced by aeson round-trip sanity
  , check "aeson round-trip null"   (Just Null)             (A.decode "null")
  , check "aeson round-trip bool"   (Just (Bool True))      (A.decode "true")
  , check "aeson round-trip number" (Just (Number 27.5))    (A.decode "27.5")
  , check "aeson round-trip string" (Just (String "hi"))    (A.decode "\"hi\"")
  , check "aeson round-trip array"
      (Just (Array (V.fromList [Number 1, Number 2])))
      (A.decode "[1, 2]")
  , check "aeson round-trip object"
      (Just (object ["a" .= Number 1, "b" .= Bool False]))
      (A.decode "{ \"a\": 1, \"b\": false }" :: Maybe Value)
  , check "aeson round-trip nested"
      (Just (object ["xs" .= Array (V.fromList [String "y"])]))
      (A.decode "{\"xs\":[\"y\"]}" :: Maybe Value)
  , check "aeson encode compact"
      "{\"a\":1,\"b\":[true,null]}"
      (A.encode (object ["a" .= Number 1, "b" .= Array (V.fromList [Bool True, Null])]))
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
  , check "decodeLLM: malformed reply -> Left DecodeError carrying the raw text"
      (Left True)
      (case decodeLLM C.str "not json at all" of
         Left e  -> Left (e.raw == "not json at all")
         Right _ -> Right ())
  -- Codec round-trip: primitives
  , check "codec encode str"  (String "hello")  (encodeVia C.str "hello")
  , check "codec decode str"  (Right "hello")   (decodeVia C.str (String "hello"))
  , check "codec encode int"  (Number 5)        (encodeVia C.int (5 :: Int))
  , check "codec decode bool" (Right True)      (decodeVia C.bool (Bool True))
  , check "codec encode float" (Number 1.5)     (encodeVia C.float (1.5 :: Double))
  -- list' round-trip
  , check "list encode"
      (Array (V.fromList [Number 1.0, Number 2.0]))
      (encodeVia (C.list' C.float) [1, 2])
  , check "list decode"
      (Right [1,2,3 :: Int])
      (decodeVia (C.list' C.int) (Array (V.fromList [Number 1, Number 2, Number 3])))
  -- nullable' round-trip
  , check "nullable encode Nothing"
      Null
      (encodeVia (C.nullable' C.str) Nothing)
  , check "nullable encode Just"
      (String "x")
      (encodeVia (C.nullable' C.str) (Just "x"))
  , check "nullable decode Nothing"
      (Right Nothing)
      (decodeVia (C.nullable' C.str) Null)
  -- enum round-trip (hand-written, lowercase tags)
  , check "enum encode"  (String "storm")  (encodeVia (C.enum [("clear", Clear), ("cloudy", Cloudy), ("storm", Storm)]) Storm)
  , check "enum decode"  (Right Cloudy)    (decodeVia (C.enum [("clear", Clear), ("cloudy", Cloudy), ("storm", Storm)]) (String "cloudy"))
  , check "enum decode bad" True
      (either (const True) (const False)
        (decodeVia (C.enum [("clear", Clear), ("cloudy", Cloudy), ("storm", Storm)]) (String "nope")))
  -- Schema shape: object codec produces a JSON Schema with type=object (robust check)
  , check "schema shape: forecastCodec is object"
      (Just (String "object"))
      (schemaType (schemaValue forecastCodec))
  , check "schema shape: list' codec is array"
      (Just (String "array"))
      (schemaType (schemaValue (C.list' C.str)))
  , check "schema shape: nullable' codec has nullable structure"
      True
      (case schemaValue (C.nullable' C.str) of
         Object _ -> True
         _        -> False)
  , check "schema shape: str codec is string"
      (Just (String "string"))
      (schemaType (schemaValue C.str))
  -- Forecast record round-trip via hand-written codec
  , check "record encode"
      (object ["city" .= String "Brisbane", "tempC" .= Number 27.5, "rainy" .= Bool False])
      (encodeVia forecastCodec (Forecast "Brisbane" 27.5 False))
  , check "record decode"
      (Right (Forecast "Brisbane" 27.5 False))
      (decodeVia forecastCodec
        (object ["city" .= String "Brisbane", "tempC" .= Number 27.5, "rainy" .= Bool False]))
  , check "record round-trips"
      (Right (Forecast "Hobart" 9.0 True))
      (decodeVia forecastCodec (encodeVia forecastCodec (Forecast "Hobart" 9.0 True)))
  -- HasCodec instances
  , check "HasCodec Text encode"   (String "hi") (toJSONVia (codec :: JSONCodec Text) "hi")
  , check "HasCodec Int encode"    (Number 7)    (toJSONVia (codec :: JSONCodec Int) 7)
  , check "HasCodec Bool encode"   (Bool True)   (toJSONVia (codec :: JSONCodec Bool) True)
  , check "HasCodec [Bool] schema is array"
      (Just (String "array"))
      (schemaType (schemaValue (codec :: JSONCodec [Bool])))
  , check "HasCodec Maybe schema has structure"
      True
      (case schemaValue (codec :: JSONCodec (Maybe Double)) of
         Object _ -> True
         Array  _ -> True
         _        -> False)
  -- Derived record (via genericCodec) round-trips
  , check "derived Forecast round-trips"
      (Right (Forecast "Cairns" 31.0 True))
      (decodeVia (codec :: JSONCodec Forecast)
                 (toJSONVia (codec :: JSONCodec Forecast) (Forecast "Cairns" 31.0 True)))
  , check "derived Forecast schema is object"
      (Just (String "object"))
      (schemaType (schemaValue (codec :: JSONCodec Forecast)))
  -- Derived enum Sky (constructor names, capitalised)
  , check "derived Sky encode"  (String "Storm")   (toJSONVia (codec :: JSONCodec Sky) Storm)
  , check "derived Sky decode"  (Right Cloudy)
      (AT.parseEither (parseJSONVia (codec :: JSONCodec Sky)) (String "Cloudy"))
  , check "derived Sky schema is string (enum)"
      (Just (String "string"))
      (schemaType (schemaValue (codec :: JSONCodec Sky)))
  -- crucible-1im: Maybe fields drop out of the schema's required list
  , check "generic schema: Maybe field dropped from required"
      (Just ["reqF"])
      (AT.parseMaybe (A.withObject "" (\o -> o A..: "required"))
         (schemaValue (codec :: JSONCodec OptRec)) :: Maybe [Text])
  , check "generic codec: present and absent optional field decode"
      (Right (OptRec "x" Nothing), Right (OptRec "x" (Just 3)))
      ( ( decodeVia (codec :: JSONCodec OptRec) (object ["reqF" .= String "x"])
        , decodeVia (codec :: JSONCodec OptRec) (object ["reqF" .= String "x", "optF" .= Number 3]) ) )
  , check "generic codec: explicit null decodes as Nothing"
      (Right (OptRec "x" Nothing))
      (decodeVia (codec :: JSONCodec OptRec) (object ["reqF" .= String "x", "optF" .= Null]))
  -- Nested derived Station round-trips
  , check "nested Station schema is object"
      (Just (String "object"))
      (schemaType (schemaValue (codec :: JSONCodec Station)))
  , check "nested Station round-trips"
      (Right stationVal)
      (decodeVia (codec :: JSONCodec Station)
                 (toJSONVia (codec :: JSONCodec Station) stationVal))
  -- M6 Task 1: Decision + decisionCodec
  , check "decode tool-call -> CallTool"
      (Right (CallTool (Tl.ToolCall "get_weather" (object ["city" .= String "Brisbane"]))))
      (decodeLLM (decisionCodec Tl.toolCallCodec (C.object (C.field "answer" id C.str)))
        "{\"tool\":\"get_weather\",\"args\":{\"city\":\"Brisbane\"}}")
  , check "decode answer -> Done"
      (Right (Done "all set" :: Decision Tl.ToolCall Text))
      (decodeLLM (decisionCodec Tl.toolCallCodec (C.object (C.field "answer" id C.str)))
        "{\"answer\":\"all set\"}")
  -- M6 Task 2: Step + reduce
  , check "reduce CallTool -> Continue"
      (Continue (Tl.ToolCall "get_weather" (object ["city" .= String "Brisbane"])))
      (reduce (CallTool (Tl.ToolCall "get_weather" (object ["city" .= String "Brisbane"])) :: Decision Tl.ToolCall Text))
  , check "reduce Done -> Halt"
      (Halt "all set" :: Step Tl.ToolCall Text)
      (reduce (Done "all set" :: Decision Tl.ToolCall Text))
  -- M7 Task 1: LLM effect + scripted interpreter
  , check "scripted pops canned replies in order"
      ["a", "b"]
      (runPureEff (runLLMScripted ["a", "b"]
        ((do x <- complete ([] :: [Message]); y <- complete ([] :: [Message]); pure [x, y]) :: Eff '[LLM] [Text])))
  -- M7 Task 2: agent control loop (over LLM + Tools effects)
  , check "agent loops tool->answer to a final Answer"
      "It is sunny in Brisbane" agentRun
  , check "agent halts immediately on a Done reply"
      "hi"
      (runAgentScripted ["{\"answer\":\"hi\"}"] agentCodec "say hi")
  -- M9 Task 1: Crucible.Tool
  , check "toolCallCodec decodes name+args"
      (Right (Tl.ToolCall "get_weather" (object ["city" .= String "Hobart"])))
      (decodeVia Tl.toolCallCodec
        (object ["tool" .= String "get_weather", "args" .= object ["city" .= String "Hobart"]]))
  , check "toolsHelp lists tools"
      "- echo(args: {\"properties\":{\"msg\":{\"type\":\"string\"}},\"required\":[\"msg\"],\"type\":\"object\"})"
      (Tl.toolsHelp [Tl.rawTool "echo" (A.object
          [ "type" A..= A.String "object"
          , "properties" A..= A.object ["msg" A..= A.object ["type" A..= A.String "string"]]
          , "required" A..= A.toJSON [A.String "msg"] ]) (\_ -> pure Null)])
  , check "tool: type-driven constructor derives object schema + decodes args"
      (Just (String "object"), Right (A.String "sunny in Hobart"))
      ( let t = Tl.tool @"weather" (\(Loc c) -> pure ("sunny in " <> c :: Text)) :: Tl.Tool '[]
        in ( schemaType t.schema
           , runPureEff (Tl.invoke t (object ["locCity" .= String "Hobart"])) ) )
  , check "tool: bad args yield Left BadArgs (schema attached, raw echoed)"
      (Just True)
      ( let t = Tl.tool @"weather" (\(Loc c) -> pure ("sunny in " <> c :: Text)) :: Tl.Tool '[]
        in case runPureEff (Tl.invoke t (object [])) of
             Left (Tl.BadArgs n e sch) ->
               Just (n == "weather" && sch == t.schema && e.raw == "{}")
             _ -> Nothing )
  , check "runTools: unknown tool -> Left UnknownTool with available names"
      (Left (Tl.UnknownTool "nope" ["get_weather", "add"]))
      (runPureEff (Tl.runTools agentTools (Tl.callTool "nope" (object []))))
  , check "renderToolError: BadArgs includes schema and echoed args"
      True
      ( let t = Tl.tool @"weather" (\(Loc c) -> pure ("sunny in " <> c :: Text)) :: Tl.Tool '[]
        in case runPureEff (Tl.invoke t (object ["city" .= String "x"])) of
             Left err ->
               let r = Tl.renderToolError err
               in T.isInfixOf "expected schema:" r
                    && T.isInfixOf "you sent:" r
                    && T.isInfixOf "locCity" r
                    && T.isInfixOf "\"city\":\"x\"" r
             Right _ -> False )
  , check "renderToolError: UnknownTool lists available names"
      True
      (T.isInfixOf "available tools: get_weather, add"
        (Tl.renderToolError (Tl.UnknownTool "nope" ["get_weather", "add"])))
  , check "runToolAgent: bad args fed back, model self-corrects (scripted)"
      (Right "fixed")
      (runPureEff (runChatScripted
        [ Turn "" [ToolUse "u1" "typed_weather" (object ["wrong" .= String "x"])]
        , Turn "fixed" [] ]
        (runToolAgent
          [Tl.tool @"typed_weather" (\(Loc c) -> pure ("sunny in " <> c :: Text))]
          "weather?")))
  , check "float codec: clean shortest-decimal encoding (not realToFrac bloat)"
      "0.1"
      (A.encode (toJSONVia C.float (0.1 :: Double)))
  -- M9 Task 3: Crucible.Example end-to-end agent
  , check "example agent: tool (get_weather) then answer"
      "sunny in Brisbane"
      (demoAgent [ "{\"tool\":\"get_weather\",\"args\":{\"city\":\"Brisbane\"}}"
                 , "{\"answer\":\"sunny in Brisbane\"}" ])
  , check "example agent: add tool then answer"
      "the sum is 7"
      (demoAgent [ "{\"tool\":\"add\",\"args\":{\"a\":3,\"b\":4}}"
                 , "{\"answer\":\"the sum is 7\"}" ])
  , check "example agent: direct answer (no tool)"
      "hello there"
      (demoAgent [ "{\"answer\":\"hello there\"}" ])
  -- M10 Task 1: Eval harness — exact/predicate/runEval/report
  , check "eval: all pass (exact + predicate)"
      (1.0, 1.0)
      (let rep = runPureEff (runLLMScripted [] (runEval id (pure . Data.Text.toUpper)
                   [ Case "abc" "upper" (Exactly "ABC")
                   , Case "xy"  "nonempty" (Predicate (not . Data.Text.null)) ]))
       in (rep.passRate, rep.meanScore))
  , check "eval: detects a mismatch"
      0.0
      ((runPureEff (runLLMScripted []
        (runEval id (pure . Data.Text.toUpper) [Case "abc" "wrong" (Exactly "abc")]))).passRate)
  , check "eval: report renders per-case + summary"
      True
      (Data.Text.isInfixOf "pass-rate:" (renderReport (runPureEff (runLLMScripted []
        (runEval id (pure . Data.Text.toUpper) [Case "abc" "c" (Exactly "ABC")])))))
  -- M10 Task 2: LLM-as-judge (Rubric) on scripted data
  , check "eval: LLM-as-judge passes a rubric (scripted verdict)"
      (1.0, "looks like a greeting")
      (let rep = runPureEff (runLLMScripted ["{\"pass\":true,\"why\":\"looks like a greeting\"}"]
                   (runEval id (pure . id) [Case "hi" "greeting" (Rubric "must be a greeting")]))
       in (rep.passRate, (head rep.results).score.rationale))
  , check "eval: LLM-as-judge fails a rubric (scripted verdict)"
      0.0
      ((runPureEff (runLLMScripted ["{\"pass\":false,\"why\":\"not a greeting\"}"]
        (runEval id (pure . id) [Case "42" "greeting" (Rubric "must be a greeting")]))).passRate)
  -- effectful capability manifest: agent runs end-to-end through interpreters
  , check "effectful agent: tool then answer"
      "sunny in Brisbane"
      (demoAgent [ "{\"tool\":\"get_weather\",\"args\":{\"city\":\"Brisbane\"}}"
                 , "{\"answer\":\"sunny in Brisbane\"}" ])
  -- M11 Task 1: Crucible.Skill — Skill + single-shot call + prompt
  , check "skill: happy path decodes the reply"
      (Right "positive")
      (runPureEff (runLLMScripted ["\"positive\""] (call classifyFn "I love it")))
  , check "skill: single bad reply -> Left"
      True
      (either (const True) (const False)
        (runPureEff (runLLMScripted ["not json"] (call (withRetries 0 classifyFn) "x"))))
  , check "skill: name is stored" "classify" classifyFn.name
  , check "prompt: system message carries the output schema"
      True
      (case prompt classifyFn "hi" of
         (Message System s : _) ->
           T.isPrefixOf "Respond ONLY with JSON" s
             && T.isInfixOf (schemaText classifyFn.output) s
         _ -> False)
  , check "prompt: user message carries instruction + rendered input"
      True
      (case prompt classifyFn "hi" of
         (_ : Message User u : _) ->
           T.isInfixOf "Classify the sentiment of: hi" u && T.isInfixOf "\"hi\"" u
         _ -> False)
  -- prompt composition: few-shot examples
  , check "prompt: example renders as a User/Assistant pair"
      (4, Just (Message Assistant "\"positive\""), True)
      (let sk = withExamples [("I love it", "positive")] classifyFn
           msgs = prompt sk "meh"
       in ( length msgs
          , case msgs of (_ : _ : a : _) -> Just a; _ -> Nothing
          , case msgs of
              (_ : Message User u : _) ->
                T.isInfixOf "Classify the sentiment of: I love it" u
                  && T.isInfixOf "\"I love it\"" u
              _ -> False ))
  , check "prompt: zero examples keeps the two-message shape"
      2
      (length (prompt classifyFn "hi"))
  , check "examplesFromTests: moves Exactly cases, keeps the rest"
      (1, 2)
      (let sk = examplesFromTests 1
                  (withTests [ Case "a" "t1" (Exactly "A")
                             , Case "b" "t2" (Rubric "r")
                             , Case "c" "t3" (Exactly "C") ] classifyFn)
       in (length sk.examples, length sk.tests))
  , check "examplesFromTests: caps at available; zero moves nothing"
      ((2, 1), (0, 3))
      (let base = withTests [ Case "a" "t1" (Exactly "A")
                            , Case "b" "t2" (Rubric "r")
                            , Case "c" "t3" (Exactly "C") ] classifyFn
           big  = examplesFromTests 5 base
           zero = examplesFromTests 0 base
       in ((length big.examples, length big.tests), (length zero.examples, length zero.tests)))
  , check "call: exampled skill still decodes"
      (Right "positive")
      (runPureEff (runLLMScripted ["\"positive\""]
        (call (withExamples [("I love it", "positive")] classifyFn) "meh")))
  -- crucible-2ce: reasoning-field convention
  , check "withReasoning: decodes the result field, discards reasoning"
      (Right "positive")
      (runPureEff (runLLMScripted
        ["{\"reasoning\":\"the review is glowing\",\"result\":\"positive\"}"]
        (call (withReasoning classifyFn) "I love it")))
  , check "withReasoning: schema requires reasoning and result"
      (Just ["reasoning", "result"])
      (fmap Data.List.sort
        (AT.parseMaybe (A.withObject "" (\o -> o A..: "required"))
           (schemaValue (withReasoning classifyFn).output) :: Maybe [Text]))
  , check "withReasoning: bare reply fails decode, retry recovers"
      (Right "positive")
      (runPureEff (runLLMScripted
        [ "\"positive\""
        , "{\"reasoning\":\"second try\",\"result\":\"positive\"}" ]
        (call (withReasoning classifyFn) "I love it")))
  , check "testSkill: moved cases consume no replies"
      (1.0, "leftover")
      (runPureEff (runLLMScripted ["\"B\"", "leftover"]
        (do rep <- testSkill id (examplesFromTests 1
                     (withTests [ Case "a" "ex" (Exactly "A")
                                , Case "b" "kept" (Exactly "B") ] classifyFn))
            extra <- complete []
            pure (rep.passRate, extra))))
  , check "skill: retries on a bad reply then succeeds"
      (Right "positive")
      (runPureEff (runLLMScripted ["not json", "\"positive\""] (call classifyFn "I love it")))
  , check "skill: exhausts retries -> Left"
      True
      (either (const True) (const False)
        (runPureEff (runLLMScripted ["bad", "bad"] (call (withRetries 1 classifyFn) "x"))))
  -- crucible-290: BAML-style test cases attached to a skill
  , check "testSkill: attached case passes on exact match"
      (1.0, 1.0)
      (let sk = withTests [Case "I love it" "pos" (Exactly "positive")] classifyFn
           rep = runPureEff (runLLMScripted ["\"positive\""] (testSkill id sk))
       in (rep.passRate, rep.meanScore))
  , check "testSkill: attached case fails on mismatch"
      0.0
      ((runPureEff (runLLMScripted ["\"negative\""]
        (testSkill id (withTests [Case "I love it" "pos" (Exactly "positive")] classifyFn)))).passRate)
  , check "testSkill: decode failure scores zero"
      0.0
      ((runPureEff (runLLMScripted ["junk"]
        (testSkill id (withTests [Case "x" "robust" (Predicate (const True))]
                        (withRetries 0 classifyFn))))).passRate)
  , check "testSkill: rubric case consults the judge"
      1.0
      ((runPureEff (runLLMScripted
        [ "\"hello there\""                                  -- the skill's reply
        , "{\"pass\":true,\"why\":\"greets the user\"}" ]    -- the judge's verdict
        (testSkill id (withTests [Case "hi" "greets" (Rubric "must be a greeting")] classifyFn)))).passRate)
  -- M12 Task 1: schemaValue shape checks (robust — autodocodec schema shape may differ)
  , check "schemaValue: object codec has type=object"
      (Just (String "object"))
      (schemaType (schemaValue forecastCodec))
  , check "schemaValue: list codec has type=array"
      (Just (String "array"))
      (schemaType (schemaValue (C.list' C.str)))
  , check "schemaValue: str codec has type=string"
      (Just (String "string"))
      (schemaType (schemaValue C.str))
  -- live-path-robustness Task 2: AnthropicError + isRetryable
  , check "isRetryable: 429"        True  (isRetryable (AnthropicStatusError 429 ""))
  , check "isRetryable: 500"        True  (isRetryable (AnthropicStatusError 500 ""))
  , check "isRetryable: 503"        True  (isRetryable (AnthropicStatusError 503 ""))
  , check "isRetryable: 400"        False (isRetryable (AnthropicStatusError 400 ""))
  , check "isRetryable: 401"        False (isRetryable (AnthropicStatusError 401 ""))
  , check "isRetryable: 404"        False (isRetryable (AnthropicStatusError 404 ""))
  , check "isRetryable: no-content" False (isRetryable (AnthropicNoContent ""))
  -- crucible-mgs: stream idle timeout config + error
  , check "config: default stream idle is 60s"
      (60 :: Int)
      ((defaultAnthropicConfig "k").streamIdleSecs)
  , check "isRetryable: stream timeout is not retryable"
      False
      (isRetryable (AnthropicStreamTimeout 1000))
  -- M12 Task 2: Chat effect + block types + scripted interpreter
  , check "runChatScripted: pops the canned turn"
      (Turn "hello" [])
      (runPureEff (runChatScripted [Turn "hello" []]
        (converse [] [Chat.Message User [TextBlock "hi"]])))
  -- M12 Task 3: runToolAgent loop
  , check "runToolAgent: runs the tool, then returns final text"
      (Right "Sunny in Brisbane!")
      (runPureEff (runChatScripted
        [ Turn "" [ToolUse "u1" "get_weather" (object ["city" .= String "Brisbane"])]
        , Turn "Sunny in Brisbane!" [] ]
        (runToolAgent [weatherToolC] "weather in Brisbane?")))
  , check "runToolAgent: unknown tool fed back, then answers"
      (Right "done")
      (runPureEff (runChatScripted
        [ Turn "" [ToolUse "u1" "nonesuch" (object [])]
        , Turn "done" [] ]
        (runToolAgent [weatherToolC] "x")))
  , check "runToolAgent: exhausts the iteration cap -> Left"
      (Left (ToolLoopExceeded 10))
      (runPureEff (runChatScripted
        (replicate 20 (Turn "" [ToolUse "u" "get_weather" (object [])]))
        (runToolAgent [weatherToolC] "x")))
  , check "runToolAgentN: custom cap is honoured and reported"
      (Left (ToolLoopExceeded 2))
      (runPureEff (runChatScripted
        (replicate 20 (Turn "" [ToolUse "u" "get_weather" (object [])]))
        (runToolAgentN 2 [weatherToolC] "x")))
  -- A#4: Usage Monoid + cost helper
  , check "usage: semigroup sums fields"
      (Usage 4 6)
      (Usage 1 2 <> Usage 3 4)
  , check "usage: mempty is left identity"
      (Usage 5 9)
      (mempty <> Usage 5 9)
  , check "usage: mempty is right identity"
      (Usage 5 9)
      (Usage 5 9 <> mempty)
  , check "usage: total tokens"
      (14 :: Int)
      (usTotalTokens (Usage 5 9))
  , check "estimateCost: per-MTok rates"
      (18.0 :: Double)
      (estimateCost (Rates 3 15) (Usage 1000000 1000000))
  -- M12 Task 5: chatRequestJson + parseTurn
  , check "parseTurn: text + tool_use"
      (Right (Turn "Let me check."
                [ToolUse "tu_1" "get_weather" (object ["city" .= String "Brisbane"])]))
      (parseTurn "{\"content\":[{\"type\":\"text\",\"text\":\"Let me check.\"},{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"get_weather\",\"input\":{\"city\":\"Brisbane\"}}]}")
  , check "chatRequestJson: tools + message blocks"
      (A.object
        [ "model" .= String "claude-haiku-4-5-20251001"
        , "max_tokens" .= Number 1024
        , "tools" .= Array (V.fromList
            [ A.object [ "name" .= String "get_weather"
                       , "input_schema" .= A.object
                           [ "type" .= String "object"
                           , "properties" .= A.object ["city" .= A.object ["type" .= String "string"]]
                           , "required" .= A.toJSON [String "city"] ] ] ])
        , "messages" .= Array (V.fromList
            [ A.object [ "role" .= String "user"
                       , "content" .= Array (V.fromList [A.object ["type" .= String "text", "text" .= String "hi"]])] ]) ])
      (chatRequestJson (defaultAnthropicConfig "k")
        [("get_weather", A.object
            [ "type" .= String "object"
            , "properties" .= A.object ["city" .= A.object ["type" .= String "string"]]
            , "required" .= A.toJSON [String "city"] ])]
        [Chat.Message User [TextBlock "hi"]])
  -- A#4: parseUsage
  , check "parseUsage: reads input/output tokens"
      (Usage 12 7)
      (parseUsage "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"usage\":{\"input_tokens\":12,\"output_tokens\":7}}")
  , check "parseUsage: missing usage -> mempty"
      (mempty :: Usage)
      (parseUsage "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}")
  , check "parseUsage: malformed token field -> mempty"
      (mempty :: Usage)
      (parseUsage "{\"usage\":{\"input_tokens\":\"twelve\",\"output_tokens\":7}}")
  -- A#3: Emit effect
  , check "emit: runEmitList collects in order"
      (((), ["a", "b"]) :: ((), [T.Text]))
      (runPureEff (runEmitList (emit "a" >> emit "b")))
  , check "emit: ignoreEmit discards, preserves result"
      (42 :: Int)
      (runPureEff (ignoreEmit (emit "x" >> emit "y" >> pure (42 :: Int))))
  -- A#3: splitFrames
  , check "splitFrames: splits complete frames, keeps remainder"
      ([BC.pack "A", BC.pack "B"], BC.pack "part")
      (splitFrames (BC.pack "A\n\nB\n\npart"))
  , check "splitFrames: no blank line -> all remainder"
      ([], BC.pack "noblank")
      (splitFrames (BC.pack "noblank"))
  , check "splitFrames: trailing delimiter -> non-empty frames, empty remainder"
      ([BC.pack "A", BC.pack "B"], BC.pack "")
      (splitFrames (BC.pack "A\n\nB\n\n"))
  -- A#3: parseEvent
  , check "parseEvent: text_delta -> EvText"
      (EvText "Hello")
      (parseEvent (sseFrame (object
        [ "type" .= String "content_block_delta", "index" .= Number 0
        , "delta" .= object ["type" .= String "text_delta", "text" .= String "Hello"] ])))
  , check "parseEvent: message_start -> EvUsageIn"
      (EvUsageIn 25)
      (parseEvent (sseFrame (object
        [ "type" .= String "message_start"
        , "message" .= object ["usage" .= object ["input_tokens" .= Number 25, "output_tokens" .= Number 1]] ])))
  , check "parseEvent: message_delta -> EvUsageOut"
      (EvUsageOut 7)
      (parseEvent (sseFrame (object
        [ "type" .= String "message_delta", "delta" .= object []
        , "usage" .= object ["output_tokens" .= Number 7] ])))
  , check "parseEvent: tool_use start -> EvToolStart"
      (EvToolStart 0 "tu_1" "get_weather")
      (parseEvent (sseFrame (object
        [ "type" .= String "content_block_start", "index" .= Number 0
        , "content_block" .= object ["type" .= String "tool_use", "id" .= String "tu_1", "name" .= String "get_weather", "input" .= object []] ])))
  , check "parseEvent: input_json_delta -> EvToolJson"
      (EvToolJson 0 "{\"city\":")
      (parseEvent (sseFrame (object
        [ "type" .= String "content_block_delta", "index" .= Number 0
        , "delta" .= object ["type" .= String "input_json_delta", "partial_json" .= String "{\"city\":"] ])))
  , check "parseEvent: unknown -> EvOther"
      EvOther
      (parseEvent (sseFrame (object ["type" .= String "ping"])))
  , check "parseEvent: content_block_stop -> EvBlockStop"
      (EvBlockStop 1)
      (parseEvent (sseFrame (object
        [ "type" .= String "content_block_stop", "index" .= Number 1 ])))
  -- A#3: stepAcc fold
  , check "stepAcc: text stream assembles text + usage"
      ("Hello", Usage 25 2)
      (let a = foldl' stepAcc emptyAcc [EvUsageIn 25, EvText "Hel", EvText "lo", EvUsageOut 2]
       in (a.text, a.usage))
  , check "stepAcc: tool stream reassembles tool_use args"
      ([ToolUse "tu_1" "get_weather" (object ["city" .= String "Brisbane"])], Usage 40 12)
      (let a = foldl' stepAcc emptyAcc
                 [ EvUsageIn 40
                 , EvToolStart 0 "tu_1" "get_weather"
                 , EvToolJson 0 "{\"city\":", EvToolJson 0 "\"Brisbane\"}"
                 , EvBlockStop 0, EvUsageOut 12 ]
       in (a.tools, a.usage))
  , check "stepAcc: interleaved tool blocks keep separate args"
      ([ ToolUse "tu_a" "alpha" (object ["x" .= Number 1])
       , ToolUse "tu_b" "beta"  (object ["y" .= Number 2]) ])
      (let a = foldl' stepAcc emptyAcc
                 [ EvToolStart 0 "tu_a" "alpha"
                 , EvToolStart 1 "tu_b" "beta"
                 , EvToolJson 0 "{\"x\":", EvToolJson 1 "{\"y\":"
                 , EvToolJson 0 "1}",      EvToolJson 1 "2}"
                 , EvBlockStop 0, EvBlockStop 1 ]
       in a.tools)
  -- A#3: keystone — full SSE body through the pure core
  , check "stream keystone: text response"
      ("Hello world", [], Usage 25 3)
      (let a = runBody (sseBody
                 [ object ["type" .= String "message_start", "message" .= object ["usage" .= object ["input_tokens" .= Number 25, "output_tokens" .= Number 1]]]
                 , object ["type" .= String "content_block_delta", "index" .= Number 0, "delta" .= object ["type" .= String "text_delta", "text" .= String "Hello"]]
                 , object ["type" .= String "content_block_delta", "index" .= Number 0, "delta" .= object ["type" .= String "text_delta", "text" .= String " world"]]
                 , object ["type" .= String "message_delta", "delta" .= object [], "usage" .= object ["output_tokens" .= Number 3]]
                 , object ["type" .= String "message_stop"] ])
       in (a.text, a.tools, a.usage))
  , check "stream keystone: tool_use response"
      ("", [ToolUse "tu_1" "get_weather" (object ["city" .= String "Brisbane"])], Usage 40 12)
      (let a = runBody (sseBody
                 [ object ["type" .= String "message_start", "message" .= object ["usage" .= object ["input_tokens" .= Number 40, "output_tokens" .= Number 1]]]
                 , object ["type" .= String "content_block_start", "index" .= Number 0, "content_block" .= object ["type" .= String "tool_use", "id" .= String "tu_1", "name" .= String "get_weather", "input" .= object []]]
                 , object ["type" .= String "content_block_delta", "index" .= Number 0, "delta" .= object ["type" .= String "input_json_delta", "partial_json" .= String "{\"city\":"]]
                 , object ["type" .= String "content_block_delta", "index" .= Number 0, "delta" .= object ["type" .= String "input_json_delta", "partial_json" .= String "\"Brisbane\"}"]]
                 , object ["type" .= String "content_block_stop", "index" .= Number 0]
                 , object ["type" .= String "message_delta", "delta" .= object [], "usage" .= object ["output_tokens" .= Number 12]] ])
       in (a.text, a.tools, a.usage))
  -- crucible-mgs: timedRead
  , do r <- timedRead 200000 (pure (BC.pack "hi"))
       check "timedRead: fast read passes through" (BC.pack "hi") r
  , do r <- try (timedRead 1000 (threadDelay 50000 >> pure (BC.pack "x")))
            :: IO (Either AnthropicError BC.ByteString)
       check "timedRead: idle timeout fires"
         (Just 1000)
         (case r of Left (AnthropicStreamTimeout n) -> Just (n :: Int); _ -> Nothing)
  , do r <- timedRead 0 (pure (BC.pack "x"))
       check "timedRead: non-positive disables the guard" (BC.pack "x") r
  -- crucible-dak: Turn JSON round-trip
  , check "turnContentJson: round-trips text + tool_use"
      (Right (Turn "Let me check." [ToolUse "tu_1" "get_weather" (object ["city" .= String "Brisbane"])]))
      (parseTurn (TE.decodeUtf8 (LBS.toStrict (A.encode (turnContentJson
        (Turn "Let me check." [ToolUse "tu_1" "get_weather" (object ["city" .= String "Brisbane"])])))))  )
  , check "turnContentJson: round-trips text-only"
      (Right (Turn "Hello." []))
      (parseTurn (TE.decodeUtf8 (LBS.toStrict (A.encode (turnContentJson (Turn "Hello." []))))))
  , check "turnContentJson: round-trips tool-only"
      (Right (Turn "" [ToolUse "u" "f" (object [])]))
      (parseTurn (TE.decodeUtf8 (LBS.toStrict (A.encode (turnContentJson (Turn "" [ToolUse "u" "f" (object [])]))))))
  -- crucible-39v: streaming JSONL rows over Emit
  , check "splitRows: completed lines + remainder"
      (["{\"n\":1}", "{\"n\":2}"], "{\"n\":")
      (splitRows "{\"n\":1}\n{\"n\":2}\n{\"n\":")
  , check "rows: deltas split across line boundaries decode as rows"
      ((), [Right 1, Right 2])
      (runPureEff (runRows rowCodec (emit "{\"n\":1}\n{\"n\"" >> emit ":2}\n")))
  , check "rows: trailing line without newline is flushed"
      ((), [Right 1, Right 2])
      (runPureEff (runRows rowCodec (emit "{\"n\":1}\n" >> emit "{\"n\":2}")))
  , check "rows: a bad line yields Left, later rows still decode"
      [False, True]
      (map (either (const False) (const True))
        (snd (runPureEff (runRows rowCodec (emit "garbage\n{\"n\":7}\n")))))
  , check "rows: blank lines are skipped"
      ((), [Right 5])
      (runPureEff (runRows rowCodec (emit "\n{\"n\":5}\n\n")))
  -- crucible-luz: OpenAI interpreter (pure wire-format coverage)
  , check "OpenAI requestJson: native system role + max_completion_tokens"
      (object
        [ "model" .= String "gpt-4o-mini"
        , "max_completion_tokens" .= Number 1024
        , "messages" .= A.toJSON
            [ object ["role" .= String "system", "content" .= String "Be terse."]
            , object ["role" .= String "user", "content" .= String "Ping?"]
            ]
        ])
      (OpenAI.requestJson (defaultOpenAIConfig "k")
        [Message System "Be terse.", Message User "Ping?"])
  , check "OpenAI extractText: choices[0].message.content"
      (Right "pong")
      (OpenAI.extractText "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"pong\"}}]}")
  , check "OpenAI parseUsage: prompt/completion tokens"
      (Usage 12 5)
      (OpenAI.parseUsage "{\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":5}}")
  , check "OpenAI parseUsage: missing usage -> mempty"
      mempty
      (OpenAI.parseUsage "{\"choices\":[]}")
  , check "OpenAI chatRequestJson: function-wrapped tools + flattened messages"
      (object
        [ "model" .= String "gpt-4o-mini"
        , "max_completion_tokens" .= Number 1024
        , "tools" .= A.toJSON
            [ object
                [ "type" .= String "function"
                , "function" .= object
                    ["name" .= String "get_weather", "parameters" .= weatherToolSchema]
                ]
            ]
        , "messages" .= A.toJSON
            [ object ["role" .= String "user", "content" .= String "weather?"]
            , object
                [ "role" .= String "assistant"
                , "content" .= Null
                , "tool_calls" .= A.toJSON
                    [ object
                        [ "id" .= String "call_1"
                        , "type" .= String "function"
                        , "function" .= object
                            [ "name" .= String "get_weather"
                            , "arguments" .= String "{\"city\":\"Brisbane\"}"
                            ]
                        ]
                    ]
                ]
            , object
                [ "role" .= String "tool"
                , "tool_call_id" .= String "call_1"
                , "content" .= String "sunny"
                ]
            ]
        ])
      (OpenAI.chatRequestJson (defaultOpenAIConfig "k")
        [("get_weather", weatherToolSchema)]
        [ Chat.Message User [TextBlock "weather?"]
        , Chat.Message Assistant
            [ToolUseBlock (ToolUse "call_1" "get_weather" (object ["city" .= String "Brisbane"]))]
        , Chat.Message User [ToolResultBlock "call_1" (String "sunny")]
        ])
  , check "OpenAI parseTurn: tool_calls with string-encoded arguments"
      (Right (Turn "" [ToolUse "call_1" "get_weather" (object ["city" .= String "Brisbane"])]))
      (OpenAI.parseTurn "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"{\\\"city\\\":\\\"Brisbane\\\"}\"}}]}}]}")
  , check "OpenAI parseTurn: text reply"
      (Right (Turn "hello" []))
      (OpenAI.parseTurn "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hello\"}}]}")
  , check "OpenAI parseTurn: undecodable arguments pass through as raw string"
      (Right (Turn "" [ToolUse "c" "f" (String "not json")]))
      (OpenAI.parseTurn "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"c\",\"function\":{\"name\":\"f\",\"arguments\":\"not json\"}}]}}]}")
  , check "OpenAI isRetryable: 429" True  (OpenAI.isRetryable (OpenAIStatusError 429 ""))
  , check "OpenAI isRetryable: 500" True  (OpenAI.isRetryable (OpenAIStatusError 500 ""))
  , check "OpenAI isRetryable: 400" False (OpenAI.isRetryable (OpenAIStatusError 400 ""))
  , check "OpenAI isRetryable: no-content" False (OpenAI.isRetryable (OpenAINoContent ""))
  , check "OpenAI isRetryable: stream timeout is not retryable"
      False (OpenAI.isRetryable (OpenAIStreamTimeout 1000))
  -- crucible-l5c: OpenAI streaming (pure core)
  , check "OpenAI stream: [DONE] sentinel"
      [OS.EvDone]
      (OS.parseEvents "data: [DONE]")
  , check "OpenAI stream: content delta"
      [OS.EvText "Hel"]
      (OS.parseEvents (sseFrame (object
        ["choices" .= A.toJSON [object ["delta" .= object ["content" .= String "Hel"]]]])))
  , check "OpenAI stream: tool_call first fragment carries id+name"
      [OS.EvToolDelta 0 (Just "call_1") (Just "get_weather") "{\"ci"]
      (OS.parseEvents (sseFrame (object
        ["choices" .= A.toJSON [object ["delta" .= object ["tool_calls" .= A.toJSON
          [object ["index" .= Number 0, "id" .= String "call_1",
                   "function" .= object ["name" .= String "get_weather", "arguments" .= String "{\"ci"]]]]]]])))
  , check "OpenAI stream: final usage chunk (empty choices)"
      [OS.EvUsage 40 12]
      (OS.parseEvents (sseFrame (object
        ["choices" .= A.toJSON ([] :: [Value]),
         "usage" .= object ["prompt_tokens" .= Number 40, "completion_tokens" .= Number 12]])))
  , check "OpenAI stream keystone: text + usage assemble"
      ("pong", Usage 27 4)
      (let body = sseBody
             [ object ["choices" .= A.toJSON [object ["delta" .= object ["content" .= String "po"]]]]
             , object ["choices" .= A.toJSON [object ["delta" .= object ["content" .= String "ng"]]]]
             , object ["choices" .= A.toJSON ([] :: [Value]),
                       "usage" .= object ["prompt_tokens" .= Number 27, "completion_tokens" .= Number 4]]
             ] <> "data: [DONE]\n\n"
           (frames, _) = splitFrames body
           a = foldl' OS.stepAcc OS.emptyAcc (concatMap OS.parseEvents frames)
       in (a.text, a.usage))
  , check "OpenAI stream keystone: tool args reassemble across chunks"
      [ToolUse "call_1" "get_weather" (object ["city" .= String "Brisbane"])]
      (let body = sseBody
             [ object ["choices" .= A.toJSON [object ["delta" .= object ["tool_calls" .= A.toJSON
                 [object ["index" .= Number 0, "id" .= String "call_1",
                          "function" .= object ["name" .= String "get_weather", "arguments" .= String "{\"city\":"]]]]]]]
             , object ["choices" .= A.toJSON [object ["delta" .= object ["tool_calls" .= A.toJSON
                 [object ["index" .= Number 0,
                          "function" .= object ["arguments" .= String "\"Brisbane\"}"]]]]]]]
             ]
           (frames, _) = splitFrames body
           a = foldl' OS.stepAcc OS.emptyAcc (concatMap OS.parseEvents frames)
       in OS.finishAcc a)
  -- crucible-l5c: cassette format is provider-neutral (recorded turns replay under OpenAI)
  , do let cassettePath = "/tmp/crucible-openai-cassette-test.jsonl"
           cassette =
             TE.decodeUtf8 (LBS.toStrict (A.encode (turnContentJson (Turn "" [ToolUse "u1" "get_weather" (object ["city" .= String "Brisbane"])])))) <> "\n"
             <> TE.decodeUtf8 (LBS.toStrict (A.encode (turnContentJson (Turn "Sunny in Brisbane!" [])))) <> "\n"
       TIO.writeFile cassettePath cassette
       r <- runEff (OpenAI.replayChat cassettePath (runToolAgent [weatherToolC] "weather in Brisbane?"))
       check "OpenAI.replayChat: replays the shared cassette format"
         (Right "Sunny in Brisbane!")
         r
  -- crucible-dak: hermetic cassette replay drives a tool loop
  , do let cassettePath = "/tmp/crucible-chat-cassette-test.jsonl"
           cassette =
             TE.decodeUtf8 (LBS.toStrict (A.encode (turnContentJson (Turn "" [ToolUse "u1" "get_weather" (object ["city" .= String "Brisbane"])])))) <> "\n"
             <> TE.decodeUtf8 (LBS.toStrict (A.encode (turnContentJson (Turn "Sunny in Brisbane!" [])))) <> "\n"
       TIO.writeFile cassettePath cassette
       r <- runEff (Anthropic.replayChat cassettePath (runToolAgent [weatherToolC] "weather in Brisbane?"))
       check "Anthropic.replayChat: replays a tool loop to the final answer"
         (Right "Sunny in Brisbane!")
         r
  , check "tools: record fields become tools, in field order"
      ["demo_weather", "demo_time"]
      (map (.name) (tools demoBox :: [Tl.Tool '[]]))
  , check "tools: derived handler decodes args and encodes result"
      (Right (A.String "sunny in Hobart"))
      (case tools demoBox :: [Tl.Tool '[]] of
         (w : _) -> runPureEff (Tl.invoke w (object ["locCity" .= String "Hobart"]))
         []      -> Left (Tl.UnknownTool "empty" []))
  , check "tools: zero-arg tool accepts an empty object"
      (Right (A.String "noon"))
      (case tools demoBox :: [Tl.Tool '[]] of
         [_, t] -> runPureEff (Tl.invoke t (object []))
         _      -> Left (Tl.UnknownTool "shape" []))
  , check "tools: zero-arg tool tolerates invented keys"
      (Right (A.String "noon"))
      (case tools demoBox :: [Tl.Tool '[]] of
         [_, t] -> runPureEff (Tl.invoke t (object ["surprise" .= String "args"]))
         _      -> Left (Tl.UnknownTool "shape" []))
  , check "tools: zero-arg schema is an object"
      (Just (String "object"))
      (case tools demoBox :: [Tl.Tool '[]] of
         [_, t] -> schemaType t.schema
         _      -> Nothing)
  -- eval rubric upgrades: verdict order, repair, voting
  , check "judge verdict: decodes why-first and legacy field order"
      (Right True, Right True)
      ( ( fmap (.pass) (decodeLLM verdictCodec "{\"why\":\"w\",\"pass\":true}")
        , fmap (.pass) (decodeLLM verdictCodec "{\"pass\":true,\"why\":\"w\"}") ) )
  , check "judge: repair recovers from one malformed verdict"
      (1.0, Nothing)
      (let s = runPureEff (runLLMScripted
                 ["not json", "{\"why\":\"ok\",\"pass\":true}"]
                 (judge id "r" ("out" :: Text)))
       in (s.value, s.votes))
  , check "judge: two malformed verdicts -> judge error score"
      (0.0, True)
      (let s = runPureEff (runLLMScripted ["junk", "junk2"] (judge id "r" ("out" :: Text)))
       in (s.value, T.isPrefixOf "judge error: " s.rationale))
  , check "judgeN: unanimous early-stops after two calls"
      (Just (2, 0), "leftover")
      (runPureEff (runLLMScripted
         [ "{\"why\":\"a\",\"pass\":true}", "{\"why\":\"b\",\"pass\":true}", "leftover" ]
         (do s <- judgeN 3 id "r" ("out" :: Text)
             extra <- complete []
             pure (s.votes, extra))))
  , check "judgeN: 2-1 split consumes three and records the tally"
      (1.0, Just (2, 1))
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"a\",\"pass\":true}"
                 , "{\"why\":\"n\",\"pass\":false}"
                 , "{\"why\":\"c\",\"pass\":true}" ]
                 (judgeN 3 id "r" ("out" :: Text)))
       in (s.value, s.votes))
  , check "judgeN: majority why is kept"
      "a"
      ((runPureEff (runLLMScripted
         [ "{\"why\":\"a\",\"pass\":true}", "{\"why\":\"b\",\"pass\":true}" ]
         (judgeN 3 id "r" ("out" :: Text)))).rationale)
  , check "judgeN: errored sample is excluded from the tally"
      (1.0, Just (2, 0))
      (let s = runPureEff (runLLMScripted
                 [ "junk", "junk2"
                 , "{\"why\":\"a\",\"pass\":true}", "{\"why\":\"b\",\"pass\":true}" ]
                 (judgeN 3 id "r" ("out" :: Text)))
       in (s.value, s.votes))
  -- eval rubric upgrades: checklists
  , check "checklist: weighted scoring + per-criterion rationale"
      (True, True)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"has it\",\"pass\":true}", "{\"why\":\"missing\",\"pass\":false}" ]
                 (scoreM id (Checklist [Criterion "cites a source" 2, Criterion "is terse" 1]) ("out" :: Text)))
       in (abs (s.value - 2/3) < 1e-9, T.isInfixOf "[fail] is terse: missing" s.rationale))
  , check "checklist: all pass scores 1.0 and counts in passRate"
      (1.0, 1.0)
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}" ]
                   (runEval id pure
                      [Case ("in" :: Text) "c" (Checklist [criterion "a", criterion "b"])]))
       in (rep.passRate, rep.meanScore))
  , check "checklist: empty list scores 1.0 with no judge calls"
      (1.0, "empty checklist")
      (let s = runPureEff (runLLMScripted []
                 (scoreM id (Checklist []) ("out" :: Text)))
       in (s.value, s.rationale))
  , check "checklist: judge error on a criterion fails that criterion"
      (0.5, True)
      (let s = runPureEff (runLLMScripted
                 [ "junk", "junk2", "{\"why\":\"y\",\"pass\":true}" ]
                 (scoreM id (Checklist [criterion "a", criterion "b"]) ("out" :: Text)))
       in (s.value, T.isInfixOf "judge error: " s.rationale))
  -- eval rubric upgrades: runEvalN + report annotations
  , check "runEvalN: votes thread to rubric cases"
      (Just (2, 0))
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}" ]
                   (runEvalN 3 id pure [Case ("x" :: Text) "c" (Rubric "r")]))
       in (head rep.results).score.votes)
  , check "renderReport: flags contested and judge-error cases"
      (True, True)
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"n\",\"pass\":false}", "{\"why\":\"y\",\"pass\":true}"
                   , "j1", "j2", "j3", "j4", "j5", "j6" ]
                   (runEvalN 3 id pure
                      [ Case ("a" :: Text) "contested" (Rubric "r")
                      , Case ("b" :: Text) "errs" (Rubric "r") ]))
           r = renderReport rep
       in ( T.isInfixOf "[votes 2-1]" r
             && T.isInfixOf "[judge uncertain: review by hand; dissent: n]" r
             && T.isInfixOf "majority-side rationale: y" r
          , T.isInfixOf "[judge error]" r ))
  -- eval rubric upgrades: calibration
  , check "calibrate: agreement/kappa/fail metrics on scripted verdicts"
      (0.75, 0.5, 1.0, 0.5, [], [], 0, 4, True)
      (let r = runPureEff (runLLMScripted
                 [ "{\"why\":\"\",\"pass\":true}", "{\"why\":\"\",\"pass\":true}"
                 , "{\"why\":\"\",\"pass\":false}", "{\"why\":\"\",\"pass\":true}" ]
                 (calibrate 1 id "r"
                    [ ("c1", "o" :: Text, True), ("c2", "o", True)
                    , ("c3", "o", False), ("c4", "o", False) ]))
           (lo, hi) = r.kappaCI
       in ( r.agreement, r.kappa, r.failPrecision, r.failRecall
          , r.contested, r.judgeErrors, r.exampleCount, r.measured
          , lo <= r.kappa && r.kappa <= hi ))
  , check "calibrate: degenerate denominators are defined"
      (CalibrationReport 1.0 0 1.0 1.0 [] [] 0 2 (0, 0))
      (runPureEff (runLLMScripted
         [ "{\"why\":\"\",\"pass\":true}", "{\"why\":\"\",\"pass\":true}" ]
         (calibrate 1 id "r" [("c1", "o" :: Text, True), ("c2", "o", True)])))
  , check "calibrate: contested and judge-error cases listed; errors excluded from stats"
      (["split"], ["broken"], 1.0)
      (let r = runPureEff (runLLMScripted
                 [ "{\"why\":\"\",\"pass\":true}", "{\"why\":\"\",\"pass\":false}", "{\"why\":\"\",\"pass\":true}"
                 , "j1", "j2", "j3", "j4", "j5", "j6" ]
                 (calibrate 3 id "r" [("split", "o" :: Text, True), ("broken", "o", True)]))
       in (r.contested, r.judgeErrors, r.agreement))
  -- crucible-tfu: few-shot calibrated judging
  , check "balanceExamples: deterministic and balanced"
      (True, [True, False, True, False])
      (let exs = [JudgeExample (T.pack (show i)) (odd i) Nothing | i <- [1 .. 8 :: Int]]
           a = balanceExamples 42 4 exs
           b = balanceExamples 42 4 exs
       in (a == b, map (.pass) a))
  , check "balanceExamples: surplus side fills after the short side runs out"
      [True, False, True, True]
      (map (.pass)
        (balanceExamples 7 4
          (JudgeExample "f" False Nothing
             : [JudgeExample (T.pack (show i)) True Nothing | i <- [1 .. 6 :: Int]])))
  , check "balanceExamples: n over supply returns all; n zero returns none"
      (3, 0)
      (let exs = [ JudgeExample "a" True Nothing
                 , JudgeExample "b" False Nothing
                 , JudgeExample "c" True Nothing ]
       in (length (balanceExamples 1 10 exs), length (balanceExamples 1 0 exs)))
  , check "judgePrompt: zero examples keeps the plain two-line user message"
      (Just "Rubric: r\nOutput to grade: out")
      (case judgePrompt [] "r" "out" of
         [_, Message User u] -> Just u
         _                   -> Nothing)
  , check "judgePrompt: examples render verdicts and optional why"
      (True, True, True)
      (case judgePrompt [ JudgeExample "good one" True (Just "matches rubric")
                        , JudgeExample "bad one" False Nothing ] "r" "out" of
         [_, Message User u] ->
           ( T.isInfixOf "Examples of past verdicts for this rubric:" u
           , T.isInfixOf "Example output:\ngood one\nVerdict: pass\nWhy: matches rubric" u
           , T.isInfixOf "Example output:\nbad one\nVerdict: fail\n" u
               && T.isSuffixOf "Output to grade: out" u )
         _ -> (False, False, False))
  , check "judgeWith: examples change no call accounting"
      (1.0, "leftover")
      (runPureEff (runLLMScripted ["{\"why\":\"y\",\"pass\":true}", "leftover"]
        (do s <- judgeWith (JudgeOpts 1 [JudgeExample "e" True Nothing])
                   id "r" ("out" :: Text)
            extra <- complete []
            pure (s.value, extra))))
  , check "runEvalWith: rubric and checklist both score under example opts"
      1.0
      ((runPureEff (runLLMScripted
         [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}" ]
         (runEvalWith (JudgeOpts 1 [JudgeExample "e" True Nothing]) id pure
            [ Case ("x" :: Text) "rub" (Rubric "r")
            , Case "y" "chk" (Checklist [criterion "c"]) ]))).passRate)
  , check "calibrateWith: examples held out of measurement"
      (CalibrationReport 1.0 0 1.0 1.0 [] [] 2 2 (0, 0), "leftover")
      (runPureEff (runLLMScripted
        [ "{\"why\":\"\",\"pass\":true}", "{\"why\":\"\",\"pass\":true}", "leftover" ]
        (do r <- calibrateWith 42 2 1 id "rubric"
                   [ ("a", "o1" :: Text, True), ("b", "o2", True)
                   , ("c", "o3", True), ("d", "o4", True) ]
            extra <- complete []
            pure (r, extra))))
  , check "calibrateWith: clamps so one measurement case remains"
      (2, 1)
      (let r = runPureEff (runLLMScripted ["{\"why\":\"\",\"pass\":true}"]
                 (calibrateWith 1 10 1 id "r"
                    [("a", "o" :: Text, True), ("b", "o2", True), ("c", "o3", True)]))
       in (r.exampleCount, r.measured))
  -- crucible-2h9: bootstrap CIs on kappa
  , check "bootstrapKappa: deterministic per seed"
      True
      (let ps = [(True, True), (True, False), (False, False), (False, True), (True, True), (False, False)]
       in bootstrapKappa 9 1000 ps == bootstrapKappa 9 1000 ps)
  , check "bootstrapKappa: perfect agreement collapses tight"
      ((0.0, 1.0))
      (bootstrapKappa 3 1000 [(True, True), (False, False), (True, True), (False, False)])
  , check "bootstrapKappa: mixed pairs bracket the point estimate"
      (True, True)
      (let ps = [(True, True), (True, True), (True, True), (False, False)
                , (False, False), (False, False), (True, False), (False, True)]
           k = 0.5
           (lo, hi) = bootstrapKappa 11 1000 ps
       in (lo <= k && k <= hi, lo < hi))
  , check "bootstrapKappa: degenerate sizes collapse to the point"
      (True, True)
      (let one = bootstrapKappa 1 1000 [(True, False)]
           none = bootstrapKappa 1 1000 []
       in (fst one == snd one, none == (0, 0)))
  , check "renderCalibration: kappa line carries the CI"
      True
      (T.isInfixOf "[95% CI "
        (renderCalibration (CalibrationReport 1 0 1 1 [] [] 0 4 (0, 0))))
  , check "renderCalibration: examples line only when used"
      (True, False)
      (let withEx    = CalibrationReport 1 0 1 1 [] [] 2 2 (0, 0)
           withoutEx = CalibrationReport 1 0 1 1 [] [] 0 4 (0, 0)
       in ( T.isInfixOf "examples fed: 2" (renderCalibration withEx)
          , T.isInfixOf "examples fed" (renderCalibration withoutEx)))
  -- crucible-mo3: derived claim grounding
  , check "groundingCheck: all claims supported -> 1.0 with lines in order"
      (1.0, True)
      (let s = runPureEff (runLLMScripted
                 [ "[\"the temperature is 26C\",\"the city is Brisbane\"]"
                 , "{\"why\":\"evidence says 26 degrees\",\"pass\":true}"
                 , "{\"why\":\"evidence names Brisbane\",\"pass\":true}" ]
                 (groundingCheck 1 id "Brisbane forecast: sunny, 26 degrees." ("It is 26C in Brisbane." :: Text)))
       in ( s.value
          , T.isInfixOf "[supported] the temperature is 26C: evidence says 26 degrees" s.rationale
              && T.isInfixOf "[supported] the city is Brisbane: evidence names Brisbane" s.rationale ))
  , check "groundingCheck: unsupported claim halves the score and is named"
      (0.5, True)
      (let s = runPureEff (runLLMScripted
                 [ "[\"the temperature is 26C\",\"it is raining\"]"
                 , "{\"why\":\"supported\",\"pass\":true}"
                 , "{\"why\":\"evidence says sunny\",\"pass\":false}" ]
                 (groundingCheck 1 id "sunny, 26 degrees" ("out" :: Text)))
       in (s.value, T.isInfixOf "[unsupported] it is raining: evidence says sunny" s.rationale))
  , check "groundingCheck: no claims -> vacuous 1.0, zero verification calls"
      (1.0, "no factual claims", "leftover")
      (runPureEff (runLLMScripted ["[]", "leftover"]
        (do s <- groundingCheck 1 id "ev" ("out" :: Text)
            extra <- complete []
            pure (s.value, s.rationale, extra))))
  , check "groundingCheck: decompose failure -> tagged judge error"
      (0.0, True)
      (let s = runPureEff (runLLMScripted ["junk", "junk2"]
                 (groundingCheck 1 id "ev" ("out" :: Text)))
       in (s.value, T.isPrefixOf "judge error: claim decomposition failed:" s.rationale))
  , check "groundingCheck: decompose repair recovers"
      1.0
      ((runPureEff (runLLMScripted
         [ "junk", "[\"a claim\"]", "{\"why\":\"yes\",\"pass\":true}" ]
         (groundingCheck 1 id "ev" ("out" :: Text)))).value)
  , check "groundingCheck: claim vote all-errors counts unsupported"
      (0.0, True)
      (let s = runPureEff (runLLMScripted
                 [ "[\"a claim\"]", "junk", "junk2" ]
                 (groundingCheck 1 id "ev" ("out" :: Text)))
       in (s.value, T.isInfixOf "[unsupported] a claim: judge error:" s.rationale))
  , check "Grounded: threads votes through runEvalN"
      (1.0, "leftover")
      (runPureEff (runLLMScripted
         [ "[\"one claim\"]"
         , "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}"
         , "leftover" ]
         (do rep <- runEvalN 3 id pure [Case ("text" :: Text) "g" (Grounded "ev")]
             extra <- complete []
             pure (rep.passRate, extra))))
  -- improve-skill cycle: structured instruction + prompt tweaks
  , check "prompt: slot-less user message has the exact tweaked shape"
      (Just ("Classify the sentiment of: hi\n\n<input>\n\"hi\"\n</input>\n\nRespond with JSON only; your reply is parsed by a machine."))
      (case prompt classifyFn "hi" of
         [_, Message User u] -> Just u
         _                   -> Nothing)
  , check "prompt: system message keeps its first line and gains the machine line"
      (True, True)
      (case prompt classifyFn "hi" of
         (Message System s : _) ->
           ( T.isPrefixOf "Respond ONLY with JSON matching this schema:" s
           , T.isInfixOf "Your reply is parsed by a machine; any text outside the JSON is an error." s )
         _ -> (False, False))
  , check "prompt: preamble renders first, constraints render after the input"
      True
      (case prompt (withPreamble "Be terse." (withConstraints "One word only." classifyFn)) "hi" of
         [_, Message User u] ->
           T.isPrefixOf "Be terse.\n\nClassify the sentiment of: hi" u
             && T.isInfixOf "</input>\n\nOne word only.\n\nRespond with JSON only" u
         _ -> False)
  , check "skillWith: carries all three instruction parts"
      True
      (case prompt (skillWith "s" C.str C.str (Instruction "P" ("Task: " <>) "C")) "x" of
         [_, Message User u] ->
           T.isPrefixOf "P\n\nTask: x" u && T.isInfixOf "\nC\n\nRespond with JSON only" u
         _ -> False)
  , check "prompt: few-shot pairs inherit the tweaked template"
      True
      (case prompt (withExamples [("I love it", "positive")] classifyFn) "meh" of
         (_ : Message User u : _) -> T.isInfixOf "<input>\n\"I love it\"\n</input>" u
         _ -> False)
  -- improveSkill (hermetic hill-climb)
  , check "improveSkill: accepted revision returns improved skill + step"
      (True, [ImproveStep 1 True 1.0 1.0 "Always answer GOOD." "Reply with GOOD only."])
      (let sk = withTests [Case ("in" :: Text) "c" (Exactly ("GOOD" :: Text))]
                  (withRetries 0 (skill "s" C.str C.str ("Echo: " <>)))
           (best, steps) = runPureEff (runLLMScripted
             [ "\"BAD\""                                                        -- baseline fails
             , "{\"preamble\":\"Always answer GOOD.\",\"constraints\":\"Reply with GOOD only.\"}"
             , "\"GOOD\""                                                       -- candidate passes
             ]
             (improveSkill 1 id sk))
       in (best.instruction.preamble == "Always answer GOOD.", steps))
  , check "improveSkill: no improvement -> rejected, original slots kept"
      (True, [False])
      (let sk = withTests [Case ("in" :: Text) "c" (Exactly ("GOOD" :: Text))]
                  (withRetries 0 (skill "s" C.str C.str ("Echo: " <>)))
           (best, steps) = runPureEff (runLLMScripted
             [ "\"BAD\""
             , "{\"preamble\":\"P\",\"constraints\":\"C\"}"
             , "\"BAD\""                                                        -- candidate also fails
             ]
             (improveSkill 1 id sk))
       in (best.instruction.preamble == "", map (.accepted) steps))
  , check "improveSkill: reflector junk burns the round, loop survives"
      [False]
      (let sk = withTests [Case ("in" :: Text) "c" (Exactly ("GOOD" :: Text))]
                  (withRetries 0 (skill "s" C.str C.str ("Echo: " <>)))
           (_, steps) = runPureEff (runLLMScripted
             [ "\"BAD\"", "j1", "j2", "j3" ]                                    -- reflector retries 2 = 3 replies
             (improveSkill 1 id sk))
       in map (.accepted) steps)
  , check "improveSkill: empty tests -> immediate return, zero calls"
      (True, "leftover")
      (runPureEff (runLLMScripted ["leftover"]
        (do (_, steps) <- improveSkill 3 id (skill "s" C.str (C.str :: JSONCodec Text) ("Echo: " <>))
            extra <- complete []
            pure (null steps, extra))))
  , check "improveSkill: all-passing baseline -> no reflection call"
      (True, "leftover")
      (runPureEff (runLLMScripted ["\"GOOD\"", "leftover"]
        (do (_, steps) <- improveSkill 3 id
              (withTests [Case ("in" :: Text) "c" (Exactly ("GOOD" :: Text))]
                 (withRetries 0 (skill "s" C.str C.str ("Echo: " <>))))
            extra <- complete []
            pure (null steps, extra))))
  -- crucible-3sj: provider fallback + round-robin
  , do c1 <- newIORef 0; c2 <- newIORef 0
       r <- runEff (Fallback.run [goodProvider "a" c1 "from-a", goodProvider "b" c2 "from-b"] (complete []))
       n2 <- readIORef c2
       check "fallback: first member answers, second untouched" ("from-a", 0 :: Int) (r, n2)
  , do c1 <- newIORef 0; c2 <- newIORef 0
       r <- runEff (Fallback.run [badProvider "a" c1, goodProvider "b" c2 "from-b"] (complete []))
       n1 <- readIORef c1
       check "fallback: failing member advances to the next" ("from-b", 1 :: Int) (r, n1)
  , do c1 <- newIORef 0; c2 <- newIORef 0
       r <- try (runEff (Fallback.run [badProvider "a" c1, badProvider "b" c2] (complete [])))
       check "fallback: exhaustion collects every member error in order"
         (Just (["a", "b"], True))
         (case r of
            Left (Fallback.FallbackExhausted errs) ->
              Just (map fst errs, all (T.isInfixOf "down" . snd) errs)
            Right (_ :: Text) -> Nothing)
  , do c1 <- newIORef 0
       (rs, u) <- runEff (Fallback.usage [goodProvider "a" c1 "ok"]
                    (do x <- complete []; y <- complete []; pure (x, y)))
       check "fallback: usage accumulates across calls" (("ok", "ok"), Usage 2 4) (rs, u)
  , do c1 <- newIORef 0; c2 <- newIORef 0
       r <- runEff (Fallback.runChat [badProvider "a" c1, goodProvider "b" c2 "from-b"]
              (converse [] []))
       check "fallback: chat path advances too" (Turn "from-b" []) r
  , do c1 <- newIORef 0; c2 <- newIORef 0
       let ps = [goodProvider "a" c1 "from-a", goodProvider "b" c2 "from-b"]
       (r1, r2, r3) <- runEff (Fallback.roundRobin ps
                         (do x <- complete []; y <- complete []; z <- complete []; pure (x, y, z)))
       (n1, n2) <- (,) <$> readIORef c1 <*> readIORef c2
       check "roundRobin: rotates the starting member per call"
         (("from-a", "from-b", "from-a"), (2 :: Int, 1 :: Int))
         ((r1, r2, r3), (n1, n2))
  , do c1 <- newIORef 0; c2 <- newIORef 0
       let ps = [goodProvider "a" c1 "from-a", badProvider "b" c2]
       (r1, r2) <- runEff (Fallback.roundRobin ps
                      (do x <- complete []; y <- complete []; pure (x, y)))
       (n1, n2) <- (,) <$> readIORef c1 <*> readIORef c2
       check "roundRobin: failure wraps back around the list"
         (("from-a", "from-a"), (2 :: Int, 1 :: Int))
         ((r1, r2), (n1, n2))
  , do r <- try (runEff (Fallback.run [] (complete [])))
       check "fallback: empty provider list throws immediately"
         (Just (Fallback.FallbackExhausted []))
         (case r of
            Left e -> Just e
            Right (_ :: Text) -> Nothing)
  , do c1 <- newIORef 0; c2 <- newIORef 0
       let asyncProvider = Provider "a"
             (\_ -> modifyIORef' c1 (+ 1) >> throwIO (SomeAsyncException (userError "cancelled")))
             (\_ _ -> modifyIORef' c1 (+ 1) >> throwIO (SomeAsyncException (userError "cancelled")))
       r <- try (runEff (Fallback.run [asyncProvider, goodProvider "b" c2 "from-b"] (complete [])))
       n2 <- readIORef c2
       check "fallback: async exceptions rethrow without advancing"
         (True, 0 :: Int)
         (case r of
            Left (e :: SomeException) -> (case fromException @SomeAsyncException e of Just _ -> True; Nothing -> False, n2)
            Right (_ :: Text) -> (False, n2))
  , do p <- Anthropic.provider (defaultAnthropicConfig "k")
       q <- OpenAI.provider (defaultOpenAIConfig "k")
       check "providers: constructors carry their names" ("anthropic", "openai") (p.name, q.name)
  -- crucible-2zw: scalar metrics
  , check "metrics: normMatch ignores case and whitespace"
      (1.0, 0.0) (normMatch "Hello  World" "hello world", normMatch "hello" "goodbye")
  , check "metrics: tokenF1 on a hand-computed overlap"
      True (abs (tokenF1 "a b c d" "c a b" - 6 / 7) < 1e-9)
  , check "metrics: tokenF1 identical and empty cases pinned"
      (1.0, 1.0, 0.0) (tokenF1 "x y" "x y", tokenF1 "" "", tokenF1 "x" "")
  , check "metrics: rougeL on a hand-computed LCS"
      True (abs (rougeL "a b c d" "c a b" - 4 / 7) < 1e-9)
  , check "metrics: rougeL empty cases pinned"
      (1.0, 0.0) (rougeL "" "", rougeL "" "x")
  , check "metrics: tokenF1 counts multiset overlap, not set"
      True (abs (tokenF1 "a a b" "a b b" - 2 / 3) < 1e-9)
  , check "metrics: rougeL is order-sensitive where tokenF1 is not"
      (1.0, True) (tokenF1 "a b c" "c b a", abs (rougeL "a b c" "c b a" - 1 / 3) < 1e-9)
  -- crucible-2zw: ordinal rating prompt
  , check "ratePrompt: anchors sort ascending; system states the range"
      ("Rubric: r\nLevels:\n1: bad\n5: good\nOutput to grade: out", True)
      (case ratePrompt 5 [(5, "good"), (1, "bad")] "r" "out" of
         [Message _ sys, Message _ u] -> (u, T.isInfixOf "between 1 and 5" sys)
         _ -> ("wrong shape", False))
  ]
