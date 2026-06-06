module Crucible.LLM
  ( Role(..), Message(..)
  , MonadLLM(..)
  ) where

import Data.Text (Text)

data Role = System | User | Assistant | Tool
  deriving (Eq, Show)

data Message = Message { role :: Role, content :: Text }
  deriving (Eq, Show)

-- | The LLM capability. A function with @MonadLLM m =>@ can talk to the model
-- and (absent other constraints) nothing else — the lightweight capability manifest.
class Monad m => MonadLLM m where
  complete :: [Message] -> m Text
