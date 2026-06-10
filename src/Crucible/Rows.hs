{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | Streaming JSONL rows. A model asked for row-based data (one JSON object
-- per line) streams through 'Crucible.Emit.Emit' as raw text deltas; the
-- interpreters here re-assemble those deltas into lines and decode each
-- completed line through a codec, so the caller sees typed rows as they
-- arrive rather than one blob at the end.
--
-- Pairs with the streaming interpreters: run @Anthropic.stream@ (which emits
-- deltas) under 'runRowsWith' and hand each decoded row to a sink the moment
-- its closing newline lands.
--
-- Prompt contract: ask the model for raw JSONL (one object per line, no
-- markdown fences). A fence or prose line does not parse as JSON and surfaces
-- as a 'Left' row; blank lines are skipped.
module Crucible.Rows
  ( splitRows
  , runRowsWith
  , runRows
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.State.Static.Local (get, modify, put, runState)

import Crucible.Codec (JSONCodec)
import Crucible.Decode (DecodeError, decodeLLM)
import Crucible.Emit (Emit (..))

-- | Split buffered text into completed lines and the trailing remainder
-- (text after the last newline, still accumulating). The kernel of the
-- rowwise interpreters; pure and total.
splitRows :: Text -> ([Text], Text)
splitRows t = case T.split (== '\n') t of
  []  -> ([], "")
  xs  -> (init xs, last xs)

-- | Decode a completed line as a row, skipping blanks. 'decodeLLM' is
-- tolerant per line, so a row wrapped in stray prose still extracts its
-- first balanced JSON value.
rowOf :: JSONCodec a -> Text -> Maybe (Either DecodeError a)
rowOf c ln
  | T.null (T.strip ln) = Nothing
  | otherwise           = Just (decodeLLM c (T.strip ln))

-- | Interpret 'Emit' rowwise: buffer deltas, and each time a newline
-- completes a line, decode it through the codec and pass the row to the
-- sink immediately. A non-blank trailing line (no final newline) is flushed
-- as a last row when the action finishes.
runRowsWith
  :: JSONCodec a
  -> (Either DecodeError a -> Eff es ())
  -> Eff (Emit : es) r
  -> Eff es r
runRowsWith c sink action = do
  (r, leftover) <-
    reinterpret (runState T.empty)
      (\_ -> \case
        Emit t -> do
          buf <- get
          let (lns, rest) = splitRows (buf <> t)
          put rest
          mapM_ (raise . sink) [row | ln <- lns, Just row <- [rowOf c ln]])
      action
  case rowOf c leftover of
    Just row -> sink row
    Nothing  -> pure ()
  pure r

-- | Like 'runRowsWith', but collect the rows and return them alongside the
-- result (for tests and batch use).
runRows :: JSONCodec a -> Eff (Emit : es) r -> Eff es (r, [Either DecodeError a])
runRows c action = do
  (r, rows) <- runState [] (runRowsWith c (\row -> modify (row :)) (inject action))
  pure (r, reverse rows)
