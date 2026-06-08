{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Example (demoAgent, demoTools) where

import Data.Text (Text)
import Effectful (Eff, runPureEff)
import Crucible.Json.Value (Value(..))
import qualified Crucible.Json.Decode as D
import Crucible.Schema (Schema(..))
import Crucible.Codec (Codec, object, field, str)
import Crucible.Decision (Decision, decisionCodec)
import Crucible.LLM (runLLMScripted, Message(..), Role(System, User))
import Crucible.Tool
import Crucible.Agent (AgentState(..), runAgent)

-- pure tools (polymorphic in es; run via `pure`)
weatherTool :: Tool es
weatherTool = Tool "get_weather" (SObj [("city", SStr)]) $ \args ->
  pure $ case D.decodeValue (D.field "city" D.string) args of
           Right c -> JString ("sunny in " <> c)
           Left _  -> JString "unknown city"

addTool :: Tool es
addTool = Tool "add" (SObj [("a", SNum), ("b", SNum)]) $ \args ->
  pure $ case (,) <$> D.decodeValue (D.field "a" D.int) args
                  <*> D.decodeValue (D.field "b" D.int) args of
           Right (a, b) -> JNumber (fromIntegral (a + b))
           Left _       -> JString "bad args"

demoTools :: [Tool es]
demoTools = [weatherTool, addTool]

-- final-answer codec: {"answer": <text>} -> Text
answerCodec :: Codec Text
answerCodec = object (field "answer" id str)

demoCodec :: Codec (Decision ToolCall Text)
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
