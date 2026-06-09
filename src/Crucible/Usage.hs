-- | Provider-agnostic token-usage accounting. Intended for use by live LLM interpreters.
--
-- 'Usage' is a 'Monoid' whose '<>' sums token counts, so accumulating usage
-- across many API calls is just '<>' / 'mconcat'. 'estimateCost' is a pure
-- helper the caller parameterises with 'Rates' — no prices are baked in here,
-- because they go stale and vary by tier/cache/batch.
module Crucible.Usage
  ( Usage (..)
  , usTotalTokens
  , Rates (..)
  , estimateCost
  ) where

-- | Input and output token counts from a single response, or summed across many.
data Usage = Usage
  { usInputTokens  :: !Int
  , usOutputTokens :: !Int
  }
  deriving (Eq, Show)

instance Semigroup Usage where
  Usage a b <> Usage c d = Usage (a + c) (b + d)

instance Monoid Usage where
  mempty = Usage 0 0

-- | Total tokens billed (input + output).
usTotalTokens :: Usage -> Int
usTotalTokens (Usage i o) = i + o

-- | Per-million-token rates. Anthropic quotes prices per MTok, so these are
-- "dollars (or any unit) per 1,000,000 tokens".
data Rates = Rates
  { rInputPerMTok  :: !Double
  , rOutputPerMTok :: !Double
  }
  deriving (Eq, Show)

-- | Estimated cost in the rates' currency: each token count divided by one
-- million, multiplied by its rate, summed.
estimateCost :: Rates -> Usage -> Double
estimateCost (Rates ri ro) (Usage i o) =
  fromIntegral i / 1e6 * ri + fromIntegral o / 1e6 * ro
