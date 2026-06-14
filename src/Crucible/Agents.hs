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

-- | Typed orchestrator-worker spawn. A 'SubAgent' is a worker: a 'Skill' whose
-- body is a tool loop. The 'Agents' effect's 'spawn' runs the worker as a fresh
-- transcript (the parent never sees it) and decodes its final answer through the
-- worker's output codec, the typed handoff no surveyed harness has. This release
-- is one level (workers are leaf, cannot spawn) and synchronous, with a built-in
-- spawn cap. 'runAgents' is the live interpreter; 'runAgentsScripted' is a
-- model-free interpreter for testing parent logic.
module Crucible.Agents
  ( SubAgent (..)
  , subAgent
  , AgentFailure (..)
  , Agents (..)
  , spawn
  , workerPrompt
  , runAgents
  , runAgentsScripted
  ) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (evalState, get, put)

import Crucible.Chat (Chat, ChatError (..), runToolAgentN, defaultMaxIterations)
import Crucible.Codec (JSONCodec, schemaText, encodeText)
import Crucible.Decode (DecodeError (..), decodeLLM)
import Crucible.Tool (Tool)

-- | A spawnable worker. @es@ is the base effect row the worker runs in (it has
-- 'Chat' and whatever its tools need, not 'Agents', which keeps spawn one level).
data SubAgent es i o = SubAgent
  { name     :: Text
  , input    :: JSONCodec i
  , output   :: JSONCodec o
  , system   :: Text
  , tools    :: [Tool es]
  , maxIters :: Int
  }

-- | Build a SubAgent with @maxIters@ defaulted to 'defaultMaxIterations'.
subAgent :: Text -> JSONCodec i -> JSONCodec o -> Text -> [Tool es] -> SubAgent es i o
subAgent n inC outC sys ts = SubAgent n inC outC sys ts defaultMaxIterations

-- | A spawn failure.
data AgentFailure
  = SpawnBudgetExceeded Int               -- ^ the spawn cap that was hit
  | WorkerLoopExceeded  Text Int          -- ^ worker name; the iteration cap it exhausted
  | WorkerDecodeFailed  Text DecodeError  -- ^ worker name, the decode error
  | GateRejected        Text Text         -- ^ worker name, the judge's critique
  deriving (Eq, Show)

-- | Orchestrator-worker spawn, indexed by the worker base row @es@.
data Agents (es :: [Effect]) :: Effect where
  Spawn :: SubAgent es i o -> i -> Agents es m (Either AgentFailure o)
type instance DispatchOf (Agents es) = Dynamic

spawn :: (Agents es :> r) => SubAgent es i o -> i -> Eff r (Either AgentFailure o)
spawn sub i = send (Spawn sub i)

-- | The worker prompt: the worker instruction, the output-schema contract, and
-- the rendered input. Pure, so it is unit-tested.
workerPrompt :: SubAgent es i o -> i -> Text
workerPrompt sub i = T.concat
  [ sub.system, "\n\n"
  , "Respond ONLY with JSON matching this schema:\n", schemaText sub.output, "\n\n"
  , "<input>\n", encodeText sub.input i, "\n</input>\n\n"
  , "When you are done, reply with JSON only; your reply is parsed by a machine."
  ]

-- | Decode a worker's final answer text into the typed result.
decodeFinal :: SubAgent es i o -> Text -> Either AgentFailure o
decodeFinal sub t = case decodeLLM sub.output t of
  Left e  -> Left (WorkerDecodeFailed sub.name e)
  Right o -> Right o

-- | Live interpreter: each spawn runs the worker tool loop as a fresh
-- transcript under the ambient 'Chat', honoring a spawn-count cap. Needs 'IOE'
-- (the budget is an 'IORef'; live spawn is IO-backed).
runAgents :: (Chat :> es, IOE :> es) => Int -> Eff (Agents es : es) a -> Eff es a
runAgents cap act = do
  ref <- liftIO (newIORef cap)
  interpret
    (\_ -> \case
        Spawn sub i -> do
          remaining <- liftIO (readIORef ref)
          if remaining <= 0
            then pure (Left (SpawnBudgetExceeded cap))
            else do
              liftIO (writeIORef ref (remaining - 1))
              res <- runToolAgentN sub.maxIters sub.tools (workerPrompt sub i)
              pure $ case res of
                Left (ToolLoopExceeded n) -> Left (WorkerLoopExceeded sub.name n)
                Right finalText           -> decodeFinal sub finalText)
    act

-- | Model-free interpreter: each spawn pops the next canned final-answer text
-- and decodes it through that spawn's output codec, honoring the same cap. Runs
-- no tools, so it is pure ('runPureEff'-compatible). The spawn input is ignored
-- (the canned text is independent of it), so this interpreter cannot verify
-- input-dependent worker behaviour; it is for testing parent orchestration
-- logic. An exhausted script returns 'WorkerDecodeFailed' without consuming
-- budget (no spawn was serviced).
runAgentsScripted :: Int -> [Text] -> Eff (Agents es : es) a -> Eff es a
runAgentsScripted cap script =
  reinterpret (evalState (cap, script)) $ \_ -> \case
    Spawn sub _i -> do
      (remaining, answers) <- get @(Int, [Text])
      if remaining <= 0
        then pure (Left (SpawnBudgetExceeded cap))
        else case answers of
          (t : ts) -> put (remaining - 1, ts) >> pure (decodeFinal sub t)
          []       -> pure (Left (WorkerDecodeFailed sub.name (DecodeError "no scripted answer" "")))
