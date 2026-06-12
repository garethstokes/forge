-- | Pure scalar metrics for 'Crucible.Eval' @Metric@ expectations. Every
-- function takes the REFERENCE first so partial application composes:
-- @Metric 0.4 (rougeL reference . render)@. All results land in [0,1].
module Crucible.Eval.Metrics
  ( normMatch
  , tokenF1
  , rougeL
  ) where

import Data.List (foldl', sort)
import Data.Text (Text)
import qualified Data.Text as T

-- | 1.0 when the two texts are equal after case-folding and whitespace
-- normalization, else 0.0.
normMatch :: Text -> Text -> Double
normMatch ref out = if tokens ref == tokens out then 1.0 else 0.0

-- | Token-multiset F1 (SQuAD style): case-folded whitespace tokens,
-- harmonic mean of precision and recall. Both empty = 1.0; one empty = 0.0.
tokenF1 :: Text -> Text -> Double
tokenF1 ref out
  | null rt && null ot = 1.0
  | null rt || null ot = 0.0
  | otherwise          = harmonic (c / len ot) (c / len rt)
  where
    rt = tokens ref
    ot = tokens out
    c  = fromIntegral (commonCount rt ot)

-- | ROUGE-L: longest common subsequence over case-folded tokens, reported
-- as the harmonic mean of LCS precision (over the candidate) and recall
-- (over the reference). Both empty = 1.0; one empty = 0.0.
rougeL :: Text -> Text -> Double
rougeL ref out
  | null rt && null ot = 1.0
  | null rt || null ot = 0.0
  | otherwise          = harmonic (l / len ot) (l / len rt)
  where
    rt = tokens ref
    ot = tokens out
    l  = fromIntegral (lcsLen rt ot)

tokens :: Text -> [Text]
tokens = T.words . T.toCaseFold

len :: [Text] -> Double
len = fromIntegral . length

-- | 2pr/(p+r); 0 when both are 0 (possible only with zero overlap).
harmonic :: Double -> Double -> Double
harmonic p r = if p + r == 0 then 0.0 else 2 * p * r / (p + r)

-- | Multiset intersection size via merge over sorted lists.
commonCount :: [Text] -> [Text] -> Int
commonCount xs ys = go (sort xs) (sort ys)
  where
    go aas@(a : as) bbs@(b : bs)
      | a == b    = 1 + go as bs
      | a < b     = go as bbs
      | otherwise = go aas bs
    go _ _ = 0

-- | Classic one-row LCS dynamic programme. Each row is forced as it is
-- produced, keeping space at O(|ys|) instead of a full lazy table.
lcsLen :: [Text] -> [Text] -> Int
lcsLen xs ys = last (foldl' step (replicate (length ys + 1) 0) xs)
  where
    step prev x = forced (scanl f 0 (zip3 ys prev (drop 1 prev)))
      where f left (y, diag, up) = if x == y then diag + 1 else max left up
    forced row = foldl' (\u v -> v `seq` u) () row `seq` row
