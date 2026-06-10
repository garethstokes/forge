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
import Crucible.Skill (Skill (..), skill, withRetries, withTests, prompt, call, testSkill)
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
import Crucible.Eval (Case(..), Expectation(..), Score(..), Result(..), Report(..), runEval, scoreM, judge, renderReport)
import Crucible.LLM.Anthropic (AnthropicConfig(..), AnthropicError(..), isRetryable, defaultAnthropicConfig, chatRequestJson, parseTurn, parseUsage, turnContentJson)
import qualified Crucible.LLM.Anthropic as Anthropic
import Crucible.LLM.OpenAI (OpenAIError(..), defaultOpenAIConfig)
import qualified Crucible.LLM.OpenAI as OpenAI
import qualified Crucible.Chat as Chat
import Crucible.Chat
  (converse, runChatScripted, runToolAgent, runToolAgentN, Turn(..), Block(..), ToolUse(..), ChatError(..))
import Crucible.Emit (emit, runEmitList, ignoreEmit)
import Crucible.Rows (splitRows, runRows)
import Crucible.Usage (Usage(..), usTotalTokens, Rates(..), estimateCost)
import qualified Data.ByteString.Char8 as BC
import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Crucible.LLM.Anthropic.Stream
  (splitFrames, StreamEvent(..), parseEvent, StreamAcc(..), emptyAcc, stepAcc, timedRead)
import Data.List (foldl')

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

stationVal :: Station
stationVal = Station "Eagle Farm" (Forecast "Brisbane" 26.0 False) Cloudy

-- Sample types for M6 tests
data ToolCall = GetWeather Text | AddNums Int Int deriving (Eq, Show)
newtype Answer = Answer Text deriving (Eq, Show)

-- Sample type for type-driven tool constructor test
data Loc = Loc { locCity :: Text } deriving (Show, Generic)
instance HasCodec Loc where codec = genericCodec

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
weatherToolC = Tl.Tool "get_weather" weatherToolSchema (\_ -> pure (A.String "Sunny in Brisbane!"))

-- M11 Task 1: Crucible.Skill fixtures
classifyFn :: Skill T.Text T.Text
classifyFn = skill "classify" C.str C.str (\s -> "Classify the sentiment of: " <> s)

-- M7 Task 2: agent test helpers — the effectful agent runs over the LLM + Tools
-- effects, dispatching tools by name from a toolbox via the Tools effect.
agentCodec :: JSONCodec (Decision Tl.ToolCall Text)
agentCodec = decisionCodec Tl.toolCallCodec (C.object (C.field "answer" id C.str))

agentTools :: [Tl.Tool es]
agentTools =
  [ Tl.Tool "get_weather" weatherToolSchema $ \args ->
      pure $ case AT.parseMaybe (A.withObject "" (\o -> o A..: "city")) args of
               Just c  -> A.String ("sunny in " <> c)
               Nothing -> A.String "unknown city"
  , Tl.Tool "add" (A.object
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
      (Tl.toolsHelp [Tl.Tool "echo" (A.object
          [ "type" A..= A.String "object"
          , "properties" A..= A.object ["msg" A..= A.object ["type" A..= A.String "string"]]
          , "required" A..= A.toJSON [A.String "msg"] ]) (\_ -> pure Null)])
  , check "tool: type-driven constructor derives object schema + decodes args"
      (Just (String "object"), A.String "sunny in Hobart")
      ( let t = Tl.tool "weather" (\(Loc c) -> pure (A.String ("sunny in " <> c))) :: Tl.Tool '[]
        in ( schemaType t.schema
           , runPureEff (t.run (object ["locCity" .= String "Hobart"])) ) )
  , check "tool: decode failure yields error string"
      True
      ( let t = Tl.tool "weather" (\(Loc c) -> pure (A.String ("sunny in " <> c))) :: Tl.Tool '[]
            result = runPureEff (t.run (object []))
        in case result of
             A.String s -> T.isPrefixOf "bad tool args:" s
             _          -> False )
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
  ]
