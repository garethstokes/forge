{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeApplications #-}

-- | M8 smoke executable. Proves the effectful substrate talks to the real
-- Anthropic provider end-to-end, and that the record/cassette slider works:
--
--   1. a LIVE call through 'Anthropic.record' (records the reply to a cassette), then
--   2. a deterministic REPLAY of that cassette via 'Anthropic.replay' (no network).
--
-- Reads @ANTHROPIC_API_KEY@ from the environment.
module Main (main) where

import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (lookupEnv)
import System.Exit (exitFailure)

import Effectful (Eff, runEff, liftIO, IOE)
import Crucible.Tool.Generic (tools)

import Crucible.LLM (Message (..), Role (..), complete, LLM)
import Crucible.LLM.Anthropic
  ( defaultAnthropicConfig
  )
import qualified Crucible.LLM.Anthropic as Anthropic
import qualified Crucible.LLM.Anthropic.Stream as Anthropic
import qualified Crucible.Embed as Embed
import Crucible.Embed (embed)
import Crucible.LLM.OpenAI (defaultOpenAIConfig)
import qualified Crucible.LLM.Voyage as Voyage
import qualified Crucible.LLM.OpenAI as OpenAI
import qualified Crucible.LLM.OpenAI.Stream as OpenAI
import qualified Crucible.LLM.Fallback as Fallback
import Crucible.LLM.CallLog (CallEntry (..))
import qualified Crucible.LLM.CallLog as CallLog
import GHC.Generics (Generic)
import qualified Data.Aeson as A
import NeatInterpolation (text)
import Crucible.Skill (Skill, skill, call, withExamples, withTests)
import Crucible.Skill.Improve (ImproveStep (..), improveSkill)
import Crucible.Decode (DecodeError (..))
import Crucible.Codec (str, int, object, field, refine, encodeText)
import Crucible.Eval (Case (..), Expectation (..), Score (..), Report (..), criterion, penalty, runEval, runEvalN, renderReport, scoreM, lintChecklist, LintFinding (..), LintIssue (..))
import Crucible.Eval.Judge (judgeOnce, votePanel)
import Crucible.Codec.Generic (HasCodec (codec), genericCodec)
import Crucible.Chat (runToolAgent, Chat)
import Crucible.Agents (subAgent, spawn, spawnAll, AgentFailure (..), runAgents, SubAgent)
import Effectful.Concurrent (Concurrent)
import qualified Effectful.Concurrent as Conc
import Crucible.Agents.Gate (gate, spawnGated)
import Crucible.Usage (Usage (..), usTotalTokens, Rates (..), estimateCost)
import qualified Crucible.Tool as Tl
import Crucible.Emit (runEmitIO)
import qualified Crucible.Ledger as Ledger
import qualified Crucible.Research as Research
import Crucible.Research.Grounded (writeGrounded, defaultGroundGate, GroundingOutcome (..))
import Crucible.Memory (MemoryKind (..), MemoryItem (..), MemoryId (..), Provenance (..), MemoryDraft (..), Query (..), remember, recall, recallAs, runMemoryFile)
import Crucible.Memory.Consolidate (ConsolidationOp, ConsolidationPlan (..), consolidationSkill, consolidate)
import Crucible.Memory.Eval (memoryLift, liftDelta)
import Crucible.Skill.Multimodal (callMedia)
import Crucible.Media (imageB64)
import Crucible.Eval.Latency (Timed (..), timed, withinMs)
import Crucible.Partial (runPartialWith)
import System.IO (hFlush, stdout)
import Data.IORef (newIORef, modifyIORef', readIORef)

data Sentiment = Sentiment { sentLabel :: T.Text } deriving (Show, Generic)
instance HasCodec Sentiment where codec = genericCodec

-- | All-Maybe partial type for the runPartialWith demo.
data Weather = Weather { wCity :: Maybe T.Text, wTempC :: Maybe Int }
  deriving (Show, Generic)
instance HasCodec Weather where codec = genericCodec

data WeatherQ = WeatherQ { city :: T.Text } deriving (Show, Generic)
instance HasCodec WeatherQ where codec = genericCodec

data WeatherTools es = WeatherTools
  { get_weather :: WeatherQ -> Eff es T.Text }
  deriving (Generic)

weatherBox :: WeatherTools es
weatherBox = WeatherTools { get_weather = \_ -> pure "It is 26C and sunny." }

prompt :: [Message]
prompt =
  [ Message System "You are a terse assistant."
  , Message User "Reply with exactly the word: pong"
  ]

main :: IO ()
main = do
  mkey <- lookupEnv "ANTHROPIC_API_KEY"
  case mkey of
    Nothing -> putStrLn "ANTHROPIC_API_KEY not set in environment" >> exitFailure
    Just key -> do
      let cfg = defaultAnthropicConfig (T.pack key)
          cassette = "/tmp/crucible-cassette.jsonl"
      TIO.writeFile cassette "" -- fresh cassette
      live <- runEff (Anthropic.record cassette cfg (complete prompt))
      TIO.putStrLn ("live:   " <> live)
      replayed <- runEff (Anthropic.replay cassette (complete prompt))
      TIO.putStrLn ("replay: " <> replayed)
      if live == replayed
        then TIO.putStrLn "OK: cassette replay matches live"
        else TIO.putStrLn "MISMATCH" >> exitFailure
      let classify :: Skill T.Text Sentiment
          classify = withExamples
            [ ("The packaging was damaged but the product works.", Sentiment "neutral") ]
            (skill "classify" str codec
              (\s -> [text|Classify the sentiment as positive, negative, or neutral for: ${s}|]))
      typed <- runEff (Anthropic.run cfg (call classify "I absolutely love this!"))
      case typed of
        Right o  -> TIO.putStrLn ("typed fn: " <> sentLabel o)
        Left e   -> TIO.putStrLn ("typed fn decode error: " <> e.message)
      let memPath = "/tmp/crucible-memory-demo.jsonl"
      _ <- runEff (runMemoryFile memPath (case typed of
             Right s -> remember (MemoryDraft Episodic (encodeText (codec @Sentiment) s) ["sentiment"] (BySkill "classify"))
             Left _  -> remember (MemoryDraft Episodic "decode failed" ["sentiment"] (BySkill "classify"))))
      recalled <- runEff (runMemoryFile memPath (recallAs (codec @Sentiment) (Query "" ["sentiment"] 5)))
      TIO.putStrLn ("memory: recalled " <> T.pack (show (length recalled)) <> " item(s); "
                    <> T.pack (show [either (const "stale") sentLabel v | (_, v) <- recalled]))
      let consoPath = "/tmp/crucible-consolidate-demo.jsonl"
      _ <- runEff (runMemoryFile consoPath (do
             _ <- remember (MemoryDraft Episodic "The user said they prefer dark mode." ["pref"] (BySession "demo"))
             _ <- remember (MemoryDraft Episodic "The user switched the theme to dark again." ["pref"] (BySession "demo"))
             pure ()))
      consoPlan <- runEff (runMemoryFile consoPath (Anthropic.run cfg
                     (consolidate consolidationSkill (Query "" [] 50))))
      consoItems <- runEff (runMemoryFile consoPath (recall (Query "" [] 50)))
      TIO.putStrLn ("consolidate: plan " <> T.pack (show (either (const 0) (length . ((.ops) :: ConsolidationPlan -> [ConsolidationOp])) consoPlan))
                    <> " op(s); store now " <> T.pack (show (map ((.content) :: MemoryItem -> T.Text) consoItems)))
      -- memoryLift: does a memory pay rent? Ablate a skill that can only
      -- answer from a memory, with and without it.
      let editorSkill = withTests
            [ Case ("What is the user's preferred editor? Answer with one word." :: T.Text)
                   "recall-editor"
                   (Predicate (\o -> "neovim" `T.isInfixOf` T.toLower o)) ]
            (skill "recall-editor" str str Prelude.id)
          editorMems =
            [ MemoryItem (MemoryId 0) Semantic
                "The user's preferred editor is Neovim." [] Curated 0 ]
      (mlBase, mlLifted) <- runEff (Anthropic.run cfg (Embed.none (memoryLift Prelude.id editorSkill editorMems)))
      let (mlDPass, mlDScore) = liftDelta (mlBase, mlLifted)
      let getPassRate = ((.passRate) :: Report T.Text (Either DecodeError T.Text) -> Double)
      TIO.putStrLn ("memoryLift: baseline pass " <> T.pack (show (getPassRate mlBase))
                    <> ", lifted pass " <> T.pack (show (getPassRate mlLifted))
                    <> "; delta (pass,score) = (" <> T.pack (show mlDPass)
                    <> ", " <> T.pack (show mlDScore) <> ")")
      -- Multimodal: send a small image to a typed skill via the Chat path.
      let bluePng = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABAAQMAAACQp+OdAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGUExURSBg0P///x0TVD8AAAABYktHRAH/Ai3eAAAAB3RJTUUH6gYOBAgJopiKpwAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0wNi0xNFQwNDowODowOSswMDowMPbQ3xQAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMDYtMTRUMDQ6MDg6MDkrMDA6MDCHjWeoAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTA2LTE0VDA0OjA4OjA5KzAwOjAw0JhGdwAAAA9JREFUKM9jYBgFo4B8AAACQAABjMWrdwAAAABJRU5ErkJggg=="
          describeImage :: Skill T.Text T.Text
          describeImage = skill "describe-image" str
            (object (field "color" Prelude.id str))
            (const "What is the dominant color of this image?")
      mmRes <- runEff (Anthropic.runChat cfg
                 (callMedia describeImage ("" :: T.Text) [imageB64 "image/png" bluePng]))
      case mmRes of
        Right d -> TIO.putStrLn ("multimodal: dominant color = " <> d)
        Left e  -> TIO.putStrLn ("multimodal decode error: " <> (e.message :: T.Text))
      let ageFn :: Skill T.Text Int
          ageFn = skill "extract-age" str
            (object (field "age" Prelude.id
               (refine "age must be between 0 and 130" (\a -> a >= 0 && a <= 130) int)))
            (\s -> [text|Extract the person's age from: ${s}|])
      ageRes <- runEff (Anthropic.run cfg (call ageFn "Maria is 34 years old."))
      TIO.putStrLn ("refine: extracted age " <> either (.message) (T.pack . show) ageRes)
      (toolAns, usage) <- runEff (Anthropic.usageChat cfg (runToolAgent (tools weatherBox) "Use the tool to get the weather in Brisbane, then tell me."))
      case toolAns of
        Right a  -> TIO.putStrLn ("tool agent: " <> a)
        Left err -> TIO.putStrLn ("tool agent error: " <> T.pack (show err))
      -- Illustrative per-MTok rates (not authoritative pricing).
      -- (show on a small Double prints scientific notation, e.g. 6.1e-4)
      let rates = Rates 1.0 5.0
      let usageIn  = let Usage { inputTokens  = n } = usage in n
          usageOut = let Usage { outputTokens = n } = usage in n
      TIO.putStrLn
        ( "usage: " <> T.pack (show usageIn) <> " in + "
            <> T.pack (show usageOut) <> " out = "
            <> T.pack (show (usTotalTokens usage)) <> " tokens"
            <> "; est. cost $" <> T.pack (show (estimateCost rates usage)) )
      -- Streaming: print tokens as they arrive (text path).
      TIO.putStr "stream: "
      (streamed, sUsage) <-
        runEff (runEmitIO (\t -> TIO.putStr t >> hFlush stdout)
                  (Anthropic.stream cfg (complete prompt)))
      TIO.putStrLn ""
      TIO.putStrLn ("stream usage: " <> T.pack (show (usTotalTokens sUsage)) <> " tokens"
                    <> " (len " <> T.pack (show (T.length streamed)) <> ")")
      -- Streaming tool-agent (deltas printed live).
      TIO.putStr "stream tool: "
      (toolStream, tUsage) <-
        runEff (runEmitIO (\t -> TIO.putStr t >> hFlush stdout)
                  (Anthropic.streamChat cfg (runToolAgent (tools weatherBox) "Use the tool to get the weather in Brisbane, then tell me.")))
      TIO.putStrLn ""
      case toolStream of
        Right a  -> TIO.putStrLn ("stream tool result: " <> a)
        Left err -> TIO.putStrLn ("stream tool error: " <> T.pack (show err))
      TIO.putStrLn ("stream tool usage: " <> T.pack (show (usTotalTokens tUsage)) <> " tokens")
      -- Partial typed streaming: decode a growing JSON object as deltas arrive.
      let weatherPrompt =
            [ Message System "You are a terse assistant. Reply with ONLY JSON, no markdown."
            , Message User "Reply with ONLY a JSON object: {\"wCity\": <city>, \"wTempC\": <int>} for the weather in Brisbane. No markdown."
            ]
      ref <- newIORef (0 :: Int, Nothing :: Maybe Weather)
      _ <- runEff (runPartialWith (codec @Weather)
             (\case
               Right w -> liftIO (modifyIORef' ref (\(n, _) -> (n + 1, Just w)))
               Left _  -> pure ())
             (Anthropic.stream cfg (complete weatherPrompt)))
      (n, mw) <- readIORef ref
      TIO.putStrLn ("partial: " <> T.pack (show n) <> " partials, final " <> T.pack (show mw))
      -- Chat cassette: record a live tool-agent run, then replay it (no network).
      let chatCassette = "/tmp/crucible-chat-cassette.jsonl"
          toolQuestion = "Use the tool to get the weather in Brisbane, then tell me."
      TIO.writeFile chatCassette ""  -- fresh cassette
      recordedAns <- runEff (Anthropic.recordChat chatCassette cfg (runToolAgent (tools weatherBox) toolQuestion))
      replayedAns <- runEff (Anthropic.replayChat chatCassette (runToolAgent (tools weatherBox) toolQuestion))
      case (recordedAns, replayedAns) of
        (Right a, Right b)
          | a == b    -> TIO.putStrLn ("chat cassette: OK replay matches: " <> a)
          | otherwise -> TIO.putStrLn ("chat cassette: MISMATCH live=" <> a <> " replay=" <> b)
        _ -> TIO.putStrLn "chat cassette: a run failed"
      -- Eval: a checklist and an n-vote rubric judged live (runEvalN 3).
      evalRep <- runEff (Anthropic.run cfg (Embed.none (runEvalN 3 id pure
        [ Case ("It is 26C and sunny in Brisbane." :: T.Text) "weather-report"
            (Checklist [ criterion "mentions a temperature"
                       , criterion "mentions a city"
                       , penalty 1 "recommends a specific product" ])
        , Case "pong" "terse-pong" (Rubric "the output is a single short word")
        , Case "It is 26C and sunny in Brisbane." "grounded-weather"
            (Grounded "Brisbane forecast: sunny, 26 degrees, light winds.")
        ])))
      TIO.putStrLn (renderReport evalRep)
      -- Rubric lint: an advisory pass over a deliberately flawed checklist.
      let renderFinding (Finding i c n) = T.pack (show i) <> " '" <> c <> "': " <> n
          renderFinding (LintUnavailable m) = "unavailable: " <> m
      findings <- runEff (Anthropic.run cfg (lintChecklist
        [ criterion "mentions the city and the temperature"
        , criterion "uses appropriate language"
        ]))
      mapM_ (\f -> TIO.putStrLn ("lint: " <> renderFinding f)) findings
      -- improveSkill: one live reflection round over a deliberately weak skill.
      let weak = withTests
            [ Case ("the meeting is at 3pm tomorrow" :: T.Text) "extracts-time"
                (Exactly ("15:00" :: T.Text)) ]
            (skill "extract-time" str str (\s -> [text|What time? ${s}|]))
      (_, improveSteps) <- runEff (Anthropic.run cfg (Embed.none (improveSkill 1 id weak)))
      TIO.putStrLn ("improveSkill: " <> T.pack (show (length improveSteps)) <> " step(s) "
                    <> T.pack (show [s.accepted | s <- improveSteps]))
      -- Abstain: a placeholder output the judge cannot assess, to provoke cannot_assess.
      abstainRep <- runEff (Anthropic.run cfg (Embed.none (runEval id pure
        [ Case ("[content unavailable]" :: T.Text) "unassessable"
            (Rubric "the summary captures the article's main argument") ])))
      TIO.putStrLn (renderReport abstainRep)
      -- Scale: an anchored 1-to-5 politeness rating, judged live.
      politeness <- runEff (Anthropic.run cfg (Embed.none (scoreM id
        (Scale 4 "Rate how polite this reply is"
           [(1, "rude"), (5, "warm and courteous")])
        ("Thanks so much for waiting, happy to help!" :: T.Text))))
      TIO.putStrLn ("scale: " <> politeness.rationale)
      -- Latency: time a live call and check it against a budget (live-only).
      tcall <- runEff (Anthropic.run cfg (timed (call classify "I love this!")))
      let Timed { latencyMs = latMs } = tcall
      TIO.putStrLn ("latency: " <> T.pack (show latMs) <> " ms (within 5000ms: "
                    <> T.pack (show (withinMs 5000 tcall)) <> ")")
      -- Spawn: an orchestrator spawns one worker subagent (with a tool) and
      -- gets back a typed result over an isolated transcript.
      let weatherWorker :: SubAgent '[Chat, IOE] T.Text T.Text
          weatherWorker =
            subAgent "weather-worker" str
              (object (field "summary" Prelude.id str))
              "Use the get_weather tool, then summarize the weather in one sentence."
              (tools weatherBox)
      spawnRes <- runEff (Anthropic.runChat cfg
                    (runAgents 4 (spawn weatherWorker "Brisbane")))
      case spawnRes of
        Right summary -> TIO.putStrLn ("spawn: worker returned: " <> summary)
        Left failure  -> TIO.putStrLn ("spawn: worker failed: " <> T.pack (show failure))
      -- Judge gate: verify the worker's summary before accepting it.
      let gatedWorker :: SubAgent '[Chat, LLM, IOE] T.Text T.Text
          gatedWorker =
            subAgent "weather-worker" str
              (object (field "summary" Prelude.id str))
              "Use the get_weather tool, then summarize the weather in one sentence."
              (tools weatherBox)
          summaryGate = gate "the summary names a city and a temperature" Prelude.id
      gatedRes <- runEff (Anthropic.run cfg (Anthropic.runChat cfg
                    (runAgents 4 (spawnGated summaryGate gatedWorker "Brisbane"))))
      case gatedRes of
        Right summary -> TIO.putStrLn ("spawnGated: accepted: " <> summary)
        Left failure  -> TIO.putStrLn ("spawnGated: " <> T.pack (show failure))
      -- Nested spawn: a coordinator worker delegates a sub-task to a child
      -- worker through a tool, all under one shared spawn budget.
      let weatherChild :: SubAgent '[Chat, IOE] T.Text T.Text
          weatherChild =
            subAgent "weather-child" str (object (field "summary" Prelude.id str))
              "Use the get_weather tool and summarize the weather in one sentence."
              (tools weatherBox)
          -- Anthropic requires a tool input_schema of type object, so the
          -- delegate tool takes {city: ...} rather than a bare string.
          delegateWeather =
            Tl.toolWith "delegate_weather" (object (field "city" Prelude.id str)) str (\city -> do
              r <- spawn weatherChild city
              pure (either (\f -> "delegation failed: " <> T.pack (show f)) Prelude.id r))
          coordinator :: SubAgent '[Chat, IOE] T.Text T.Text
          coordinator =
            subAgent "coordinator" str (object (field "report" Prelude.id str))
              "Delegate the weather lookup to the delegate_weather tool, then report what it returns."
              [delegateWeather]
      nestedRes <- runEff (Anthropic.runChat cfg (runAgents 6 (spawn coordinator "Brisbane")))
      case nestedRes of
        Right report -> TIO.putStrLn ("nested spawn: " <> report)
        Left failure -> TIO.putStrLn ("nested spawn: " <> T.pack (show failure))
      -- Concurrent spawn: fan out three weather workers at once under one
      -- shared budget; results come back in input order.
      let cityWorker :: SubAgent '[Chat, Concurrent, IOE] T.Text T.Text
          cityWorker =
            subAgent "city-weather" str (object (field "summary" Prelude.id str))
              "Use the get_weather tool and summarize the weather in one sentence."
              (tools weatherBox)
          cityPairs = [(cityWorker, "Brisbane"), (cityWorker, "Sydney"), (cityWorker, "Perth")]
      concRes <- runEff (Conc.runConcurrent (Anthropic.runChat cfg
                   (runAgents 6 (spawnAll cityPairs))))
      mapM_ (\r -> TIO.putStrLn ("concurrent spawn: " <> either (T.pack . show) Prelude.id r)) concRes
      -- Work ledger: session 1 records and processes one item; a SEPARATE
      -- session 2 on the same file reads back what remains (outlives sessions).
      let ledgerPath = "/tmp/crucible-ledger-demo.jsonl"
      TIO.writeFile ledgerPath ""  -- fresh ledger
      _ <- runEff (Ledger.runLedgerFile ledgerPath (do
        a <- Ledger.record "summarize the inbox"
        _ <- Ledger.record "draft the reply"
        ok <- Ledger.claim a "worker-1"
        if ok then Ledger.complete a else pure ()))
      ledgerRemaining <- runEff (Ledger.runLedgerFile ledgerPath
        (map (\it -> it.payload) <$> Ledger.listReady))
      TIO.putStrLn ("ledger: remaining ready = " <> T.pack (show ledgerRemaining))
      -- Research: a typed, persistent knowledge base (markdown files on disk).
      let researchDir = "/tmp/crucible-research-demo"
          alpha = Research.Page (Research.Slug "alpha") "Alpha" [] "Alpha is the first letter." ("" :: T.Text)
          beta  = Research.Page (Research.Slug "beta") "Beta"
                    [Research.Link (Research.Slug "alpha") Research.Extends]
                    "Beta extends alpha." ("" :: T.Text)
      (researchIdx, researchHits) <- runEff (Research.runResearchDir str researchDir (do
        Research.writePage alpha
        Research.writePage beta
        Research.appendLog @T.Text "wrote alpha and beta"
        i <- Research.index @T.Text
        h <- Research.search @T.Text "extends"
        pure (i, h)))
      TIO.putStrLn ("research: index = " <> T.pack (show (map (\(Research.Slug s) -> s) researchIdx))
                    <> ", search 'extends' = " <> T.pack (show (map (\(Research.Slug s) -> s) researchHits)))
      -- Grounding-gated writes: a page lands only if its body is supported by
      -- the evidence. One grounded page commits; one ungrounded page is rejected.
      let groundDir = "/tmp/crucible-research-grounded-demo"
          evidence = "Brisbane recorded 26C and sunny skies today."
          grounded   = Research.Page (Research.Slug "weather-ok") "Weather"
                         [] "Brisbane reached 26C and was sunny." ("" :: T.Text)
          ungrounded = Research.Page (Research.Slug "weather-bad") "Weather"
                         [] "Brisbane reached 40C and it snowed." ("" :: T.Text)
      (okRes, badRes) <- runEff (Anthropic.run cfg (Research.runResearchDir str groundDir (do
        a <- writeGrounded defaultGroundGate evidence grounded
        b <- writeGrounded defaultGroundGate evidence ungrounded
        pure (a, b))))
      let render r = case r of
            Right () -> "committed"
            Left o   -> "rejected (" <> T.pack (show o) <> ")"
      TIO.putStrLn ("grounded write (supported): " <> render okRes)
      TIO.putStrLn ("grounded write (unsupported): " <> render badRes)
      -- OpenAI: the same skills and loops, only the interpreter changes.
      mOpenKey <- lookupEnv "OPENAI_API_KEY"
      case mOpenKey of
        Nothing -> TIO.putStrLn "OPENAI_API_KEY not set; skipping OpenAI demo"
        Just okey -> do
          let ocfg = defaultOpenAIConfig (T.pack okey)
          otyped <- runEff (OpenAI.run ocfg (call classify "I absolutely love this!"))
          case otyped of
            Right o  -> TIO.putStrLn ("openai typed fn: " <> sentLabel o)
            Left e   -> TIO.putStrLn ("openai typed fn decode error: " <> e.message)
          (oAns, oUsage) <- runEff (OpenAI.usageChat ocfg (runToolAgent (tools weatherBox) toolQuestion))
          case oAns of
            Right a  -> TIO.putStrLn ("openai tool agent: " <> a)
            Left err -> TIO.putStrLn ("openai tool agent error: " <> T.pack (show err))
          TIO.putStrLn ("openai usage: " <> T.pack (show (usTotalTokens oUsage)) <> " tokens")
          TIO.putStr "openai stream: "
          (oStreamed, osUsage) <-
            runEff (runEmitIO (\t -> TIO.putStr t >> hFlush stdout)
                      (OpenAI.stream ocfg (complete prompt)))
          TIO.putStrLn ""
          TIO.putStrLn ("openai stream usage: " <> T.pack (show (usTotalTokens osUsage)) <> " tokens"
                        <> " (len " <> T.pack (show (T.length oStreamed)) <> ")")
          TIO.putStr "openai stream tool: "
          (oToolStream, otUsage) <-
            runEff (runEmitIO (\t -> TIO.putStr t >> hFlush stdout)
                      (OpenAI.streamChat ocfg (runToolAgent (tools weatherBox) toolQuestion)))
          TIO.putStrLn ""
          case oToolStream of
            Right a  -> TIO.putStrLn ("openai stream tool result: " <> a)
            Left err -> TIO.putStrLn ("openai stream tool error: " <> T.pack (show err))
          TIO.putStrLn ("openai stream tool usage: " <> T.pack (show (usTotalTokens otUsage)) <> " tokens")
          let oChatCassette = "/tmp/crucible-openai-chat-cassette.jsonl"
          TIO.writeFile oChatCassette ""
          oRecorded <- runEff (OpenAI.recordChat oChatCassette ocfg (runToolAgent (tools weatherBox) toolQuestion))
          oReplayed <- runEff (OpenAI.replayChat oChatCassette (runToolAgent (tools weatherBox) toolQuestion))
          case (oRecorded, oReplayed) of
            (Right a, Right b)
              | a == b    -> TIO.putStrLn ("openai chat cassette: OK replay matches: " <> a)
              | otherwise -> TIO.putStrLn ("openai chat cassette: MISMATCH live=" <> a <> " replay=" <> b)
            _ -> TIO.putStrLn "openai chat cassette: a run failed"
          -- Fallback: a junk-key member fails fast; the chain recovers.
          lg <- CallLog.new
          providers <- map (CallLog.logging lg) <$> sequence
            [ Anthropic.provider (defaultAnthropicConfig "junk-key")
            , OpenAI.provider ocfg
            ]
          fb <- runEff (Fallback.run providers (complete prompt))
          TIO.putStrLn ("fallback: " <> fb <> " (first member cannot succeed; answered by second)")
          entries <- CallLog.drain lg
          mapM_
            (\e -> TIO.putStrLn
              ("calllog: " <> e.provider <> " " <> e.model <> " "
                 <> either (const "error") (const "ok") e.outcome
                 <> " in " <> T.pack (show e.durationMs) <> "ms"))
            entries
          -- Embeddings: consistency across paraphrases + a SimilarTo case.
          cons <- runEff (OpenAI.runEmbed ocfg (Embed.consistency
            [ "The return window is 30 days."
            , "You have thirty days to return an item." ]))
          TIO.putStrLn ("consistency: " <> T.pack (show cons))
          simRep <- runEff (OpenAI.runEmbed ocfg (Anthropic.run cfg (runEval id pure
            [ Case ("The capital of France is Paris." :: T.Text) "similar-capital"
                (SimilarTo 0.6 "Paris is France's capital city.") ])))
          TIO.putStrLn (renderReport simRep)
          panelOut <- votePanel
            [ \r g -> runEff (Anthropic.run cfg (judgeOnce [] r g))
            , \r g -> runEff (OpenAI.run ocfg (judgeOnce [] r g)) ]
            "the output is a friendly greeting" "Hello there, lovely to meet you!"
          TIO.putStrLn ("panel: " <> T.pack (show panelOut))
      mVoyKey <- lookupEnv "VOYAGE_API_KEY"
      case mVoyKey of
        Nothing -> TIO.putStrLn "VOYAGE_API_KEY not set; skipping Voyage demo"
        Just vkey -> do
          vec <- runEff (Voyage.runEmbed (Voyage.defaultVoyageConfig (T.pack vkey))
                   (embed "crucible embeds with Voyage"))
          TIO.putStrLn ("voyage: embedded to " <> T.pack (show (length vec)) <> " dims")
