{-# LANGUAGE OverloadedStrings #-}
module Crucible.Agent
  ( AgentState(..), startAgent, runAgent
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Crucible.LLM (MonadLLM(..), Message(..), Role(..))
import Crucible.Schema (renderSchema)
import Crucible.Codec (Codec(..))
import Crucible.SAP (decodeLLM)
import Crucible.Decision (Decision, Step(..), reduce)
import qualified Crucible.Json.Decode as D

-- | The agent's running context: the conversation so far.
newtype AgentState = AgentState { transcript :: [Message] }
  deriving (Eq, Show)

-- | Seed an agent: a system message stating the required output schema, then the user's question.
startAgent :: Codec (Decision tool answer) -> Text -> AgentState
startAgent codec question = AgentState
  [ Message System ("Respond ONLY with JSON matching this schema:\n" <> renderSchema (codecSchema codec))
  , Message User question ]

-- | Run the agent to a final answer. The control loop: complete -> decode (SAP)
-- -> reduce -> (dispatch tool & loop | halt). @MonadLLM m =>@ is the capability
-- manifest; tool dispatch is the supplied runner (M9 upgrades it to MonadTool).
runAgent :: MonadLLM m
         => Codec (Decision tool answer)
         -> (tool -> m Text)            -- ^ tool runner: returns a result string
         -> AgentState
         -> m answer
runAgent codec runTool = loop
  where
    loop st = do
      raw <- complete (transcript st)
      let st1 = append st (Message Assistant raw)
      case decodeLLM codec raw of
        Left err -> loop (append st1
          (Message User ("Your reply did not parse: " <> T.pack (D.message err)
                         <> ". Respond with valid JSON only.")))
        Right dec -> case reduce dec of
          Halt ans    -> pure ans
          Continue tc -> do
            res <- runTool tc
            loop (append st1 (Message Tool res))

append :: AgentState -> Message -> AgentState
append (AgentState ms) m = AgentState (ms ++ [m])
