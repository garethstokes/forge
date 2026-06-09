{-# LANGUAGE OverloadedStrings #-}

-- | M8 smoke executable. Proves the effectful substrate talks to the real
-- Anthropic provider end-to-end, and that the @recordLLM@/cassette slider works:
--
--   1. a LIVE call through 'runLLMAnthropic' / 'recordLLMAnthropic' (records the
--      reply to a cassette), then
--   2. a deterministic REPLAY of that cassette via 'runLLMCassette' (no network).
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
  , recordLLMAnthropic
  , runChatAnthropic
  , runLLMAnthropic
  , runLLMCassette
  )
import Crucible.Function (llmFn, call)
import Crucible.Codec (str)
import qualified Crucible.Json.Decode as D
import Crucible.Chat (runToolAgent)
import qualified Crucible.Tool as Tl
import Crucible.Schema (Schema (SObj, SStr))
import Crucible.Json.Value (Value (JString))

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
      live <- runEff (recordLLMAnthropic cassette cfg (complete prompt))
      TIO.putStrLn ("live:   " <> live)
      replayed <- runEff (runLLMCassette cassette (complete prompt))
      TIO.putStrLn ("replay: " <> replayed)
      if live == replayed
        then TIO.putStrLn "OK: cassette replay matches live"
        else TIO.putStrLn "MISMATCH" >> exitFailure
      let classify = llmFn "classify" str str
            (\s -> "Reply with one word — positive, negative, or neutral — for: " <> s)
      typed <- runEff (runLLMAnthropic cfg (call classify "I absolutely love this!"))
      case typed of
        Right o  -> TIO.putStrLn ("typed fn: " <> o)
        Left err -> TIO.putStrLn ("typed fn decode error: " <> T.pack (D.message err))
      let weatherTool = Tl.Tool "get_weather" (SObj [("city", SStr)])
            (\_ -> pure (JString "It is 26C and sunny."))
      toolAns <- runEff (runChatAnthropic cfg (runToolAgent [weatherTool] "Use the tool to get the weather in Brisbane, then tell me."))
      case toolAns of
        Right a  -> TIO.putStrLn ("tool agent: " <> a)
        Left err -> TIO.putStrLn ("tool agent error: " <> T.pack (show err))
