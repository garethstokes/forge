{-# LANGUAGE OverloadedStrings #-}

-- | SSE streaming for the live Anthropic path: a pure event core
-- ('splitFrames' / 'parseEvent' / 'stepAcc') plus thin streaming interpreters.
module Crucible.LLM.Anthropic.Stream
  ( splitFrames
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS

-- | Split complete SSE frames (blank-line @\\n\\n@-delimited) off the buffer,
-- returning the frames and the unconsumed remainder. With no blank line yet the
-- whole buffer is the remainder. Empty frames (e.g. from a trailing @\\n\\n@,
-- which every well-formed SSE body has) are omitted, so returned frames are
-- always non-empty. (Anthropic SSE uses bare LF; CRLF is not normalised.)
splitFrames :: ByteString -> ([ByteString], ByteString)
splitFrames = go []
  where
    go acc buf =
      let (before, rest) = BS.breakSubstring "\n\n" buf
      in if BS.null rest
           then (reverse acc, buf)
           else if BS.null before
                  then go acc (BS.drop 2 rest)
                  else go (before : acc) (BS.drop 2 rest)
