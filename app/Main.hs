{-# LANGUAGE AllowAmbiguousTypes #-}
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

import Effectful (Eff, runEff, liftIO)
import Crucible.Tool.Generic (tools)

import Crucible.LLM (Message (..), Role (..), complete)
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
import Crucible.Eval (Case (..), Expectation (..), Score (..), criterion, penalty, runEval, runEvalN, renderReport, scoreM, lintChecklist, LintFinding (..), LintIssue (..))
import Crucible.Eval.Judge (judgeOnce, votePanel)
import Crucible.Codec.Generic (HasCodec (codec), genericCodec)
import Crucible.Chat (runToolAgent)
import Crucible.Usage (Usage (..), usTotalTokens, Rates (..), estimateCost)
import qualified Crucible.Tool as Tl
import Crucible.Emit (runEmitIO)
import Crucible.Memory (MemoryKind (..), MemoryItem (..), Provenance (..), MemoryDraft (..), Query (..), remember, recall, recallAs, runMemoryFile)
import Crucible.Memory.Consolidate (ConsolidationOp, ConsolidationPlan (..), consolidationSkill, consolidate)
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
