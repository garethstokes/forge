{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | A first-class effect for streaming text deltas. Streaming interpreters
-- 'emit' each delta as it arrives; the caller chooses how to consume them by
-- picking an interpreter (print live, collect, or discard) without the streamer
-- knowing. Parallel to 'Crucible.LLM.LLM' / 'Crucible.Chat.Chat'.
module Crucible.Emit
  ( Emit (..)
  , emit
  , runEmitIO
  , ignoreEmit
  , runEmitList
  ) where

import Data.Text (Text)

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (modify, runState)

data Emit :: Effect where
  Emit :: Text -> Emit m ()
type instance DispatchOf Emit = Dynamic

emit :: (Emit :> es) => Text -> Eff es ()
emit = send . Emit

-- | Run each delta through an IO sink (e.g. @putStr . T.unpack@).
runEmitIO :: (IOE :> es) => (Text -> IO ()) -> Eff (Emit : es) a -> Eff es a
runEmitIO sink = interpret $ \_ -> \case
  Emit t -> liftIO (sink t)

-- | Discard all deltas (the result is still fully assembled by the streamer).
ignoreEmit :: Eff (Emit : es) a -> Eff es a
ignoreEmit = interpret $ \_ -> \case
  Emit _ -> pure ()

-- | Collect deltas in arrival order alongside the result (for tests).
runEmitList :: Eff (Emit : es) a -> Eff es (a, [Text])
runEmitList action = do
  (a, xs) <- reinterpret (runState []) (\_ -> \case Emit t -> modify (t :)) action
  pure (a, reverse xs)
