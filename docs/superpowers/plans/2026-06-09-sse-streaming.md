# SSE Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream Anthropic responses token-by-token (SSE) for both the text (`LLM`) and chat (`Chat`) paths via a new `Emit` delta effect, returning the fully-assembled result plus `Usage`.

**Architecture:** A new provider-agnostic `Crucible.Emit` effect carries text deltas; the caller picks an interpreter (print/collect/ignore). A new `Crucible.LLM.Anthropic.Stream` module holds a pure, fully-tested SSE core (`splitFrames` → `parseEvent` → `stepAcc`) and a thin `Eff` byte-reading loop that `emit`s deltas live while folding the stream into a `StreamAcc`. Two streaming interpreters (`runLLMAnthropicStream`/`runChatAnthropicStream`) discharge the unchanged `LLM`/`Chat` effects and return `(a, Usage)`.

**Tech Stack:** Haskell GHC 9.6.5, `effectful` (`reinterpret`, `Effectful.State.Static.Local` `runState`/`modify`, `Effectful.Exception` `bracket`), `http-client` streaming (`responseOpen`/`responseClose`/`brRead`), in-repo `Crucible.Json`. Build/test via `nix develop . --command zinc {build,test}`.

---

## Background for the implementer

- **Spec:** `docs/superpowers/specs/2026-06-09-sse-streaming-design.md`.
- **Test harness:** `test/Harness.hs` — `check :: (Eq a, Show a) => String -> a -> a -> IO Bool`, `runChecks :: [IO Bool] -> IO ()`. `test/Spec.hs` builds one big `runChecks [ ... ]` list in `main`. Add a test = add a `, check "name" expected actual` element. There is NO per-test runner: run the WHOLE suite with `nix develop . --command zinc test`; pass prints `ALL PASS` and `1 test suite(s) passed`. "Verify it fails" = add the test/import, run `zinc test`, observe a build error (undefined name) or a `FAIL <name>` line.
- **Library modules under `src/` are auto-discovered** — creating `src/Crucible/Emit.hs` or `src/Crucible/LLM/Anthropic/Stream.hs` needs no manifest entry.
- **`test/Spec.hs` already imports:** `Crucible.Json.Value (Value(..))`, `Crucible.Json.Encode (encode)`, `Crucible.Chat (... ToolUse(..) ...)`, `Effectful (Eff, runPureEff)`, `Data.Text as T`. Reuse these.
- **In-repo JSON:** `Value = JNull | JBool Bool | JNumber Double | JString Text | JArray [Value] | JObject [(Text,Value)]`. `Crucible.Json.Encode.encode :: Value -> Text` (renders whole numbers as integers). `Crucible.Json.Parse.parse :: Text -> Either String Value`. `Crucible.Json.Decode` exports `Decoder`, `Error`, `decodeValue :: Decoder a -> Value -> Either Error a`, `field`, `at :: [Text] -> Decoder a -> Decoder a`, `int`, `string`, `value`.
- **Effectful idiom** (see `src/Crucible/LLM.hs`, `src/Crucible/Chat.hs`): declare `data E :: Effect where ...`; `type instance DispatchOf E = Dynamic`; smart ctor via `send`; interpret with `interpret`/`reinterpret`. `reinterpret (runState s0) handler :: Eff (E:es) a -> Eff es (a, s)`.
- **Anthropic module** (`src/Crucible/LLM/Anthropic.hs`) already exports `AnthropicConfig(..)`, `AnthropicError(..)` (ctors `AnthropicHttpError`/`AnthropicStatusError`/`AnthropicNoContent`), `isRetryable`, `chatRequestJson`, `parseUsage`. It does NOT yet export `newAnthropicManager` or `requestJson` (Task 6 adds those).
- **Commit footer:** end every commit body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File structure

- **Create `src/Crucible/Emit.hs`** — `Emit` effect + `emit` + `runEmitIO`/`ignoreEmit`/`runEmitList`. (Task 1)
- **Create `src/Crucible/LLM/Anthropic/Stream.hs`** — `splitFrames` (Task 2), `StreamEvent`/`parseEvent` (Task 3), `PartialTool`/`StreamAcc`/`emptyAcc`/`stepAcc` (Task 4), `openStream`/`streamLoop`/`addStream`/`runLLMAnthropicStream` (Task 6), `runChatAnthropicStream` (Task 7).
- **Modify `src/Crucible/LLM/Anthropic.hs`** — export `newAnthropicManager`, `requestJson`. (Task 6)
- **Modify `zinc.toml`** — add `bytestring` to the `[build.test.spec]` depends (Task 2).
- **Modify `test/Spec.hs`** — checks for each pure unit (Tasks 1–5).
- **Modify `app/Main.hs`** — live streaming demo (Task 8).

---

### Task 1: `Crucible.Emit` — the delta effect

**Files:** Create `src/Crucible/Emit.hs`; Test `test/Spec.hs`.

- [ ] **Step 1: Write failing tests.** In `test/Spec.hs` add import (near the other `Crucible.*` imports):

```haskell
import Crucible.Emit (emit, runEmitList, ignoreEmit)
```

Add to the `runChecks [ ... ]` list (each element starts with a leading `,`):

```haskell
  -- A#3: Emit effect
  , check "emit: runEmitList collects in order"
      (((), ["a", "b"]) :: ((), [T.Text]))
      (runPureEff (runEmitList (emit "a" >> emit "b")))
  , check "emit: ignoreEmit discards, preserves result"
      (42 :: Int)
      (runPureEff (ignoreEmit (emit "x" >> emit "y" >> pure (42 :: Int))))
```

- [ ] **Step 2: Run suite to verify it fails.** `nix develop . --command zinc test` → build failure `Could not find module 'Crucible.Emit'`.

- [ ] **Step 3: Create the module.** Create `src/Crucible/Emit.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | A first-class effect for streaming text deltas. Streaming interpreters
-- 'emit' each delta as it arrives; the caller chooses how to consume them by
-- picking an interpreter (print live, collect, or discard) without the streamer
-- knowing. Parallel to 'Crucible.LLM.LLM' / 'Crucible.Chat.Chat'.
module Crucible.Emit
  ( Emit (..)
  , emit
  , runEmitIO
  , ignoreEmit
  , runEmitList
  ) where

import Data.Text (Text)

import Effectful
import Effectful.Dispatch.Dynamic (interpret, reinterpret, send)
import Effectful.State.Static.Local (modify, runState)

data Emit :: Effect where
  Emit :: Text -> Emit m ()
type instance DispatchOf Emit = Dynamic

emit :: (Emit :> es) => Text -> Eff es ()
emit = send . Emit

-- | Run each delta through an IO sink (e.g. @putStr . T.unpack@).
runEmitIO :: (IOE :> es) => (Text -> IO ()) -> Eff (Emit : es) a -> Eff es a
runEmitIO sink = interpret $ \_ -> \case
  Emit t -> liftIO (sink t)

-- | Discard all deltas (the result is still fully assembled by the streamer).
ignoreEmit :: Eff (Emit : es) a -> Eff es a
ignoreEmit = interpret $ \_ -> \case
  Emit _ -> pure ()

-- | Collect deltas in arrival order alongside the result (for tests).
runEmitList :: Eff (Emit : es) a -> Eff es (a, [Text])
runEmitList = reinterpret (runState []) $ \_ -> \case
  Emit t -> modify (++ [t])
```

- [ ] **Step 4: Run suite to verify it passes.** `nix develop . --command zinc test` → both new checks `ok`, `ALL PASS`.

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/Emit.hs test/Spec.hs
git commit -m "$(printf 'feat(stream): Emit effect for streaming text deltas\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: `splitFrames` — SSE frame splitter

**Files:** Create `src/Crucible/LLM/Anthropic/Stream.hs`; Modify `zinc.toml`; Test `test/Spec.hs`.

- [ ] **Step 1: Add `bytestring` to the test target.** In `zinc.toml`, the test depends line is:

```toml
depends = ["base", "text", "mtl", "crucible", "effectful", "effectful-core"]
```

Change it to add `bytestring` (needed for `Data.ByteString.Char8` in the SSE tests):

```toml
depends = ["base", "text", "bytestring", "mtl", "crucible", "effectful", "effectful-core"]
```

- [ ] **Step 2: Write failing tests.** In `test/Spec.hs` add imports:

```haskell
import qualified Data.ByteString.Char8 as BC
import Crucible.LLM.Anthropic.Stream (splitFrames)
```

Add checks:

```haskell
  -- A#3: splitFrames
  , check "splitFrames: splits complete frames, keeps remainder"
      ([BC.pack "A", BC.pack "B"], BC.pack "part")
      (splitFrames (BC.pack "A\n\nB\n\npart"))
  , check "splitFrames: no blank line -> all remainder"
      ([], BC.pack "noblank")
      (splitFrames (BC.pack "noblank"))
```

- [ ] **Step 3: Run suite to verify it fails.** `nix develop . --command zinc test` → build failure `Could not find module 'Crucible.LLM.Anthropic.Stream'`.

- [ ] **Step 4: Create the module with `splitFrames`.** Create `src/Crucible/LLM/Anthropic/Stream.hs`:

```haskell
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
-- whole buffer is the remainder.
splitFrames :: ByteString -> ([ByteString], ByteString)
splitFrames = go []
  where
    go acc buf =
      let (before, rest) = BS.breakSubstring "\n\n" buf
      in if BS.null rest
           then (reverse acc, buf)
           else go (before : acc) (BS.drop 2 rest)
```

- [ ] **Step 5: Run suite to verify it passes.** `nix develop . --command zinc test` → both `splitFrames` checks `ok`, `ALL PASS`.

- [ ] **Step 6: Commit.**

```bash
git add src/Crucible/LLM/Anthropic/Stream.hs zinc.toml test/Spec.hs
git commit -m "$(printf 'feat(stream): splitFrames SSE frame splitter\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: `StreamEvent` + `parseEvent`

**Files:** Modify `src/Crucible/LLM/Anthropic/Stream.hs`; Test `test/Spec.hs`.

- [ ] **Step 1: Write failing tests.** In `test/Spec.hs` add imports:

```haskell
import qualified Data.Text.Encoding as TE
import Crucible.LLM.Anthropic.Stream (StreamEvent(..), parseEvent)
```

Add a helper near the top-level helpers in `test/Spec.hs` (after the imports, before `main`):

```haskell
-- Build an SSE frame ("data: <json>") as a ByteString from a Value.
sseFrame :: Value -> BC.ByteString
sseFrame v = TE.encodeUtf8 ("data: " <> encode v)
```

Add checks:

```haskell
  -- A#3: parseEvent
  , check "parseEvent: text_delta -> EvText"
      (EvText "Hello")
      (parseEvent (sseFrame (JObject
        [ ("type", JString "content_block_delta"), ("index", JNumber 0)
        , ("delta", JObject [("type", JString "text_delta"), ("text", JString "Hello")]) ])))
  , check "parseEvent: message_start -> EvUsageIn"
      (EvUsageIn 25)
      (parseEvent (sseFrame (JObject
        [ ("type", JString "message_start")
        , ("message", JObject [("usage", JObject [("input_tokens", JNumber 25), ("output_tokens", JNumber 1)])]) ])))
  , check "parseEvent: message_delta -> EvUsageOut"
      (EvUsageOut 7)
      (parseEvent (sseFrame (JObject
        [ ("type", JString "message_delta"), ("delta", JObject [])
        , ("usage", JObject [("output_tokens", JNumber 7)]) ])))
  , check "parseEvent: tool_use start -> EvToolStart"
      (EvToolStart 0 "tu_1" "get_weather")
      (parseEvent (sseFrame (JObject
        [ ("type", JString "content_block_start"), ("index", JNumber 0)
        , ("content_block", JObject [("type", JString "tool_use"), ("id", JString "tu_1"), ("name", JString "get_weather"), ("input", JObject [])]) ])))
  , check "parseEvent: input_json_delta -> EvToolJson"
      (EvToolJson 0 "{\"city\":")
      (parseEvent (sseFrame (JObject
        [ ("type", JString "content_block_delta"), ("index", JNumber 0)
        , ("delta", JObject [("type", JString "input_json_delta"), ("partial_json", JString "{\"city\":")]) ])))
  , check "parseEvent: unknown -> EvOther"
      EvOther
      (parseEvent (sseFrame (JObject [("type", JString "ping")])))
```

- [ ] **Step 2: Run suite to verify it fails.** `nix develop . --command zinc test` → build failure (`StreamEvent`/`parseEvent` not exported).

- [ ] **Step 3: Implement.** In `src/Crucible/LLM/Anthropic/Stream.hs`, extend the export list and imports, and add the code.

Change the export list to:

```haskell
module Crucible.LLM.Anthropic.Stream
  ( splitFrames
  , StreamEvent (..)
  , parseEvent
  ) where
```

Add imports (below the existing `Data.ByteString` imports):

```haskell
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Crucible.Json.Decode (Decoder, at, decodeValue, field, int, string)
import Crucible.Json.Parse (parse)
import Crucible.Json.Value (Value)
import Crucible.Tool (ToolName)
import Crucible.Chat (ToolUse)   -- ToolUseId is Text; kept explicit below
```

(Note: `ToolUse` import is unused until Task 4; if GHC warns, it is harmless — Task 4 uses it. To avoid a warning now, omit the `Crucible.Chat` import line until Task 4. Prefer omitting it now.)

Add the types and functions:

```haskell
-- Anthropic's tool_use id is a JSON string.
type ToolUseId = Text

-- | A single parsed SSE event, reduced to what the accumulator needs.
data StreamEvent
  = EvText      Text                    -- text_delta
  | EvToolStart Int ToolUseId ToolName  -- tool_use block opened at index
  | EvToolJson  Int Text                -- input_json_delta fragment for index
  | EvBlockStop Int
  | EvUsageIn   Int
  | EvUsageOut  Int
  | EvOther
  deriving (Eq, Show)

-- | Parse one frame's @data:@ payload into a 'StreamEvent'. A frame with no
-- usable @data:@ JSON, or an unrecognised shape, is 'EvOther'.
parseEvent :: ByteString -> StreamEvent
parseEvent frame = case dataPayload frame of
  Nothing  -> EvOther
  Just txt -> case parse txt of
    Left _  -> EvOther
    Right v -> classify v

-- | Extract the (stripped, UTF-8-decoded) text after the first @data:@ line.
dataPayload :: ByteString -> Maybe Text
dataPayload frame = case filter ("data:" `BS.isPrefixOf`) (BC.lines frame) of
  (ln : _) -> Just (T.strip (TE.decodeUtf8Lenient (BS.drop 5 ln)))
  []       -> Nothing

classify :: Value -> StreamEvent
classify v = case dv (field "type" string) of
  Just "content_block_delta" -> case dv (at ["delta", "type"] string) of
    Just "text_delta"       -> maybe EvOther EvText            (dv (at ["delta", "text"] string))
    Just "input_json_delta" -> maybe EvOther (EvToolJson idx)  (dv (at ["delta", "partial_json"] string))
    _                       -> EvOther
  Just "content_block_start" -> case dv (at ["content_block", "type"] string) of
    Just "tool_use" -> case ( dv (at ["content_block", "id"] string)
                            , dv (at ["content_block", "name"] string) ) of
      (Just i, Just n) -> EvToolStart idx i n
      _                -> EvOther
    _ -> EvOther
  Just "content_block_stop" -> maybe EvOther EvBlockStop (dv (field "index" int))
  Just "message_start"      -> maybe EvOther EvUsageIn   (dv (at ["message", "usage", "input_tokens"] int))
  Just "message_delta"      -> maybe EvOther EvUsageOut  (dv (at ["usage", "output_tokens"] int))
  _                         -> EvOther
  where
    idx = maybe 0 id (dv (field "index" int))
    dv :: Decoder a -> Maybe a
    dv d = either (const Nothing) Just (decodeValue d v)
```

- [ ] **Step 4: Run suite to verify it passes.** `nix develop . --command zinc test` → all six `parseEvent` checks `ok`, `ALL PASS`.

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/LLM/Anthropic/Stream.hs test/Spec.hs
git commit -m "$(printf 'feat(stream): StreamEvent + parseEvent (SSE event classification)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 4: `StreamAcc` + `stepAcc` (the fold)

**Files:** Modify `src/Crucible/LLM/Anthropic/Stream.hs`; Test `test/Spec.hs`.

- [ ] **Step 1: Write failing tests.** In `test/Spec.hs` extend the Stream import to add the accumulator names:

```haskell
import Crucible.LLM.Anthropic.Stream
  (StreamEvent(..), parseEvent, splitFrames, StreamAcc(..), emptyAcc, stepAcc)
```

(`Usage(..)` and `ToolUse(..)` are already imported — `Usage` from Task A#4's import line, `ToolUse` from the existing `Crucible.Chat` import.)

Add checks (uses `Data.List.foldl'` — add `import Data.List (foldl')` to `test/Spec.hs` if not present):

```haskell
  -- A#3: stepAcc fold
  , check "stepAcc: text stream assembles text + usage"
      ("Hello", Usage 25 2)
      (let a = foldl' stepAcc emptyAcc [EvUsageIn 25, EvText "Hel", EvText "lo", EvUsageOut 2]
       in (saText a, saUsage a))
  , check "stepAcc: tool stream reassembles tool_use args"
      ([ToolUse "tu_1" "get_weather" (JObject [("city", JString "Brisbane")])], Usage 40 12)
      (let a = foldl' stepAcc emptyAcc
                 [ EvUsageIn 40
                 , EvToolStart 0 "tu_1" "get_weather"
                 , EvToolJson 0 "{\"city\":", EvToolJson 0 "\"Brisbane\"}"
                 , EvBlockStop 0, EvUsageOut 12 ]
       in (saTools a, saUsage a))
```

- [ ] **Step 2: Run suite to verify it fails.** `nix develop . --command zinc test` → build failure (`StreamAcc`/`emptyAcc`/`stepAcc` not exported).

- [ ] **Step 3: Implement.** In `src/Crucible/LLM/Anthropic/Stream.hs`:

Extend the export list:

```haskell
module Crucible.LLM.Anthropic.Stream
  ( splitFrames
  , StreamEvent (..)
  , parseEvent
  , StreamAcc (..)
  , PartialTool (..)
  , emptyAcc
  , stepAcc
  ) where
```

Add imports (the `Crucible.Chat` and `Crucible.Usage`/`Value` constructors are now used):

```haskell
import Crucible.Chat (ToolUse (..))
import Crucible.Json.Value (Value (JObject))
import Crucible.Usage (Usage (..))
```

(If `Crucible.Json.Value (Value)` is already imported from Task 3, change that line to `import Crucible.Json.Value (Value (JObject))` so both the type and the `JObject` constructor are in scope.)

Add the types and fold:

```haskell
-- | An in-progress tool_use block: id, name, and accumulated argument JSON.
data PartialTool = PartialTool ToolUseId ToolName Text
  deriving (Eq, Show)

-- | Running accumulation across one streamed response.
data StreamAcc = StreamAcc
  { saText    :: Text                 -- concatenated text deltas
  , saPartial :: [(Int, PartialTool)] -- in-progress tool_use blocks, by index
  , saTools   :: [ToolUse]            -- completed tool_uses, in completion order
  , saUsage   :: Usage
  }
  deriving (Eq, Show)

emptyAcc :: StreamAcc
emptyAcc = StreamAcc "" [] [] mempty

-- | Fold one event into the accumulator (and the IO loop 'emit's text deltas).
stepAcc :: StreamAcc -> StreamEvent -> StreamAcc
stepAcc acc = \case
  EvText t            -> acc { saText = saText acc <> t }
  EvToolStart i tid n -> acc { saPartial = (i, PartialTool tid n "") : saPartial acc }
  EvToolJson i frag   -> acc { saPartial = map (bump i frag) (saPartial acc) }
  EvBlockStop i       -> case lookup i (saPartial acc) of
    Nothing                       -> acc
    Just (PartialTool tid n js) -> acc
      { saPartial = filter ((/= i) . fst) (saPartial acc)
      , saTools   = saTools acc ++ [ToolUse tid n (parseArgs js)]
      }
  EvUsageIn n  -> acc { saUsage = (saUsage acc) { usInputTokens  = n } }
  EvUsageOut n -> acc { saUsage = (saUsage acc) { usOutputTokens = n } }
  EvOther      -> acc
  where
    bump i frag (j, pt@(PartialTool tid n js))
      | i == j    = (j, PartialTool tid n (js <> frag))
      | otherwise = (j, pt)
    parseArgs js = either (const (JObject [])) id (parse js)
```

- [ ] **Step 4: Run suite to verify it passes.** `nix develop . --command zinc test` → both `stepAcc` checks `ok`, `ALL PASS`.

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/LLM/Anthropic/Stream.hs test/Spec.hs
git commit -m "$(printf 'feat(stream): StreamAcc + stepAcc fold (text, tool reassembly, usage)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 5: Keystone — full recorded SSE body

**Files:** Test `test/Spec.hs` only (integrates Tasks 2–4 on realistic bodies).

- [ ] **Step 1: Write the tests.** In `test/Spec.hs`, add a helper (near `sseFrame`):

```haskell
-- Assemble a full SSE body (frames joined by blank lines, trailing blank line).
sseBody :: [Value] -> BC.ByteString
sseBody vs = TE.encodeUtf8 (T.intercalate "\n\n" ["data: " <> encode v | v <- vs] <> "\n\n")

-- Run a full body through the pure core to a final StreamAcc.
runBody :: BC.ByteString -> StreamAcc
runBody body = let (frames, _) = splitFrames body
               in foldl' stepAcc emptyAcc (map parseEvent frames)
```

Add checks:

```haskell
  -- A#3: keystone — full SSE body through the pure core
  , check "stream keystone: text response"
      ("Hello world", Usage 25 3)
      (let a = runBody (sseBody
                 [ JObject [("type", JString "message_start"), ("message", JObject [("usage", JObject [("input_tokens", JNumber 25), ("output_tokens", JNumber 1)])])]
                 , JObject [("type", JString "content_block_delta"), ("index", JNumber 0), ("delta", JObject [("type", JString "text_delta"), ("text", JString "Hello")])]
                 , JObject [("type", JString "content_block_delta"), ("index", JNumber 0), ("delta", JObject [("type", JString "text_delta"), ("text", JString " world")])]
                 , JObject [("type", JString "message_delta"), ("delta", JObject []), ("usage", JObject [("output_tokens", JNumber 3)])]
                 , JObject [("type", JString "message_stop")] ])
       in (saText a, saUsage a))
  , check "stream keystone: tool_use response"
      ([ToolUse "tu_1" "get_weather" (JObject [("city", JString "Brisbane")])], Usage 40 12)
      (let a = runBody (sseBody
                 [ JObject [("type", JString "message_start"), ("message", JObject [("usage", JObject [("input_tokens", JNumber 40), ("output_tokens", JNumber 1)])])]
                 , JObject [("type", JString "content_block_start"), ("index", JNumber 0), ("content_block", JObject [("type", JString "tool_use"), ("id", JString "tu_1"), ("name", JString "get_weather"), ("input", JObject [])])]
                 , JObject [("type", JString "content_block_delta"), ("index", JNumber 0), ("delta", JObject [("type", JString "input_json_delta"), ("partial_json", JString "{\"city\":")])]
                 , JObject [("type", JString "content_block_delta"), ("index", JNumber 0), ("delta", JObject [("type", JString "input_json_delta"), ("partial_json", JString "\"Brisbane\"}")])]
                 , JObject [("type", JString "content_block_stop"), ("index", JNumber 0)]
                 , JObject [("type", JString "message_delta"), ("delta", JObject []), ("usage", JObject [("output_tokens", JNumber 12)])] ])
       in (saTools a, saUsage a))
```

- [ ] **Step 2: Run suite to verify it passes.** `nix develop . --command zinc test` → both keystone checks `ok`, `ALL PASS`. (No new production code — this validates the pure core end-to-end. If a check fails, the bug is in Task 2–4 code; fix there.)

- [ ] **Step 3: Commit.**

```bash
git add test/Spec.hs
git commit -m "$(printf 'test(stream): keystone full-SSE-body checks (text + tool_use)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 6: `openStream` + streaming loop + `runLLMAnthropicStream`

This task adds the IO/Eff streaming machinery and the text-path interpreter. There is no pure unit test (it is network-bound); verification = the build succeeds and the existing suite stays green. Task 8 exercises it live.

**Files:** Modify `src/Crucible/LLM/Anthropic.hs` (exports); Modify `src/Crucible/LLM/Anthropic/Stream.hs`.

- [ ] **Step 1: Export the shared helpers from `Anthropic.hs`.** In `src/Crucible/LLM/Anthropic.hs`, add `newAnthropicManager` and `requestJson` to the module export list (anywhere in the `( ... ) where` block, e.g. after `defaultAnthropicConfig`):

```haskell
  , newAnthropicManager
  , requestJson
```

- [ ] **Step 2: Build to confirm exports compile.** `nix develop . --command zinc build` → exit 0.

- [ ] **Step 3: Add streaming machinery + interpreter to `Stream.hs`.**

Extend the export list:

```haskell
module Crucible.LLM.Anthropic.Stream
  ( splitFrames
  , StreamEvent (..)
  , parseEvent
  , StreamAcc (..)
  , PartialTool (..)
  , emptyAcc
  , stepAcc
  , runLLMAnthropicStream
  ) where
```

Add imports:

```haskell
import qualified Data.ByteString.Lazy as LBS
import Data.Word (Word8)

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret)
import Effectful.Exception (bracket)
import Effectful.State.Static.Local (modify, runState)

import Control.Exception (handle, throwIO)
import Control.Monad.Catch (Handler (Handler))
import Control.Retry (capDelay, fullJitterBackoff, limitRetries, recovering)
import Network.HTTP.Client
  ( BodyReader, HttpException, Manager, RequestBody (RequestBodyLBS), Response
  , brRead, method, parseRequest, requestBody, requestHeaders, responseBody
  , responseClose, responseOpen, responseStatus )
import Network.HTTP.Types.Status (statusCode)

import Crucible.Emit (Emit, emit)
import Crucible.Json.Encode (encode)
import Crucible.Json.Value (Value (JBool, JObject))   -- widen the existing Value import
import Crucible.LLM (LLM (..))
import Crucible.LLM.Anthropic
  ( AnthropicConfig (..), AnthropicError (..), isRetryable, newAnthropicManager
  , requestJson )
```

(Adjust the earlier `import Crucible.Json.Value (Value (JObject))` line to `Value (JBool, JObject)` rather than importing twice.)

Add the code:

```haskell
-- | Upper bound on a single backoff delay (30s). Mirrors the constant in
-- "Crucible.LLM.Anthropic"; kept local so this module is self-contained.
maxBackoffMicros :: Int
maxBackoffMicros = 30000000

-- | Add @"stream": true@ to a request body object.
addStream :: Value -> Value
addStream (JObject kvs) = JObject (kvs ++ [("stream", JBool True)])
addStream v             = v

-- | Open a @stream:true@ POST, retrying transient PRE-stream failures
-- (network/timeout, 429, 5xx) with the same policy as the non-streaming path.
-- Returns the live 2xx response (the caller streams and closes it); a non-2xx
-- response is drained, closed, and thrown as a retryable 'AnthropicStatusError'.
-- Nothing is emitted before this returns, so retrying is safe.
openStream :: AnthropicConfig -> Manager -> Value -> IO (Response BodyReader)
openStream cfg mgr bodyJson =
  recovering
    (capDelay maxBackoffMicros (fullJitterBackoff (acBaseDelayMicros cfg))
       <> limitRetries (acMaxRetries cfg))
    [ \_ -> Handler (\(e :: AnthropicError) -> pure (isRetryable e)) ]
    (\_ -> doOpen)
  where
    doOpen = handle (\(e :: HttpException) -> throwIO (AnthropicHttpError e)) $ do
      base <- parseRequest "https://api.anthropic.com/v1/messages"
      let req = base
            { method = "POST"
            , requestHeaders =
                [ ("x-api-key", TE.encodeUtf8 (acApiKey cfg))
                , ("anthropic-version", "2023-06-01")
                , ("content-type", "application/json")
                ]
            , requestBody = RequestBodyLBS (LBS.fromStrict (TE.encodeUtf8 (encode bodyJson)))
            }
      resp <- responseOpen req mgr
      let code = statusCode (responseStatus resp)
      if code >= 200 && code < 300
        then pure resp
        else do
          errBody <- drainBody (responseBody resp)
          responseClose resp
          throwIO (AnthropicStatusError code (TE.decodeUtf8Lenient errBody))

-- | Read a BodyReader to exhaustion into one strict ByteString.
drainBody :: BodyReader -> IO ByteString
drainBody br = go []
  where
    go acc = do
      chunk <- brRead br
      if BS.null chunk then pure (BS.concat (reverse acc)) else go (chunk : acc)

-- | Stream an open response: read chunks, split frames, 'emit' text deltas live,
-- and fold the whole stream into a 'StreamAcc'.
streamLoop :: (IOE :> es, Emit :> es) => Response BodyReader -> Eff es StreamAcc
streamLoop resp = go emptyAcc BS.empty
  where
    br = responseBody resp
    go acc buf = do
      chunk <- liftIO (brRead br)
      if BS.null chunk
        then if BS.all isWs buf then pure acc else emitFrames acc [buf]
        else do
          let (frames, rest) = splitFrames (buf <> chunk)
          acc' <- emitFrames acc frames
          go acc' rest
    emitFrames acc []       = pure acc
    emitFrames acc (f : fs) = do
      let ev = parseEvent f
      case ev of
        EvText t -> emit t
        _        -> pure ()
      emitFrames (stepAcc acc ev) fs
    isWs :: Word8 -> Bool
    isWs c = c == 32 || c == 10 || c == 13 || c == 9

-- | Stream the text path: interpret 'LLM' against Anthropic SSE, 'emit'ting each
-- text delta and returning the assembled reply plus summed 'Usage'.
runLLMAnthropicStream
  :: (IOE :> es, Emit :> es)
  => AnthropicConfig -> Eff (LLM : es) a -> Eff es (a, Usage)
runLLMAnthropicStream cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  reinterpret (runState mempty)
    (\_ (Complete msgs) -> do
        acc <- bracket
                 (liftIO (openStream cfg mgr (addStream (requestJson cfg msgs))))
                 (liftIO . responseClose)
                 streamLoop
        modify (<> saUsage acc)
        pure (saText acc))
    action
```

- [ ] **Step 4: Build + run the suite.** `nix develop . --command zinc build` → exit 0. `nix develop . --command zinc test` → `1 test suite(s) passed` (existing pure checks unaffected).

- [ ] **Step 5: Commit.**

```bash
git add src/Crucible/LLM/Anthropic.hs src/Crucible/LLM/Anthropic/Stream.hs
git commit -m "$(printf 'feat(stream): openStream + streamLoop + runLLMAnthropicStream\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 7: `runChatAnthropicStream`

Chat-path streaming interpreter, reusing `streamLoop`/`openStream`/`addStream`. Build-verified; Task 8 exercises it live.

**Files:** Modify `src/Crucible/LLM/Anthropic/Stream.hs`.

- [ ] **Step 1: Add the interpreter.** In `src/Crucible/LLM/Anthropic/Stream.hs`, add `runChatAnthropicStream` to the export list:

```haskell
  , runLLMAnthropicStream
  , runChatAnthropicStream
```

Extend the imports — add `Chat`/`Turn` from `Crucible.Chat` and `chatRequestJson`/`Schema`/`ToolName` as needed. The existing `import Crucible.Chat (ToolUse (..))` becomes:

```haskell
import Crucible.Chat (Chat (..), ToolUse (..), Turn (..))
```

Add `chatRequestJson` to the `Crucible.LLM.Anthropic` import list:

```haskell
import Crucible.LLM.Anthropic
  ( AnthropicConfig (..), AnthropicError (..), chatRequestJson, isRetryable
  , newAnthropicManager, requestJson )
```

Add the code:

```haskell
-- | Stream the chat path: interpret 'Chat' against Anthropic SSE, 'emit'ting each
-- text delta, reassembling tool_use blocks, and returning the assembled 'Turn'
-- plus summed 'Usage'.
runChatAnthropicStream
  :: (IOE :> es, Emit :> es)
  => AnthropicConfig -> Eff (Chat : es) a -> Eff es (a, Usage)
runChatAnthropicStream cfg action = do
  mgr <- liftIO (newAnthropicManager cfg)
  reinterpret (runState mempty)
    (\_ (Converse specs msgs) -> do
        acc <- bracket
                 (liftIO (openStream cfg mgr (addStream (chatRequestJson cfg specs msgs))))
                 (liftIO . responseClose)
                 streamLoop
        modify (<> saUsage acc)
        pure (Turn (saText acc) (saTools acc)))
    action
```

- [ ] **Step 2: Build + run the suite.** `nix develop . --command zinc build` → exit 0. `nix develop . --command zinc test` → `1 test suite(s) passed`.

- [ ] **Step 3: Commit.**

```bash
git add src/Crucible/LLM/Anthropic/Stream.hs
git commit -m "$(printf 'feat(stream): runChatAnthropicStream (chat-path SSE interpreter)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 8: Live streaming demo

**Files:** Modify `app/Main.hs`.

- [ ] **Step 1: Add imports.** In `app/Main.hs`, add:

```haskell
import Crucible.Emit (runEmitIO)
import Crucible.LLM.Anthropic.Stream (runLLMAnthropicStream, runChatAnthropicStream)
import System.IO (hFlush, stdout)
```

(The file already imports `Crucible.LLM (... complete)`, `Crucible.Chat (runToolAgent)`, `Crucible.Usage (Usage(..), usTotalTokens, ...)`, `Effectful (runEff)`, `Data.Text as T`, `Data.Text.IO as TIO`, `Crucible.Tool as Tl`, `Crucible.Schema (...)`, `Crucible.Json.Value (JString)`.)

- [ ] **Step 2: Add the streaming demo.** Append to the end of the `Just key -> do` block in `main` (after the existing usage-line print), at the same indentation as the other demo blocks:

```haskell
      -- Streaming: print tokens as they arrive (text path).
      TIO.putStr "stream: "
      (streamed, sUsage) <-
        runEff (runEmitIO (\t -> TIO.putStr t >> hFlush stdout)
                  (runLLMAnthropicStream cfg (complete prompt)))
      TIO.putStrLn ""
      TIO.putStrLn ("stream usage: " <> T.pack (show (usTotalTokens sUsage)) <> " tokens"
                    <> " (len " <> T.pack (show (T.length streamed)) <> ")")
      -- Streaming tool-agent (deltas printed live).
      let weatherTool2 = Tl.Tool "get_weather" (SObj [("city", SStr)])
            (\_ -> pure (JString "It is 26C and sunny."))
      TIO.putStr "stream tool: "
      (toolStream, tUsage) <-
        runEff (runEmitIO (\t -> TIO.putStr t >> hFlush stdout)
                  (runChatAnthropicStream cfg (runToolAgent [weatherTool2] "Use the tool to get the weather in Brisbane, then tell me.")))
      TIO.putStrLn ""
      case toolStream of
        Right a  -> TIO.putStrLn ("stream tool result: " <> a)
        Left err -> TIO.putStrLn ("stream tool error: " <> T.pack (show err))
      TIO.putStrLn ("stream tool usage: " <> T.pack (show (usTotalTokens tUsage)) <> " tokens")
```

(`prompt` is the existing top-level demo prompt already used by the cassette demo. `runToolAgent` returns `Eff es (Either ChatError Text)`, so `toolStream :: Either ChatError Text`.)

- [ ] **Step 3: Build.** `nix develop . --command zinc build` → exit 0.

- [ ] **Step 4: Run the live demo.** The binary reads `ANTHROPIC_API_KEY` from the environment (`.env` is gitignored — never print/commit it). Run:

```bash
nix develop . --command bash -c 'set -a; . ./.env; set +a; BIN=$(find .zinc/build -type f -name crucible-anthropic | head -1); "$BIN"'
```

Expected: the existing demo output, then a `stream: ` line whose text appears incrementally (token by token), a `stream usage: N tokens (len M)` line with non-zero N and M matching the streamed text length, then a `stream tool: ...`, `stream tool result: ...`, and `stream tool usage: N tokens` line. Non-zero usage + assembled text confirm end-to-end streaming, emit, reassembly, and usage capture. If the live call fails for an environment reason (no network/key), report DONE_WITH_CONCERNS noting the build succeeded but the live run could not be verified — do NOT fake output.

- [ ] **Step 5: Confirm the suite is still green + commit.** `nix develop . --command zinc test` → `1 test suite(s) passed`.

```bash
git add app/Main.hs
git commit -m "$(printf 'feat(stream): live streaming demo (text + tool-agent, tokens printed live)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Self-Review

**1. Spec coverage:**
- `Emit` effect + `emit` + `runEmitIO`/`ignoreEmit`/`runEmitList` → Task 1. ✅
- Pure SSE core: `splitFrames` (Task 2), `parseEvent`/`StreamEvent` (Task 3), `StreamAcc`/`stepAcc`/`PartialTool`/`emptyAcc` (Task 4). ✅
- Byte-level frame buffering (split then decode) → `splitFrames` on `ByteString`; `streamLoop` buffers `ByteString` and only `parseEvent` decodes. ✅
- `openStream` retry pre-stream only; non-2xx drained+closed+thrown retryable → Task 6. ✅
- `streamLoop` emits text deltas live, folds to `StreamAcc`, bracketed close → Task 6. ✅
- `runLLMAnthropicStream`/`runChatAnthropicStream :: ... -> Eff es (a, Usage)` → Tasks 6, 7. ✅
- Usage from `message_start`/`message_delta` (set, not add) → `parseEvent` (`EvUsageIn`/`EvUsageOut`) + `stepAcc` (record set) → Tasks 3, 4. ✅
- Tool-arg reassembly from `input_json_delta` → `EvToolJson` + `PartialTool` + `EvBlockStop` parse → Tasks 3, 4. ✅
- Keystone full-body test (text + tool) → Task 5. ✅
- Helper exports (`newAnthropicManager`, `requestJson`) → Task 6. ✅
- Live demo (text + tool-agent, tokens live, usage printed) → Task 8. ✅
- Test target `bytestring` dep → Task 2. ✅
- Non-goals respected: no streaming cassettes; no `Emit` on the non-streaming path; no mid-stream retry; `LLM`/`Chat`/`Message`/`Turn`/`Block` and existing interpreters untouched (only additive exports in `Anthropic.hs`). ✅

**2. Placeholder scan:** No TBD/TODO; every code step has complete code; commands have expected output. The Task 8 run note describes the live-invocation fallback (runtime detail), not a code placeholder.

**3. Type consistency:** `StreamEvent` ctors (`EvText`/`EvToolStart`/`EvToolJson`/`EvBlockStop`/`EvUsageIn`/`EvUsageOut`/`EvOther`) are identical across Tasks 3–6. `StreamAcc` fields (`saText`/`saPartial`/`saTools`/`saUsage`) consistent Tasks 4–7. `PartialTool ToolUseId ToolName Text` matches its construction/teardown in `stepAcc`. `emptyAcc`/`stepAcc`/`splitFrames`/`parseEvent` signatures match their test call sites. `runLLMAnthropicStream`/`runChatAnthropicStream :: (IOE :> es, Emit :> es) => AnthropicConfig -> Eff (E:es) a -> Eff es (a, Usage)` match `reinterpret (runState mempty)`'s `(a, s)` return and the demo's tuple binds. `ToolUse (..)`/`Turn (..)`/`Usage (..)`/`Value (JBool, JObject)` constructor imports cover every constructor used. `addStream`/`openStream`/`streamLoop`/`drainBody` are defined before their single use sites. ✅
