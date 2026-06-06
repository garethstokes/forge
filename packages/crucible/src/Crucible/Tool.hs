{-# LANGUAGE OverloadedStrings #-}
module Crucible.Tool
  ( ToolName, ToolCall(..), toolCallCodec, anyValue
  , Tool(..), MonadTool(..), dispatchTools, toolsHelp
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Crucible.Schema (Schema(..), renderSchema)
import Crucible.Json.Value (Value(..))
import qualified Crucible.Json.Decode as D
import Crucible.Codec (Codec(..), object, field, str)

type ToolName = Text

-- | A tool invocation as the model emits it: a name and raw args.
data ToolCall = ToolCall { tcName :: ToolName, tcArgs :: Value }
  deriving (Eq, Show)

-- | Identity codec over an arbitrary JSON value (args are tool-specific).
anyValue :: Codec Value
anyValue = Codec SAny D.value id

toolCallCodec :: Codec ToolCall
toolCallCodec = object (ToolCall <$> field "tool" tcName str <*> field "args" tcArgs anyValue)

-- | A named tool: an args schema (shown in the prompt) and a runner in @m@.
-- The runner's monad constraint is the tool's capability (pure tools are
-- @Monad m => Tool m@; an IO tool would be @MonadIO m => Tool m@).
data Tool m = Tool
  { toolName   :: ToolName
  , toolSchema :: Schema
  , toolRun    :: Value -> m Value }

-- | The tool-dispatch capability.
class Monad m => MonadTool m where
  callTool :: ToolName -> Value -> m (Either Text Value)

-- | Dispatch a call against a toolbox by name.
dispatchTools :: Monad m => [Tool m] -> ToolName -> Value -> m (Either Text Value)
dispatchTools ts name args =
  case [t | t <- ts, toolName t == name] of
    (t : _) -> Right <$> toolRun t args
    []      -> pure (Left ("unknown tool: " <> name))

-- | A prose listing of the toolbox for the system prompt.
toolsHelp :: [Tool m] -> Text
toolsHelp ts = T.intercalate "\n"
  [ "- " <> toolName t <> "(args: " <> renderSchema (toolSchema t) <> ")" | t <- ts ]
