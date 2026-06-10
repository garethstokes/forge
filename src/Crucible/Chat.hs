{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Native tool-calling as a block-based conversation capability, separate from
-- the text-only 'Crucible.LLM' path. A 'Chat' interpreter turns a conversation
-- (content blocks) plus tool specs into the assistant's 'Turn' (text + any
-- tool_use requests); 'runToolAgent' drives the request/run/result loop.
module Crucible.Chat
  ( ToolUseId
  , ToolUse (..)
  , Block (..)
  , Message (..)
  , Turn (..)
  , Chat (..)
  , converse
  , ChatError (..)
  , runChatScripted
  , runToolAgent
  , runToolAgentN
  , defaultMaxIterations
  ) where

import Control.Exception (Exception)
import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret, send)
import Effectful.State.Static.Local (evalState, get, put)

import qualified Data.Aeson as A
import Data.Aeson (Value)

import Crucible.LLM (Role (Assistant, User))
import Crucible.Tool (Tool (..), ToolName)

type ToolUseId = Text

-- | A model request to invoke a tool.
data ToolUse = ToolUse
  { id   :: ToolUseId
  , name :: ToolName
  , args :: Value
  }
  deriving (Eq, Show)

-- | A content block within a conversation message.
data Block
  = TextBlock       Text
  | ToolUseBlock    ToolUse
  | ToolResultBlock ToolUseId Value   -- ^ a result (or error) for a prior tool_use
  deriving (Eq, Show)

data Message = Message Role [Block]
  deriving (Eq, Show)

-- | The assistant's reply: any text, plus any tool_use requests.
data Turn = Turn
  { text     :: Text
  , toolUses :: [ToolUse]
  }
  deriving (Eq, Show)

-- | One tool-aware conversation step. The interpreter is given the tool specs
-- (name + input schema) to advertise, and the conversation so far.
data Chat :: Effect where
  Converse :: [(ToolName, Value)] -> [Message] -> Chat m Turn
type instance DispatchOf Chat = Dynamic

converse :: (Chat :> es) => [(ToolName, Value)] -> [Message] -> Eff es Turn
converse specs msgs = send (Converse specs msgs)

-- | A tool-loop failure: the iteration budget was exhausted.
newtype ChatError = ToolLoopExceeded Int
  deriving (Eq, Show)

instance Exception ChatError

-- | Canned-turn interpreter for tests: each 'Converse' pops the next 'Turn';
-- an exhausted script yields a text-only empty 'Turn' (so a loop terminates).
runChatScripted :: [Turn] -> Eff (Chat : es) a -> Eff es a
runChatScripted turns = reinterpret (evalState turns) $ \_ -> \case
  Converse _ _ -> do
    ts <- get
    case ts of
      (t : rest) -> put rest >> pure t
      []         -> pure (Turn "" [])

-- | Cap on tool-loop iterations, to bound a runaway model.
defaultMaxIterations :: Int
defaultMaxIterations = 10

-- | Like 'runToolAgent' but with an explicit iteration cap. On exhaustion
-- returns @Left ('ToolLoopExceeded' cap)@ — the actual budget used.
runToolAgentN :: (Chat :> es) => Int -> [Tool es] -> Text -> Eff es (Either ChatError Text)
runToolAgentN cap tools question = loop cap [Message User [TextBlock question]]
  where
    specs = [(t.name, t.schema) | t <- tools]

    loop n msgs = do
      turn <- converse specs msgs
      if null turn.toolUses
        then pure (Right turn.text)
        else
          if n <= 0
            then pure (Left (ToolLoopExceeded cap))
            else do
              results <- mapM runOne turn.toolUses
              let assistant =
                    Message Assistant
                      ( [TextBlock turn.text | not (T.null turn.text)]
                          ++ map ToolUseBlock turn.toolUses )
                  userResults = Message User results
              loop (n - 1) (msgs ++ [assistant, userResults])

    runOne u = case filter ((== u.name) . (.name)) tools of
      (t : _) -> ToolResultBlock u.id <$> t.run u.args
      []      -> pure (ToolResultBlock u.id (A.String ("unknown tool: " <> u.name)))

-- | Drive a native tool-calling loop to a final text answer, capped at
-- 'defaultMaxIterations'. See 'runToolAgentN' for a custom cap. Total: works
-- under the scripted and live interpreters alike (needs only @Chat :> es@).
runToolAgent :: (Chat :> es) => [Tool es] -> Text -> Eff es (Either ChatError Text)
runToolAgent = runToolAgentN defaultMaxIterations
