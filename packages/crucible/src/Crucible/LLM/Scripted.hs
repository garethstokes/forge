{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Crucible.LLM.Scripted
  ( ScriptedM, runScripted
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Control.Monad.State (State, evalState, get, put)
import Crucible.LLM (MonadLLM(..))

-- | A pure carrier that answers each `complete` with the next canned reply.
newtype ScriptedM a = ScriptedM (State [Text] a)
  deriving (Functor, Applicative, Monad)

instance MonadLLM ScriptedM where
  complete _ = ScriptedM $ do
    rs <- get
    case rs of
      (x : xs) -> put xs >> pure x
      []       -> pure T.empty   -- script exhausted: empty reply (tests should supply enough)

-- | Run a scripted computation against a list of canned model replies.
runScripted :: [Text] -> ScriptedM a -> a
runScripted replies (ScriptedM m) = evalState m replies
