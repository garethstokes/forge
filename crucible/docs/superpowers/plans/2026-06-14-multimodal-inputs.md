# Multimodal Inputs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a typed `Skill` accept image and PDF inputs and return structured typed output, on both the Anthropic and OpenAI providers.

**Architecture:** Media rides the existing block-based `Chat` path. A new pure `Crucible.Media` value carries base64 bytes; two new `Chat.Block` constructors carry it; each provider's request builder encodes them; a new `callMedia` in `Crucible.Skill.Multimodal` sends one media-bearing user message through `converse` and reuses the existing `Skill` output codec and retry loop. No change to the text `complete`/`LLM` path.

**Tech Stack:** GHC 9.12.2, effectful, aeson, autodocodec, base64-bytestring; zinc build (`nix develop . --command timeout -s KILL 300 zinc build|test`).

**Spec:** `docs/superpowers/specs/2026-06-14-multimodal-inputs-design.md`

## Conventions (every task)
- Build: `nix develop . --command timeout -s KILL 300 zinc build`. Test: `nix develop . --command timeout -s KILL 300 zinc test`. Judge success by exit status or the "test suite(s) passed" line, never a pipeline tail. Exit 137 = GHC iserv flake: retry once; a second 137 = BLOCKED. Ignore the "Git tree is dirty" warning.
- House style: DuplicateRecordFields + NoFieldSelectors + OverloadedRecordDot, prefix-free fields, `(.field)` access (add an inline type annotation if a getter section is ambiguous, and report it).
- Tests use the custom harness in `test/Harness.hs`: `check :: (Eq a, Show a) => String -> a -> a -> IO Bool`, called `check "label" expected actual`. Tests are entries in the list passed to `runChecks` at the end of `test/Spec.hs` (each entry is `check ...`, separated by commas). Do NOT use hspec.
- Commit trailer EXACTLY: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Commit at the end of each task; do not push.
- Modules are auto-discovered from `source-dirs`; new module files need no zinc.toml entry. Only the dependency list needs editing (Task 1).

## File Structure
- Create `src/Crucible/Media.hs` — the `Media` value, pure constructors, IO file helpers (Task 1).
- Modify `src/Crucible/Chat.hs` — `ImageBlock`/`DocumentBlock` constructors + `blockJson` cases (Task 2).
- Modify `src/Crucible/LLM/OpenAI.hs` — parts-array encoding for media-bearing user turns (Task 3).
- Modify `src/Crucible/Skill.hs` — extract and export `instructionText` (Task 4).
- Create `src/Crucible/Skill/Multimodal.hs` — `mediaMessage` + `callMedia` (Task 5).
- Modify `app/Main.hs` — live demo (Task 6).
- Create `docs/multimodal.md` — manual page (Task 7).
- Modify `zinc.toml` — add `base64-bytestring` and `filepath` (Task 1).
- Modify `test/Spec.hs` — tests for Tasks 1-5.

---

### Task 1: `Crucible.Media` value + dependencies

**Files:**
- Modify: `zinc.toml`
- Create: `src/Crucible/Media.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Add dependencies to `zinc.toml`**

In `[build.lib]` (line 15), add `"base64-bytestring"` and `"filepath"` to the `depends` list. In `[build.test.spec]` (line 25), add `"base64-bytestring"` to the `depends` list (the round-trip test decodes base64). Leave all other entries unchanged.

- [ ] **Step 2: Create `src/Crucible/Media.hs`**

```haskell
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
```

- [ ] **Step 3: Add failing tests to `test/Spec.hs`**

Add the import near the other crucible imports (around line 19-48):
```haskell
import Crucible.Media (Media (..), imageB64, pdfB64, imageFile, pdfFile)
import qualified Data.ByteString.Base64 as B64TEST
import qualified Data.ByteString as BSTEST
import qualified Data.Text.Encoding as TETEST
import System.IO (openTempFile, hClose)
```
(If `openTempFile`/`hClose` from `System.IO` and `System.Directory (removeFile)` are already imported for the existing memory-file tests, do not duplicate them; reuse the existing import.)

Add these entries to the `runChecks` list (at the end, before the closing `]`):
```haskell
  , check "Media.imageB64 sets fields, no filename"
      (Media "image/png" "QUJD" Nothing)
      (imageB64 "image/png" "QUJD")
  , check "Media.pdfB64 sets application/pdf, no filename"
      (Media "application/pdf" "JVBERg==" Nothing)
      (pdfB64 "JVBERg==")
```

For the IO file helpers, add an `IO Bool` entry that does the work inline (the list holds `IO Bool` values, so a `do` block is fine):
```haskell
  , do (p, h) <- openTempFile "/tmp" "crucible-media-test.png"
       BSTEST.hPut h (BSTEST.pack [1,2,3,4]) >> hClose h
       m <- imageFile p
       removeFile p
       let okType = m.mediaType == "image/png"
           okData = B64TEST.decode (TETEST.encodeUtf8 m.dataB64) == Right (BSTEST.pack [1,2,3,4])
           okName = m.filename == Nothing
       check "Media.imageFile infers png + round-trips bytes" True (okType && okData && okName)
  , do (p, h) <- openTempFile "/tmp" "crucible-media-test.pdf"
       BSTEST.hPut h (BSTEST.pack [37,80,68,70]) >> hClose h
       m <- pdfFile p
       removeFile p
       let okType = m.mediaType == "application/pdf"
           okName = maybe False (T.isSuffixOf ".pdf") m.filename
       check "Media.pdfFile sets pdf type + filename" True (okType && okName)
```
Note: `BSTEST.hPut` needs `Data.ByteString (hPut, pack)`; the qualified `BSTEST` import covers both. `removeFile` comes from `System.Directory` (reuse the existing import; add `import System.Directory (removeFile)` only if not present). `T.isSuffixOf` needs the existing `qualified Data.Text as T` import (already present in Spec.hs).

- [ ] **Step 4: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the four new Media checks pass; full suite green. If the build fails because `base64-bytestring` is not in the registry, report BLOCKED with the exact error. Retry once on exit 137.

- [ ] **Step 5: Commit**

```bash
git add zinc.toml src/Crucible/Media.hs test/Spec.hs
git commit -m "feat(media): Crucible.Media base64 value + file helpers"
```

---

### Task 2: `Chat.Block` image/document constructors + `blockJson`

**Files:**
- Modify: `src/Crucible/Chat.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Extend the `Block` type and import `Media`**

In `src/Crucible/Chat.hs`, add the import near the other crucible imports (around line 50):
```haskell
import Crucible.Media (Media (..))
```
Extend the `Block` data type (currently lines 63-68) to:
```haskell
-- | A content block within a conversation message.
data Block
  = TextBlock       Text
  | ToolUseBlock    ToolUse
  | ToolResultBlock ToolUseId Value   -- ^ a result (or error) for a prior tool_use
  | ImageBlock      Media             -- ^ an image attachment (request side only)
  | DocumentBlock   Media             -- ^ a PDF/document attachment (request side only)
  deriving (Eq, Show)
```
Add `Media (..)` to the module export list line `, Block (..)` is already exported via `Block (..)`; no export-list change is needed for the constructors, but add `Media` is NOT re-exported here (callers import it from `Crucible.Media`). Leave the export list otherwise unchanged.

- [ ] **Step 2: Extend `blockJson`**

Add two cases to `blockJson` (currently lines 145-158), after the `ToolResultBlock` case:
```haskell
blockJson (ImageBlock m) =
  A.object
    [ "type" .= A.String "image"
    , "source" .= A.object
        [ "type" .= A.String "base64"
        , "media_type" .= m.mediaType
        , "data" .= m.dataB64
        ]
    ]
blockJson (DocumentBlock m) =
  A.object
    [ "type" .= A.String "document"
    , "source" .= A.object
        [ "type" .= A.String "base64"
        , "media_type" .= m.mediaType
        , "data" .= m.dataB64
        ]
    ]
```
`parseRBlock` is unchanged: image/document never appear in responses and fall through to the `RSkip` default.

- [ ] **Step 3: Add failing tests to `test/Spec.hs`**

`blockJson` is exported from `Crucible.Chat` (and `Chat` is imported qualified as `Chat` and unqualified). Add to `runChecks`:
```haskell
  , check "blockJson: ImageBlock -> base64 image source"
      (C.encodeText C.anyValue (Chat.blockJson (Chat.ImageBlock (imageB64 "image/png" "QUJD"))))
      "{\"source\":{\"data\":\"QUJD\",\"media_type\":\"image/png\",\"type\":\"base64\"},\"type\":\"image\"}"
  , check "blockJson: DocumentBlock -> base64 document source"
      (C.encodeText C.anyValue (Chat.blockJson (Chat.DocumentBlock (pdfB64 "JVBERg=="))))
      "{\"source\":{\"data\":\"JVBERg==\",\"media_type\":\"application/pdf\",\"type\":\"base64\"},\"type\":\"document\"}"
```
Note: `C.encodeText C.anyValue` renders a `Value` to compact JSON; aeson sorts object keys alphabetically, so the expected strings above use alphabetical key order (`data`, `media_type`, `type` inside `source`; `source`, `type` outside). If the actual output differs, PIN THE ACTUAL OUTPUT in the expected string (run once, copy the exact bytes) and note it; do not weaken the assertion. `Chat.ImageBlock`/`Chat.DocumentBlock` are in scope via the qualified `Chat` import; `imageB64`/`pdfB64` from the Task 1 import.

- [ ] **Step 4: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: two new blockJson checks pass; full suite green. If the key ordering differs, pin the actual bytes (see note). Retry once on 137.

- [ ] **Step 5: Commit**

```bash
git add src/Crucible/Chat.hs test/Spec.hs
git commit -m "feat(chat): Image/Document blocks + blockJson base64 sources"
```

---

### Task 3: OpenAI parts-array for media-bearing user turns

**Files:**
- Modify: `src/Crucible/LLM/OpenAI.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Update the user-turn branch of `chatMessagesJson`**

In `src/Crucible/LLM/OpenAI.hs`, the second `chatMessagesJson` clause (lines 421-435) handles non-assistant turns: it emits `role: tool` messages for tool results and a flat-string `content` user message for text. Replace the text-emitting list comprehension so that, when the turn contains any `ImageBlock`/`DocumentBlock`, it emits a single user message whose `content` is a parts array; otherwise it keeps the existing flat-string behavior.

Replace the whole second clause with:
```haskell
chatMessagesJson (Chat.Message r blocks) =
  [ A.object
      [ "role" .= A.String "tool"
      , "tool_call_id" .= i
      , "content" .= resultText v
      ]
  | ToolResultBlock i v <- blocks
  ]
    ++ userMsgs
  where
    resultText (String s) = A.String s
    resultText other      = A.String (encodeText other)

    txt    = T.concat [s | TextBlock s <- blocks]
    images = [m | ImageBlock m <- blocks]
    docs   = [m | DocumentBlock m <- blocks]

    userMsgs
      | not (null images && null docs) =
          [ A.object ["role" .= openaiRole r, "content" .= A.Array (V.fromList parts)] ]
      | not (T.null txt) =
          [ A.object ["role" .= openaiRole r, "content" .= txt] ]
      | otherwise = []

    parts =
      [ A.object ["type" .= A.String "text", "text" .= txt] | not (T.null txt) ]
        ++ [ imagePart m | m <- images ]
        ++ [ docPart m   | m <- docs ]

    imagePart m =
      A.object
        [ "type" .= A.String "image_url"
        , "image_url" .= A.object ["url" .= dataUri m]
        ]
    docPart m =
      A.object
        [ "type" .= A.String "file"
        , "file" .= A.object
            [ "filename" .= maybe "document.pdf" Prelude.id m.filename
            , "file_data" .= dataUri m
            ]
        ]
    dataUri m = "data:" <> m.mediaType <> ";base64," <> m.dataB64
```
Add `ImageBlock`/`DocumentBlock` to the `Block (..)` import if it is selective (line 99 imports `Block (..)`, which already brings all constructors, so no change). `Media` fields `.mediaType`/`.dataB64`/`.filename` are reached through OverloadedRecordDot; if a getter section is ambiguous, annotate (`(m.filename :: Maybe Text)`) and report. `dataUri` returns `Text`.

- [ ] **Step 2: Add failing tests to `test/Spec.hs`**

`chatMessagesJson` is exported from `Crucible.LLM.OpenAI` (imported qualified as `OpenAI`). It returns `[Value]`. Test the user turn shape:
```haskell
  , check "OpenAI chatMessagesJson: text-only user stays a flat string"
      (C.encodeText (C.list' C.anyValue) (OpenAI.chatMessagesJson (Chat.Message User [Chat.TextBlock "hi"])))
      "[{\"content\":\"hi\",\"role\":\"user\"}]"
  , check "OpenAI chatMessagesJson: image user becomes a parts array"
      (C.encodeText (C.list' C.anyValue)
        (OpenAI.chatMessagesJson (Chat.Message User [Chat.TextBlock "look", Chat.ImageBlock (imageB64 "image/png" "QUJD")])))
      "[{\"content\":[{\"text\":\"look\",\"type\":\"text\"},{\"image_url\":{\"url\":\"data:image/png;base64,QUJD\"},\"type\":\"image_url\"}],\"role\":\"user\"}]"
  , check "OpenAI chatMessagesJson: pdf without filename defaults to document.pdf"
      (C.encodeText (C.list' C.anyValue)
        (OpenAI.chatMessagesJson (Chat.Message User [Chat.DocumentBlock (pdfB64 "JVBERg==")])))
      "[{\"content\":[{\"file\":{\"file_data\":\"data:application/pdf;base64,JVBERg==\",\"filename\":\"document.pdf\"},\"type\":\"file\"}],\"role\":\"user\"}]"
```
The expected strings assume aeson's alphabetical key ordering. RUN ONCE; if the actual bytes differ in key order, PIN THE ACTUAL OUTPUT (do not weaken to a substring check) and note the pin. `User` is in scope from the `Crucible.Chat` unqualified import (it re-exports `Role`'s constructors? check: `Crucible.LLM` exports `Role(..)`; `User` is imported in Spec.hs already via the LLM import; if not, qualify as needed).

- [ ] **Step 3: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: three new OpenAI checks pass; the existing OpenAI tool-agent / flat-text tests still pass (regression). Pin actual bytes if key order differs. Retry once on 137.

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/LLM/OpenAI.hs test/Spec.hs
git commit -m "feat(openai): parts-array content for media-bearing user turns"
```

---

### Task 4: Factor `instructionText` out of `Skill.prompt`

**Files:**
- Modify: `src/Crucible/Skill.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Add and export `instructionText`, refactor `prompt`**

In `src/Crucible/Skill.hs`, add `instructionText` to the export list (after `prompt`). Add the function (place it just above `prompt`, around line 153):
```haskell
-- | The user-facing instruction text for an input: preamble, task, the
-- @\<input\>@ JSON block, constraints, and the trailing machine-only reminder.
-- Does not include the output-schema contract (the System message carries that
-- in 'prompt'; 'Crucible.Skill.Multimodal.callMedia' folds it into its text
-- block). Exposed so both share one assembly.
instructionText :: Skill i o -> i -> Text
instructionText sk i' =
  T.concat
    [ block sk.instruction.preamble
    , (sk.instruction.task) i'
    , "\n\n<input>\n"
    , jsonText (toJSONVia sk.input i')
    , "\n</input>\n\n"
    , block sk.instruction.constraints
    , "Respond with JSON only; your reply is parsed by a machine."
    ]
  where
    block t = if T.null t then "" else t <> "\n\n"
```
Then change `prompt`'s `userMsg` (lines 166-176) to reuse it:
```haskell
    userMsg i' = Message User (instructionText sk i')
```
Delete the now-duplicated `block` local from `prompt`'s `where` if it is no longer referenced there (the `pair` helper at line 177 uses `userMsg`, not `block`, so removing `block` from `prompt`'s where-clause is safe; verify by compiling). Keep everything else in `prompt` identical.

- [ ] **Step 2: Add a failing test to `test/Spec.hs`**

`instructionText` is now exported from `Crucible.Skill`. Add to the existing Skill import on line 19 (append `, instructionText` inside the import list). Then:
```haskell
  , check "instructionText contains the task and the input JSON"
      True
      (let s = skill "t" C.str C.str (\x -> "Do the thing with " <> x)
           out = instructionText s "ABC"
       in T.isInfixOf "Do the thing with ABC" out && T.isInfixOf "<input>\n\"ABC\"" out)
```

- [ ] **Step 3: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the new check passes; ALL existing `prompt`/`call` tests still pass (the refactor is behavior-preserving). Retry once on 137.

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/Skill.hs test/Spec.hs
git commit -m "refactor(skill): extract instructionText helper from prompt"
```

---

### Task 5: `Crucible.Skill.Multimodal` (`mediaMessage` + `callMedia`)

**Files:**
- Create: `src/Crucible/Skill/Multimodal.hs`
- Test: `test/Spec.hs`

- [ ] **Step 1: Create `src/Crucible/Skill/Multimodal.hs`**

```haskell
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
import qualified Data.Text as T
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
      turn <- converse [] msgs
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
```
Notes: `converse :: (Chat :> es) => [(ToolName, Value)] -> [Message] -> Eff es Turn` (here `[]` tool specs). `Message`/`Block`/`Turn` come from `Crucible.Chat`. `Role` constructors `User`/`Assistant` come from `Crucible.LLM`. If `[text| |]` trailing newlines cause a test mismatch later, that only affects prompt wording, not decoding.

- [ ] **Step 2: Add failing tests to `test/Spec.hs`**

Add the import:
```haskell
import Crucible.Skill.Multimodal (mediaMessage, callMedia)
```
Define a tiny output type with a codec for the decode tests, OR reuse an existing small codec already in Spec.hs (search for an existing `data ... ` with a `JSONCodec`, e.g. a `Sentiment`/`Weather`/`Loc` used by other tests; if one exists with a known JSON shape, reuse it). If none is convenient, use a `Text`-output skill (`C.str`), where the reply JSON is a quoted string. Tests:

```haskell
  -- mediaMessage: media blocks precede the text block; PDF routes to DocumentBlock
  , check "mediaMessage: image then text, image routed to ImageBlock"
      True
      (case mediaMessage (skill "s" C.str C.str (const "extract")) () [imageB64 "image/png" "QUJD"] of
         Chat.Message User (Chat.ImageBlock m : Chat.TextBlock _ : []) -> m.mediaType == "image/png"
         _ -> False)
  , check "mediaMessage: pdf routed to DocumentBlock"
      True
      (case mediaMessage (skill "s" C.str C.str (const "extract")) () [pdfB64 "JVBERg=="] of
         Chat.Message User (Chat.DocumentBlock _ : Chat.TextBlock _ : []) -> True
         _ -> False)
  -- callMedia: valid reply decodes
  , check "callMedia: valid reply decodes to output"
      (Right ("hello" :: Text))
      (runPureEff (runChatScripted [Turn "\"hello\"" []]
        (callMedia (skill "s" C.str C.str (const "extract")) () [imageB64 "image/png" "QUJD"])))
  -- callMedia: bad-then-good recovers via retry
  , check "callMedia: bad reply then good reply recovers"
      (Right ("ok" :: Text))
      (runPureEff (runChatScripted [Turn "not json" [], Turn "\"ok\"" []]
        (callMedia (skill "s" C.str C.str (const "extract")) () [imageB64 "image/png" "QUJD"])))
  -- callMedia: exhausted retries returns Left
  , check "callMedia: all-bad past retries returns Left (isLeft)"
      True
      (either (const True) (const False)
        (runPureEff (runChatScripted [Turn "x" [], Turn "y" [], Turn "z" [], Turn "w" []]
          (callMedia (withRetries 1 (skill "s" C.str C.str (const "extract"))) () [imageB64 "image/png" "QUJD"]))))
```
Notes: `skill`, `withRetries` are already imported from `Crucible.Skill` in Spec.hs (verify; `withRetries` is exported there). `runPureEff` and `runChatScripted` and `Turn`/`Chat.Message`/`Chat.ImageBlock`/`Chat.DocumentBlock`/`Chat.TextBlock` are already in scope (Chat is imported). `User` from the LLM/Chat import. The `()` input uses the unit codec? NO: `skill "s" C.str C.str ...` has input codec `C.str`, so the input must be `Text`, not `()`. CHANGE the input value from `()` to a `Text` and the input codec stays `C.str`; e.g. `mediaMessage (skill ...) ("" :: Text) [...]`. Apply this to every `callMedia`/`mediaMessage` call above: pass `("" :: Text)` as the input, not `()`. (Alternatively define a unit codec, but using `C.str` with `""` is simpler.)

- [ ] **Step 3: Build and test**

Run: `nix develop . --command timeout -s KILL 300 zinc test`
Expected: the five new checks pass; full suite green. Retry once on 137.

- [ ] **Step 4: Commit**

```bash
git add src/Crucible/Skill/Multimodal.hs test/Spec.hs
git commit -m "feat(skill): Crucible.Skill.Multimodal callMedia + mediaMessage"
```

---

### Task 6: Live demo in `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add a multimodal demo to the Anthropic-key-gated block**

Read `app/Main.hs`. In the `Just key -> do` block (after an existing demo, e.g. after the memoryLift demo added earlier, near line 145), add a multimodal demo. Use a tiny valid base64 PNG (a 1x1 transparent pixel) so no asset file is needed:

```haskell
      -- Multimodal: send a tiny image to a typed skill via the Chat path.
      let onePxPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
          describeImage = skill "describe-image" str str
            (const "Describe this image in one short sentence.")
      mmRes <- runEff (Anthropic.runChat cfg
                 (callMedia describeImage ("" :: T.Text) [imageB64 "image/png" onePxPng]))
      case mmRes of
        Right d -> TIO.putStrLn ("multimodal: " <> d)
        Left e  -> TIO.putStrLn ("multimodal decode error: " <> e.message)
```
Add imports near the existing crucible imports: `import Crucible.Skill.Multimodal (callMedia)` and `import Crucible.Media (imageB64)`. `Anthropic.runChat`, `skill`, `str`, `runEff`, `TIO` are already imported (used by other demos). If `str` is not imported in Main, it is available from `Crucible.Codec` (other demos use it; reuse the existing import). The output codec is `str`, so the reply is a JSON string; the model is asked to describe, and `str` decodes a bare JSON string reply. If the model wraps the description in prose (not JSON), the demo prints the decode error, which is acceptable for a smoke demo; to make it robust, the skill instruction already says nothing about JSON, but `callMedia` folds in the schema contract, so the model will reply with a JSON string.

- [ ] **Step 2: Build**

Run: `nix develop . --command timeout -s KILL 300 zinc build`
Expected: clean compile. Retry once on 137. (Do not run the binary; it needs a key.)

- [ ] **Step 3: Commit**

```bash
git add app/Main.hs
git commit -m "demo(multimodal): live image-to-typed-skill via callMedia"
```

---

### Task 7: Manual page `docs/multimodal.md`

**Files:**
- Create: `docs/multimodal.md`

- [ ] **Step 1: Write the page**

Create `docs/multimodal.md` with front matter and content. Match the voice of `docs/memory.md` (matter-of-fact, short declarative sentences, no hype). Pick the next `nav_order` (memory.md is 10; use 11; if another page already uses 11, use the next free integer):

```markdown
---
title: Multimodal
nav_order: 11
---

# Multimodal inputs

A skill can take an image or a PDF as input and return typed output. This is
the document-extraction shape: a scan or a PDF in, a typed record out.

## The Media value

`Crucible.Media` carries an attachment as base64 bytes plus a media type:

\```haskell
data Media = Media { mediaType :: Text, dataB64 :: Text, filename :: Maybe Text }

imageB64 :: Text -> Text -> Media   -- mediaType, base64 data
pdfB64   :: Text -> Media           -- application/pdf
imageFile :: FilePath -> IO Media   -- reads + encodes, infers type from extension
pdfFile   :: FilePath -> IO Media
\```

`Media` is a pure value: the same attachment serializes identically on both
providers and is fully reproducible. There is no remote-URL source; the bytes
travel with the request.

## Calling a multimodal skill

`callMedia` runs an ordinary `Skill i o` with attached media:

\```haskell
callMedia :: (Chat :> es) => Skill i o -> i -> [Media] -> Eff es (Either DecodeError o)
\```

It builds one user message (the media blocks, then a text block with the
instruction and the output-schema contract), sends it over the block-based
`Chat` path, and decodes the reply against the skill's output codec with the
same retry loop as `call`. Multimodal skills therefore carry `Chat :> es`
rather than `LLM :> es`: the richer input needs the richer effect.

For pure document extraction, the input type is often unused:

\```haskell
data Invoice = Invoice { total :: Double, dueDate :: Text }
-- invoiceCodec :: JSONCodec Invoice  (see the codec guide)

extractInvoice :: Skill Text Invoice
extractInvoice = skill "extract-invoice" str invoiceCodec
  (const "Extract the invoice total and due date.")

run :: (Chat :> es) => Media -> Eff es (Either DecodeError Invoice)
run pdf = callMedia extractInvoice "" [pdf]
\```

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
```
(Replace the `\``` fences with real triple backticks when writing the file; they are escaped here only to nest inside this plan.)

- [ ] **Step 2: Verify house style**

Run: `grep -nP "—|–" docs/multimodal.md` (expected: no output).
Run: `grep -niE "powerful|seamless|robust|manifest|effortless" docs/multimodal.md` (expected: no output).
Confirm `nav_order` does not collide: `grep -rn "nav_order: 11" docs/` (if it collides, bump to the next free integer).

- [ ] **Step 3: Commit**

```bash
git add docs/multimodal.md
git commit -m "docs(multimodal): image/PDF skill inputs manual page"
```

---

## Self-Review

- **Spec coverage:** `Crucible.Media` + deps (T1); `Chat.Block` image/document + `blockJson` (T2); OpenAI parts-array (T3); `instructionText` factor (T4); `mediaMessage` + `callMedia` (T5); demo (T6); `docs/multimodal.md` (T7). Anthropic `chatMsgJson` needs no edit (it already routes through `blockJson`, noted in T2). All spec Design and Testing items map to a task. Non-goals are "do not build".
- **Type consistency:** `Media {mediaType, dataB64, filename}` is identical across T1/T2/T3/T5. `callMedia :: (Chat :> es) => Skill i o -> i -> [Media] -> Eff es (Either DecodeError o)` matches the spec. `mediaMessage :: Skill i o -> i -> [Media] -> Chat.Message`. `instructionText :: Skill i o -> i -> Text` used by T4 and T5. Block constructors `ImageBlock`/`DocumentBlock` consistent T2/T3/T5.
- **Placeholder scan:** the only deliberate "run once and pin" steps are the JSON-equality assertions in T2/T3, where aeson key ordering must be confirmed against actual bytes (the plan tells the engineer to pin the actual output, not weaken the test). T5 corrects the `()`-vs-`Text` input pitfall explicitly. No vague steps.
- **Known pitfall flagged:** input codec in the test skills is `C.str`, so inputs must be `Text` (`""`), not `()` (called out in T5 Step 2).
