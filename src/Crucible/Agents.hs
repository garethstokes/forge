{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | Typed orchestrator-worker spawn. A 'SubAgent' is a worker: a 'Skill' whose
-- body is a tool loop. The 'Agents' effect's 'spawn' runs the worker as a fresh
-- transcript (the parent never sees it) and decodes its final answer through the
-- worker's output codec, the typed handoff no surveyed harness has. A worker's
-- tools run in a row that can 'spawn', so a worker can spawn sub-workers (an
-- arbitrary-depth tree); 'runAgents' threads one spawn budget across the whole
-- tree. Spawn is synchronous. 'runAgents' is the live interpreter;
-- 'runAgentsScripted' is a model-free interpreter for testing parent logic.
module Crucible.Agents
  ( SubAgent (..)
  , subAgent
  , AgentFailure (..)
  , Agents (..)
  , spawn
  , spawnAll
  , workerPrompt
  , runAgents
  , runAgentsScripted
  ) where

import Data.IORef (IORef, newIORef, atomicModifyIORef')
import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Concurrent (Concurrent)
import Effectful.Concurrent.Async (mapConcurrently)
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (evalState, get, put)

import Crucible.Chat (Chat, ChatError (..), runToolAgentN, defaultMaxIterations)
import Crucible.Codec (JSONCodec, schemaText, encodeText)
import Crucible.Decode (DecodeError (..), decodeLLM)
import Crucible.Tool (Tool)

-- | A spawnable worker. @es@ is the base effect row; the worker's tools run in
-- @Agents es : es@, so a tool handler may call 'spawn' (this is how a worker
-- spawns sub-workers).
data SubAgent es i o = SubAgent
  { name     :: Text
  , input    :: JSONCodec i
  , output   :: JSONCodec o
  , system   :: Text
  , tools    :: [Tool (Agents es : es)]
  , maxIters :: Int
  }

-- | Build a SubAgent with @maxIters@ defaulted to 'defaultMaxIterations'.
subAgent :: Text -> JSONCodec i -> JSONCodec o -> Text -> [Tool (Agents es : es)] -> SubAgent es i o
subAgent n inC outC sys ts = SubAgent n inC outC sys ts defaultMaxIterations

-- | A spawn failure.
data AgentFailure
  = SpawnBudgetExceeded Int               -- ^ the spawn cap that was hit
  | WorkerLoopExceeded  Text Int          -- ^ worker name; the iteration cap it exhausted
  | WorkerDecodeFailed  Text DecodeError  -- ^ worker name, the decode error
  | GateRejected        Text Text         -- ^ worker name, the judge's critique
  deriving (Eq, Show)

-- | Orchestrator-worker spawn, indexed by the worker base row @es@. Workers run
-- in @Agents es : es@, so a worker tool can issue 'spawn' for sub-workers.
data Agents (es :: [Effect]) :: Effect where
  Spawn :: SubAgent es i o -> i -> Agents es m (Either AgentFailure o)
type instance DispatchOf (Agents es) = Dynamic

spawn :: (Agents es :> r) => SubAgent es i o -> i -> Eff r (Either AgentFailure o)
spawn sub i = send (Spawn sub i)

-- | Spawn a batch of workers concurrently and collect their results in input
-- order. Built on effectful's 'Concurrent' ('mapConcurrently' over 'spawn'), so
-- the 'Agents' effect is unchanged. Siblings share no state; each returns its
-- own typed result. The spawn budget is shared atomically across the batch (and
-- the whole tree), so with a cap below the batch size exactly cap spawns
-- succeed and the rest return 'SpawnBudgetExceeded'. A worker failure is a
-- 'Left' (it does not cancel siblings); a worker that throws cancels the
-- siblings and rethrows (the 'async' semantics). Discharge 'Concurrent' with
-- 'Effectful.Concurrent.runConcurrent'. Discharge the spawn with 'runAgents',
-- not 'runAgentsScripted': the live interpreter holds the budget in an 'IORef'
-- shared across the forked siblings, whereas the scripted interpreter's
-- 'State' budget is cloned per sibling and so would not be shared (the cap
-- would not bound a concurrent batch).
spawnAll :: (Agents es :> r, Concurrent :> r)
         => [(SubAgent es i o, i)] -> Eff r [Either AgentFailure o]
spawnAll = mapConcurrently (uncurry spawn)

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

-- | Atomically claim one unit of budget: True if a slot was taken (and the
-- counter decremented), False if the budget was already exhausted. Safe under
-- concurrent spawns (a compare-and-set), so the cap is never over-spent.
claimSlot :: IORef Int -> IO Bool
claimSlot ref = atomicModifyIORef' ref (\r -> if r <= 0 then (r, False) else (r - 1, True))

-- | Live interpreter for a spawn tree. One shared spawn budget is threaded
-- across the whole tree (each spawn anywhere decrements it; exhaustion is
-- 'SpawnBudgetExceeded'). Each worker runs in the full row 'Agents es : es', so
-- a worker tool can 'spawn' sub-workers; the handler re-interprets that worker
-- computation ('go'), servicing nested spawns against the same budget. Needs
-- 'IOE' (the budget is an 'IORef'; live spawn is IO-backed).
runAgents :: forall es a. (Chat :> es, IOE :> es) => Int -> Eff (Agents es : es) a -> Eff es a
runAgents cap act = do
  ref <- liftIO (newIORef cap)
  let go :: forall x. Eff (Agents es : es) x -> Eff es x
      go = interpret $ \_ -> \case
        Spawn sub i -> do
          claimed <- liftIO (claimSlot ref)
          if not claimed
            then pure (Left (SpawnBudgetExceeded cap))
            else do
              res <- go (runToolAgentN sub.maxIters sub.tools (workerPrompt sub i))
              pure $ case res of
                Left (ToolLoopExceeded n) -> Left (WorkerLoopExceeded sub.name n)
                Right finalText           -> decodeFinal sub finalText
  go act

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
