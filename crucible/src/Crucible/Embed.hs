{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | The embedding capability as a dynamic effect, plus the pure vector
-- math evals build on. Interpret with 'runEmbedScripted' in tests,
-- @OpenAI.runEmbed@ or @Voyage.runEmbed@ live, or 'none' for programs
-- that never embed (the one-line migration for scoreM\/runEval callers
-- with no 'Crucible.Eval.SimilarTo' cases).
module Crucible.Embed
  ( Embed (..)
  , embed
  , runEmbedScripted
  , none
  , cosine
  , consistency
  ) where

import Data.List (tails)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (evalState, get, put)

-- | The embedding capability: one text in, one vector out.
data Embed :: Effect where
  EmbedText :: Text -> Embed m [Double]
type instance DispatchOf Embed = Dynamic

embed :: (Embed :> es) => Text -> Eff es [Double]
embed t = send (EmbedText t)

-- | Interpret Embed by popping canned vectors (tests). Mirrors
-- 'Crucible.LLM.runLLMScripted', including its dry-script behaviour:
-- an exhausted script yields @[]@.
runEmbedScripted :: [[Double]] -> Eff (Embed : es) a -> Eff es a
runEmbedScripted vecs = reinterpret (evalState vecs) $ \_ -> \case
  EmbedText _ -> do
    vs <- get
    case vs of
      (x : xs) -> put xs >> pure x
      []       -> pure []

-- | Discharge Embed for programs that never embed: errors with a clear
-- message on first use. Wrap scoreM\/runEval programs with this when the
-- dataset has no 'Crucible.Eval.SimilarTo' cases.
none :: Eff (Embed : es) a -> Eff es a
none = interpret $ \_ -> \case
  EmbedText _ ->
    error
      "Crucible.Embed.none: this program embeds text; interpret Embed with \
      \OpenAI.runEmbed, Voyage.runEmbed, or runEmbedScripted"

-- | Pure cosine similarity; 0 when either vector is all zeros. Expects
-- same-length vectors (one embedder, one dimensionality); a length
-- mismatch truncates the dot product to the shared prefix.
cosine :: [Double] -> [Double] -> Double
cosine xs ys
  | nx == 0 || ny == 0 = 0
  | otherwise          = dot / (nx * ny)
  where
    dot = sum (zipWith (*) xs ys)
    nx  = sqrt (sum [x * x | x <- xs])
    ny  = sqrt (sum [y * y | y <- ys])

-- | Mean pairwise cosine over a paraphrase group's outputs; groups of
-- zero or one text score 1.0. The group-shaped consistency eval:
-- compares outputs across runs, deliberately outside
-- 'Crucible.Eval.Expectation' (which grades one output).
consistency :: (Embed :> es) => [Text] -> Eff es Double
consistency ts
  | length ts <= 1 = pure 1.0
  | otherwise = do
      vs <- mapM embed ts
      let pairs = [cosine a b | (a : rest) <- tails vs, b <- rest]
      pure (sum pairs / fromIntegral (length pairs))
