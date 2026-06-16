{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
module Crucible.Decision
  ( Decision(..)
  , decisionCodec
  , Step(..)
  , reduce
  ) where

import Autodocodec (JSONCodec, disjointEitherCodec, dimapCodec)

-- | Everything the model emits is one of these: a tool call or a final answer.
data Decision tool answer = CallTool tool | Done answer
  deriving (Eq, Show)

-- | Build a codec that decodes a reply into a Decision and encodes it back.
-- Tries the tool codec first, then the answer codec.
decisionCodec :: JSONCodec tool -> JSONCodec answer -> JSONCodec (Decision tool answer)
decisionCodec toolC ansC =
  dimapCodec (either CallTool Done)
             (\d -> case d of CallTool t -> Left t; Done a -> Right a)
             (disjointEitherCodec toolC ansC)

-- | The pure outcome of interpreting a Decision: run a tool, or stop.
data Step tool answer = Continue tool | Halt answer
  deriving (Eq, Show)

-- | Pure, total: the seam the control loop pivots on (no effects).
reduce :: Decision tool answer -> Step tool answer
reduce (CallTool t) = Continue t
reduce (Done a)     = Halt a
