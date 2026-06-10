{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Agent
  ( AgentState(..), startAgent, runAgent
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text.Encoding as TE
import qualified Data.Aeson as A
import Data.Aeson (Value)
import Effectful
import Crucible.LLM (LLM, complete, Message(..), Role(..))
import Crucible.Tool (Tools, callTool, ToolCall(..))
import Crucible.Codec (JSONCodec, schemaText)
import Crucible.SAP (decodeLLM)
import Crucible.Decision (Decision, Step(..), reduce)

-- | The agent's running context: the conversation so far.
newtype AgentState = AgentState { transcript :: [Message] }
  deriving (Eq, Show)

-- | Seed an agent: a system message stating the required output schema, then the user's question.
startAgent :: JSONCodec (Decision tool answer) -> Text -> AgentState
startAgent codec question = AgentState
  [ Message System ("Respond ONLY with JSON matching this schema:\n" <> schemaText codec)
  , Message User question ]

-- | The control loop. Its type IS the capability manifest: it may talk to the
-- model (@LLM :> es@) and dispatch tools (@Tools :> es@), and nothing else.
runAgent :: (LLM :> es, Tools :> es)
         => JSONCodec (Decision ToolCall answer) -> AgentState -> Eff es answer
runAgent codec = loop
  where
    loop st = do
      raw <- complete (transcript st)
      let st1 = append st (Message Assistant raw)
      case decodeLLM codec raw of
        Left err -> loop (append st1
          (Message User ("Your reply did not parse: " <> T.pack err
                         <> ". Respond with valid JSON only.")))
        Right dec -> case reduce dec of
          Halt ans                -> pure ans
          Continue (ToolCall n a) -> do
            res <- callTool n a
            loop (append st1 (Message Tool (either ("error: " <>) encodeValue res)))

encodeValue :: Value -> Text
encodeValue = TE.decodeUtf8 . LB.toStrict . A.encode

append :: AgentState -> Message -> AgentState
append (AgentState ms) m = AgentState (ms ++ [m])
