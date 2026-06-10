{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

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

import Effectful (runEff)

import Crucible.LLM (Message (..), Role (..), complete)
import Crucible.LLM.Anthropic
  ( defaultAnthropicConfig
  )
import qualified Crucible.LLM.Anthropic as Anthropic
import qualified Crucible.LLM.Anthropic.Stream as Anthropic
import GHC.Generics (Generic)
import qualified Data.Aeson as A
import NeatInterpolation (text)
import Crucible.Skill (Skill, skill, call)
import Crucible.Decode (DecodeError (..))
import Crucible.Codec (str)
import Crucible.Codec.Generic (HasCodec (codec), genericCodec)
import Crucible.Chat (runToolAgent)
import Crucible.Usage (Usage (..), usTotalTokens, Rates (..), estimateCost)
import qualified Crucible.Tool as Tl
import Crucible.Emit (runEmitIO)
import System.IO (hFlush, stdout)

data Sentiment = Sentiment { sentLabel :: T.Text } deriving (Show, Generic)
instance HasCodec Sentiment where codec = genericCodec

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
          classify = skill "classify" str codec
            (\s -> [text|Classify the sentiment as positive, negative, or neutral for: ${s}|])
      typed <- runEff (Anthropic.run cfg (call classify "I absolutely love this!"))
      case typed of
        Right o  -> TIO.putStrLn ("typed fn: " <> sentLabel o)
        Left e   -> TIO.putStrLn ("typed fn decode error: " <> e.message)
      let weatherSchema = A.object
            [ "type" A..= A.String "object"
            , "properties" A..= A.object [ "city" A..= A.object ["type" A..= A.String "string"] ]
            , "required" A..= A.toJSON [A.String "city"]
            ]
          weatherTool = Tl.Tool "get_weather" weatherSchema
            (\_ -> pure (A.String "It is 26C and sunny."))
      (toolAns, usage) <- runEff (Anthropic.usageChat cfg (runToolAgent [weatherTool] "Use the tool to get the weather in Brisbane, then tell me."))
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
      let weatherTool2 = Tl.Tool "get_weather" weatherSchema
            (\_ -> pure (A.String "It is 26C and sunny."))
      TIO.putStr "stream tool: "
      (toolStream, tUsage) <-
        runEff (runEmitIO (\t -> TIO.putStr t >> hFlush stdout)
                  (Anthropic.streamChat cfg (runToolAgent [weatherTool2] "Use the tool to get the weather in Brisbane, then tell me.")))
      TIO.putStrLn ""
      case toolStream of
        Right a  -> TIO.putStrLn ("stream tool result: " <> a)
        Left err -> TIO.putStrLn ("stream tool error: " <> T.pack (show err))
      TIO.putStrLn ("stream tool usage: " <> T.pack (show (usTotalTokens tUsage)) <> " tokens")
      -- Chat cassette: record a live tool-agent run, then replay it (no network).
      let chatCassette = "/tmp/crucible-chat-cassette.jsonl"
          weatherTool3 = Tl.Tool "get_weather" weatherSchema
            (\_ -> pure (A.String "It is 26C and sunny."))
          toolQuestion = "Use the tool to get the weather in Brisbane, then tell me."
      TIO.writeFile chatCassette ""  -- fresh cassette
      recordedAns <- runEff (Anthropic.recordChat chatCassette cfg (runToolAgent [weatherTool3] toolQuestion))
      replayedAns <- runEff (Anthropic.replayChat chatCassette (runToolAgent [weatherTool3] toolQuestion))
      case (recordedAns, replayedAns) of
        (Right a, Right b)
          | a == b    -> TIO.putStrLn ("chat cassette: OK replay matches — " <> a)
          | otherwise -> TIO.putStrLn ("chat cassette: MISMATCH — live=" <> a <> " replay=" <> b)
        _ -> TIO.putStrLn "chat cassette: a run failed"
