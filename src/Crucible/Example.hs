{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Example (demoAgent, demoTools) where

import Data.Text (Text)
import Effectful (Eff, runPureEff)
import qualified Data.Aeson as A
import Data.Aeson (Value)
import Data.Aeson.Types (parseMaybe)
import Crucible.Codec (JSONCodec, object, field, str)
import Crucible.Decision (Decision, decisionCodec)
import Crucible.LLM (runLLMScripted, Message(..), Role(System, User))
import Crucible.Tool
import Crucible.Agent (AgentState(..), runAgent)

-- | JSON-Schema Value for weather tool: {city: string}
weatherSchema :: Value
weatherSchema = A.object
  [ "type" A..= A.String "object"
  , "properties" A..= A.object
      [ "city" A..= A.object [ "type" A..= A.String "string" ] ]
  , "required" A..= A.toJSON [A.String "city"]
  ]

-- | JSON-Schema Value for add tool: {a: number, b: number}
addSchema :: Value
addSchema = A.object
  [ "type" A..= A.String "object"
  , "properties" A..= A.object
      [ "a" A..= A.object [ "type" A..= A.String "number" ]
      , "b" A..= A.object [ "type" A..= A.String "number" ]
      ]
  , "required" A..= A.toJSON [A.String "a", A.String "b"]
  ]

-- pure tools (polymorphic in es; run via `pure`)
weatherTool :: Tool es
weatherTool = Tool "get_weather" weatherSchema $ \args ->
  pure $ case parseMaybe (A.withObject "" (\o -> o A..: "city")) args of
           Just c  -> A.String ("sunny in " <> c)
           Nothing -> A.String "unknown city"

addTool :: Tool es
addTool = Tool "add" addSchema $ \args ->
  pure $ case parseMaybe (\v -> A.withObject "" (\o -> (,) <$> o A..: "a" <*> o A..: "b") v) args of
           Just (a, b) -> A.Number (fromIntegral (a + b :: Int))
           Nothing     -> A.String "bad args"

demoTools :: [Tool es]
demoTools = [weatherTool, addTool]

-- final-answer codec: {"answer": <text>} -> Text
answerCodec :: JSONCodec Text
answerCodec = object (field "answer" id str)

demoCodec :: JSONCodec (Decision ToolCall Text)
demoCodec = decisionCodec toolCallCodec answerCodec

startDemo :: AgentState
startDemo = AgentState
  [ Message System ("You can call these tools:\n" <> toolsHelp demoTools
      <> "\nRespond with JSON: either {\"tool\":<name>,\"args\":{...}} or {\"answer\":<text>}.")
  , Message User "demo" ]

-- | Run the example agent on canned replies. Discharge LLM (scripted) then
-- Tools, then run the pure stack.
demoAgent :: [Text] -> Text
demoAgent replies =
  runPureEff
    . runTools demoTools
    . runLLMScripted replies
    $ runAgent demoCodec startDemo
