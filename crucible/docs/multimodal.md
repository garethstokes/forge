---
title: Multimodal
nav_order: 11
---

# Multimodal inputs

A skill can take an image or a PDF as input and return typed output. This is
the document-extraction shape: a scan or a PDF in, a typed record out.

## The Media value

`Crucible.Media` carries an attachment as base64 bytes plus a media type:

```haskell
data Media = Media { mediaType :: Text, dataB64 :: Text, filename :: Maybe Text }

imageB64 :: Text -> Text -> Media   -- mediaType, base64 data
pdfB64   :: Text -> Media           -- base64 data; media type fixed to application/pdf
imageFile :: FilePath -> IO Media   -- reads + encodes, infers type from extension
pdfFile   :: FilePath -> IO Media
```

`Media` is a pure value: the same attachment serializes identically on both
providers and is fully reproducible. There is no remote-URL source; the bytes
travel with the request.

## Calling a multimodal skill

`callMedia` runs an ordinary `Skill i o` with attached media:

```haskell
callMedia :: (Chat :> es) => Skill i o -> i -> [Media] -> Eff es (Either DecodeError o)
```

It builds one user message (the media blocks, then a text block with the
output-schema contract and the instruction), sends it over the block-based
`Chat` path, and decodes the reply against the skill's output codec with the
same retry loop as `call`. Multimodal skills therefore carry `Chat :> es`
rather than `LLM :> es`: the richer input needs the richer effect.

For pure document extraction, the input type is often unused:

```haskell
data Invoice = Invoice { total :: Double, dueDate :: Text }
-- invoiceCodec :: JSONCodec Invoice  (see the codec guide)

extractInvoice :: Skill Text Invoice
extractInvoice = skill "extract-invoice" str invoiceCodec
  (const "Extract the invoice total and due date.")

run :: (Chat :> es) => Media -> Eff es (Either DecodeError Invoice)
run pdf = callMedia extractInvoice "" [pdf]
```

## Provider coverage

Images and PDF work on both providers. Anthropic uses image and document
content blocks; OpenAI uses an `image_url` data URI for images and a `file`
content part for PDF. The same `Media` value drives both; crucible encodes the
provider-specific shape.

## Cassettes

Chat cassettes record only the assistant's reply, not the request, so media
bytes are never written to a cassette. Replay is unaffected by attachment size.

## What is not covered

Media in `testSkill` cases and few-shot examples is text-only for now.
Remote-URL sources, audio and video, multimodal model outputs, and streaming
`callMedia` are out of scope for this release.
