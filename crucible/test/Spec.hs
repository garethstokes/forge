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
import Crucible.Codec (JSONCodec, schemaValue, schemaText, refine, checked, Checked (..), allPassed)
import Crucible.Codec.Generic (HasCodec(..), genericCodec)
import Crucible.Skill (Skill (..), Instruction (..), skill, skillWith, withPreamble, withConstraints, withRetries, withTests, withExamples, examplesFromTests, withReasoning, prompt, instructionText, call, testSkill)
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text as T
import GHC.Generics (Generic)
import Crucible.Decode (stripToJson, decodeLLM, DecodeError (..))
import Crucible.Decision (Decision(..), decisionCodec, Step(..), reduce)
import Effectful (Eff, IOE, runEff, runPureEff, liftIO, (:>))
import qualified Data.Text.IO as TIO
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text.Encoding as TE
import Crucible.LLM (LLM, complete, Message(..), Role(..), runLLMScripted)
import Crucible.Agent (startAgent, runAgent)
import qualified Crucible.Tool as Tl
import Crucible.Tool (runTools)
import Crucible.Example (demoAgent)
import Crucible.Tool.Generic (tools)
import Crucible.Eval (Case(..), Expectation(..), Criterion(..), criterion, penalty, Score(..), score, Result(..), Report(..), runEval, runEvalN, scoreM, scoreN, scoreWith, judge, judgeN, renderReport, groundingCheck, judgeWith, runEvalWith, lintChecklist)
import Crucible.Eval.Latency (Timed (..), timed, timeEach, withinMs, maxLatencyMs)
import Crucible.Eval.Lint (LintIssue (..), LintFinding (..), lintPrompt)
import Crucible.Skill.Improve (ImproveStep (..), improveSkill)
import Crucible.Eval.Judge (VerdictKind(..), Verdict(..), verdictCodec, AbstainPolicy(..), JudgeExample(..), JudgeOpts(..), defaultJudgeOpts, VoteOutcome(..), vote, tally, votePanel, balanceExamples, judgePrompt, ratePrompt, JudgeError(..))
import Data.Functor.Identity (Identity (..))
import Crucible.Eval.Calibrate (CalibrationReport (..), calibrate, renderCalibration, calibrateWith, bootstrapKappa, reportFromVerdicts, bootstrapStdErr)
import Crucible.LLM.Anthropic (AnthropicConfig(..), AnthropicError(..), isRetryable, defaultAnthropicConfig, chatRequestJson, parseTurn, parseUsage, turnContentJson)
import qualified Crucible.LLM.Anthropic as Anthropic
import Crucible.LLM.OpenAI (OpenAIError(..), defaultOpenAIConfig)
import qualified Crucible.LLM.OpenAI as OpenAI
import qualified Crucible.LLM.Voyage as Voyage
import qualified Crucible.LLM.OpenAI.Stream as OS
import qualified Crucible.Chat as Chat
import Crucible.Chat
  (converse, runChatScripted, runToolAgent, runToolAgentN, Turn(..), Block(..), ToolUse(..), ChatError(..))
import Crucible.Emit (emit, runEmitList, ignoreEmit)
import Crucible.Rows (splitRows, runRows)
import Crucible.Partial (closeJson, runPartial)
import Crucible.Usage (Usage(..), usTotalTokens, Rates(..), estimateCost)
import qualified Data.ByteString.Char8 as BC
import Control.Concurrent (threadDelay)
import Control.Exception (try, throwIO, fromException, evaluate, SomeException, SomeAsyncException (..), catch)
import Crucible.LLM.Anthropic.Stream
  (splitFrames, StreamEvent(..), parseEvent, StreamAcc(..), emptyAcc, stepAcc, timedRead)
import Data.List (foldl')
import qualified Data.List
import Data.IORef (IORef, newIORef, modifyIORef', readIORef, writeIORef)
import Crucible.LLM.Provider (Provider (..))
import qualified Crucible.LLM.Fallback as Fallback
import Crucible.LLM.CallLog (CallEntry (..))
import qualified Crucible.LLM.CallLog as CallLog
import Crucible.Eval.Metrics (normMatch, tokenF1, rougeL)
import Crucible.Embed (embed, runEmbedScripted, cosine, consistency)
import qualified Crucible.Embed as Embed
import Crucible.Memory (MemoryKind (..), MemoryId (..), Provenance (..), MemoryDraft (..), MemoryItemT (..), MemoryItem, Query (..), remember, recall, forget, recallAs, runMemoryScripted, runMemoryPure, runMemoryFile, runMemoryWith, newMemoryStorePure, memoryStoreFile)
import Crucible.Memory.Consolidate (ConsolidationOp (..), ConsolidationPlan (..), consolidationSkill, applyPlan, unaddressed, consolidate)
import Crucible.Memory.Eval (renderMemories, withMemories, memoryLift, liftDelta)
import System.IO (openTempFile, hClose)
import System.Directory (removeFile, createDirectoryIfMissing, removeDirectoryRecursive, doesFileExist)
import Crucible.Media (Media (..), imageB64, pdfB64, imageFile, pdfFile)
import Crucible.Skill.Multimodal (mediaMessage, callMedia)
import qualified Data.ByteString.Base64 as B64TEST
import qualified Data.ByteString as BSTEST
import Crucible.Agents (SubAgent (..), subAgent, AgentFailure (..), Agents, spawn, spawnAll, workerPrompt, runAgentsScripted, runAgents)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Crucible.Agents.Gate (Gate (..), gate, spawnGated)
import qualified Crucible.Ledger as Ledger
import Crucible.Ledger (WorkId (..), WorkState (Ready, Claimed), WorkItemT (..), WorkItem, runLedgerState, runLedgerFile, runLedgerWith, newLedgerStorePure, ledgerStoreFile, workItemCodec)
import Crucible.Research (Slug (..), mkSlug, LinkType (..), Link (..), Page (..), Research, readPage, writePage, index, search, appendLog, runResearchState, runResearchDir, runResearchWith, researchStoreState, linkCodec, pageCodec, slugCodec)
import Crucible.Research.Tools (researchTools, researchInstructions)
import Crucible.Research.Grounded (NoClaimsPolicy (..), GroundGate (..), defaultGroundGate, writeGrounded, GroundingOutcome (..))
import Crucible.Research.Lint (Finding (..), orphans, brokenLinks, sparsePages, lintStructural, linkedPairs, allPairs, lintContradictions, lintStale, LintOpts (..), defaultLintOpts, lintWiki)
import qualified Crucible.Journal as J
import Crucible.Journal (Journal (..), JournalIdentity (..), Entry (..), CassetteKey (..), MissPolicy (Signal, Fallthrough), Divergence (..), ReplayOutcome (..), JournalError (..), ActivityKind (..), IdemKey (..))
import qualified Effectful.State.Static.Local as ES
import qualified Effectful.Error.Static as EE
import qualified Crucible.Workflow as W
import Crucible.Workflow (WorkflowEnv (..), WaitSpec (..), Suspended (..))
import Crucible.Eval.Replay (runReplayEval, settle, noteDivergence, ddmin)

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

-- crucible-2ey: all-optional partial type for runPartial tests
data PersonP = PersonP { ppName :: Maybe Text, ppAge :: Maybe Int }
  deriving (Eq, Show, Generic)
instance HasCodec PersonP where codec = genericCodec

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
goodProvider nm c out = Provider nm "fake-model"
  (\_ -> modifyIORef' c (+ 1) >> pure (out, Usage 1 2))
  (\_ _ -> modifyIORef' c (+ 1) >> pure (Turn out [], Usage 1 2))

badProvider :: Text -> IORef Int -> Provider
badProvider nm c = Provider nm "fake-model"
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

-- Phase 0 journal tests: encode/decode an Int as the recorded result bytes.
encInt :: Int -> BC.ByteString
encInt = BC.pack . show

decInt :: BC.ByteString -> Either Data.Text.Text Int
decInt b = case reads (BC.unpack b) of
  [(n, "")] -> Right n
  _         -> Left "bad int"

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
      (let rep = runPureEff (runLLMScripted [] (Embed.none (runEval id (pure . Data.Text.toUpper)
                   [ Case "abc" "upper" (Exactly "ABC")
                   , Case "xy"  "nonempty" (Predicate (not . Data.Text.null)) ])))
       in (rep.passRate, rep.meanScore))
  , check "eval: detects a mismatch"
      0.0
      ((runPureEff (runLLMScripted []
        (Embed.none (runEval id (pure . Data.Text.toUpper) [Case "abc" "wrong" (Exactly "abc")])))).passRate)
  , check "eval: report renders per-case + summary"
      True
      (Data.Text.isInfixOf "pass-rate:" (renderReport (runPureEff (runLLMScripted []
        (Embed.none (runEval id (pure . Data.Text.toUpper) [Case "abc" "c" (Exactly "ABC")]))))))
  -- M10 Task 2: LLM-as-judge (Rubric) on scripted data
  , check "eval: LLM-as-judge passes a rubric (scripted verdict)"
      (1.0, "looks like a greeting")
      (let rep = runPureEff (runLLMScripted ["{\"pass\":true,\"why\":\"looks like a greeting\"}"]
                   (Embed.none (runEval id (pure . id) [Case "hi" "greeting" (Rubric "must be a greeting")])))
       in (rep.passRate, (head rep.results).score.rationale))
  , check "eval: LLM-as-judge fails a rubric (scripted verdict)"
      0.0
      ((runPureEff (runLLMScripted ["{\"pass\":false,\"why\":\"not a greeting\"}"]
        (Embed.none (runEval id (pure . id) [Case "42" "greeting" (Rubric "must be a greeting")])))).passRate)
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
        (Embed.none (do rep <- testSkill id (examplesFromTests 1
                          (withTests [ Case "a" "ex" (Exactly "A")
                                     , Case "b" "kept" (Exactly "B") ] classifyFn))
                        extra <- complete []
                        pure (rep.passRate, extra)))))
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
           rep = runPureEff (runLLMScripted ["\"positive\""] (Embed.none (testSkill id sk)))
       in (rep.passRate, rep.meanScore))
  , check "testSkill: attached case fails on mismatch"
      0.0
      ((runPureEff (runLLMScripted ["\"negative\""]
        (Embed.none (testSkill id (withTests [Case "I love it" "pos" (Exactly "positive")] classifyFn))))).passRate)
  , check "testSkill: decode failure scores zero"
      0.0
      ((runPureEff (runLLMScripted ["junk"]
        (Embed.none (testSkill id (withTests [Case "x" "robust" (Predicate (const True))]
                        (withRetries 0 classifyFn)))))).passRate)
  , check "testSkill: rubric case consults the judge"
      1.0
      ((runPureEff (runLLMScripted
        [ "\"hello there\""                                  -- the skill's reply
        , "{\"pass\":true,\"why\":\"greets the user\"}" ]    -- the judge's verdict
        (Embed.none (testSkill id (withTests [Case "hi" "greets" (Rubric "must be a greeting")] classifyFn))))).passRate)
  , check "instructionText contains the task and the input JSON"
      True
      (let s = skill "t" C.str C.str (\x -> "Do the thing with " <> x)
           out = instructionText s "ABC"
       in T.isInfixOf "Do the thing with ABC" out && T.isInfixOf "<input>\n\"ABC\"" out)
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
  , check "verdict codec: new enum, legacy pass bool, and cannot_assess decode"
      (Right Pass, Right Pass, Right Fail, Right CannotAssess)
      ( fmap (.kind) (decodeLLM verdictCodec "{\"why\":\"w\",\"verdict\":\"pass\"}")
      , fmap (.kind) (decodeLLM verdictCodec "{\"pass\":true,\"why\":\"w\"}")
      , fmap (.kind) (decodeLLM verdictCodec "{\"why\":\"w\",\"pass\":false}")
      , fmap (.kind) (decodeLLM verdictCodec "{\"why\":\"w\",\"verdict\":\"cannot_assess\"}") )
  , check "verdict codec: a reply with neither verdict nor pass fails to parse"
      True
      (case decodeLLM verdictCodec "{\"why\":\"w\"}" of
         Left _ -> True
         Right (_ :: Verdict) -> False)
  , check "vote: all samples abstain yields AllAbstained"
      True
      (case runPureEff (runLLMScripted
              (replicate 3 "{\"why\":\"cant tell\",\"verdict\":\"cannot_assess\"}")
              (vote False (JudgeOpts 3 [] AbstainFails) "r" "out")) of
         AllAbstained m -> T.isInfixOf "cant tell" m
         _              -> False)
  , check "vote: a yes/no majority amid abstains still decides"
      (True, 2, 0)
      (case runPureEff (runLLMScripted
              [ "{\"why\":\"a\",\"verdict\":\"pass\"}"
              , "{\"why\":\"b\",\"verdict\":\"cannot_assess\"}"
              , "{\"why\":\"c\",\"verdict\":\"pass\"}" ]
              (vote False (JudgeOpts 3 [] AbstainFails) "r" "out")) of
         Decided p _ _ y f -> (p, y, f)
         _                 -> (False, 0, 0))
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
  -- crucible-ymh: cross-model judge panels
  , check "tally: unanimous pass decides true; tie resolves to fail"
      ((True, 2, 0), (False, 1, 1))
      ( case tally [Right (Verdict "a" Pass), Right (Verdict "b" Pass)] of
          Decided p _ _ y f -> (p, y, f); _ -> (False, -1, -1)
      , case tally [Right (Verdict "a" Pass), Right (Verdict "b" Fail)] of
          Decided p _ _ y f -> (p, y, f); _ -> (False, -1, -1) )
  , check "tally: majority decides and records the first dissent"
      (False, Just "yo")
      (case tally [Right (Verdict "yo" Pass), Right (Verdict "n1" Fail), Right (Verdict "n2" Fail)] of
         Decided p _ d _ _ -> (p, d); _ -> (True, Nothing))
  , check "tally: all abstain -> AllAbstained; all error -> AllErrored; errors excluded"
      (True, True, (True, 1, 0))
      ( case tally [Right (Verdict "x" CannotAssess)] of AllAbstained _ -> True; _ -> False
      , case tally [Left (JudgeError "down")] of AllErrored m -> T.isInfixOf "down" m; _ -> False
      , case tally [Left (JudgeError "e"), Right (Verdict "y" Pass)] of
          Decided p _ _ y f -> (p, y, f); _ -> (False, -1, -1) )
  , check "votePanel: combines member verdicts via tally (pure Identity)"
      (True, 2, 0)
      (case runIdentity (votePanel
              [ \_ _ -> Identity (Right (Verdict "a" Pass))
              , \_ _ -> Identity (Right (Verdict "b" Pass)) ] "r" "out") of
         Decided p _ _ y f -> (p, y, f); _ -> (False, -1, -1))
  , check "votePanel: each member receives the rubric and output"
      "r|out"
      (case runIdentity (votePanel
              [ \r g -> Identity (Right (Verdict (r <> "|" <> g) Pass)) ] "r" "out") of
         Decided _ w _ _ _ -> w; _ -> "")
  -- eval rubric upgrades: checklists
  , check "checklist: weighted scoring + per-criterion rationale"
      (True, True)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"has it\",\"pass\":true}", "{\"why\":\"missing\",\"pass\":false}" ]
                 (Embed.none (scoreM id (Checklist [Criterion "cites a source" 2, Criterion "is terse" 1]) ("out" :: Text))))
       in (abs (s.value - 2/3) < 1e-9, T.isInfixOf "[fail] is terse: missing" s.rationale))
  , check "checklist: all pass scores 1.0 and counts in passRate"
      (1.0, 1.0)
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}" ]
                   (Embed.none (runEval id pure
                      [Case ("in" :: Text) "c" (Checklist [criterion "a", criterion "b"])])))
       in (rep.passRate, rep.meanScore))
  , check "checklist: empty list scores 1.0 with no judge calls"
      (1.0, "empty checklist")
      (let s = runPureEff (runLLMScripted []
                 (Embed.none (scoreM id (Checklist []) ("out" :: Text))))
       in (s.value, s.rationale))
  , check "checklist: judge error on a criterion fails that criterion"
      (0.5, True)
      (let s = runPureEff (runLLMScripted
                 [ "junk", "junk2", "{\"why\":\"y\",\"pass\":true}" ]
                 (Embed.none (scoreM id (Checklist [criterion "a", criterion "b"]) ("out" :: Text))))
       in (s.value, T.isInfixOf "judge error: " s.rationale))
  -- crucible-nwa: penalty criteria (negative weights)
  , check "checklist: a fired penalty subtracts; positives set the denominator"
      True
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"y\",\"pass\":true}"
                 , "{\"why\":\"fired\",\"pass\":true}" ]
                 (Embed.none (scoreM id
                    (Checklist [Criterion "helpful" 2, penalty 1 "recommends a product"]) ("out" :: Text))))
       in abs (s.value - 0.5) < 1e-9)
  , check "checklist: a heavy penalty clamps the score at 0"
      0.0
      ((runPureEff (runLLMScripted
         [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"fired\",\"pass\":true}" ]
         (Embed.none (scoreM id
            (Checklist [Criterion "helpful" 2, penalty 5 "recommends a product"]) ("out" :: Text))))).value)
  , check "checklist: a penalty present but not fired keeps the case perfect"
      (1.0, 1.0)
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}"
                   , "{\"why\":\"absent\",\"pass\":false}" ]
                   (Embed.none (runEval id pure
                      [Case ("in" :: Text) "c" (Checklist [Criterion "helpful" 2, penalty 3 "recommends a product"])])))
       in (rep.passRate, rep.meanScore))
  , check "checklist: a fired penalty drops the case out of passRate"
      (0.0, True)
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"fired\",\"pass\":true}" ]
                   (Embed.none (runEval id pure
                      [Case ("in" :: Text) "c" (Checklist [Criterion "helpful" 2, penalty 1 "recommends a product"])])))
       in (rep.passRate, abs (rep.meanScore - 0.5) < 1e-9))
  , check "checklist: a penalty-only checklist scores 1.0 clear, 0.0 fired"
      (1.0, 0.0)
      ( (runPureEff (runLLMScripted ["{\"why\":\"absent\",\"pass\":false}"]
          (Embed.none (scoreM id (Checklist [penalty 2 "recommends a product"]) ("out" :: Text))))).value
      , (runPureEff (runLLMScripted ["{\"why\":\"fired\",\"pass\":true}"]
          (Embed.none (scoreM id (Checklist [penalty 2 "recommends a product"]) ("out" :: Text))))).value )
  , check "checklist: rationale uses [penalty]/[clear] for negatives, [pass]/[fail] for positives"
      (True, True, True)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"y\",\"pass\":true}"
                 , "{\"why\":\"fired\",\"pass\":true}"
                 , "{\"why\":\"absent\",\"pass\":false}" ]
                 (Embed.none (scoreM id (Checklist
                    [ Criterion "helpful" 1
                    , penalty 1 "recommends a product"
                    , penalty 1 "uses slang" ]) ("out" :: Text))))
       in ( T.isInfixOf "[pass] helpful" s.rationale
          , T.isInfixOf "[penalty] recommends a product" s.rationale
          , T.isInfixOf "[clear] uses slang" s.rationale ))
  , check "penalty: builds a negative-weight criterion; abs guards a negative arg"
      (-2.0, -2.0)
      (let a = penalty 2 "x"; b = penalty (-2) "x"
       in (a.weight, b.weight))
  -- eval rubric upgrades: runEvalN + report annotations
  , check "runEvalN: votes thread to rubric cases"
      (Just (2, 0))
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}" ]
                   (Embed.none (runEvalN 3 id pure [Case ("x" :: Text) "c" (Rubric "r")])))
       in (head rep.results).score.votes)
  , check "renderReport: flags contested and judge-error cases"
      (True, True)
      (let rep = runPureEff (runLLMScripted
                   [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"n\",\"pass\":false}", "{\"why\":\"y\",\"pass\":true}"
                   , "j1", "j2", "j3", "j4", "j5", "j6" ]
                   (Embed.none (runEvalN 3 id pure
                      [ Case ("a" :: Text) "contested" (Rubric "r")
                      , Case ("b" :: Text) "errs" (Rubric "r") ])))
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
      (CalibrationReport 1.0 0 1.0 1.0 [] [] 0 2 (0, 0) [] 1.0 1.0 1.0)
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
  , check "calibrate: an abstained case is listed separately and excluded from kappa"
      ["b"]
      ((runPureEff (runLLMScripted
         [ "{\"why\":\"\",\"verdict\":\"pass\"}"
         , "{\"why\":\"\",\"verdict\":\"cannot_assess\"}" ]
         (calibrate 0 id "r"
            [ ("a", "o1" :: Text, True), ("b", "o2", True) ]))).abstained)
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
        (do s <- judgeWith (JudgeOpts 1 [JudgeExample "e" True Nothing] AbstainFails)
                   id "r" ("out" :: Text)
            extra <- complete []
            pure (s.value, extra))))
  , check "runEvalWith: rubric and checklist both score under example opts"
      1.0
      ((runPureEff (runLLMScripted
         [ "{\"why\":\"y\",\"pass\":true}", "{\"why\":\"y\",\"pass\":true}" ]
         (Embed.none (runEvalWith (JudgeOpts 1 [JudgeExample "e" True Nothing] AbstainFails) id pure
            [ Case ("x" :: Text) "rub" (Rubric "r")
            , Case "y" "chk" (Checklist [criterion "c"]) ])))).passRate)
  , check "calibrateWith: examples held out of measurement"
      (CalibrationReport 1.0 0 1.0 1.0 [] [] 2 2 (0, 0) [] 1.0 1.0 1.0, "leftover")
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
  , check "bootstrapStdErr: identical values -> 0"
      0.0
      (bootstrapStdErr 1 1000 [0.5, 0.5, 0.5, 0.5])
  , check "bootstrapStdErr: single / empty -> 0"
      (0.0, 0.0)
      (bootstrapStdErr 1 1000 [0.7], bootstrapStdErr 1 1000 [])
  , check "bootstrapStdErr: spread -> positive, deterministic per seed"
      True
      (let xs = [0.0, 0.25, 0.5, 0.75, 1.0, 0.1, 0.9]
       in bootstrapStdErr 9 1000 xs > 0 && bootstrapStdErr 9 1000 xs == bootstrapStdErr 9 1000 xs)
  , check "renderCalibration: kappa line carries the CI"
      True
      (T.isInfixOf "[95% CI "
        (renderCalibration (CalibrationReport 1 0 1 1 [] [] 0 4 (0, 0) [] 1 1 1)))
  , check "renderCalibration: examples line only when used"
      (True, False)
      (let withEx    = CalibrationReport 1 0 1 1 [] [] 2 2 (0, 0) [] 1 1 1
           withoutEx = CalibrationReport 1 0 1 1 [] [] 0 4 (0, 0) [] 1 1 1
       in ( T.isInfixOf "examples fed: 2" (renderCalibration withEx)
          , T.isInfixOf "examples fed" (renderCalibration withoutEx)))
  , check "reportFromVerdicts: perfect agreement, kappa 1, measured 2"
      (1.0, 1.0, 2)
      (let r = reportFromVerdicts 0 [("a", True, Just True), ("b", False, Just False)]
       in (r.agreement, r.kappa, r.measured))
  , check "reportFromVerdicts: all-same class is degenerate kappa 0"
      (1.0, 0.0)
      (let r = reportFromVerdicts 0 [("a", True, Just True), ("b", True, Just True)]
       in (r.agreement, r.kappa))
  , check "reportFromVerdicts: errored case excluded from stats, listed"
      (1.0, 1, ["b"])
      (let r = reportFromVerdicts 0 [("a", True, Just True), ("b", False, Nothing)]
       in (r.agreement, r.measured, r.judgeErrors))
  , check "reportFromVerdicts: fail precision/recall on mixed verdicts"
      (0.5, 0.5, 0.5)
      (let r = reportFromVerdicts 0
                 [ ("a", True,  Just True),  ("b", False, Just False)
                 , ("c", True,  Just False), ("d", False, Just True) ]
       in (r.agreement, r.failPrecision, r.failRecall))
  , check "reportFromVerdicts: fail precision and recall are distinct"
      (1.0, 0.5)
      (let r = reportFromVerdicts 0 [("a", False, Just False), ("b", False, Just True)]
       in (r.failPrecision, r.failRecall))
  , check "reportFromVerdicts: empty input is the degenerate report"
      (CalibrationReport 0 0 1.0 1.0 [] [] 0 0 (0, 0) [] 1.0 1.0 1.0)
      (reportFromVerdicts 0 [])
  , check "reportFromVerdicts: balanced-F1 averages distinct per-class F1s"
      True
      (let r = reportFromVerdicts 0
                 [ ("a", True,  Just True),  ("b", True,  Just True)
                 , ("c", False, Just False), ("d", False, Just True) ]
           near x y = abs (x - y) < 1e-9
       in near r.passF1 0.8 && near r.failF1 (2/3)
          && near r.balancedF1 ((0.8 + 2/3) / 2) && r.passF1 /= r.failF1)
  , check "reportFromVerdicts: CI brackets the point estimate"
      True
      (let r = reportFromVerdicts 7
                 [ ("a", True, Just True), ("b", True, Just False), ("c", False, Just False)
                 , ("d", False, Just True), ("e", True, Just True), ("f", False, Just False) ]
           (lo, hi) = r.kappaCI
       in lo <= r.kappa && r.kappa <= hi)
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
         (Embed.none (do rep <- runEvalN 3 id pure [Case ("text" :: Text) "g" (Grounded "ev")]
                         extra <- complete []
                         pure (rep.passRate, extra)))))
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
             (Embed.none (improveSkill 1 id sk)))
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
             (Embed.none (improveSkill 1 id sk)))
       in (best.instruction.preamble == "", map (.accepted) steps))
  , check "improveSkill: reflector junk burns the round, loop survives"
      [False]
      (let sk = withTests [Case ("in" :: Text) "c" (Exactly ("GOOD" :: Text))]
                  (withRetries 0 (skill "s" C.str C.str ("Echo: " <>)))
           (_, steps) = runPureEff (runLLMScripted
             [ "\"BAD\"", "j1", "j2", "j3" ]                                    -- reflector retries 2 = 3 replies
             (Embed.none (improveSkill 1 id sk)))
       in map (.accepted) steps)
  , check "improveSkill: empty tests -> immediate return, zero calls"
      (True, "leftover")
      (runPureEff (runLLMScripted ["leftover"]
        (Embed.none (do (_, steps) <- improveSkill 3 id (skill "s" C.str (C.str :: JSONCodec Text) ("Echo: " <>))
                        extra <- complete []
                        pure (null steps, extra)))))
  , check "improveSkill: all-passing baseline -> no reflection call"
      (True, "leftover")
      (runPureEff (runLLMScripted ["\"GOOD\"", "leftover"]
        (Embed.none (do (_, steps) <- improveSkill 3 id
                          (withTests [Case ("in" :: Text) "c" (Exactly ("GOOD" :: Text))]
                             (withRetries 0 (skill "s" C.str C.str ("Echo: " <>))))
                        extra <- complete []
                        pure (null steps, extra)))))
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
       let asyncProvider = Provider "a" "fake-model"
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
  -- crucible-c11: providers carry their models
  , do let acfg = defaultAnthropicConfig "k"
           ocfg = defaultOpenAIConfig "k"
       p <- Anthropic.provider acfg
       q <- OpenAI.provider ocfg
       check "providers: constructors fill model from config"
         (acfg.model, ocfg.model) (p.model, q.model)
  -- crucible-c11: CallLog decorator
  , do lg <- CallLog.new; c1 <- newIORef 0
       let p = goodProvider "a" c1 "from-a"
       r  <- runEff (Fallback.run [CallLog.logging lg p] (complete []))
       r0 <- runEff (Fallback.run [p] (complete []))
       es <- CallLog.drain lg
       check "calllog: success entry records provider/model/usage; decoration transparent"
         (True, [("a", "fake-model", Right (Usage 1 2))], True)
         ( r == r0 && r == "from-a"
         , [(e.provider, e.model, e.outcome) | e <- es]
         , all (\e -> e.durationMs >= 0) es )
  , do lg <- CallLog.new; c1 <- newIORef 0; c2 <- newIORef 0
       r <- runEff (Fallback.run
              (map (CallLog.logging lg) [badProvider "a" c1, goodProvider "b" c2 "from-b"])
              (complete []))
       es <- CallLog.drain lg
       check "calllog: failed attempts log in tried order before the answer"
         ("from-b", ["a", "b"], (True, True))
         ( r
         , map (.provider) es
         , case map (.outcome) es of
             [Left m, Right u] -> (T.isInfixOf "down" m, u == Usage 1 2)
             _                 -> (False, False) )
  , do lg <- CallLog.new; c1 <- newIORef 0
       let ps = [CallLog.logging lg (goodProvider "a" c1 "ok")]
       _ <- runEff (Fallback.run ps (complete []))
       es1 <- CallLog.drain lg
       es2 <- CallLog.drain lg
       _ <- runEff (Fallback.run ps (complete []))
       es3 <- CallLog.drain lg
       check "calllog: drain reads and clears; later calls land in the next window"
         (1 :: Int, 0 :: Int, 1 :: Int) (length es1, length es2, length es3)
  , do lg <- CallLog.new; c1 <- newIORef 0
       r <- runEff (Fallback.runChat [CallLog.logging lg (goodProvider "a" c1 "t")]
              (converse [] []))
       es <- CallLog.drain lg
       check "calllog: chat path records too"
         (Turn "t" [], [Right (Usage 1 2)]) (r, map (.outcome) es)
  , do lg <- CallLog.new; c1 <- newIORef 0; c2 <- newIORef 0
       let ps = map (CallLog.logging lg) [goodProvider "a" c1 "from-a", goodProvider "b" c2 "from-b"]
       _ <- runEff (Fallback.roundRobin ps (do _ <- complete []; _ <- complete []; pure ()))
       es <- CallLog.drain lg
       check "calllog: round-robin rotation is visible in the log"
         ["a", "b"] (map (.provider) es)
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
  -- crucible-2zw: Metric expectation + pass rule
  , check "metric: scalars land in meanScore; threshold gates passRate"
      (0.5, 0.5)
      (let rep = runPureEff (runLLMScripted []
                   (Embed.none (runEval id pure
                      [ Case ("hello" :: Text) "hit"  (Metric 0.5 (normMatch "Hello "))
                      , Case "bye" "miss" (Metric 0.5 (normMatch "Hello ")) ])))
       in (rep.passRate, rep.meanScore))
  , check "metric: values clamp into [0,1]"
      (1.0, 0.0)
      (let s1 = runPureEff (runLLMScripted [] (Embed.none (scoreM id (Metric 1.0 (const 1.5)) ("x" :: Text))))
           s0 = runPureEff (runLLMScripted [] (Embed.none (scoreM id (Metric 0.0 (const (-0.5))) ("x" :: Text))))
       in (s1.value, s0.value))
  -- crucible-2zw: Scale expectation
  , check "scale: single vote level 4 of 5"
      (0.75, "level 4 of 5: polite", Nothing)
      (let s = runPureEff (runLLMScripted ["{\"why\":\"polite\",\"level\":4}"]
                 (Embed.none (scoreM id (Scale 4 "politeness" [(1, "rude"), (5, "warm")]) ("out" :: Text))))
       in (s.value, s.rationale, s.votes))
  , check "scale: median of (3,4,4) is 4 with tally (2,1), no dissent at spread 1"
      (0.75, Just (2, 1), Nothing)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"meh\",\"level\":3}"
                 , "{\"why\":\"good\",\"level\":4}"
                 , "{\"why\":\"good\",\"level\":4}" ]
                 (Embed.none (scoreN 3 id (Scale 4 "r" [(1, "bad"), (5, "good")]) ("out" :: Text))))
       in (s.value, s.votes, s.dissent))
  , check "scale: spread beyond one level records dissent"
      (Just (2, 1), Just "awful")
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"awful\",\"level\":1}"
                 , "{\"why\":\"good\",\"level\":4}"
                 , "{\"why\":\"good\",\"level\":4}" ]
                 (Embed.none (scoreN 3 id (Scale 4 "r" [(1, "bad"), (5, "good")]) ("out" :: Text))))
       in (s.votes, s.dissent))
  , check "scale: out-of-range level takes the judge-error path"
      (0.0, True)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"x\",\"level\":7}", "{\"why\":\"x\",\"level\":9}" ]
                 (Embed.none (scoreM id (Scale 4 "r" [(1, "bad"), (5, "good")]) ("out" :: Text))))
       in (s.value, T.isInfixOf "judge error: " s.rationale))
  , check "scale: anchors without a top level are a judge error"
      (0.0, True)
      (let s = runPureEff (runLLMScripted []
                 (Embed.none (scoreM id (Scale 1 "r" [(1, "only")]) ("out" :: Text))))
       in (s.value, T.isInfixOf "judge error: " s.rationale))
  -- crucible-2zw: per-expectation pass rule, mixed dataset
  , check "passRate: per-expectation thresholds across a mixed dataset"
      (2 / 3, 2 / 3)
      (let rep = runPureEff (runLLMScripted ["{\"why\":\"mid\",\"level\":3}"]
                   (Embed.none (runEval id pure
                      [ Case ("x" :: Text) "exact" (Exactly "x")
                      , Case "y" "metric-borderline" (Metric 0.5 (const 0.5))
                      , Case "z" "scale-fail" (Scale 4 "r" [(1, "bad"), (5, "good")]) ])))
       in (rep.passRate, rep.meanScore))
  -- crucible-d4w: embeddings (pure math + scripted interpreter)
  , check "cosine: orthogonal and zero-vector cases are 0"
      (0.0, 0.0) (cosine [1, 0] [0, 1], cosine [0, 0] [1, 1])
  , check "cosine: identical is 1; hand value 1/sqrt 2"
      (True, True)
      ( abs (cosine [1, 2] [1, 2] - 1.0) < 1e-9
      , abs (cosine [1, 0] [1, 1] - 1 / sqrt 2) < 1e-9 )
  , check "consistency: mean pairwise cosine over a group"
      True
      (let r = runPureEff (runEmbedScripted [[1, 0], [0, 1], [1, 1]]
                 (consistency ["a", "b", "c"]))
       in abs (r - sqrt 2 / 3) < 1e-9)
  , check "consistency: empty and singleton groups score 1.0"
      (1.0, 1.0)
      ( runPureEff (runEmbedScripted [] (consistency []))
      , runPureEff (runEmbedScripted [] (consistency ["only"])) )
  , check "embed: a dry script yields the empty vector"
      ([] :: [Double])
      (runPureEff (runEmbedScripted [] (embed "x")))
  -- crucible-d4w: embedding wire formats (pure)
  , check "openai embed: request body pins model and input"
      (A.object ["model" A..= ("text-embedding-3-small" :: Text), "input" A..= ("hello" :: Text)])
      (OpenAI.embedRequestJson (defaultOpenAIConfig "k") "hello")
  , check "openai embed: response decode pulls data[0].embedding"
      (Right [0.1, 0.2 :: Double])
      (OpenAI.extractEmbedding "{\"data\":[{\"embedding\":[0.1,0.2]}]}")
  , check "voyage embed: request body wraps input in an array"
      (A.object ["model" A..= ("voyage-3.5-lite" :: Text), "input" A..= (["hello"] :: [Text])])
      (Voyage.embedRequestJson (Voyage.defaultVoyageConfig "k") "hello")
  , check "voyage embed: response decode + junk rejection"
      (Right [1.5 :: Double], True)
      ( Voyage.extractEmbedding "{\"data\":[{\"embedding\":[1.5]}]}"
      , case Voyage.extractEmbedding "junk" of Left _ -> True; Right _ -> False )
  -- crucible-d4w: SimilarTo expectation
  , check "similarTo: identical embeddings score 1.0, no votes"
      (1.0, Nothing)
      (let s = runPureEff (runLLMScripted [] (runEmbedScripted [[1, 0], [1, 0]]
                 (scoreM id (SimilarTo 0.8 "ref") ("out" :: Text))))
       in (s.value, s.votes))
  , check "similarTo: hand cosine lands in value"
      True
      (let s = runPureEff (runLLMScripted [] (runEmbedScripted [[1, 0], [1, 1]]
                 (scoreM id (SimilarTo 0.8 "ref") ("out" :: Text))))
       in abs (s.value - 1 / sqrt 2) < 1e-9)
  , check "similarTo: negative cosine clamps to 0"
      0.0
      ((runPureEff (runLLMScripted [] (runEmbedScripted [[1, 0], [-1, 0]]
          (scoreM id (SimilarTo 0.5 "ref") ("out" :: Text))))).value)
  , check "similarTo: threshold gates passRate in a mixed dataset"
      (0.5, 0.5)
      (let rep = runPureEff (runLLMScripted [] (runEmbedScripted [[1, 0], [0, 1]]
                   (runEval id pure
                      [ Case ("x" :: Text) "exact" (Exactly "x")
                      , Case "y" "orthogonal" (SimilarTo 0.8 "ref") ])))
       in (rep.passRate, rep.meanScore))
  , do r <- try (evaluate (runPureEff (runLLMScripted [] (Embed.none
              (scoreM id (SimilarTo 0.8 "ref") ("out" :: Text))))))
       check "embed: none errors clearly when a program embeds"
         True
         (case r of
            Left (e :: SomeException) -> T.isInfixOf "Crucible.Embed.none" (T.pack (show e))
            Right s -> s.value < 0)  -- unreachable; forces the Score
  -- crucible-ic0: rubric lint
  , check "lintPrompt: lists labels, the four checks, and the precision rule"
      (True, True, True, True, True, True)
      (case lintPrompt ["a and b", "clear one"] of
         [Message _ sys, Message _ usr] ->
           let hay = sys <> "\n" <> usr
           in ( T.isInfixOf "a and b" hay
              , T.isInfixOf "conflation" hay
              , T.isInfixOf "direction" hay
              , T.isInfixOf "redundancy" hay
              , T.isInfixOf "vague" hay
              , T.isInfixOf "clear violations" sys )
         _ -> (False, False, False, False, False, False))
  , check "lint: a reply with findings decodes to typed findings"
      [ Finding Conflation "mentions city and temp" "tests two things"
      , Finding Vague "good" "unfalsifiable" ]
      (runPureEff (runLLMScripted
        [ "[{\"issue\":\"conflation\",\"criterion\":\"mentions city and temp\",\"note\":\"tests two things\"},{\"issue\":\"vague\",\"criterion\":\"good\",\"note\":\"unfalsifiable\"}]" ]
        (lintChecklist [criterion "mentions city and temp", criterion "good"])))
  , check "lint: a clean checklist yields no findings"
      ([] :: [LintFinding])
      (runPureEff (runLLMScripted ["[]"] (lintChecklist [criterion "avoids jargon"])))
  , check "lint: empty checklist short-circuits with no judge call"
      ([] :: [LintFinding])
      (runPureEff (runLLMScripted [] (lintChecklist [])))
  , check "lint: feeds labels not weights to the prompt"
      (True, False)
      (case lintPrompt (map ((.label) :: Criterion -> Text) [Criterion "alpha" 7]) of
         [_, Message _ usr] -> (T.isInfixOf "alpha" usr, T.isInfixOf "7" usr)
         _ -> (False, True))
  , check "lint: unparseable reply after repair returns LintUnavailable"
      True
      (case runPureEff (runLLMScripted ["junk", "junk2"] (lintChecklist [criterion "x"])) of
         [LintUnavailable m] -> not (T.null m)
         _                   -> False)
  , check "lint: an unknown issue tag drives the repair re-prompt"
      [Finding Direction "x" "fixed"]
      (runPureEff (runLLMScripted
        [ "[{\"issue\":\"bogus\",\"criterion\":\"x\",\"note\":\"n\"}]"
        , "[{\"issue\":\"direction\",\"criterion\":\"x\",\"note\":\"fixed\"}]" ]
        (lintChecklist [criterion "x"])))
  , check "abstain: a standalone rubric abstain scores 0 with the abstained tag"
      (0.0, True)
      (let s = runPureEff (runLLMScripted ["{\"why\":\"no info\",\"verdict\":\"cannot_assess\"}"]
                 (judge id "r" ("out" :: Text)))
       in (s.value, T.isInfixOf "judge abstained: " s.rationale))
  , check "abstain: AbstainFails keeps an abstained positive criterion in the denominator"
      True
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"y\",\"verdict\":\"pass\"}"
                 , "{\"why\":\"no info\",\"verdict\":\"cannot_assess\"}" ]
                 (Embed.none (scoreM id (Checklist [criterion "a", criterion "b"]) ("out" :: Text))))
       in abs (s.value - 0.5) < 1e-9)
  , check "abstain: AbstainSkips drops an abstained criterion from the denominator"
      (1.0, True)
      (let s = runPureEff (runLLMScripted
                 [ "{\"why\":\"y\",\"verdict\":\"pass\"}"
                 , "{\"why\":\"no info\",\"verdict\":\"cannot_assess\"}" ]
                 (Embed.none (scoreWith (defaultJudgeOpts { abstain = AbstainSkips }) id
                    (Checklist [criterion "a", criterion "b"]) ("out" :: Text))))
       in (s.value, T.isInfixOf "[skip] b" s.rationale))
  , check "abstain: a penalty abstain clears under AbstainFails"
      1.0
      ((runPureEff (runLLMScripted
         [ "{\"why\":\"y\",\"verdict\":\"pass\"}"
         , "{\"why\":\"no info\",\"verdict\":\"cannot_assess\"}" ]
         (Embed.none (scoreM id (Checklist [criterion "a", penalty 1 "recommends a product"]) ("out" :: Text))))).value)
  , check "renderReport: abstained case is annotated distinctly from judge error"
      (True, False)
      (let rep = runPureEff (runLLMScripted ["{\"why\":\"no info\",\"verdict\":\"cannot_assess\"}"]
                   (Embed.none (runEval id pure [Case ("x" :: Text) "a" (Rubric "r")])))
           t = renderReport rep
       in (T.isInfixOf "[judge abstained]" t, T.isInfixOf "[judge error]" t))
  -- crucible-mti: refine (hard) and checked (soft)
  , check "refine: a satisfying value decodes, a violating one fails with the message"
      (Right 5 :: Either DecodeError Int, True)
      ( decodeLLM (refine "must be positive" (> 0) C.int) "5"
      , case decodeLLM (refine "must be positive" (> 0) C.int) "-3" of
          Left e -> T.isInfixOf "must be positive" e.message
          Right (_ :: Int) -> False )
  , check "refine: the message is surfaced in the schema description"
      True
      (T.isInfixOf "must be positive" (schemaText (refine "must be positive" (> 0) C.int)))
  , check "refine: a field-level violation carries the constraint message"
      True
      (case decodeLLM (C.object (C.field "age" Prelude.id
              (refine "age must be 0..130" (\a -> a >= 0 && a <= 130) C.int))) "{\"age\": 200}" of
         Left e -> T.isInfixOf "age must be 0..130" e.message
         Right (_ :: Int) -> False)
  , check "refine: call retries on a violation then succeeds"
      (Right 42 :: Either DecodeError Int)
      (runPureEff (runLLMScripted ["{\"n\": -1}", "{\"n\": 42}"]
         (call (skill "s" C.str
                  (C.object (C.field "n" Prelude.id (refine "n must be positive" (> 0) C.int)))
                  (\x -> "give n for " <> x))
               ("in" :: Text))))
  , check "refine: with no retries a violation is returned"
      True
      (case runPureEff (runLLMScripted ["{\"n\": -1}"]
              (call (withRetries 0 (skill "s" C.str
                       (C.object (C.field "n" Prelude.id (refine "n must be positive" (> 0) C.int)))
                       (\x -> "give n for " <> x)))
                    ("in" :: Text))) of
         Left e -> T.isInfixOf "n must be positive" e.message
         Right (_ :: Int) -> False)
  , check "checked: a passing value wraps with all checks true"
      (Checked ("hi" :: Text) [("nonempty", True), ("short", True)], True)
      (let cv = either (const (Checked "" [])) Prelude.id
                  (decodeLLM (checked [("nonempty", not . T.null), ("short", (< 10) . T.length)] C.str)
                     "\"hi\"")
       in (cv, allPassed cv))
  , check "checked: a failing value preserves the value and marks the failing check"
      (Checked ("" :: Text) [("nonempty", False), ("short", True)], False)
      (let cv = either (const (Checked "x" [])) Prelude.id
                  (decodeLLM (checked [("nonempty", not . T.null), ("short", (< 10) . T.length)] C.str)
                     "\"\"")
       in (cv, allPassed cv))
  , check "checked: the advertised schema is the inner codec's"
      True
      (schemaText (checked [("nonempty", not . T.null)] C.str) == schemaText C.str)
  -- crucible-n0p: dynamic codec from a runtime list (schema follows the data)
  , check "dynamic enum: schema lists the runtime categories; decode honours them"
      (True, True, Right ("urgent" :: Text), True)
      (let cats = ["urgent", "normal", "low"] :: [Text]
           c    = C.enum (zip cats cats)
           sch  = schemaText c
       in ( T.isInfixOf "urgent" sch
          , T.isInfixOf "low" sch
          , decodeLLM c "\"urgent\""
          , case decodeLLM c "\"bogus\"" of Left _ -> True; Right (_ :: Text) -> False ) )
  -- crucible-2ey: closeJson (partial JSON completion)
  , check "closeJson: closes a partial value string"
      "{\"name\":\"Ali\"}"        (closeJson "{\"name\":\"Ali")
  , check "closeJson: complete-but-unclosed object"
      "{\"name\":\"Bob\",\"age\":3}" (closeJson "{\"name\":\"Bob\",\"age\":3")
  , check "closeJson: drops a trailing comma"
      "{\"a\":1}"                 (closeJson "{\"a\":1,")
  , check "closeJson: drops a key with no value"
      "{}"                        (closeJson "{\"a\":")
  , check "closeJson: drops an incomplete key"
      "{}"                        (closeJson "{\"na")
  , check "closeJson: drops a partial literal"
      "{}"                        (closeJson "{\"a\":tr")
  , check "closeJson: nested object, value string and stack closed in order"
      "{\"a\":1,\"b\":{\"c\":\"x\"}}" (closeJson "{\"a\":1,\"b\":{\"c\":\"x")
  , check "closeJson: already-closed and trivial inputs"
      ("{}", "")                  (closeJson "{}", closeJson "")
  , check "closeJson: drops a partial unicode escape in a value string"
      ("{\"a\":\"x\"}", "{\"a\":\"x\"}")
      (closeJson "{\"a\":\"x\\u00", closeJson "{\"a\":\"x\\u")
  , check "closeJson: keeps a complete unicode escape"
      "{\"a\":\"x\\u00e9\"}"      (closeJson "{\"a\":\"x\\u00e9")
  , check "closeJson: drops a complete key with no colon"
      ("{}", "{\"a\":1}")
      (closeJson "{\"name\"", closeJson "{\"a\":1,\"b\"")
  , check "closeJson: keeps an escaped backslash then closes"
      "{\"a\":\"x\\\\\"}"         (closeJson "{\"a\":\"x\\\\")
  -- crucible-2ey: runPartial end-to-end
  , check "runPartial: the final partial has all fields; a leading blank emits nothing"
      (Just (Just "Alice", Just 30))
      (let (_, ps) = runPureEff (runPartial (codec @PersonP)
                       (mapM_ emit ["", "{\"ppName\": \"Al", "ice\", \"ppAge\": 3", "0}"]))
           lastRight xs = case [a | Right a <- xs] of [] -> Nothing; rs -> Just (last rs)
       in fmap (\p -> (ppName p, ppAge p)) (lastRight ps))
  , check "runPartial: an intermediate partial shows the arrived field only"
      (Just (Just "Al", Nothing))
      (let (_, ps) = runPureEff (runPartial (codec @PersonP)
                       (mapM_ emit ["{\"ppName\": \"Al", "ice\", \"ppAge\": 3", "0}"]))
           rights' = [a | Right a <- ps]
       in case rights' of (p : _) -> Just (ppName p, ppAge p); [] -> Nothing)
  -- crucible-l9d: Memory foundation (pure + scripted + typed recall)
  , check "memory: remember then recall-all returns the item with assigned id"
      (MemoryId 0, "hello", 0 :: Int)
      (let (_, items) = runPureEff (runMemoryPure
              (remember (MemoryDraft Episodic "hello" ["greet"] (BySkill "s"))
               >> recall (Query "" [] 10)))
           it = head items
       in (it.memId, it.content, it.createdAt))
  , check "memory: tag filter and case-folded needle"
      (["alpha"], ["beta"])
      (let prog = do _ <- remember (MemoryDraft Semantic "Alpha" ["a"] Curated)
                     _ <- remember (MemoryDraft Semantic "Beta" ["b"] Curated)
                     byTag <- recall (Query "" ["a"] 10)
                     byNeedle <- recall (Query "bet" [] 10)
                     pure (map (.content) byTag, map (.content) byNeedle)
           ((tg, nd), _) = runPureEff (runMemoryPure prog)
       in (map T.toLower tg, map T.toLower nd))
  , check "memory: maxItems caps and ordering is most-recent-first"
      ["c", "b"]
      (let prog = do mapM_ (\t -> remember (MemoryDraft Episodic t [] Curated)) ["a","b","c"]
                     recall (Query "" [] 2)
           (out, _) = runPureEff (runMemoryPure prog)
       in map (.content) out)
  , check "memory: forget removes from live recall but keeps the others"
      ["a", "c"]
      (let prog = do _ <- remember (MemoryDraft Episodic "a" [] Curated)
                     _ <- remember (MemoryDraft Episodic "b" [] Curated)
                     _ <- remember (MemoryDraft Episodic "c" [] Curated)
                     forget (MemoryId 1)
                     recall (Query "" [] 10)
           (out, _) = runPureEff (runMemoryPure prog)
       in reverse (map (.content) out))
  , check "memory: all four provenance arms round-trip and are matchable"
      (True, True, True, True)
      (let (_, items) = runPureEff (runMemoryPure (do
              mapM_ remember
                [ MemoryDraft Episodic "p" [] (BySkill "k")
                , MemoryDraft Episodic "q" [] (BySession "run1")
                , MemoryDraft Episodic "r" [] ByConsolidation
                , MemoryDraft Episodic "s" [] Curated ]
              recall (Query "" [] 10)))
           has p = any (\it -> it.source == p) items
       in (has (BySkill "k"), has (BySession "run1"), has ByConsolidation, has Curated))
  , check "memory scripted: canned recalls pop in order; remember ids increment"
      ([["x"]], [], MemoryId 0)
      (let canned = [[MemoryItem (MemoryId 9) Episodic "x" [] Curated 9]]
           prog = do i <- remember (MemoryDraft Episodic "ignored" [] Curated)
                     r1 <- recall (Query "" [] 10)
                     r2 <- recall (Query "" [] 10)
                     pure (map (map (.content)) [r1], map (.content) r2, i)
           (a, b, c) = runPureEff (runMemoryScripted canned prog)
       in (a, b, c))
  , check "memory recallAs: typed round-trip and staleness on schema drift"
      (Right (42 :: Int), True)
      (let prog = do _ <- remember (MemoryDraft Semantic (C.encodeText C.int 42) ["n"] Curated)
                     _ <- remember (MemoryDraft Semantic "not a number" ["n"] Curated)
                     recallAs C.int (Query "" ["n"] 10)
           (out, _) = runPureEff (runMemoryPure prog)
           rs = map snd out
       in ( case [v | Right v <- rs] of (v : _) -> Right v; [] -> Left ()
          , any (\e -> case e of { Left _ -> True; Right _ -> False }) rs ))
  , do (path, h) <- openTempFile "/tmp" "crucible-mem-test.jsonl"
       hClose h
       items <- runEff (runMemoryFile path (do
                  _ <- remember (MemoryDraft Episodic "alpha" ["x"] (BySkill "k"))
                  _ <- remember (MemoryDraft Semantic "beta" ["y"] Curated)
                  forget (MemoryId 0)
                  recall (Query "" [] 10)))
       raw <- TIO.readFile path
       removeFile path
       check "memory file: recall folds tombstones; history stays in the file"
         (["beta"], True, True)
         ( map (.content) items
         , T.isInfixOf "alpha" raw
         , T.isInfixOf "\"forgot\"" raw )
  , do (path, h) <- openTempFile "/tmp" "crucible-mem-prov.jsonl"
       hClose h
       items <- runEff (runMemoryFile path (do
                  mapM_ remember
                    [ MemoryDraft Episodic   "a" [] (BySkill "k")
                    , MemoryDraft Semantic   "b" [] (BySession "run1")
                    , MemoryDraft Procedural "c" [] ByConsolidation
                    , MemoryDraft Episodic   "d" [] Curated ]
                  recall (Query "" [] 10)))
       removeFile path
       let found c p = any (\it -> it.content == c && it.source == p) items
       check "memory file: provenance arms and kinds round-trip through JSONL"
         (4 :: Int, True)
         ( length items
         , found "a" (BySkill "k") && found "b" (BySession "run1")
             && found "c" ByConsolidation && found "d" Curated )
  , do store <- newMemoryStorePure
       got <- runEff $ runMemoryWith store $ do
                i1 <- remember (MemoryDraft Semantic "alpha fact" ["t"] Curated)
                _  <- remember (MemoryDraft Semantic "beta fact" ["t"] Curated)
                forget i1
                rs <- recall (Query "" ["t"] 10)
                pure (map ((.content) :: MemoryItem -> Text) rs)
       check "memory: runMemoryWith pure handle remembers/forgets/recalls" ["beta fact"] got
  , do (path, h) <- openTempFile "/tmp" "crucible-memory-parity.jsonl"
       hClose h
       let prog = do _  <- remember (MemoryDraft Semantic "a" ["x"] Curated)
                     i2 <- remember (MemoryDraft Episodic "b" ["x"] Curated)
                     _  <- remember (MemoryDraft Semantic "c" ["x"] Curated)
                     forget i2
                     map ((.content) :: MemoryItem -> Text) <$> recall (Query "" ["x"] 10)
       fromFile <- runEff (runMemoryWith (memoryStoreFile path) prog)
       removeFile path `catch` \(_ :: SomeException) -> pure ()
       store <- newMemoryStorePure
       fromPure <- runEff (runMemoryWith store prog)
       check "memory: file and pure handles agree (remember/forget/recall)" fromFile fromPure
  -- crucible-cyx: memory consolidation
  , check "consolidate applyPlan: drop/supersede/merge rewrite the store, ByConsolidation"
      (["CD", "B2"], Semantic, ["t4", "t3"], ByConsolidation)
      (let prog = do
             mapM_ remember
               [ MemoryDraft Episodic "a" ["t1"] Curated
               , MemoryDraft Episodic "b" ["t2"] Curated
               , MemoryDraft Episodic "c" ["t3"] Curated
               , MemoryDraft Episodic "d" ["t4"] Curated ]
             cur <- recall (Query "" [] 100)
             applyPlan cur (ConsolidationPlan
               [ Drop (MemoryId 0)
               , Supersede (MemoryId 1) Semantic "B2"
               , Merge [MemoryId 2, MemoryId 3] Semantic "CD" ])
             recall (Query "" [] 100)
           (out, _) = runPureEff (runMemoryPure prog)
           cd = head out
       in (map (.content) out, cd.kind, cd.tags, cd.source))
  , check "consolidate unaddressed: items no op references"
      ["b"]
      (let items = [ MemoryItem (MemoryId 0) Episodic "a" [] Curated 0
                   , MemoryItem (MemoryId 1) Episodic "b" [] Curated 1 ]
       in map (.content) (unaddressed items (ConsolidationPlan [Drop (MemoryId 0)])))
  , check "consolidationSkill: decodes a scripted plan array"
      (ConsolidationPlan [Drop (MemoryId 0), Merge [MemoryId 1, MemoryId 2] Semantic "merged"])
      (runPureEff (runLLMScripted
         ["[{\"op\":\"drop\",\"id\":0},{\"op\":\"merge\",\"ids\":[1,2],\"kind\":\"semantic\",\"content\":\"merged\"}]"]
         (either (const (ConsolidationPlan [])) Prelude.id <$> call consolidationSkill [])))
  , check "consolidate end to end: scripted plan applied to the pure store"
      ["merged"]
      (let prog = do mapM_ remember [ MemoryDraft Episodic "x" ["a"] Curated
                                    , MemoryDraft Episodic "y" ["a"] Curated ]
                     _ <- consolidate consolidationSkill (Query "" [] 100)
                     recall (Query "" [] 100)
           (out, _) = runPureEff (runLLMScripted
                        ["[{\"op\":\"merge\",\"ids\":[0,1],\"kind\":\"semantic\",\"content\":\"merged\"}]"]
                        (runMemoryPure prog))
       in map (.content) out)
  -- Memory.Eval renderMemories/withMemories
  , let mi c = MemoryItem (MemoryId 0) Semantic c [] Curated 0
        m1 = mi "The user prefers dark mode."
        m2 = mi "The user's name is Gareth."
    in check "renderMemories: lists content with a header, in order"
         "Relevant memories from past sessions:\n- The user prefers dark mode.\n- The user's name is Gareth.\n"
         (renderMemories [m1, m2])
  , check "renderMemories: empty list is empty string"
      ""
      (renderMemories [])
  , let mi c = MemoryItem (MemoryId 0) Semantic c [] Curated 0
        m1 = mi "The user prefers dark mode."
        sk  = skill "s" C.str C.str (const "do it")
        sk' = withMemories [m1] sk
    in check "withMemories: appends to an empty preamble"
         (renderMemories [m1])
         (sk'.instruction :: Instruction Text).preamble
  , let mi c = MemoryItem (MemoryId 0) Semantic c [] Curated 0
        m1 = mi "The user prefers dark mode."
        sk  = withPreamble "BASE" (skill "s" C.str C.str (const "do it"))
        sk' = withMemories [m1] sk
    in check "withMemories: appends after an existing preamble"
         ("BASE\n\n" <> renderMemories [m1])
         (sk'.instruction :: Instruction Text).preamble
  , let sk  = withPreamble "BASE" (skill "s" C.str C.str (const "do it"))
        sk' = withMemories ([] :: [MemoryItem]) sk
    in check "withMemories: empty list leaves the preamble unchanged"
         "BASE"
         (sk'.instruction :: Instruction Text).preamble
  -- Memory.Eval liftDelta (pure arithmetic)
  , let rep pr ms = Report [] pr ms :: Report () ()
    in check "liftDelta lifted minus baseline"
         (0.5, 0.5)
         (liftDelta (rep 0.5 0.25, rep 1.0 0.75))
  , let rep pr ms = Report [] pr ms :: Report () ()
    in check "liftDelta negative when memories hurt"
         (-0.5, -0.5)
         (liftDelta (rep 1.0 1.0, rep 0.5 0.5))
  , let rep pr ms = Report [] pr ms :: Report () ()
    in check "liftDelta of equal reports is zero"
         (0.0, 0.0)
         (liftDelta (rep 0.7 0.7, rep 0.7 0.7))
  -- Memory.Eval memoryLift integration (scripted LLM + Embed.none)
  , let evalSkill = withTests
          [ Case ("q" :: Text) "case1" (Exactly ("answer" :: Text)) ]
          (skill "s" C.str C.str (const "produce the answer"))
        mems = [ MemoryItem (MemoryId 0) Semantic "a hint" [] Curated 0 ]
        -- str output codec expects a JSON-encoded string reply: "\"answer\""
        cannedReply = "\"answer\""
        (base, lifted) = runPureEff (runLLMScripted [cannedReply, cannedReply]
                           (Embed.none (memoryLift id evalSkill mems)))
    in check "memoryLift zero delta on identical outputs"
         (0.0, 0.0)
         (liftDelta (base, lifted))
  -- Memory.Eval memoryLift: both arms execute and score independently.
  -- runLLMScripted serves replies by position, so the baseline arm (run
  -- first) gets the failing reply and the lifted arm (run second) gets the
  -- passing one, giving a positive delta. This proves both reports carry
  -- real scores (not empty defaults) and that liftDelta's sign is correct.
  , let evalSkill = withTests
          [ Case ("q" :: Text) "case1" (Exactly ("answer" :: Text)) ]
          (skill "s" C.str C.str (const "produce the answer"))
        mems = [ MemoryItem (MemoryId 0) Semantic "a hint" [] Curated 0 ]
        (base, lifted) = runPureEff (runLLMScripted ["\"wrong\"", "\"answer\""]
                           (Embed.none (memoryLift id evalSkill mems)))
    in check "memoryLift positive delta when lifted arm passes"
         (1.0, 1.0)
         (liftDelta (base, lifted))
  , check "Media.imageB64 sets fields, no filename"
      (Media "image/png" "QUJD" Nothing)
      (imageB64 "image/png" "QUJD")
  , check "Media.pdfB64 sets application/pdf, no filename"
      (Media "application/pdf" "JVBERg==" Nothing)
      (pdfB64 "JVBERg==")
  , do (p, h) <- openTempFile "/tmp" "crucible-media-test.png"
       BSTEST.hPut h (BSTEST.pack [1,2,3,4]) >> hClose h
       m <- imageFile p
       removeFile p
       let okType = m.mediaType == "image/png"
           okData = B64TEST.decode (TE.encodeUtf8 m.dataB64) == Right (BSTEST.pack [1,2,3,4])
           okName = m.filename == Nothing
       check "Media.imageFile infers png + round-trips bytes" True (okType && okData && okName)
  , do (p, h) <- openTempFile "/tmp" "crucible-media-test.pdf"
       BSTEST.hPut h (BSTEST.pack [37,80,68,70]) >> hClose h
       m <- pdfFile p
       removeFile p
       let okType = m.mediaType == "application/pdf"
           okName = maybe False (T.isSuffixOf ".pdf") m.filename
       check "Media.pdfFile sets pdf type + filename" True (okType && okName)
  , check "blockJson: ImageBlock -> base64 image source"
      "{\"source\":{\"data\":\"QUJD\",\"media_type\":\"image/png\",\"type\":\"base64\"},\"type\":\"image\"}"
      (C.encodeText C.anyValue (Chat.blockJson (Chat.ImageBlock (imageB64 "image/png" "QUJD"))))
  , check "blockJson: DocumentBlock -> base64 document source"
      "{\"source\":{\"data\":\"JVBERg==\",\"media_type\":\"application/pdf\",\"type\":\"base64\"},\"type\":\"document\"}"
      (C.encodeText C.anyValue (Chat.blockJson (Chat.DocumentBlock (pdfB64 "JVBERg=="))))
  , check "OpenAI chatMessagesJson: text-only user stays a flat string"
      "[{\"content\":\"hi\",\"role\":\"user\"}]"
      (C.encodeText (C.list' C.anyValue) (OpenAI.chatMessagesJson (Chat.Message User [Chat.TextBlock "hi"])))
  , check "OpenAI chatMessagesJson: image user becomes a parts array"
      "[{\"content\":[{\"text\":\"look\",\"type\":\"text\"},{\"image_url\":{\"url\":\"data:image/png;base64,QUJD\"},\"type\":\"image_url\"}],\"role\":\"user\"}]"
      (C.encodeText (C.list' C.anyValue)
        (OpenAI.chatMessagesJson (Chat.Message User [Chat.TextBlock "look", Chat.ImageBlock (imageB64 "image/png" "QUJD")])))
  , check "OpenAI chatMessagesJson: pdf without filename defaults to document.pdf"
      "[{\"content\":[{\"file\":{\"file_data\":\"data:application/pdf;base64,JVBERg==\",\"filename\":\"document.pdf\"},\"type\":\"file\"}],\"role\":\"user\"}]"
      (C.encodeText (C.list' C.anyValue)
        (OpenAI.chatMessagesJson (Chat.Message User [Chat.DocumentBlock (pdfB64 "JVBERg==")])))
  , check "OpenAI chatMessagesJson: tool-result + media -> tool msg then user parts"
      "[{\"content\":\"done\",\"role\":\"tool\",\"tool_call_id\":\"u1\"},{\"content\":[{\"image_url\":{\"url\":\"data:image/png;base64,QUJD\"},\"type\":\"image_url\"}],\"role\":\"user\"}]"
      (C.encodeText (C.list' C.anyValue)
        (OpenAI.chatMessagesJson (Chat.Message User [Chat.ToolResultBlock "u1" (String "done"), Chat.ImageBlock (imageB64 "image/png" "QUJD")])))
  , check "mediaMessage: image then text, image routed to ImageBlock"
      True
      (case mediaMessage (skill "s" C.str C.str (const "extract")) ("" :: Text) [imageB64 "image/png" "QUJD"] of
         Chat.Message User (Chat.ImageBlock m : Chat.TextBlock _ : []) -> m.mediaType == "image/png"
         _ -> False)
  , check "mediaMessage: pdf routed to DocumentBlock"
      True
      (case mediaMessage (skill "s" C.str C.str (const "extract")) ("" :: Text) [pdfB64 "JVBERg=="] of
         Chat.Message User (Chat.DocumentBlock _ : Chat.TextBlock _ : []) -> True
         _ -> False)
  , check "callMedia: valid reply decodes to output"
      (Right ("hello" :: Text))
      (runPureEff (runChatScripted [Turn "\"hello\"" []]
        (callMedia (skill "s" C.str C.str (const "extract")) ("" :: Text) [imageB64 "image/png" "QUJD"])))
  , check "callMedia: bad reply then good reply recovers"
      (Right ("ok" :: Text))
      (runPureEff (runChatScripted [Turn "not json" [], Turn "\"ok\"" []]
        (callMedia (skill "s" C.str C.str (const "extract")) ("" :: Text) [imageB64 "image/png" "QUJD"])))
  , check "callMedia: all-bad past retries returns Left (isLeft)"
      True
      (either (const True) (const False)
        (runPureEff (runChatScripted [Turn "x" [], Turn "y" [], Turn "z" [], Turn "w" []]
          (callMedia (withRetries 1 (skill "s" C.str C.str (const "extract"))) ("" :: Text) [imageB64 "image/png" "QUJD"]))))
  -- Crucible.Eval.Latency: pure predicates
  , check "withinMs: under budget passes" True  (withinMs 100 (Timed () 50))
  , check "withinMs: over budget fails"  False (withinMs 100 (Timed () 150))
  , check "withinMs: at budget passes"   True  (withinMs 100 (Timed () 100))
  , check "maxLatencyMs: returns the largest" 30 (maxLatencyMs [Timed () 10, Timed () 30, Timed () 20])
  , check "maxLatencyMs: empty is zero" 0 (maxLatencyMs ([] :: [Timed ()]))
  , check "Timed Functor: maps value, keeps latency"
      (Timed (2 :: Int) 42)
      (fmap (+1) (Timed (1 :: Int) 42))
  -- Crucible.Eval.Latency: IOE timing tests
  , do t <- runEff (timed (pure (7 :: Int)))
       check "timed: preserves value, latency >= 0" True (t.value == 7 && t.latencyMs >= 0)
  , do t <- runEff (timed (liftIO (threadDelay 50000)))
       check "timed: a 50ms delay measures >= 30ms" True (t.latencyMs >= 30)
  , do ts <- runEff (timeEach pure [1, 2, 3 :: Int])
       check "timeEach: times each input, values preserved" True
         (map (.value) ts == [1, 2, 3] && all (\x -> x.latencyMs >= 0) ts)
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[] : '[])])
    in check "spawn: canned answer decodes to typed output"
         (Right (6 :: Int))
         (runPureEff (runAgentsScripted 5 ["{\"n\": 6}"] (spawn w 3)))
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[] : '[])])
    in check "spawn: undecodable answer -> WorkerDecodeFailed"
         True
         (case runPureEff (runAgentsScripted 5 ["not json"] (spawn w 3)) of
            Left (WorkerDecodeFailed nm _) -> nm == "double"
            _ -> False)
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[] : '[])])
    in check "spawn: budget cap exceeded on the second spawn"
         (Right (1 :: Int), Left (SpawnBudgetExceeded 1))
         (runPureEff (runAgentsScripted 1 ["{\"n\": 1}", "{\"n\": 2}"]
            (do a <- spawn w 0; b <- spawn w 0; pure (a, b))))
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[] : '[])])
    in check "spawn: parent branches on a typed result then spawns again"
         (Right (2 :: Int))
         (runPureEff (runAgentsScripted 2 ["{\"n\": 1}", "{\"n\": 2}"]
            (do r <- spawn w 0
                case r of
                  Right v -> spawn w v
                  Left e  -> pure (Left e))))
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[] : '[])])
    in check "spawn: exhausted script -> WorkerDecodeFailed"
         True
         (case runPureEff (runAgentsScripted 5 [] (spawn w 0)) of
            Left (WorkerDecodeFailed _ e) -> e.message == "no scripted answer"
            _ -> False)
  , check "workerPrompt contains system, schema, and input"
      True
      (let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[] : '[])])
           p = workerPrompt w 7
       in T.isInfixOf "double the input" p && T.isInfixOf "<input>\n7" p && T.isInfixOf "\"n\"" p)
  , check "AgentFailure Eq/Show round value"
      (SpawnBudgetExceeded 3) (SpawnBudgetExceeded 3)
  , do let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[Chat.Chat, IOE] : '[Chat.Chat, IOE])])
       r <- runEff (runChatScripted [Turn "{\"n\": 42}" []] (runAgents 5 (spawn w 21)))
       check "runAgents (scripted Chat): worker answer decodes to typed output" (Right (42 :: Int)) r
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[LLM] : '[LLM])])
        g = gate "the number is positive" (\n -> T.pack (show (n :: Int)))
    in check "spawnGated: judge passes -> Right o"
         (Right (6 :: Int))
         (runPureEff (runLLMScripted ["{\"verdict\":\"pass\",\"why\":\"ok\"}"]
            (runAgentsScripted 5 ["{\"n\": 6}"] (spawnGated g w 3))))
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[LLM] : '[LLM])])
        g = gate "the number is positive" (\n -> T.pack (show (n :: Int)))
    in check "spawnGated: reject then accept on retry"
         (Right (7 :: Int))
         (runPureEff (runLLMScripted ["{\"verdict\":\"fail\",\"why\":\"too small\"}", "{\"verdict\":\"pass\",\"why\":\"ok\"}"]
            (runAgentsScripted 5 ["{\"n\": 1}", "{\"n\": 7}"] (spawnGated g w 3))))
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[LLM] : '[LLM])])
        g = gate "the number is positive" (\n -> T.pack (show (n :: Int)))
    in check "spawnGated: reject past retries -> GateRejected"
         True
         (case runPureEff (runLLMScripted ["{\"verdict\":\"fail\",\"why\":\"bad\"}", "{\"verdict\":\"fail\",\"why\":\"still bad\"}"]
                 (runAgentsScripted 5 ["{\"n\": 1}", "{\"n\": 2}"] (spawnGated g w 3))) of
            Left (GateRejected nm w') -> nm == "double" && T.isInfixOf "still bad" w'
            _ -> False)
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[LLM] : '[LLM])])
        g = gate "the number is positive" (\n -> T.pack (show (n :: Int)))
    in check "spawnGated: spawn decode failure short-circuits (no judging)"
         True
         (case runPureEff (runLLMScripted []
                 (runAgentsScripted 5 ["not json"] (spawnGated g w 3))) of
            Left (WorkerDecodeFailed nm _) -> nm == "double"
            _ -> False)
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[LLM] : '[LLM])])
        g = gate "the number is positive" (\n -> T.pack (show (n :: Int)))
    in check "spawnGated: spawn budget exhausted on the retry -> SpawnBudgetExceeded"
         True
         (case runPureEff (runLLMScripted ["{\"verdict\":\"fail\",\"why\":\"bad\"}"]
                 (runAgentsScripted 1 ["{\"n\": 1}"] (spawnGated g w 3))) of
            Left (SpawnBudgetExceeded _) -> True
            _ -> False)
  , let w = subAgent "double" C.int (C.object (C.field "n" Prelude.id C.int)) "double the input" ([] :: [Tl.Tool (Agents '[LLM] : '[LLM])])
        g = gate "the number is positive" (\n -> T.pack (show (n :: Int)))
    in check "spawnGated: judge AllErrored -> GateRejected with judge-error tag"
         True
         (case runPureEff (runLLMScripted []
                 (runAgentsScripted 5 ["{\"n\": 6}"] (spawnGated g w 3))) of
            Left (GateRejected _ m) -> T.isInfixOf "judge error:" m
            _ -> False)
  , check "gate defaults: votes = 1, retries = 1"
      (1 :: Int, 1 :: Int)
      (let g = gate "r" (id :: Text -> Text) in (g.votes, g.retries))
  , check "ledger: record yields sequential ids"
      ([WorkId 0, WorkId 1])
      (fst (runPureEff (runLedgerState (do a <- Ledger.record "A"; b <- Ledger.record "B"; pure [a, b]))))
  , check "ledger: both recorded items are Ready in record order"
      [WorkId 0, WorkId 1]
      (map ((.wid) :: WorkItem -> WorkId) (fst (runPureEff (runLedgerState (do _ <- Ledger.record "A"; _ <- Ledger.record "B"; Ledger.listReady)))))
  , check "ledger: claim a Ready item succeeds and sets claimant"
      (True, Just "worker-1", Claimed)
      (let (ok, final) = runPureEff (runLedgerState (do
                 w <- Ledger.record "A"
                 Ledger.claim w "worker-1"))
           it = head (filter (\i -> i.wid == WorkId 0) final)
       in (ok, it.claimant, it.state))
  , check "ledger: a second claim of the same item fails"
      (True, False)
      (fst (runPureEff (runLedgerState (do
                 w <- Ledger.record "A"
                 a <- Ledger.claim w "worker-1"
                 b <- Ledger.claim w "worker-2"
                 pure (a, b)))))
  , check "ledger: claiming an unknown id fails"
      False
      (fst (runPureEff (runLedgerState (Ledger.claim (WorkId 99) "x"))))
  , check "ledger: claimed item drops from listReady"
      ([] :: [WorkId])
      (map ((.wid) :: WorkItem -> WorkId) (fst (runPureEff (runLedgerState (do w <- Ledger.record "A"; _ <- Ledger.claim w "w1"; Ledger.listReady)))))
  , check "ledger: complete marks Done and drops from listReady"
      (Ledger.Done, ([] :: [WorkId]))
      (let (readyIds, final) = runPureEff (runLedgerState (do
                 w <- Ledger.record "A"
                 Ledger.complete w
                 rs <- Ledger.listReady
                 pure (map ((.wid) :: WorkItem -> WorkId) rs)))
           it = head final
       in (it.state, readyIds))
  , check "ledger: workItemCodec round-trips a Ready item"
      (Right (WorkItem (WorkId 3) "do it" Ready Nothing))
      (decodeLLM workItemCodec (C.encodeText workItemCodec (WorkItem (WorkId 3) "do it" Ready Nothing)))
  , check "ledger: workItemCodec round-trips a Claimed item with claimant"
      (Right (WorkItem (WorkId 4) "do it" Claimed (Just "worker-1")))
      (decodeLLM workItemCodec (C.encodeText workItemCodec (WorkItem (WorkId 4) "do it" Claimed (Just "worker-1"))))
  , check "ledger: workItemCodec round-trips a Done item"
      (Right (WorkItem (WorkId 5) "do it" Ledger.Done Nothing))
      (decodeLLM workItemCodec (C.encodeText workItemCodec (WorkItem (WorkId 5) "do it" Ledger.Done Nothing)))
  , do (path, h) <- openTempFile "/tmp" "crucible-ledger-complete.jsonl"
       hClose h
       _ <- runEff (runLedgerFile path (do w <- Ledger.record "A"; Ledger.complete w))
       items <- runEff (runLedgerFile path Ledger.listReady)
       removeFile path
       check "ledger file: a complete is visible in a later session" ([] :: [WorkId])
         (map ((.wid) :: WorkItem -> WorkId) items)
  , do (path, h) <- openTempFile "/tmp" "crucible-ledger-test.jsonl"
       hClose h
       _ <- runEff (runLedgerFile path (do _ <- Ledger.record "A"; _ <- Ledger.record "B"; pure ()))
       ready <- runEff (runLedgerFile path Ledger.listReady)
       removeFile path
       check "ledger file: recorded items outlive the session" [WorkId 0, WorkId 1] (map ((.wid) :: WorkItem -> WorkId) ready)
  , do (path, h) <- openTempFile "/tmp" "crucible-ledger-claim.jsonl"
       hClose h
       ok <- runEff (runLedgerFile path (do w <- Ledger.record "A"; Ledger.claim w "worker-1"))
       ready <- runEff (runLedgerFile path Ledger.listReady)
       removeFile path
       check "ledger file: a claim is visible in a later session" (True, ([] :: [WorkId]))
         (ok, map ((.wid) :: WorkItem -> WorkId) ready)
  , do store <- newLedgerStorePure
       got <- runEff $ runLedgerWith store $ do
                w  <- Ledger.record "task-1"
                c1 <- Ledger.claim w "alice"
                c2 <- Ledger.claim w "bob"   -- already claimed -> False
                rs <- Ledger.listReady
                pure (c1, c2, length rs)
       check "ledger: runLedgerWith pure handle records/claims (CAS) and lists" (True, False, 0 :: Int) got
  , do (path2, h2) <- openTempFile "/tmp" "crucible-ledger-parity.jsonl"
       hClose h2
       let prog = do w  <- Ledger.record "A"
                     _  <- Ledger.claim w "w1"
                     w2 <- Ledger.record "B"
                     rs <- Ledger.listReady
                     pure (map ((.wid) :: WorkItem -> WorkId) rs, w, w2)
       fromFile <- runEff (runLedgerWith (ledgerStoreFile path2) prog)
       removeFile path2 `catch` \(_ :: SomeException) -> pure ()
       store2 <- newLedgerStorePure
       fromPure <- runEff (runLedgerWith store2 prog)
       check "ledger: file and pure handles agree (record/claim/listReady)" fromFile fromPure
  , do ref <- newIORef (Nothing :: Maybe (Either AgentFailure Text))
       let child :: SubAgent '[Chat.Chat, IOE] Text Text
           child = subAgent "child" C.str C.str "child instruction" []
           delegate = Tl.toolWith "delegate" C.str C.str (\q -> do
                        r <- spawn child q
                        liftIO (writeIORef ref (Just r))
                        pure (either (const "failed") Prelude.id r))
           root :: SubAgent '[Chat.Chat, IOE] Text Text
           root = subAgent "root" C.str C.str "root instruction" [delegate]
       _ <- runEff (runChatScripted
              [ Turn "" [ToolUse "u1" "delegate" (String "sub-task")]
              , Turn "\"child-done\"" []
              , Turn "\"root-done\"" [] ]
              (runAgents 5 (spawn root "start")))
       childResult <- readIORef ref
       check "nesting: a worker tool spawns a child that returns its typed result"
         (Just (Right "child-done")) childResult
  , do ref <- newIORef (Nothing :: Maybe (Either AgentFailure Text))
       let child :: SubAgent '[Chat.Chat, IOE] Text Text
           child = subAgent "child" C.str C.str "child instruction" []
           delegate = Tl.toolWith "delegate" C.str C.str (\q -> do
                        r <- spawn child q
                        liftIO (writeIORef ref (Just r))
                        pure (either (const "failed") Prelude.id r))
           root :: SubAgent '[Chat.Chat, IOE] Text Text
           root = subAgent "root" C.str C.str "root instruction" [delegate]
       _ <- runEff (runChatScripted
              [ Turn "" [ToolUse "u1" "delegate" (String "sub-task")]
              , Turn "\"root-done\"" [] ]
              (runAgents 1 (spawn root "start")))
       childResult <- readIORef ref
       check "nesting: the spawn budget is shared across the tree"
         True
         (case childResult of Just (Left (SpawnBudgetExceeded 1)) -> True; _ -> False)
  -- Each forked sibling clones the scripted-Chat state, so a one-turn script
  -- gives every worker its own canned "ok"; the shared budget lives in the
  -- runAgents IORef, so the cap still bounds the concurrent batch.
  , do let w :: SubAgent '[Chat.Chat, Concurrent, IOE] Text Text
           w = subAgent "w" C.str C.str "do it" []
           pairs = [(w, "a"), (w, "b"), (w, "c")]
       rs <- runEff (runConcurrent (runChatScripted [Turn "\"ok\"" []]
               (runAgents 5 (spawnAll pairs))))
       check "spawnAll: all succeed under the cap" [Right "ok", Right "ok", Right "ok"] rs
  , do let w :: SubAgent '[Chat.Chat, Concurrent, IOE] Text Text
           w = subAgent "w" C.str C.str "do it" []
           pairs = [(w, "a"), (w, "b"), (w, "c")]
       rs <- runEff (runConcurrent (runChatScripted [Turn "\"ok\"" []]
               (runAgents 2 (spawnAll pairs))))
       let oks  = length [() | Right _ <- rs]
           caps = length [() | Left (SpawnBudgetExceeded _) <- rs]
       check "spawnAll: shared budget caps the batch (2 ok, 1 over budget)" (2 :: Int, 1 :: Int) (oks, caps)
  , let p = Page (Slug "a") "Alpha" [] "the body of alpha" ()
        (r, _, _) = runPureEff (runResearchState ([] :: [Page ()]) (do writePage p; readPage (Slug "a")))
    in check "research: write then read" (Just p) r
  , let (r, _, _) = runPureEff (runResearchState ([] :: [Page ()]) (readPage (Slug "missing")))
    in check "research: read absent page is Nothing" (Nothing :: Maybe (Page ())) r
  , let p1 = Page (Slug "a") "Alpha" [] "first" ()
        p2 = Page (Slug "a") "Alpha v2" [] "second" ()
        (r, _, _) = runPureEff (runResearchState ([] :: [Page ()]) (do writePage p1; writePage p2; readPage (Slug "a")))
    in check "research: write overwrites by slug" (Just p2) r
  , let ps = [Page (Slug "b") "B" [] "x" (), Page (Slug "a") "A" [] "y" ()]
        (r, _, _) = runPureEff (runResearchState ps (index @()))
    in check "research: index lists slugs in slug order" [Slug "a", Slug "b"] r
  , let ps = [Page (Slug "a") "Alpha note" [] "mentions Haskell" (), Page (Slug "b") "Beta" [] "nothing here" ()]
        (rt, _, _)  = runPureEff (runResearchState ps (search @() "haskell"))
        (rti, _, _) = runPureEff (runResearchState ps (search @() "ALPHA"))
        (rn, _, _)  = runPureEff (runResearchState ps (search @() "zzz"))
    in check "research: search matches body/title case-insensitively, else []"
         ([Slug "a"], [Slug "a"], ([] :: [Slug])) (rt, rti, rn)
  , let (_, _, logs) = runPureEff (runResearchState ([] :: [Page ()]) (do appendLog @() "one"; appendLog @() "two"))
    in check "research: appendLog accumulates in order" ["one", "two"] logs
  , check "research: linkCodec round-trips each link type"
      (Right (Link (Slug "t") Supersedes))
      (decodeLLM linkCodec (C.encodeText linkCodec (Link (Slug "t") Supersedes)))
  , do let dir = "/tmp/crucible-research-test"
       removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ()
       let p = Page (Slug "alpha") "Alpha" [Link (Slug "beta") Extends] "body text here" ("m" :: Text)
       _ <- runEff (runResearchDir C.str dir (writePage p))
       got <- runEff (runResearchDir C.str dir (readPage (Slug "alpha")))
       removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ()
       check "research dir: a written page reads back across sessions (title/links/meta)" (Just p) got
  , do let dir = "/tmp/crucible-research-idx"
       removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ()
       (idx, hits) <- runEff (runResearchDir C.str dir (do
                        writePage (Page (Slug "a") "Apple" [] "red fruit" ("" :: Text))
                        writePage (Page (Slug "b") "Boat" [] "floats" ("" :: Text))
                        i <- index @Text
                        h <- search @Text "fruit"
                        pure (i, h)))
       removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ()
       check "research dir: index lists slugs, search greps body" ([Slug "a", Slug "b"], [Slug "a"]) (idx, hits)
  , do let dir = "/tmp/crucible-research-nl"
       removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ()
       let p = Page (Slug "nl") "NL" [] "line one\nline two\n" ("" :: Text)   -- trailing newline + multi-line
       _ <- runEff (runResearchDir C.str dir (writePage p))
       got <- runEff (runResearchDir C.str dir (readPage (Slug "nl")))
       removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ()
       check "research dir: body round-trips verbatim (trailing newline + multi-line)" (Just p) got
  , check "research: mkSlug accepts a plain slug, rejects path-unsafe ones"
      (Just (Slug "ok"), Nothing, Nothing, Nothing)
      (mkSlug "ok", mkSlug "../escape", mkSlug "a/b", mkSlug "")
  , do let dir = "/tmp/crucible-research-safe"
           escapeDir = "/tmp/crucible-research-ESCAPED.md"
       removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ()
       removeFile escapeDir `catch` \(_ :: SomeException) -> pure ()
       -- a path-unsafe slug must not be written (no escape), and reads Nothing
       got <- runEff (runResearchDir C.str dir (do
                writePage (Page (Slug "../crucible-research-ESCAPED") "X" [] "pwned" ("" :: Text))
                readPage (Slug "../crucible-research-ESCAPED")))
       escaped <- doesFileExist escapeDir
       removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ()
       check "research dir: a path-unsafe slug is refused (no escape, reads Nothing)"
         (Nothing :: Maybe (Page Text), False) (got, escaped)
  , do pagesRef <- newIORef ([] :: [Page ()])
       logRef   <- newIORef ([] :: [Text])
       got <- runEff $ runResearchWith (researchStoreState pagesRef logRef) $ do
                writePage (Page (Slug "a") "A" [] "body-a" ())
                mp <- readPage (Slug "a")
                ix <- index @()
                pure (fmap ((.body) :: Page () -> Text) mp, ix)
       check "research: runResearchWith state round-trips write/read/index" (Just "body-a", [Slug "a"]) got
  , do pagesRef <- newIORef ([] :: [Page ()])
       logRef   <- newIORef ([] :: [Text])
       got <- runEff $ runResearchWith (researchStoreState pagesRef logRef) $ do
                writePage (Page (Slug "a") "Alpha note" [] "mentions Haskell" ())
                writePage (Page (Slug "b") "Beta" [] "nothing here" ())
                search @() "haskell"
       check "research: runResearchWith state search greps body" [Slug "a"] got
  , do let dir = "/tmp/crucible-research-parity"
       removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ()
       let prog :: (Research Text :> es) => Eff es ([Slug], [Slug])
           prog = do writePage (Page (Slug "a") "Apple" [] "red fruit" ("" :: Text))
                     writePage (Page (Slug "b") "Boat" [] "floats" ("" :: Text))
                     i <- index @Text
                     h <- search @Text "fruit"
                     pure (i, h)
       fromDir <- runEff (runResearchDir C.str dir prog)
       removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ()
       pagesRef <- newIORef ([] :: [Page Text])
       logRef   <- newIORef ([] :: [Text])
       fromState <- runEff (runResearchWith (researchStoreState pagesRef logRef) prog)
       check "research: dir and state handles agree (index/search)" fromDir fromState
  , let page = Page (Slug "p") "P" [] "the temperature is 26C. the city is Brisbane." ()
        (res, pages, _) = runPureEff (runLLMScripted
          [ "[\"the temperature is 26C\",\"the city is Brisbane\"]"
          , "{\"why\":\"ok\",\"pass\":true}"
          , "{\"why\":\"ok\",\"pass\":true}" ]
          (runResearchState [] (writeGrounded defaultGroundGate "Brisbane is 26C." page)))
    in check "writeGrounded: all supported -> committed" (Right (), [page]) (res, pages)
  , let page = Page (Slug "p") "P" [] "the temperature is 26C. it is raining." ()
        (res, pages, _) = runPureEff (runLLMScripted
          [ "[\"the temperature is 26C\",\"it is raining\"]"
          , "{\"why\":\"ok\",\"pass\":true}"
          , "{\"why\":\"evidence says sunny\",\"pass\":false}" ]
          (runResearchState [] (writeGrounded defaultGroundGate "sunny, 26C" page)))
    in check "writeGrounded: an unsupported claim at threshold 1.0 -> rejected, not written"
         (True, ([] :: [Page ()]))
         (case res of Left (GroundingOutcome 1 2 _) -> True; _ -> False, pages)
  , let page = Page (Slug "p") "P" [] "the temperature is 26C. it is raining." ()
        (res, pages, _) = runPureEff (runLLMScripted
          [ "[\"the temperature is 26C\",\"it is raining\"]"
          , "{\"why\":\"ok\",\"pass\":true}"
          , "{\"why\":\"evidence says sunny\",\"pass\":false}" ]
          (runResearchState [] (writeGrounded (defaultGroundGate { threshold = 0.5 }) "sunny, 26C" page)))
    in check "writeGrounded: threshold 0.5 with 1/2 supported -> committed" (Right (), [page]) (res, pages)
  , let page = Page (Slug "p") "P" [] "no factual claims here" ()
        (res, pages, _) = runPureEff (runLLMScripted ["[]"]
          (runResearchState [] (writeGrounded defaultGroundGate "ev" page)))
    in check "writeGrounded: NoClaims under CommitNoClaims -> committed" (Right (), [page]) (res, pages)
  , let page = Page (Slug "p") "P" [] "no factual claims here" ()
        (res, pages, _) = runPureEff (runLLMScripted ["[]"]
          (runResearchState [] (writeGrounded (defaultGroundGate { onNoClaims = RejectNoClaims }) "ev" page)))
    in check "writeGrounded: NoClaims under RejectNoClaims -> rejected, not written"
         (True, ([] :: [Page ()]))
         (case res of Left NoClaims -> True; _ -> False, pages)
  , let page = Page (Slug "p") "P" [] "something" ()
        (res, pages, _) = runPureEff (runLLMScripted ["junk", "junk2"]
          (runResearchState [] (writeGrounded defaultGroundGate "ev" page)))
    in check "writeGrounded: DecomposeFailed -> rejected, not written"
         (True, ([] :: [Page ()]))
         (case res of Left (DecomposeFailed _) -> True; _ -> False, pages)
  , check "writeGrounded: defaultGroundGate fields"
      (1.0, 1 :: Int, CommitNoClaims)
      (defaultGroundGate.threshold, defaultGroundGate.votes, defaultGroundGate.onNoClaims)
  -- Research.Tools: researchTools + researchInstructions
  , let pageVal = object [ "slug" .= String "p", "title" .= String "P"
                         , "links" .= ([] :: [Value]), "body" .= String "the body", "meta" .= String "" ]
        expected = Page (Slug "p") "P" [] "the body" ("" :: Text)
        (res, pages, _) = runPureEff (runResearchState []
          (Tl.invoke (head [t | t <- researchTools C.str, t.name == "write_page"]) pageVal))
    in check "researchTools: write_page lands the page"
         (True, [expected])
         (either (const False) (const True) res, pages)
  , let known = Page (Slug "p") "P" [] "b" ("" :: Text)
        (r1, _, _) = runPureEff (runResearchState [known]
          (Tl.invoke (head [t | t <- researchTools C.str, t.name == "read_page"]) (object ["slug" .= String "p"])))
        (r2, _, _) = runPureEff (runResearchState [known]
          (Tl.invoke (head [t | t <- researchTools C.str, t.name == "read_page"]) (object ["slug" .= String "absent"])))
        decodeRP v = case decodeLLM (C.nullable' (pageCodec C.str)) (C.encodeText C.anyValue v) of
                       Right x -> Right x
                       Left  _ -> Left ("decode error" :: Text)
    in check "researchTools: read_page returns the page or null"
         (Right (Just known), Right Nothing)
         ( either (\_ -> Left ("tool error" :: Text)) decodeRP r1
         , either (\_ -> Left ("tool error" :: Text)) decodeRP r2 )
  , let p1 = Page (Slug "a") "Apple" [] "red fruit" ("" :: Text)
        p2 = Page (Slug "b") "Boat" [] "floats" ("" :: Text)
        (r, _, _) = runPureEff (runResearchState [p1, p2]
          (Tl.invoke (head [t | t <- researchTools C.str, t.name == "search_pages"]) (object ["query" .= String "fruit"])))
        decodeSL v = case decodeLLM (C.list' slugCodec) (C.encodeText C.anyValue v) of
                       Right x -> Right x
                       Left  _ -> Left ("decode error" :: Text)
    in check "researchTools: search_pages returns matching slugs"
         (Right [Slug "a"])
         (either (\_ -> Left ("tool error" :: Text)) decodeSL r)
  , let pageVal = object [ "slug" .= String "x", "title" .= String "X"
                         , "links" .= ([] :: [Value]), "body" .= String "recorded", "meta" .= String "" ]
        expected = Page (Slug "x") "X" [] "recorded" ("" :: Text)
        (_, pages, _) = runPureEff (runChatScripted
          [ Turn "" [ToolUse "u1" "write_page" pageVal], Turn "\"done\"" [] ]
          (runResearchState [] (runToolAgent (researchTools C.str) "record X")))
    in check "researchTools: agent loop writes a page via write_page" [expected] pages
  , check "researchInstructions: names the three tools"
      True
      (all (`T.isInfixOf` researchInstructions) ["read_page", "write_page", "search_pages"])
  , let pA = Page (Slug "a") "A" [Link (Slug "b") Relates] "body of a" ()
        pB = Page (Slug "b") "B" [] "body of b" ()
    in check "lint: orphan is a page with no inbound link" [Orphan (Slug "a")] (orphans [pA, pB])
  , let pC = Page (Slug "c") "C" [Link (Slug "ghost") Relates] "body of c" ()
    in check "lint: broken link to an absent target"
         [BrokenLink (Slug "c") (Link (Slug "ghost") Relates)] (brokenLinks [pC])
  , let pS = Page (Slug "s") "S" [] "hi" ()
        pL = Page (Slug "l") "L" [] "a sufficiently long body" ()
    in check "lint: sparse page under the threshold" [SparsePage (Slug "s") 2] (sparsePages 5 [pS, pL])
  , let pA = Page (Slug "a") "A" [Link (Slug "b") Relates] "aaaaa" ()
        pB = Page (Slug "b") "B" [] "bbbbb" ()
        pC = Page (Slug "c") "C" [] "ccccc" ()
    in check "lint: linkedPairs is only the joined pair; allPairs is all three"
         ([(pA, pB)], [(pA, pB), (pA, pC), (pB, pC)])
         (linkedPairs [pA, pB, pC], allPairs [pA, pB, pC])
  , let pA = Page (Slug "a") "A" [Link (Slug "b") Relates] "aaaaa" ()
        pB = Page (Slug "b") "B" [Link (Slug "a") Relates] "bbbbb" ()
    in check "lint: no orphans and no broken links when every page is linked and resolvable"
         (([] :: [Finding]), ([] :: [Finding]))
         (orphans [pA, pB], brokenLinks [pA, pB])
  , let pA = Page (Slug "a") "A" [] "x" ()
        pB = Page (Slug "b") "B" [] "y" ()
    in check "lint: contradiction on a passing vote"
         [Contradiction (Slug "a") (Slug "b") "they disagree"]
         (runPureEff (runLLMScripted ["{\"why\":\"they disagree\",\"pass\":true}"]
            (lintContradictions 1 [(pA, pB)])))
  , let pA = Page (Slug "a") "A" [] "x" ()
        pB = Page (Slug "b") "B" [] "y" ()
    in check "lint: no contradiction on a failing vote"
         ([] :: [Finding])
         (runPureEff (runLLMScripted ["{\"why\":\"unrelated\",\"pass\":false}"]
            (lintContradictions 1 [(pA, pB)])))
  , let pA = Page (Slug "a") "A" [] "x" ()
        pB = Page (Slug "b") "B" [] "y" ()
    in check "lint: a judge failure invents no finding (empty script -> AllErrored)"
         ([] :: [Finding])
         (runPureEff (runLLMScripted []
            (lintContradictions 1 [(pA, pB)])))
  , let p = Page (Slug "a") "A" [] "the moon is made of cheese" ()
    in check "lint: stale on a passing vote against current facts"
         [Stale (Slug "a") "contradicts the facts"]
         (runPureEff (runLLMScripted ["{\"why\":\"contradicts the facts\",\"pass\":true}"]
            (lintStale 1 "the moon is made of rock" [p])))
  , let pA = Page (Slug "a") "A" [Link (Slug "b") Relates] "aaaaa" ()
        pB = Page (Slug "b") "B" [] "bbbbb" ()
        res = runPureEff (runLLMScripted ["{\"why\":\"clash\",\"pass\":true}"]
                (lintWiki defaultLintOpts { sparseThreshold = 1 } [pA, pB]))
    in check "lint: lintWiki combines structural and contradiction"
         [Orphan (Slug "a"), Contradiction (Slug "a") (Slug "b") "clash"]
         res
  , check "journal: empty journal has no entries"
      (0 :: Int)
      (length (J.jEntries (J.emptyJournal (J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"))))
  , check "journal: insert then lookup returns the bytes with seq 0"
      (Just (0 :: Int, "6"))
      (let k = J.mkKey "double" ["3"]
           j = J.insertEntry k (encInt 6) (J.emptyJournal (J.JournalIdentity "double" "" "v1" "2026-06-15T00:00:00Z"))
       in (\e -> (J.eSeq e, BC.unpack (J.eResult e))) <$> J.lookupEntry k j)
  , check "journal: lookup of an absent key is Nothing"
      (Nothing :: Maybe Int)
      (let j = J.emptyJournal (J.JournalIdentity "double" "" "v1" "2026-06-15T00:00:00Z")
       in J.eSeq <$> J.lookupEntry (J.mkKey "double" ["3"]) j)
  , check "journal: two inserts get sequential seqs"
      [0 :: Int, 1]
      (let j0 = J.emptyJournal (J.JournalIdentity "double" "" "v1" "2026-06-15T00:00:00Z")
           j1 = J.insertEntry (J.mkKey "double" ["3"]) (encInt 6) j0
           j2 = J.insertEntry (J.mkKey "double" ["4"]) (encInt 8) j1
       in map (J.eSeq . snd) (J.jEntries j2))
  , check "journal: distinct args produce distinct keys"
      False
      (J.mkKey "double" ["3"] == J.mkKey "double" ["4"])
  , check "journal: same op+args produce equal keys"
      True
      (J.mkKey "double" ["3"] == J.mkKey "double" ["3"])
  , check "journal: record returns the live value and appends one entry"
      (6 :: Int, 1 :: Int)
      (let ident = J.JournalIdentity "double" "" "v1" "2026-06-15T00:00:00Z"
           (a, j) = runPureEff (ES.runState (J.emptyJournal ident)
                      (J.record (J.mkKey "double" ["3"]) encInt (pure (6 :: Int))))
       in (a, length (J.jEntries j)))
  , check "journal: recorded bytes are recoverable by key"
      (Just "6")
      (let ident = J.JournalIdentity "double" "" "v1" "2026-06-15T00:00:00Z"
           (_, j) = runPureEff (ES.runState (J.emptyJournal ident)
                      (J.record (J.mkKey "double" ["3"]) encInt (pure (6 :: Int))))
       in BC.unpack . J.eResult <$> J.lookupEntry (J.mkKey "double" ["3"]) j)
  , check "journal: two records append in order with sequential seqs"
      [0 :: Int, 1]
      (let ident = J.JournalIdentity "calc" "" "v1" "2026-06-15T00:00:00Z"
           (_, j) = runPureEff (ES.runState (J.emptyJournal ident) (do
                      _ <- J.record (J.mkKey "double" ["3"]) encInt (pure (6 :: Int))
                      J.record (J.mkKey "triple" ["3"]) encInt (pure (9 :: Int))))
       in map (J.eSeq . snd) (J.jEntries j))
  , check "journal: replay hit returns Replayed with the decoded value"
      (Right (J.Replayed (6 :: Int)) :: Either J.JournalError (J.ReplayOutcome Int))
      (fmap fst (runPureEff (EE.runErrorNoCallStack
        (ES.runState
          (J.insertEntry (J.mkKey "double" ["3"]) (encInt 6) (J.emptyJournal (J.JournalIdentity "double" "" "v1" "2026-06-15T00:00:00Z")))
          (J.replay J.Signal (J.mkKey "double" ["3"]) decInt (pure 0))))))
  , check "journal: replay miss under Signal flags divergence and runs live"
      (Right (J.Diverged (J.Divergence (J.mkKey "double" ["99"])) (198 :: Int)) :: Either J.JournalError (J.ReplayOutcome Int))
      (fmap fst (runPureEff (EE.runErrorNoCallStack
        (ES.runState (J.emptyJournal (J.JournalIdentity "double" "" "v1" "2026-06-15T00:00:00Z"))
          (J.replay J.Signal (J.mkKey "double" ["99"]) decInt (pure 198))))))
  , check "journal: replay miss under Fallthrough runs live silently (no divergence)"
      (Right (J.Replayed (198 :: Int)) :: Either J.JournalError (J.ReplayOutcome Int))
      (fmap fst (runPureEff (EE.runErrorNoCallStack
        (ES.runState (J.emptyJournal (J.JournalIdentity "double" "" "v1" "2026-06-15T00:00:00Z"))
          (J.replay J.Fallthrough (J.mkKey "double" ["99"]) decInt (pure 198))))))
  , check "journal: replay miss under Fail aborts with MissError"
      (Left (J.MissError (J.mkKey "double" ["99"])) :: Either J.JournalError (J.ReplayOutcome Int))
      (fmap fst (runPureEff (EE.runErrorNoCallStack
        (ES.runState (J.emptyJournal (J.JournalIdentity "double" "" "v1" "2026-06-15T00:00:00Z"))
          (J.replay J.Fail (J.mkKey "double" ["99"]) decInt (pure 0))))))
  , check "journal: replay hit with undecodable bytes is a DecodeError"
      (Left (J.DecodeError (J.mkKey "double" ["3"]) "bad int") :: Either J.JournalError (J.ReplayOutcome Int))
      (fmap fst (runPureEff (EE.runErrorNoCallStack
        (ES.runState
          (J.insertEntry (J.mkKey "double" ["3"]) (BC.pack "not-a-number") (J.emptyJournal (J.JournalIdentity "double" "" "v1" "2026-06-15T00:00:00Z")))
          (J.replay J.Signal (J.mkKey "double" ["3"]) decInt (pure 0))))))
  , check "journal: codec round-trips a journal with identity + entries"
      (Right True)
      (let j0 = J.emptyJournal (J.JournalIdentity "calc" "the-input" "sha-abc" "2026-06-15T00:00:00Z")
           j  = J.insertEntry (J.mkKey "triple" ["3"]) (encInt 9)
                  (J.insertEntry (J.mkKey "double" ["3"]) (encInt 6) j0)
           v  = toJSONVia J.journalCodec j
       in fmap (== j) (AT.parseEither (parseJSONVia J.journalCodec) v))
  , check "journal: codec round-trips an empty journal"
      (Right True)
      (let j = J.emptyJournal (J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z")
           v = toJSONVia J.journalCodec j
       in fmap (== j) (AT.parseEither (parseJSONVia J.journalCodec) v))
  , check "journal: codec round-trips non-UTF8 binary result + input bytes"
      (Right True)
      (let j = J.insertEntry (J.mkKey "blob" [BSTEST.pack [0,255,0x1f]]) (BSTEST.pack [0,255,31,128,7])
                 (J.emptyJournal (J.JournalIdentity "wf" (BSTEST.pack [200,0,255]) "v1" "2026-06-15T00:00:00Z"))
           v = toJSONVia J.journalCodec j
       in fmap (== j) (AT.parseEither (parseJSONVia J.journalCodec) v))
  , check "journal: duplicate key is last-write-wins on lookup (history retained)"
      (Just "v2", 2 :: Int)
      (let k = J.mkKey "op" ["a"]
           j = J.insertEntry k (BC.pack "v2") (J.insertEntry k (BC.pack "v1")
                 (J.emptyJournal (J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z")))
       in (BC.unpack . J.eResult <$> J.lookupEntry k j, length (J.jEntries j)))
  , check "journal: record-then-replay-changed surfaces exactly the new op as Diverged"
      (Right [J.Replayed (6 :: Int), J.Diverged (J.Divergence (J.mkKey "triple" ["3"])) 9] :: Either J.JournalError [J.ReplayOutcome Int])
      (let ident = J.JournalIdentity "calc" "" "v1" "2026-06-15T00:00:00Z"
           -- original code recorded only `double 3`
           (_, j) = runPureEff (ES.runState (J.emptyJournal ident)
                      (J.record (J.mkKey "double" ["3"]) encInt (pure (6 :: Int))))
           -- changed code keeps `double 3` (hits) and adds `triple 3` (diverges)
       in fmap fst (runPureEff (EE.runErrorNoCallStack (ES.runState j (do
            a <- J.replay J.Signal (J.mkKey "double" ["3"]) decInt (pure 6)
            b <- J.replay J.Signal (J.mkKey "triple" ["3"]) decInt (pure 9)
            pure [a, b])))))
  , do let ident0 = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
       st <- J.newInMemoryJournalStore (J.emptyJournal ident0)
       v  <- runEff (J.recordTo st (J.mkKey "double" ["3"]) "double" encInt (pure (6 :: Int)))
       j  <- J.jsLoad st
       check "journal store: recordTo persists and returns the value"
         (6 :: Int, Just "6") (v, BC.unpack . J.eResult <$> J.lookupEntry (J.mkKey "double" ["3"]) j)
  , do let ident0 = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
       st <- J.newInMemoryJournalStore
          (J.insertEntry (J.mkKey "double" ["3"]) (encInt 6) (J.emptyJournal ident0))
       j   <- J.jsLoad st
       out <- runEff (EE.runErrorNoCallStack
                (J.replayFrom j J.Fallthrough (J.mkKey "double" ["3"]) decInt (pure (0 :: Int))))
       check "journal store: replayFrom hit returns Replayed"
         (Right (J.Replayed (6 :: Int)) :: Either J.JournalError (J.ReplayOutcome Int)) out
  , do let ident0 = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
       st <- J.newInMemoryJournalStore (J.emptyJournal ident0)
       j   <- J.jsLoad st
       out <- runEff (EE.runErrorNoCallStack
                (J.replayFrom j J.Signal (J.mkKey "new" ["x"]) decInt (pure (99 :: Int))))
       check "journal store: replayFrom miss under Signal is Diverged + live"
         (Right (J.Diverged (J.Divergence (J.mkKey "new" ["x"])) (99 :: Int)) :: Either J.JournalError (J.ReplayOutcome Int)) out

  -- Crucible.Workflow tests (Phase 2a)

  -- Helper: run a Workflow program against an in-memory store + loaded journal.
  -- Returns Either Suspended (Either JournalError a).
  -- Discharge order: runEff > runErrorNoCallStack @Suspended > runErrorNoCallStack @JournalError > runWorkflow
  , do let ident = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           fixedEnv = WorkflowEnv (pure "2026-06-15T00:00:00Z") (pure "id-1")
       st <- J.newInMemoryJournalStore (J.emptyJournal ident)
       -- Run 1: record "now"
       j1   <- J.jsLoad st
       res1 <- runEff
                 (EE.runErrorNoCallStack @Suspended
                   (EE.runErrorNoCallStack @J.JournalError
                     (W.runWorkflow fixedEnv st j1 W.now)))
       -- Run 2: replay with a different env (weNow returns something else)
       let altEnv = WorkflowEnv (pure "9999-01-01T00:00:00Z") (pure "id-x")
       j2   <- J.jsLoad st
       res2 <- runEff
                 (EE.runErrorNoCallStack @Suspended
                   (EE.runErrorNoCallStack @J.JournalError
                     (W.runWorkflow altEnv st j2 W.now)))
       check "workflow: now determinism across runs (replay ignores changed env)"
         (Right (Right "2026-06-15T00:00:00Z") :: Either Suspended (Either J.JournalError Text))
         res2

  , do let ident = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           fixedEnv = WorkflowEnv (pure "2026-06-15T00:00:00Z") (pure "id-1")
       st <- J.newInMemoryJournalStore (J.emptyJournal ident)
       j  <- J.jsLoad st
       -- Run two now calls in one pass
       res <- runEff
                (EE.runErrorNoCallStack @Suspended
                  (EE.runErrorNoCallStack @J.JournalError
                    (W.runWorkflow fixedEnv st j (do
                       t1 <- W.now
                       t2 <- W.now
                       pure (t1, t2)))))
       j' <- J.jsLoad st
       check "workflow: two now calls get distinct keys (both recorded)"
         (Right (Right ("2026-06-15T00:00:00Z", "2026-06-15T00:00:00Z")) :: Either Suspended (Either J.JournalError (Text, Text)), 2 :: Int)
         (res, length (J.jEntries j'))

  , do let ident = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
       idRef <- newIORef (0 :: Int)
       let idSrc = modifyIORef' idRef (+ 1) >> fmap (T.pack . ("id-" ++) . show) (readIORef idRef)
           env1  = WorkflowEnv (pure "2026-06-15T00:00:00Z") idSrc
           env2  = WorkflowEnv (pure "2026-06-15T00:00:00Z") (pure "id-different")
       st <- J.newInMemoryJournalStore (J.emptyJournal ident)
       j1 <- J.jsLoad st
       res1 <- runEff
                 (EE.runErrorNoCallStack @Suspended
                   (EE.runErrorNoCallStack @J.JournalError
                     (W.runWorkflow env1 st j1 W.newId)))
       j2 <- J.jsLoad st
       res2 <- runEff
                 (EE.runErrorNoCallStack @Suspended
                   (EE.runErrorNoCallStack @J.JournalError
                     (W.runWorkflow env2 st j2 W.newId)))
       check "workflow: newId replay returns first-run value (journaled determinism)"
         (res1 :: Either Suspended (Either J.JournalError Text))
         res2

  , do -- retryN: Left twice then Right -> returns Right
       counter <- newIORef (0 :: Int)
       let act = do
             n <- readIORef counter
             modifyIORef' counter (+ 1)
             if n < 2 then pure (Left ("fail" :: Text)) else pure (Right n)
       res <- W.retryN 3 act
       check "workflow: retryN 3 succeeds after two failures"
         (Right (2 :: Int))
         res

  , do -- retryN: always-Left -> returns last Left
       counter2 <- newIORef (0 :: Int)
       let alwaysFail2 :: IO (Either Text Int)
           alwaysFail2 = modifyIORef' counter2 (+ 1) >> pure (Left "fail")
       res2 <- W.retryN 3 alwaysFail2
       finalN <- readIORef counter2
       check "workflow: retryN 3 all-fail returns last Left and ran 3 times"
         (Left ("fail" :: Text) :: Either Text Int, 3 :: Int)
         (res2, finalN)

  , do -- durableSleep: first encounter (empty journal) -> Suspended
       let ident = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           fixedEnv = WorkflowEnv (pure "2026-06-15T00:00:00Z") (pure "id-1")
       st <- J.newInMemoryJournalStore (J.emptyJournal ident)
       j  <- J.jsLoad st
       res <- runEff
                (EE.runErrorNoCallStack @Suspended
                  (EE.runErrorNoCallStack @J.JournalError
                    (W.runWorkflow fixedEnv st j (W.durableSleep 10))))
       check "workflow: durableSleep suspends on miss with correct wakeAt"
         (Left (Suspended (WaitTimer (J.mkKey "sleep" ["0"]) "2026-06-15T00:00:10Z")) :: Either Suspended (Either J.JournalError ()))
         res

  , do -- durableSleep: entry present -> returns ()
       let ident = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           fixedEnv = WorkflowEnv (pure "2026-06-15T00:00:00Z") (pure "id-1")
           sleepKey = J.mkKey "sleep" ["0"]
           seededJ  = J.insertEntry sleepKey (BC.pack "") (J.emptyJournal ident)
       st <- J.newInMemoryJournalStore seededJ
       j  <- J.jsLoad st
       res <- runEff
                (EE.runErrorNoCallStack @Suspended
                  (EE.runErrorNoCallStack @J.JournalError
                    (W.runWorkflow fixedEnv st j (W.durableSleep 10))))
       check "workflow: durableSleep returns () when journal entry present"
         (Right (Right ()) :: Either Suspended (Either J.JournalError ()))
         res

  -- recordActivity / newInMemoryJournalStore' tests

  , do -- recordActivity: result is journaled, IdemKey is derived from the CassetteKey bytes
       let ident0 = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           k      = J.mkKey "act" ["1"]
       (st, _pending) <- J.newInMemoryJournalStore' (J.emptyJournal ident0)
       capturedRef <- newIORef (Nothing :: Maybe IdemKey)
       v <- runEff (J.recordActivity st Keyable k "act" encInt
              (\idem -> liftIO (writeIORef capturedRef (Just idem)) >> pure (6 :: Int)))
       j <- J.jsLoad st
       capturedIdem <- readIORef capturedRef
       let CassetteKey kb = k
           expected = IdemKey kb
       check "recordActivity: result is journaled under the key"
         (Just "6")
         (BC.unpack . J.eResult <$> J.lookupEntry k j)
       check "recordActivity: IdemKey passed to action equals CassetteKey bytes"
         (Just expected)
         capturedIdem
       check "recordActivity: return value equals the action result"
         (6 :: Int)
         v

  , do -- recordActivity: IdemKey is deterministic across independent runs
       let ident0 = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           k      = J.mkKey "act" ["1"]
       capturedRef1 <- newIORef (Nothing :: Maybe IdemKey)
       capturedRef2 <- newIORef (Nothing :: Maybe IdemKey)
       (st1, _) <- J.newInMemoryJournalStore' (J.emptyJournal ident0)
       _ <- runEff (J.recordActivity st1 Keyable k "act" encInt
              (\idem -> liftIO (writeIORef capturedRef1 (Just idem)) >> pure (1 :: Int)))
       (st2, _) <- J.newInMemoryJournalStore' (J.emptyJournal ident0)
       _ <- runEff (J.recordActivity st2 Keyable k "act" encInt
              (\idem -> liftIO (writeIORef capturedRef2 (Just idem)) >> pure (1 :: Int)))
       idem1 <- readIORef capturedRef1
       idem2 <- readIORef capturedRef2
       check "recordActivity: IdemKey is deterministic across independent runs"
         idem1
         idem2

  , do -- pending intents: jsIntent then query shows pending; jsAppend clears it
       let ident0 = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           k      = J.mkKey "x" []
       (st, pending) <- J.newInMemoryJournalStore' (J.emptyJournal ident0)
       J.jsIntent st k "x" Keyable
       p1 <- pending
       check "pending intents: intent without result appears in pending"
         [(k, Keyable)]
         p1
       J.jsAppend st k "x" "v"
       p2 <- pending
       check "pending intents: after jsAppend, pending is empty"
         ([] :: [(CassetteKey, ActivityKind)])
         p2

  -- AwaitSignal tests

  , do -- awaitSignal: empty journal -> Suspended (WaitSignal)
       let ident0   = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           fixedEnv = WorkflowEnv (pure "2026-06-15T00:00:00Z") (pure "id-1")
       st  <- J.newInMemoryJournalStore (J.emptyJournal ident0)
       j   <- J.jsLoad st
       res <- runEff
                (EE.runErrorNoCallStack @Suspended
                  (EE.runErrorNoCallStack @J.JournalError
                    (W.runWorkflow fixedEnv st j (W.awaitSignal "go"))))
       check "workflow: awaitSignal miss -> Suspended (WaitSignal)"
         (Left (Suspended (WaitSignal (J.mkKey "signal" ["0"]) "go")) :: Either Suspended (Either J.JournalError BSTEST.ByteString))
         res

  , do -- awaitSignal: entry seeded -> returns payload
       let ident0     = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           fixedEnv   = WorkflowEnv (pure "2026-06-15T00:00:00Z") (pure "id-1")
           signalKey  = J.mkKey "signal" ["0"]
           seededJ    = J.insertEntry signalKey (BC.pack "payload") (J.emptyJournal ident0)
       st  <- J.newInMemoryJournalStore seededJ
       j   <- J.jsLoad st
       res <- runEff
                (EE.runErrorNoCallStack @Suspended
                  (EE.runErrorNoCallStack @J.JournalError
                    (W.runWorkflow fixedEnv st j (W.awaitSignal "go"))))
       check "workflow: awaitSignal hit -> returns seeded payload"
         (Right (Right (BC.pack "payload")) :: Either Suspended (Either J.JournalError BSTEST.ByteString))
         res

  -- ExecuteChild tests

  , do -- executeChild: empty journal -> Suspended (WaitChild)
       let ident0   = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           fixedEnv = WorkflowEnv (pure "2026-06-15T00:00:00Z") (pure "id-1")
       st  <- J.newInMemoryJournalStore (J.emptyJournal ident0)
       j   <- J.jsLoad st
       res <- runEff
                (EE.runErrorNoCallStack @Suspended
                  (EE.runErrorNoCallStack @J.JournalError
                    (W.runWorkflow fixedEnv st j (W.executeChild "calc" ("child" :: BSTEST.ByteString)))))
       check "workflow: executeChild miss -> Suspended (WaitChild)"
         (Left (Suspended (WaitChild (J.mkKey "child" ["0"]) "calc" "child")) :: Either Suspended (Either J.JournalError BSTEST.ByteString))
         res

  , do -- executeChild: entry seeded -> returns child result
       let ident0    = J.JournalIdentity "wf" "" "v1" "2026-06-15T00:00:00Z"
           fixedEnv  = WorkflowEnv (pure "2026-06-15T00:00:00Z") (pure "id-1")
           childKey  = J.mkKey "child" ["0"]
           seededJ   = J.insertEntry childKey (BC.pack "child-result") (J.emptyJournal ident0)
       st  <- J.newInMemoryJournalStore seededJ
       j   <- J.jsLoad st
       res <- runEff
                (EE.runErrorNoCallStack @Suspended
                  (EE.runErrorNoCallStack @J.JournalError
                    (W.runWorkflow fixedEnv st j (W.executeChild "calc" ("child" :: BSTEST.ByteString)))))
       check "workflow: executeChild hit -> returns child result"
         (Right (Right (BC.pack "child-result")) :: Either Suspended (Either J.JournalError BSTEST.ByteString))
         res

  -- Crucible.Eval.Replay tests

  , check "replay: settle collects diverged ops, passes values through"
      ([1,2,3] :: [Int], 2 :: Int)
      (let (vals, ds) = runPureEff (runReplayEval (do
              a <- settle (J.Replayed (1 :: Int))
              b <- settle (J.Diverged (J.Divergence (J.mkKey "op" ["1"])) 2)
              c <- settle (J.Diverged (J.Divergence (J.mkKey "op" ["2"])) 3)
              pure [a, b, c]))
       in (vals, length ds))

  , check "replay: divergence keys collected in order"
      [J.mkKey "op" ["1"], J.mkKey "op" ["2"]]
      (map J.dKey (snd (runPureEff (runReplayEval (do
         _ <- settle (J.Diverged (J.Divergence (J.mkKey "op" ["1"])) ())
         settle (J.Diverged (J.Divergence (J.mkKey "op" ["2"])) ()))))))

  , do -- end-to-end replay-to-eval: changed code diverges on the new op only
       let ident0 = J.JournalIdentity "twin" "" "v1" "2026-06-15T00:00:00Z"
           keyA   = J.mkKey "twin" ["a"]
           keyB   = J.mkKey "twin" ["b"]
           -- original code recorded only keyA
           j = J.insertEntry keyA (encInt 42) (J.emptyJournal ident0)
       -- replay: keyA hits (Replayed), keyB misses (Diverged under Signal)
       -- runEff . runErrorNoCallStack @JournalError . runReplayEval :: Either JournalError ((a, b), [Divergence])
       outcome <- runEff (EE.runErrorNoCallStack @J.JournalError
                    (runReplayEval (do
                      oa <- J.replayFrom j J.Signal keyA decInt (pure (42 :: Int))
                      ob <- J.replayFrom j J.Signal keyB decInt (pure (99 :: Int))
                      a  <- settle oa
                      b  <- settle ob
                      pure (a, b))))
       let divKeys = fmap (map J.dKey . snd) outcome
       check "replay: end-to-end — only new/changed op is a divergence"
         (Right [keyB] :: Either J.JournalError [J.CassetteKey])
         divKeys

  , do got <- ddmin (\sub -> pure (5 `elem` sub)) [1..8 :: Int]
       check "ddmin: reduces to the single required element" [5 :: Int] got

  , do got <- ddmin (\sub -> pure (sum sub >= 10)) [1..8 :: Int]
       check "ddmin: result is minimal-ish and still reproduces" True (sum got >= 10 && length got < 8)

  , do got <- ddmin (\_ -> pure True) ([] :: [Int])
       check "ddmin: empty input is a no-op" ([] :: [Int]) got
  ]
