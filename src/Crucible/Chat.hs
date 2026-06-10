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
  , blockJson
  , turnContentJson
  , parseTurn
  ) where

import Control.Exception (Exception)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as LBS

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret, send)
import Effectful.State.Static.Local (evalState, get, put)

import qualified Data.Aeson as A
import Data.Aeson (Value (String), (.=), (.:))
import qualified Data.Aeson.Types as AT
import qualified Data.Vector as V

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

-- | crucible's canonical content-block JSON for a 'Block' (the Anthropic
-- content shape, which doubles as the provider-neutral cassette format).
blockJson :: Block -> Value
blockJson (TextBlock t) =
  A.object ["type" .= A.String "text", "text" .= t]
blockJson (ToolUseBlock (ToolUse i n a)) =
  A.object ["type" .= A.String "tool_use", "id" .= i, "name" .= n, "input" .= a]
blockJson (ToolResultBlock i v) =
  A.object
    [ "type" .= A.String "tool_result"
    , "tool_use_id" .= i
    , "content" .= resultText v
    ]
  where
    resultText (String s) = A.String s
    resultText other      = A.String (TE.decodeUtf8 (LBS.toStrict (A.encode other)))

-- | Encode a 'Turn' as a content-block object, for recording to a chat
-- cassette. Round-trips: @parseTurn (encode (turnContentJson t)) == Right t@.
-- Provider-neutral: both the Anthropic and OpenAI cassette interpreters use it.
turnContentJson :: Turn -> Value
turnContentJson (Turn t uses) =
  A.object ["content" .= A.Array (V.fromList (map blockJson blocks))]
  where
    blocks = [TextBlock t | not (T.null t)] ++ map ToolUseBlock uses

-- | Parse a content-block object (a cassette line, or an Anthropic
-- @/v1/messages@ response body) into a 'Turn': concatenated @text@ blocks,
-- plus every @tool_use@ block.
parseTurn :: Text -> Either String Turn
parseTurn t = do
  v <- A.eitherDecode (LBS.fromStrict (TE.encodeUtf8 t))
  AT.parseEither
    (A.withObject "resp" $ \o -> do
        blocks <- o .: "content"
        rbs    <- mapM parseRBlock blocks
        pure (Turn (T.concat [tx | RText tx <- rbs]) [u | RUse u <- rbs]))
    v

data RBlock = RText Text | RUse ToolUse | RSkip

parseRBlock :: Value -> AT.Parser RBlock
parseRBlock = A.withObject "block" $ \o -> do
  ty <- o .: "type" :: AT.Parser Text
  case ty of
    "text"     -> RText <$> o .: "text"
    "tool_use" -> do
      i   <- o .: "id"
      n   <- o .: "name"
      inp <- o .: "input"
      pure (RUse (ToolUse i n inp))
    _ -> pure RSkip
