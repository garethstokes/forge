{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Crucible.Tool
  ( ToolName, ToolCall(..), toolCallCodec, anyValue
  , Tool(..), Tools(..), callTool, runTools, toolsHelp
  , tool
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text.Encoding as TE
import qualified Data.Aeson as A
import Data.Aeson (Value)
import qualified Data.Aeson.Types as AT
import Autodocodec (parseJSONVia)
import Crucible.Codec (JSONCodec, object, field, str, anyValue, schemaValue)
import Crucible.Codec.Generic (HasCodec (codec))
import Effectful
import Effectful.Dispatch.Dynamic (send, interpret)

type ToolName = Text

-- | A tool invocation as the model emits it: a name and raw args.
data ToolCall = ToolCall { name :: ToolName, args :: Value }
  deriving (Eq, Show)

toolCallCodec :: JSONCodec ToolCall
toolCallCodec = object (ToolCall <$> field "tool" (.name) str <*> field "args" (.args) anyValue)

-- | A named tool: an args schema (shown in the prompt) and a runner in the
-- ambient effect row @Eff es@. Pure tools are polymorphic in @es@ (via 'pure');
-- an IO tool would carry @IOE :> es@.
data Tool es = Tool
  { name   :: ToolName
  , schema :: Value
  , run    :: Value -> Eff es Value }

-- | The tool-dispatch capability as a dynamic effect.
data Tools :: Effect where
  CallTool :: ToolName -> Value -> Tools m (Either Text Value)
type instance DispatchOf Tools = Dynamic

callTool :: (Tools :> es) => ToolName -> Value -> Eff es (Either Text Value)
callTool n v = send (CallTool n v)

-- | Interpret Tools against a toolbox; unknown tool -> Left.
runTools :: [Tool es] -> Eff (Tools : es) a -> Eff es a
runTools tools = interpret $ \_ -> \case
  CallTool tname targs -> case filter ((== tname) . (.name)) tools of
    (t : _) -> Right <$> t.run targs
    []      -> pure (Left ("unknown tool: " <> tname))

-- | A prose listing of the toolbox for the system prompt.
toolsHelp :: [Tool es] -> Text
toolsHelp ts = T.intercalate "\n"
  [ "- " <> t.name <> "(args: " <> renderSchemaValue t.schema <> ")" | t <- ts ]

-- | Render a JSON schema Value as compact JSON text.
renderSchemaValue :: Value -> Text
renderSchemaValue = TE.decodeUtf8 . LB.toStrict . A.encode

-- | Build a tool whose JSON-Schema is derived from its argument type and whose
-- arguments are decoded for you. A decode failure is surfaced as an error
-- 'Value' (the existing tool error convention).
tool :: forall a es. HasCodec a => Text -> (a -> Eff es Value) -> Tool es
tool nm run' = Tool nm (schemaValue (codec @a)) $ \args ->
  case AT.parseEither (parseJSONVia (codec @a)) args of
    Right a  -> run' a
    Left err -> pure (A.String ("bad tool args: " <> T.pack err))
