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
  , runLLMCassette
  )

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
