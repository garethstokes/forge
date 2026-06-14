{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeOperators #-}

-- | Multimodal skills: run a typed 'Skill' with image/PDF inputs. 'callMedia'
-- sends the skill's instruction plus the attached 'Media' as one user message
-- over the block-based 'Chat' path, then decodes the reply against the skill's
-- output codec with the same retry loop as 'Crucible.Skill.call'. Multimodal
-- skills therefore carry @Chat :> es@ (not @LLM :> es@): richer input needs the
-- richer effect.
module Crucible.Skill.Multimodal
  ( mediaMessage
  , callMedia
  ) where

import Data.Text (Text)
import Data.Aeson (Value)
import NeatInterpolation (text)

import Effectful

import Crucible.Chat (Chat, Message (..), Block (..), Turn (..), converse)
import Crucible.LLM (Role (Assistant, User))
import Crucible.Media (Media (..))
import Crucible.Skill (Skill (..), instructionText)
import Crucible.Codec (schemaText)
import Crucible.Decode (decodeLLM, DecodeError (..))

-- | The single user message 'callMedia' sends: the media blocks (a PDF routes
-- to 'DocumentBlock', anything else to 'ImageBlock') followed by one text block
-- carrying the output-schema contract and the skill's instruction. Pure, so the
-- block order is unit-tested.
mediaMessage :: Skill i o -> i -> [Media] -> Message
mediaMessage sk i media =
  Message User (map mediaBlock media ++ [TextBlock fullText])
  where
    mediaBlock m
      | m.mediaType == "application/pdf" = DocumentBlock m
      | otherwise                        = ImageBlock m
    schema = schemaText sk.output
    contract = [text|
      Respond ONLY with JSON matching this schema:
      ${schema}
      Your reply is parsed by a machine; any text outside the JSON is an error.|]
    fullText = contract <> "\n\n" <> instructionText sk i

-- | Run a typed skill with attached media. Builds 'mediaMessage', sends it via
-- 'converse' (no tools), and decodes the reply against the output codec. On a
-- decode failure, re-asks with the parse error and the schema restated, up to
-- the skill's 'retries'; on exhaustion returns 'Left'.
callMedia :: (Chat :> es) => Skill i o -> i -> [Media] -> Eff es (Either DecodeError o)
callMedia sk i media = loop sk.retries [mediaMessage sk i media]
  where
    schema = schemaText sk.output
    loop n msgs = do
      turn <- converse ([] :: [(Text, Value)]) msgs
      let raw = turn.text
      case decodeLLM sk.output raw of
        Right o -> pure (Right o)
        Left err
          | n <= 0    -> pure (Left err)
          | otherwise ->
              let e = err.message
              in loop (n - 1)
                ( msgs
                    ++ [ Message Assistant [TextBlock raw]
                       , Message User [TextBlock [text|
                           Your reply did not parse: ${e}.
                           Respond ONLY with valid JSON matching this schema:
                           ${schema}|]]
                       ]
                )
