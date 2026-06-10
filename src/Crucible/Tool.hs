{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Typed tools. A 'Tool' is an existential sealing a handler's input and
-- output types together with the codecs that mediate the JSON boundary;
-- 'invoke' is the only place JSON enters or leaves. Failures at the boundary
-- are structured 'ToolError's, rendered for the model once by 'renderToolError'.
--
-- Constructors, happy path first: 'tool' (name as a type-level Symbol, codecs
-- from 'HasCodec'), 'toolWith' (explicit codecs), 'rawTool' (hand-written
-- schema, 'Value' in and out; @rawTool n sch = Tool n sch anyValue anyValue@).
--
-- There is deliberately no Profunctor instance: the handler @i -> Eff es o@
-- is already one (dimap it before construction), but codecs are invariant,
-- so a lawful instance on the codec-carrying record cannot exist.
module Crucible.Tool
  ( ToolName, ToolCall(..), toolCallCodec, anyValue
  , Tool(..), tool, toolWith, rawTool
  , ToolError(..), invoke, renderToolError
  , Tools(..), callTool, runTools, toolsHelp
  ) where

import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text.Encoding as TE
import qualified Data.Aeson as A
import Data.Aeson (Value)
import qualified Data.Aeson.Types as AT
import GHC.TypeLits (KnownSymbol, symbolVal)
import Autodocodec (parseJSONVia, toJSONVia)
import Crucible.Codec (JSONCodec, object, field, str, anyValue, schemaValue)
import Crucible.Codec.Generic (HasCodec (codec))
import Crucible.Decode (DecodeError (..))
import Effectful
import Effectful.Dispatch.Dynamic (send, interpret)

type ToolName = Text

-- | A tool invocation as the model emits it: a name and raw args.
data ToolCall = ToolCall { name :: ToolName, args :: Value }
  deriving (Eq, Show)

toolCallCodec :: JSONCodec ToolCall
toolCallCodec = object (ToolCall <$> field "tool" (.name) str <*> field "args" (.args) anyValue)

-- | A named tool: the advertised input schema, the codecs for both ends of
-- the JSON boundary, and a typed runner in the ambient effect row. The
-- handler's types are existential; 'invoke' is their only consumer.
data Tool es where
  Tool ::
    { name   :: ToolName
    , schema :: Value          -- ^ input JSON Schema as advertised on the wire
    , input  :: JSONCodec i
    , output :: JSONCodec o
    , run    :: i -> Eff es o
    } -> Tool es

-- | Build a tool from a typed handler; the name is a type-level Symbol and
-- the schema is derived from the input codec:
-- @tool \@"get_weather" $ \\(Loc city) -> pure (Sky ("sunny in " <> city))@
tool :: forall name i o es. (KnownSymbol name, HasCodec i, HasCodec o)
     => (i -> Eff es o) -> Tool es
tool = toolWith (T.pack (symbolVal (Proxy @name))) (codec @i) (codec @o)

-- | 'tool' with explicit codecs (irregular names, types without 'HasCodec').
toolWith :: ToolName -> JSONCodec i -> JSONCodec o -> (i -> Eff es o) -> Tool es
toolWith n inC outC = Tool n (schemaValue inC) inC outC

-- | The escape hatch: a hand-written schema and a raw 'Value' handler.
rawTool :: ToolName -> Value -> (Value -> Eff es Value) -> Tool es
rawTool n sch = Tool n sch anyValue anyValue

-- | A structured wire-boundary failure, rendered for the model by
-- 'renderToolError'. Handler exceptions are NOT caught; they propagate.
data ToolError
  = UnknownTool ToolName [ToolName]         -- ^ requested, available
  | BadArgs     ToolName DecodeError Value  -- ^ tool, decode failure, its schema
  deriving (Eq, Show)

-- | Run a tool against raw model-supplied args: decode through the input
-- codec (failure: 'BadArgs' carrying the offending args as the error's
-- @raw@), run the handler, encode the result through the output codec
-- (total; the result half has no failure path).
invoke :: Tool es -> Value -> Eff es (Either ToolError Value)
invoke (Tool n sch inC outC f) v =
  case AT.parseEither (parseJSONVia inC) v of
    Left err -> pure (Left (BadArgs n (DecodeError (T.pack err) (renderValue v)) sch))
    Right i  -> Right . toJSONVia outC <$> f i

-- | The model-facing feedback for a 'ToolError': the error, the expected
-- schema, and the args echoed back, so the model can self-correct.
renderToolError :: ToolError -> Text
renderToolError (UnknownTool n avail) =
  "unknown tool: " <> n <> ". available tools: " <> T.intercalate ", " avail
renderToolError (BadArgs n e sch) =
  "tool " <> n <> ": arguments did not decode: " <> e.message
    <> "\nexpected schema: " <> renderValue sch
    <> "\nyou sent: " <> e.raw

-- | The tool-dispatch capability as a dynamic effect.
data Tools :: Effect where
  CallTool :: ToolName -> Value -> Tools m (Either ToolError Value)
type instance DispatchOf Tools = Dynamic

callTool :: (Tools :> es) => ToolName -> Value -> Eff es (Either ToolError Value)
callTool n v = send (CallTool n v)

-- | Interpret Tools against a toolbox; unknown tool -> Left (with the
-- available names); bad args -> Left via 'invoke'.
runTools :: [Tool es] -> Eff (Tools : es) a -> Eff es a
runTools tools = interpret $ \_ -> \case
  CallTool tname targs -> case filter ((== tname) . (.name)) tools of
    (t : _) -> invoke t targs
    []      -> pure (Left (UnknownTool tname (map (.name) tools)))

-- | A prose listing of the toolbox for the system prompt.
toolsHelp :: [Tool es] -> Text
toolsHelp ts = T.intercalate "\n"
  [ "- " <> t.name <> "(args: " <> renderValue t.schema <> ")" | t <- ts ]

-- | Render a JSON Value as compact JSON text.
renderValue :: Value -> Text
renderValue = TE.decodeUtf8 . LB.toStrict . A.encode
