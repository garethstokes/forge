{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A media attachment for multimodal skills: bytes carried as base64 plus a
-- media type, a pure serializable value identical across providers. Construct
-- from an explicit base64 string ('imageB64', 'pdfB64') or read from a file
-- ('imageFile', 'pdfFile', which infer the media type from the extension).
-- Carried in a conversation by 'Crucible.Chat.ImageBlock' / 'DocumentBlock'
-- and sent by 'Crucible.Skill.Multimodal.callMedia'.
module Crucible.Media
  ( Media (..)
  , imageB64
  , pdfB64
  , imageFile
  , pdfFile
  ) where

import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import System.FilePath (takeExtension, takeFileName)

-- | A media attachment. @filename@ is only used by OpenAI's PDF file part.
data Media = Media
  { mediaType :: Text        -- ^ "image/png", "image/jpeg", "application/pdf", ...
  , dataB64   :: Text        -- ^ base64-encoded bytes
  , filename  :: Maybe Text  -- ^ used by OpenAI's PDF file part; ignored elsewhere
  }
  deriving (Eq, Show)

-- | An image from an explicit media type and base64 data.
imageB64 :: Text -> Text -> Media
imageB64 mt b64 = Media mt b64 Nothing

-- | A PDF from base64 data (media type "application/pdf").
pdfB64 :: Text -> Media
pdfB64 b64 = Media "application/pdf" b64 Nothing

-- | Read an image file, base64-encode it, and infer its media type from the
-- extension (.png/.jpg/.jpeg/.gif/.webp; anything else is
-- application/octet-stream, which the provider will reject, so pass an explicit
-- type via 'imageB64' for unusual formats).
imageFile :: FilePath -> IO Media
imageFile path = do
  bytes <- BS.readFile path
  pure (Media (imageMimeFor path) (TE.decodeUtf8 (B64.encode bytes)) Nothing)

-- | Read a PDF file, base64-encode it, and set filename to the base name.
pdfFile :: FilePath -> IO Media
pdfFile path = do
  bytes <- BS.readFile path
  pure (Media "application/pdf" (TE.decodeUtf8 (B64.encode bytes)) (Just (T.pack (takeFileName path))))

imageMimeFor :: FilePath -> Text
imageMimeFor path = case map toLower (takeExtension path) of
  ".png"  -> "image/png"
  ".jpg"  -> "image/jpeg"
  ".jpeg" -> "image/jpeg"
  ".gif"  -> "image/gif"
  ".webp" -> "image/webp"
  _       -> "application/octet-stream"
