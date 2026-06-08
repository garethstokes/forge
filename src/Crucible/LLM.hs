{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Crucible.LLM
  ( Role(..), Message(..)
  , LLM(..), complete
  , runLLMScripted
  ) where

import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (send, reinterpret)
import Effectful.State.Static.Local (evalState, get, put)

data Role = System | User | Assistant | Tool
  deriving (Eq, Show)

data Message = Message { role :: Role, content :: Text }
  deriving (Eq, Show)

-- | The LLM capability as a dynamic effect. A function with @LLM :> es@ can
-- talk to the model and (absent other constraints) nothing else — the
-- lightweight capability manifest.
data LLM :: Effect where
  Complete :: [Message] -> LLM m Text
type instance DispatchOf LLM = Dynamic

complete :: (LLM :> es) => [Message] -> Eff es Text
complete msgs = send (Complete msgs)

-- | Interpret LLM by popping canned replies (tests). Uses a local State.
runLLMScripted :: [Text] -> Eff (LLM : es) a -> Eff es a
runLLMScripted replies = reinterpret (evalState replies) $ \_ -> \case
  Complete _ -> do
    rs <- get
    case rs of
      (x : xs) -> put xs >> pure x
      []       -> pure ""
