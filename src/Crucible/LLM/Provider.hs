{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}

-- | A named provider as a pair of per-call functions. The functions carry
-- the provider's own retry policy (full-jitter backoff per its retryable
-- classification), so member-level behaviour under a fallback chain is
-- exactly what the provider does alone. Build with
-- 'Crucible.LLM.Anthropic.provider' or 'Crucible.LLM.OpenAI.provider', or
-- construct directly for stubs and custom strategies.
module Crucible.LLM.Provider
  ( Provider (..)
  ) where

import Data.Aeson (Value)
import Data.Text (Text)

import qualified Crucible.Chat as Chat
import Crucible.Chat (Turn)
import Crucible.LLM (Message)
import Crucible.Tool (ToolName)
import Crucible.Usage (Usage)

data Provider = Provider
  { name     :: Text
  , complete :: [Message] -> IO (Text, Usage)
  , converse :: [(ToolName, Value)] -> [Chat.Message] -> IO (Turn, Usage)
  }
