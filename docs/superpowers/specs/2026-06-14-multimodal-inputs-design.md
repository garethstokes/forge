# Multimodal Inputs Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-pw2` (from the BAML review, item 5).
**Goal:** Let a typed `Skill` accept image and PDF inputs and return structured
typed output (the document-extraction use case), on both the Anthropic and
OpenAI providers.

**Scope:** new `src/Crucible/Media.hs`; new `src/Crucible/Skill/Multimodal.hs`;
`src/Crucible/Chat.hs` (two block constructors + `blockJson`);
`src/Crucible/LLM/OpenAI.hs` (parts-array user turns);
`src/Crucible/Skill.hs` (factor out an instruction-text helper);
`zinc.toml` (add `base64-bytestring`); `test/Spec.hs`; `app/Main.hs`;
`docs/multimodal.md` (new manual page).

## Motivation

`Crucible.LLM.Message` carries `Text` only, so skills cannot send an image or
a PDF. Both providers support image and document content blocks on the wire.
Wiring them up unlocks document-extraction skills (a PDF or scan in, a typed
record out), the category BAML demonstrates best. The work rides the existing
block-based `Chat` path rather than the text `complete` path: `Chat` is already
block-structured and already runs under the scripted, live-Anthropic,
live-OpenAI, and cassette interpreters, so the net-new surface is small.

## Decisions taken during design

- **Transport: extend the `Chat` block path.** Add image/document blocks to
  `Crucible.Chat.Block`; multimodal skills route through `converse`. The cost
  is that multimodal skills carry `Chat :> es` instead of `LLM :> es`, which is
  a clean capability story (richer input needs the richer effect). No change to
  the text `complete`/`LLM` path, so nothing breaks for manifest-evals.
- **Media is base64 inline.** A `Media` value carries the bytes as base64 plus
  a media type. It is a pure, serializable value, identical across providers
  and fully reproducible. IO file helpers read and encode. Remote URLs are a
  non-goal (they differ per provider and are not deterministic on replay).
- **Coverage: images and PDF on both providers.** Anthropic image and document
  (PDF) content blocks; OpenAI `image_url` (data URI) for images and the `file`
  content part (base64 `file_data` + `filename`) for PDF.
- **Skill API: a media channel at the call site.** `callMedia` takes the
  existing `Skill i o` plus an extra `[Media]` argument. Base64 media cannot
  pass through the input `JSONCodec i` text rendering, so it is a separate
  channel, not part of `i`. The skill's output codec, retry budget, and
  instruction assembly are reused unchanged.
- **Cassette: no media persisted.** Chat cassettes record only the response
  turn (`turnContentJson`), and replies never contain media, so request-side
  base64 is never written to a cassette. No bloat, no elision logic needed.

## Design

### `Crucible.Media` (new)

```haskell
data Media = Media
  { mediaType :: Text        -- "image/png", "image/jpeg", "application/pdf", ...
  , dataB64   :: Text        -- base64-encoded bytes
  , filename  :: Maybe Text  -- used by OpenAI's PDF file part; ignored elsewhere
  }
  deriving (Eq, Show)

-- Pure constructors.
imageB64 :: Text -> Text -> Media   -- ^ mediaType -> base64 data -> Media (filename = Nothing)
pdfB64   :: Text -> Media           -- ^ base64 data -> Media (mediaType "application/pdf", filename = Nothing)

-- IO helpers: read the file, base64-encode, infer mediaType from the extension.
imageFile :: FilePath -> IO Media   -- ^ .png/.jpg/.jpeg/.gif/.webp -> the matching image/* type
pdfFile   :: FilePath -> IO Media   -- ^ application/pdf; filename = Just (takeFileName path)
```

Extension-to-type inference for images: `.png` -> `image/png`,
`.jpg`/`.jpeg` -> `image/jpeg`, `.gif` -> `image/gif`, `.webp` -> `image/webp`.
An unknown image extension defaults to `application/octet-stream` (the provider
will reject it; the caller can use `imageB64` with an explicit type instead).
Base64 via `base64-bytestring` (`Data.ByteString.Base64.encode`), reading bytes
with `Data.ByteString.readFile`. `filename` for `imageFile` is `Nothing` (only
OpenAI's PDF part needs it); `pdfFile` sets `Just (takeFileName path)`.

This module is pure plus two IO helpers; it imports only `base64-bytestring`,
`bytestring`, `text`, and `filepath` (for `takeFileName`/`takeExtension`).

### `Crucible.Chat` (extended)

```haskell
data Block
  = TextBlock       Text
  | ToolUseBlock    ToolUse
  | ToolResultBlock ToolUseId Value
  | ImageBlock      Media           -- new
  | DocumentBlock   Media           -- new
  deriving (Eq, Show)
```

`Crucible.Chat` imports `Crucible.Media` (no cycle: `Media` imports nothing
from crucible). `blockJson` gains two cases, in crucible's canonical
(Anthropic) content shape, which also serves as the cassette format:

```json
{"type":"image","source":{"type":"base64","media_type":"<mediaType>","data":"<dataB64>"}}
{"type":"document","source":{"type":"base64","media_type":"<mediaType>","data":"<dataB64>"}}
```

`parseRBlock` / `parseTurn` (the response side) are untouched: model replies
never contain image or document blocks, so they fall through to the existing
`RSkip` default. `turnContentJson` is unchanged for the same reason.

### `Crucible.LLM.Anthropic` (no change beyond `blockJson`)

`chatMsgJson` already maps each block through `blockJson` into a content array,
so the two new block cases flow through with no edit to the request builder.

### `Crucible.LLM.OpenAI` (extended)

OpenAI's `chatMessagesJson` currently emits a user turn's `content` as a flat
string. When a user turn contains any `ImageBlock`/`DocumentBlock`, emit
`content` as a parts array instead; a text-only user turn keeps the flat-string
output (regression-safe). Part shapes:

```json
{"type":"text","text":"<text>"}
{"type":"image_url","image_url":{"url":"data:<mediaType>;base64,<dataB64>"}}
{"type":"file","file":{"filename":"<filename or document.pdf>","file_data":"data:<mediaType>;base64,<dataB64>"}}
```

Order: the text part (if any) first, then the media parts in list order. A
`DocumentBlock` with `filename = Nothing` defaults the part `filename` to
`"document.pdf"` (OpenAI requires a filename on the file part). Assistant turns
and tool-result turns are unchanged.

### `Crucible.Skill` (factor out a helper)

Extract the user-instruction text currently inlined in `prompt`'s `userMsg`
into an exported helper, reused by `prompt` and `callMedia`:

```haskell
-- | The user-facing instruction text for an input: preamble, task, the
-- <input> JSON block, constraints, and the trailing machine-only reminder.
-- Does not include the output-schema contract (the System message carries
-- that in 'prompt'; 'callMedia' folds it into its text block).
instructionText :: Skill i o -> i -> Text
```

`prompt`'s `userMsg` becomes `Message User (instructionText sk i')`. Behavior is
identical (pure refactor, covered by existing `prompt` tests).

### `Crucible.Skill.Multimodal` (new)

```haskell
callMedia :: (Chat :> es) => Skill i o -> i -> [Media] -> Eff es (Either DecodeError o)
```

Builds one user message via a pure, separately testable helper, whose blocks
are the media followed by a single text block:

```haskell
-- | The single user message callMedia sends: media blocks then the
-- instruction-and-schema text block. Pure, so the block order is unit-tested.
mediaMessage :: Skill i o -> i -> [Media] -> Chat.Message
mediaMessage sk i media =
  Message User (map mediaBlock media ++ [TextBlock fullText])
  where
    mediaBlock m | m.mediaType == "application/pdf" = DocumentBlock m
                 | otherwise                        = ImageBlock m
    fullText = schemaContract sk.output <> "\n\n" <> instructionText sk i
```

`callMedia` calls `converse [] [mediaMessage sk i media]`.

`schemaContract` is the same "Respond ONLY with JSON matching this schema: ..."
text `call` puts in its System message, folded into the text block because the
`Chat` path has no separate system slot (`anthropicRole`/`openaiRole` map
`System` to a user turn). It then runs `converse [] [msg]`, takes `turn.text`,
and decodes against `sk.output`. On a decode failure it mirrors `call`: append
`Message Assistant [TextBlock raw]` and a `Message User [TextBlock repair]`
(the parse error plus the restated schema), re-`converse`, bounded by
`sk.retries`; on exhaustion return `Left`.

`mediaBlock` routes by `mediaType` (PDF -> document, else image). A caller who
needs a non-PDF document type constructs the `Chat.Message` directly; `callMedia`
covers the image-and-PDF common case.

## Demo (`app/Main.hs`)

In the Anthropic-key-gated block: embed a small base64 image literal (for
example a tiny solid-color PNG), define a multimodal skill
`Skill () <SmallRecord>` whose task asks for a structured description, and call
`callMedia` through the live Anthropic `Chat` interpreter (`Anthropic.runChat`
or the existing chat runner used by the tool-agent demo). Print the decoded
result. Shows an image flowing into a typed skill output live. PDF is covered
by tests and the manual rather than a bulky base64 literal in `Main`.

## Manual (`docs/multimodal.md`, new page)

A new page (next `nav_order`, 11): the `Media` value and its constructors
(`imageB64`/`pdfB64`/`imageFile`/`pdfFile`), the image/document blocks, that
multimodal rides the `Chat` path (so a multimodal skill carries `Chat :> es`),
`callMedia` with a document-extraction example (`Skill () Invoice` + a PDF),
the provider coverage (images and PDF on both), the base64/determinism
rationale, and the cassette note (media is request-side, never recorded).
House style: no emdashes/endashes, no hype words, no manifest mentions.

## Testing (hermetic)

`Crucible.Media`:
- `imageB64`/`pdfB64` set the expected fields.
- `imageFile` on a temp `.png` infers `image/png` and round-trips the bytes
  (decode the `dataB64` back to the original bytes); `pdfFile` sets
  `application/pdf` and `filename = Just "<name>.pdf"`.

`Crucible.Chat.blockJson`:
- `ImageBlock` and `DocumentBlock` encode to the base64 `source` shapes above.

`Crucible.LLM.OpenAI.chatMessagesJson`:
- A user turn with text + an `ImageBlock` emits a parts array: a `text` part and
  an `image_url` part with a `data:<type>;base64,<data>` URL.
- A user turn with a `DocumentBlock` emits a `file` part with `filename` and
  `file_data`; a `DocumentBlock` whose `filename` is `Nothing` defaults to
  `document.pdf`.
- A text-only user turn still emits a flat-string `content` (regression).

`Crucible.Skill.Multimodal.callMedia` (under `runChatScripted`):
- A canned `Turn` with valid JSON decodes to the expected output.
- A canned bad-then-good `Turn` sequence recovers via the retry loop.
- An all-bad sequence past `retries` returns `Left`.
- `mediaMessage` (the pure helper) places the media blocks before the text
  block, routes a PDF `Media` to `DocumentBlock` and others to `ImageBlock`, and
  folds the schema contract into the text block.

`Crucible.Skill.instructionText`:
- Existing `prompt` tests continue to pass (the refactor is behavior-preserving);
  add one direct assertion that `instructionText` contains the task and the
  `<input>` JSON.

Live: the demo image extraction before merge (gated on the Anthropic key).

## Non-goals

- Media in `testSkill`/eval `Case`s and few-shot `examples` (both are text-only
  here; multimodal test cases and examples are a follow-on).
- Remote-URL media sources (base64 only, for determinism and replay fidelity).
- Audio, video, and other modalities.
- Multimodal assistant outputs (the model still replies text/JSON; crucible
  sends media, it does not receive it).
- Streaming `callMedia` (it is non-streaming; the existing stream path stays
  text/tool only).
- A non-PDF document MIME beyond what `mediaBlock` routes; the caller builds the
  `Chat.Message` directly for exotic types.
