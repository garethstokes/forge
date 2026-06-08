{-# LANGUAGE OverloadedStrings #-}
module Crucible.Decision
  ( Decision(..)
  , decisionCodec
  , Step(..)
  , reduce
  ) where

import Crucible.Codec (Codec(..), Variant(..), oneOfC)

-- | Everything the model emits is one of these: a tool call or a final answer.
data Decision tool answer = CallTool tool | Done answer
  deriving (Eq, Show)

-- | Build a codec that decodes a reply into a Decision and encodes it back.
-- Tries the tool codec first, then the answer codec.
decisionCodec :: Codec tool -> Codec answer -> Codec (Decision tool answer)
decisionCodec toolC ansC = oneOfC
  [ Variant (codecSchema toolC)
            (CallTool <$> codecDecode toolC)
            (\d -> case d of CallTool t -> Just (codecEncode toolC t); _ -> Nothing)
  , Variant (codecSchema ansC)
            (Done <$> codecDecode ansC)
            (\d -> case d of Done a -> Just (codecEncode ansC a); _ -> Nothing) ]

-- | The pure outcome of interpreting a Decision: run a tool, or stop.
data Step tool answer = Continue tool | Halt answer
  deriving (Eq, Show)

-- | Pure, total: the seam the control loop pivots on (no effects).
reduce :: Decision tool answer -> Step tool answer
reduce (CallTool t) = Continue t
reduce (Done a)     = Halt a
