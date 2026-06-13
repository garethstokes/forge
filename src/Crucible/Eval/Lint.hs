{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | Advisory rubric lint: run the four documented checklist anti-pattern
-- checks (docs/evals.md "Lint your rubric") as one judge call over
-- criterion labels. Advisory only, never a gate; a clean checklist
-- yields no findings. Coverage is absent because it needs the author's
-- observed failure modes, not the labels.
--
-- Like "Crucible.Eval.Grounding", this module does not depend on
-- 'Crucible.Eval' (it returns 'LintFinding', and Eval wraps it as
-- 'lintChecklist'); the prompt + repair are local plumbing with the same
-- semantics 'Crucible.Skill.call' would provide.
module Crucible.Eval.Lint
  ( LintIssue (..)
  , LintFinding (..)
  , lintPrompt
  , lintLabels
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Effectful
import NeatInterpolation (text)

import Crucible.Codec (JSONCodec, enum, field, list', object, schemaText, str)
import Crucible.Decode (DecodeError (..), decodeLLM)
import Crucible.LLM (LLM, Message (..), Role (..), complete)

-- | The four checklist anti-patterns.
data LintIssue = Conflation | Direction | Redundancy | Vague
  deriving (Eq, Show)

-- | One advisory finding, or the tool's own failure. 'LintUnavailable'
-- is returned (never thrown) when the reply will not parse after one
-- repair, so a caller can tell "no problems" from "lint did not run".
data LintFinding
  = Finding
      { issue     :: LintIssue
      , criterion :: Text
      , note      :: Text
      }
  | LintUnavailable Text
  deriving (Eq, Show)

-- | Internal wire shape: a single-constructor record so the codec getters
-- are total (a sum type has no total per-field getter). Decoded then
-- mapped to 'Finding'.
data RawFinding = RawFinding
  { issue     :: LintIssue
  , criterion :: Text
  , note      :: Text
  }

issueCodec :: JSONCodec LintIssue
issueCodec = enum
  [ ("conflation", Conflation)
  , ("direction",  Direction)
  , ("redundancy", Redundancy)
  , ("vague",      Vague)
  ]

lintCodec :: JSONCodec [RawFinding]
lintCodec = list' $ object
  (RawFinding <$> field "issue"     ((.issue)     :: RawFinding -> LintIssue) issueCodec
              <*> field "criterion" ((.criterion) :: RawFinding -> Text)      str
              <*> field "note"      ((.note)      :: RawFinding -> Text)      str)

toFinding :: RawFinding -> LintFinding
toFinding r = Finding r.issue r.criterion r.note

-- | The lint messages, pure and testable (mirrors 'judgePrompt'). Lists
-- every label and asks for only clear violations of the four
-- anti-patterns; conservative by instruction.
lintPrompt :: [Text] -> [Message]
lintPrompt labels =
  [ Message System [text|
      You are a strict rubric linter. Report ONLY clear violations of the
      four checklist anti-patterns below. If a criterion is fine, say
      nothing about it; a clean checklist yields an empty array. Do not
      flag borderline cases.
      Respond ONLY with JSON matching this schema:
      ${schema}|]
  , Message User [text|
      Check each labelled criterion for these issues:
      - conflation: the criterion tests two things joined by "and"; split it.
      - direction: "yes" is not unambiguously the good outcome; rephrase.
      - redundancy: it is a near-duplicate of another criterion, so one
        failure double-counts under weights; merge them.
      - vague: the wording is unfalsifiable; nobody could agree on yes/no.

      Criteria:
      ${rendered}

      Output a JSON array of {"issue", "criterion", "note"} objects, one
      per clear violation. "criterion" is the offending label verbatim.|]
  ]
  where
    schema   = schemaText lintCodec
    rendered = T.intercalate "\n" [ "- " <> l | l <- labels ]

-- | Lint criterion labels with one holistic judge call (redundancy is
-- cross-criterion, so the judge sees the whole set) plus one repair. An
-- empty list short-circuits to [] with no call.
lintLabels :: (LLM :> es) => [Text] -> Eff es [LintFinding]
lintLabels [] = pure []
lintLabels labels = do
  raw <- complete msgs
  case decodeLLM lintCodec raw of
    Right fs -> pure (map toFinding fs)
    Left e1  -> do
      let m = e1.message
      raw2 <- complete
        ( msgs
            ++ [ Message Assistant raw
               , Message User [text|
                   Your reply did not parse: ${m}.
                   Respond ONLY with valid JSON matching this schema:
                   ${schema}|]
               ]
        )
      case decodeLLM lintCodec raw2 of
        Right fs -> pure (map toFinding fs)
        Left e2  -> pure [LintUnavailable e2.message]
  where
    schema = schemaText lintCodec
    msgs   = lintPrompt labels
