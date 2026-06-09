{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Native tool-calling as a block-based conversation capability, separate from
-- the text-only 'Crucible.LLM' path. A 'Chat' interpreter turns a conversation
-- (content blocks) plus tool specs into the assistant's 'Turn' (text + any
-- tool_use requests); 'runToolAgent' (later task) drives the request/run/result loop.
module Crucible.Chat
  ( ToolUseId
  , ToolUse (..)
  , Block (..)
  , ChatMsg (..)
  , Turn (..)
  , Chat (..)
  , converse
  , ChatError (..)
  , runChatScripted
  ) where

import Control.Exception (Exception)
import Data.Text (Text)

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret, send)
import Effectful.State.Static.Local (evalState, get, put)

import Crucible.Json.Value (Value)
import Crucible.LLM (Role)
import Crucible.Schema (Schema)
import Crucible.Tool (ToolName)

type ToolUseId = Text

-- | A model request to invoke a tool.
data ToolUse = ToolUse
  { tuId   :: ToolUseId
  , tuName :: ToolName
  , tuArgs :: Value
  }
  deriving (Eq, Show)

-- | A content block within a conversation message.
data Block
  = TextBlock       Text
  | ToolUseBlock    ToolUse
  | ToolResultBlock ToolUseId Value   -- ^ a result (or error) for a prior tool_use
  deriving (Eq, Show)

data ChatMsg = ChatMsg Role [Block]
  deriving (Eq, Show)

-- | The assistant's reply: any text, plus any tool_use requests.
data Turn = Turn
  { turnText     :: Text
  , turnToolUses :: [ToolUse]
  }
  deriving (Eq, Show)

-- | One tool-aware conversation step. The interpreter is given the tool specs
-- (name + input schema) to advertise, and the conversation so far.
data Chat :: Effect where
  Converse :: [(ToolName, Schema)] -> [ChatMsg] -> Chat m Turn
type instance DispatchOf Chat = Dynamic

converse :: (Chat :> es) => [(ToolName, Schema)] -> [ChatMsg] -> Eff es Turn
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
