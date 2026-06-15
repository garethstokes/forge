{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- | Lint a 'Crucible.Research' page set. Structural checks (orphans, broken
-- links, sparse pages) are pure over the page set; semantic checks
-- (contradiction between pages, staleness against caller-supplied current facts)
-- reuse the judge vote ('Crucible.Eval.Judge.vote'). Returns typed 'Finding's.
-- Lives apart from 'Crucible.Research' so that module keeps no dependency on the
-- eval machinery.
module Crucible.Research.Lint
  ( Finding (..)
  , orphans, brokenLinks, sparsePages, lintStructural
  , linkedPairs, allPairs
  , lintContradictions, lintStale
  , LintOpts (..), defaultLintOpts, lintWiki
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Effectful

import Crucible.Eval.Judge (JudgeOpts (..), VoteOutcome (..), defaultJudgeOpts, vote)
import Crucible.LLM (LLM)
import Crucible.Research (Page (..), Slug (..), Link (..))

data Finding
  = Orphan        Slug
  | BrokenLink    Slug Link
  | SparsePage    Slug Int
  | Contradiction Slug Slug Text
  | Stale         Slug Text
  deriving (Eq, Show)

slugText :: Slug -> Text
slugText (Slug s) = s

orphans :: [Page meta] -> [Finding]
orphans pages = [Orphan p.slug | p <- pages, p.slug `notElem` inbound]
  where inbound = [l.target | q <- pages, l <- q.links, l.target /= q.slug]

brokenLinks :: [Page meta] -> [Finding]
brokenLinks pages = [BrokenLink p.slug l | p <- pages, l <- p.links, l.target `notElem` slugs]
  where slugs = map ((.slug) :: Page meta -> Slug) pages

sparsePages :: Int -> [Page meta] -> [Finding]
sparsePages threshold pages =
  [SparsePage p.slug (T.length p.body) | p <- pages, T.length p.body < threshold]

lintStructural :: Int -> [Page meta] -> [Finding]
lintStructural threshold pages =
  orphans pages ++ brokenLinks pages ++ sparsePages threshold pages

allPairs :: [Page meta] -> [(Page meta, Page meta)]
allPairs (x : xs) = map ((,) x) xs ++ allPairs xs
allPairs []       = []

linkedPairs :: [Page meta] -> [(Page meta, Page meta)]
linkedPairs pages = filter joined (allPairs pages)
  where joined (a, b) = any ((== b.slug) . target') a.links || any ((== a.slug) . target') b.links
        target' l = ((.target) :: Link -> Slug) l

lintContradictions :: forall meta es. (LLM :> es) => Int -> [(Page meta, Page meta)] -> Eff es [Finding]
lintContradictions n prs = concat <$> mapM check prs
  where
    check :: (Page meta, Page meta) -> Eff es [Finding]
    check (a, b) = do
      out <- vote True (defaultJudgeOpts :: JudgeOpts) { votes = n }
               "These two pages make claims that contradict each other."
               (rendered a b)
      pure $ case out of
        Decided True why _ _ _ -> [Contradiction a.slug b.slug why]
        _                      -> []
    rendered a b =
      "Page 1 (" <> slugText a.slug <> "):\n" <> a.body
        <> "\n\nPage 2 (" <> slugText b.slug <> "):\n" <> b.body

lintStale :: forall meta es. (LLM :> es) => Int -> Text -> [Page meta] -> Eff es [Finding]
lintStale n facts pages = concat <$> mapM check pages
  where
    check :: Page meta -> Eff es [Finding]
    check p = do
      out <- vote True (defaultJudgeOpts :: JudgeOpts) { votes = n }
               ("The page conflicts with or is out of date relative to these current facts:\n" <> facts)
               p.body
      pure $ case out of
        Decided True why _ _ _ -> [Stale p.slug why]
        _                      -> []

data LintOpts meta = LintOpts
  { sparseThreshold :: Int
  , votes           :: Int
  , pairs           :: [Page meta] -> [(Page meta, Page meta)]
  , currentFacts    :: Maybe Text
  }

defaultLintOpts :: LintOpts meta
defaultLintOpts = LintOpts 1 1 linkedPairs Nothing

lintWiki :: forall meta es. (LLM :> es) => LintOpts meta -> [Page meta] -> Eff es [Finding]
lintWiki opts pages = do
  cs <- lintContradictions opts.votes (opts.pairs pages)
  ss <- maybe (pure []) (\facts -> lintStale opts.votes facts pages) opts.currentFacts
  pure (lintStructural opts.sparseThreshold pages ++ cs ++ ss)
