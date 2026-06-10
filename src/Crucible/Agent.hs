{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}
module Crucible.Agent
  ( AgentState(..), startAgent, runAgent
  ) where

import Data.Text (Text)
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text.Encoding as TE
import qualified Data.Aeson as A
import Data.Aeson (Value)
import Effectful
import NeatInterpolation (text)
import Crucible.LLM (LLM, complete, Message(..), Role(..))
import Crucible.Tool (Tools, callTool, ToolCall(..))
import Crucible.Codec (JSONCodec, schemaText)
import Crucible.SAP (decodeLLM, DecodeError(..))
import Crucible.Decision (Decision, Step(..), reduce)

-- | The agent's running context: the conversation so far.
newtype AgentState = AgentState { transcript :: [Message] }
  deriving (Eq, Show)

-- | Seed an agent: a system message stating the required output schema, then the user's question.
startAgent :: JSONCodec (Decision tool answer) -> Text -> AgentState
startAgent codec question = AgentState
  [ Message System [text|
      Respond ONLY with JSON matching this schema:
      ${schema}|]
  , Message User question ]
  where schema = schemaText codec

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
        Left (DecodeError msg _) ->
          let e = msg
          in loop (append st1
               (Message User [text|Your reply did not parse: ${e}. Respond with valid JSON only.|]))
        Right dec -> case reduce dec of
          Halt ans                -> pure ans
          Continue (ToolCall n a) -> do
            res <- callTool n a
            loop (append st1 (Message Tool (either ("error: " <>) encodeValue res)))

encodeValue :: Value -> Text
encodeValue = TE.decodeUtf8 . LB.toStrict . A.encode

append :: AgentState -> Message -> AgentState
append (AgentState ms) m = AgentState (ms ++ [m])
