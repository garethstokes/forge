{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Tool
  ( ToolName, ToolCall(..), toolCallCodec, anyValue
  , Tool(..), Tools(..), callTool, runTools, toolsHelp
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Crucible.Schema (Schema(..), renderSchema)
import Crucible.Json.Value (Value(..))
import qualified Crucible.Json.Decode as D
import Crucible.Codec (Codec(..), object, field, str)
import Effectful
import Effectful.Dispatch.Dynamic (send, interpret)

type ToolName = Text

-- | A tool invocation as the model emits it: a name and raw args.
data ToolCall = ToolCall { tcName :: ToolName, tcArgs :: Value }
  deriving (Eq, Show)

-- | Identity codec over an arbitrary JSON value (args are tool-specific).
anyValue :: Codec Value
anyValue = Codec SAny D.value id

toolCallCodec :: Codec ToolCall
toolCallCodec = object (ToolCall <$> field "tool" tcName str <*> field "args" tcArgs anyValue)

-- | A named tool: an args schema (shown in the prompt) and a runner in the
-- ambient effect row @Eff es@. Pure tools are polymorphic in @es@ (via 'pure');
-- an IO tool would carry @IOE :> es@.
data Tool es = Tool
  { toolName   :: ToolName
  , toolSchema :: Schema
  , toolRun    :: Value -> Eff es Value }

-- | The tool-dispatch capability as a dynamic effect.
data Tools :: Effect where
  CallTool :: ToolName -> Value -> Tools m (Either Text Value)
type instance DispatchOf Tools = Dynamic

callTool :: (Tools :> es) => ToolName -> Value -> Eff es (Either Text Value)
callTool n v = send (CallTool n v)

-- | Interpret Tools against a toolbox; unknown tool -> Left.
runTools :: [Tool es] -> Eff (Tools : es) a -> Eff es a
runTools tools = interpret $ \_ -> \case
  CallTool name args -> case filter ((== name) . toolName) tools of
    (t : _) -> Right <$> toolRun t args
    []      -> pure (Left ("unknown tool: " <> name))

-- | A prose listing of the toolbox for the system prompt.
toolsHelp :: [Tool es] -> Text
toolsHelp ts = T.intercalate "\n"
  [ "- " <> toolName t <> "(args: " <> renderSchema (toolSchema t) <> ")" | t <- ts ]
