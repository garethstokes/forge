{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Example (demoAgent, demoTools) where

import Data.Text (Text)
import Control.Monad.State (State, evalState, state)
import Crucible.Json.Value (Value(..))
import qualified Crucible.Json.Decode as D
import Crucible.Schema (Schema(..))
import Crucible.Codec (Codec, object, field, str)
import Crucible.Decision (Decision, decisionCodec)
import Crucible.LLM (MonadLLM(..), Message(..), Role(System, User))
import Crucible.Tool
import Crucible.Agent (AgentState(..), runAgentT)

-- | A carrier that satisfies BOTH capabilities: scripted model replies (State)
-- and the fixed demo toolbox. Its instances are the manifest made concrete.
newtype DemoM a = DemoM (State [Text] a)
  deriving (Functor, Applicative, Monad)

instance MonadLLM DemoM where
  complete _ = DemoM (state (\rs -> case rs of (x : xs) -> (x, xs); [] -> ("", [])))

instance MonadTool DemoM where
  callTool = dispatchTools demoTools

runDemo :: [Text] -> DemoM a -> a
runDemo replies (DemoM m) = evalState m replies

-- pure tools: polymorphic in m (no special capability), specialised to DemoM below.
weatherTool :: Monad m => Tool m
weatherTool = Tool "get_weather" (SObj [("city", SStr)]) $ \args ->
  pure $ case D.decodeValue (D.field "city" D.string) args of
           Right c -> JString ("sunny in " <> c)
           Left _  -> JString "unknown city"

addTool :: Monad m => Tool m
addTool = Tool "add" (SObj [("a", SNum), ("b", SNum)]) $ \args ->
  pure $ case (,) <$> D.decodeValue (D.field "a" D.int) args
                  <*> D.decodeValue (D.field "b" D.int) args of
           Right (a, b) -> JNumber (fromIntegral (a + b))
           Left _       -> JString "bad args"

demoTools :: [Tool DemoM]
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

-- | Run the example agent against canned model replies; returns the final answer.
demoAgent :: [Text] -> Text
demoAgent replies = runDemo replies (runAgentT demoCodec startDemo)
