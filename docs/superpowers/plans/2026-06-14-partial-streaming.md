# Partial Typed Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** `Crucible.Partial`: `closeJson` (close a partial JSON buffer to valid JSON) plus `runPartialWith`/`runPartial` interpreters over `Emit` that decode each growing buffer through a caller-supplied all-optional codec.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-14-partial-streaming-design.md` (tracker `crucible-2ey`). Mirrors `Crucible.Rows` (pure kernel + sink interpreter + collecting variant). Option B: the caller supplies the partial type `p` and its codec.

**Tech Stack:** Haskell GHC 9.12.2, effectful, text. No -Werror. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). Exit 137 = retry once. Judge by exit status or the pass line, never a pipeline tail.

---

## Background

- Branch `feat/partial-streaming` from master. House style: NoFieldSelectors, OverloadedRecordDot. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- READ `src/Crucible/Rows.hs` (the exact pattern to mirror: `splitRows` kernel; `runRowsWith` = `reinterpret (runState T.empty)` accumulating, sink via `raise . sink`; `runRows` = collecting via `runState [] (... (inject action))`) and `src/Crucible/Emit.hs` (the `Emit` effect) and `src/Crucible/Decode.hs` (`decodeLLM :: JSONCodec a -> Text -> Either DecodeError a`, and `scanBalanced` for the depth/string scan discipline).
- Suite passes with 318 checks (verify the live count; tests added land on top).
- Keys in `.env` (gitignored). NEVER print/echo/cat them.

---

### Task 1: `Crucible.Partial` (closeJson + interpreters) + tests

**Files:** Create `src/Crucible/Partial.hs`; modify `test/Spec.hs`, and add the module to `zinc.toml` if the lib stanza lists modules explicitly (check; zinc usually auto-discovers `src/` — if so, no zinc.toml change).

- [ ] **Step 1: module skeleton + interpreters.** Create `src/Crucible/Partial.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | Incremental decoding of one growing JSON object over 'Emit': as deltas
-- arrive, close the partial buffer to valid JSON and decode it through a
-- caller-supplied all-optional codec, so the caller receives progressively
-- more complete typed partial values. This is to one growing object what
-- "Crucible.Rows" is to JSONL lines. The caller writes the partial type
-- (every field 'Maybe') and its codec; crucible does not generate it.
module Crucible.Partial
  ( closeJson
  , runPartialWith
  , runPartial
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Effectful
import Effectful.Dispatch.Dynamic (reinterpret, raise, inject)
import Effectful.State.Static.Local (get, modify, put, runState)

import Crucible.Emit (Emit (..))
import Crucible.Decode (DecodeError, decodeLLM)
import Crucible.Codec (JSONCodec)

-- | Interpret 'Emit' for one growing object: accumulate the whole buffer,
-- and on each delta close it and decode through the partial codec, handing
-- the 'Either DecodeError p' to the sink immediately. A blank buffer emits
-- nothing. Use a codec whose fields are all optional so partials decode as
-- fields arrive.
runPartialWith
  :: JSONCodec p
  -> (Either DecodeError p -> Eff es ())
  -> Eff (Emit : es) r
  -> Eff es r
runPartialWith c sink action =
  reinterpret (runState T.empty) (\_ -> \case
    Emit t -> do
      buf <- get
      let buf' = buf <> t
      put buf'
      if T.null (T.strip buf')
        then pure ()
        else raise (sink (decodeLLM c (closeJson buf')))) action
    >>= \(r, _buf) -> pure r

-- | Like 'runPartialWith', but collect the partials alongside the result.
runPartial :: JSONCodec p -> Eff (Emit : es) r -> Eff es (r, [Either DecodeError p])
runPartial c action = do
  (r, ps) <- runState [] (runPartialWith c (\p -> modify (p :)) (inject action))
  pure (r, reverse ps)
```

Match `runRows`'s exact effect plumbing; if `reinterpret (runState ...)` returns `(r, buf)` differently than the `>>= \(r,_) -> pure r` shown, follow `runRowsWith`'s structure verbatim (it binds `(r, leftover)` then returns `r`). If `raise`/`inject` import paths differ, copy them from `Crucible.Rows`.

- [ ] **Step 2: `closeJson`.** Add the pure kernel. Strategy: one left-to-right scan to compute (a) the open-bracket stack (innermost first), (b) whether the buffer ends inside a string and whether that string is a key (innermost container is an object and we are before its `:`) or a value, (c) escape state. Then:
  - first non-space char not `{` (or blank) -> return input unchanged (single-object scope);
  - mid VALUE string -> drop a dangling trailing backslash, append `"`, then append closers;
  - mid KEY string -> drop the partial key back through its opening `"` and a preceding `,` (if any), then append closers;
  - not in a string -> trim trailing whitespace, then drop a trailing `,`; drop a trailing `:` together with its key (and a preceding `,`); drop a trailing partial literal (`true`/`false`/`null` strict prefix) or partial number (ends in `.`/`e`/`E`/`+`/`-`) back to the last separator; then append closers;
  - closers = for each open bracket in the stack (innermost first), `}` for `{` and `]` for `[`.

  **The pinned test matrix below is the contract; implement `closeJson` so every case passes, adjusting the scanner until it does.** Reuse `Crucible.Decode`'s scan discipline (depth + string/escape) as a starting point; the key-vs-value tracking is the addition.

- [ ] **Step 3: tests in `test/Spec.hs`.** Add `import Crucible.Partial (closeJson, runPartial)`. The closeJson contract (exact outputs):

```haskell
  -- crucible-2ey: closeJson (partial JSON completion)
  , check "closeJson: closes a partial value string"
      "{\"name\":\"Ali\"}"        (closeJson "{\"name\":\"Ali")
  , check "closeJson: complete-but-unclosed object"
      "{\"name\":\"Bob\",\"age\":3}" (closeJson "{\"name\":\"Bob\",\"age\":3")
  , check "closeJson: drops a trailing comma"
      "{\"a\":1}"                 (closeJson "{\"a\":1,")
  , check "closeJson: drops a key with no value"
      "{}"                        (closeJson "{\"a\":")
  , check "closeJson: drops an incomplete key"
      "{}"                        (closeJson "{\"na")
  , check "closeJson: drops a partial literal"
      "{}"                        (closeJson "{\"a\":tr")
  , check "closeJson: nested object, value string and stack closed in order"
      "{\"a\":1,\"b\":{\"c\":\"x\"}}" (closeJson "{\"a\":1,\"b\":{\"c\":\"x")
  , check "closeJson: already-closed and trivial inputs"
      ("{}", "")                  (closeJson "{}", closeJson "")
```

The `runPartial` end-to-end contract (scripted `emit` deltas; define a partial type with a HasCodec/genericCodec instance near the other test fixtures, e.g. `data PersonP = PersonP { ppName :: Maybe Text, ppAge :: Maybe Int } deriving (Eq, Show, Generic)` with `instance HasCodec PersonP where codec = genericCodec` — match how Spec.hs already defines such fixtures; if genericCodec field-name handling needs specific record field names, mirror an existing generic fixture):

```haskell
  , check "runPartial: fields fill in across deltas; last partial is complete"
      (Just (Just "Alice", Just 30))
      (let (_, ps) = runPureEff (runEmit... ) -- see note
       in fmap (\p -> (ppName p, ppAge p)) (lastRight ps))
```

NOTE on driving deltas: `runPartial codec (mapM_ emit chunks)` where `chunks = ["{\"ppName\": \"Al", "ice\", \"ppAge\": 3", "0}"]`, run under `runPureEff`. The collecting `runPartial` returns `(r, [Either DecodeError PersonP])`. Assert: the last `Right` partial has `ppName = Just "Alice", ppAge = Just 30`; an intermediate partial has `ppName = Just "Al"` (or `"Ali"` depending on chunk boundary) and `ppAge = Nothing`; a leading blank delta (prepend `""`) emits nothing. Use a small `lastRight :: [Either e a] -> Maybe a` helper inline. Pin the intermediate assertion to the actual chunk boundaries you choose so it is deterministic. If `genericCodec` on an all-`Maybe` record does not treat missing fields as `Nothing` on decode (it should, via autodocodec optional fields for `Maybe`), report it: that would mean Option B needs `optField`-built codecs, which is a finding worth surfacing.

- [ ] **Step 4: build + suite.** Build exit 0; `1 test suite(s) passed`, count = prior + (8 closeJson + the runPartial checks). Report the exact ok count.

- [ ] **Step 5: commit.**

```bash
git add src/Crucible/Partial.hs test/Spec.hs
git commit -m "$(printf 'feat(partial): runPartial streams typed partial values of one growing object\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: demo + live smoke + docs

**Files:** Modify `app/Main.hs`, `docs/streaming.md`.

- [ ] **Step 1: demo.** In the Anthropic-gated block, stream one object and print the partials. Add `import Crucible.Partial (runPartialWith)` and a partial type (reuse the test's `PersonP` shape or a demo-local one). Example:

```haskell
      partials <- runEff (runEmitList' ... )  -- choose the simplest wiring:
```

Prefer the streaming interpreter: `Anthropic.stream cfg (complete prompt)` emits deltas; wrap with `runPartialWith pcodec sink`. Concretely, ask for a small JSON object and print each partial's filled fields, e.g. collect them and print the last one and the count. If threading the live stream through `runPartialWith` is awkward, demonstrate with scripted `emit` deltas and print the sequence; REPORT which. Keep it to a few fields.

- [ ] **Step 2: build + live smoke.**

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: lines showing a partial object's fields filling in (or a final assembled partial + a count); exit 0. REPORT the relevant output lines.

- [ ] **Step 3: docs.** In `docs/streaming.md`, replace the "Incremental typed decoding of a single JSON object ... is out of scope" sentence (in "Streaming and typed skills") with a "Partial typed values" section: the caller writes an all-`Maybe` partial type and its codec; `runPartialWith` streams `Either DecodeError p` as fields arrive; `closeJson` is the kernel; one top-level object; the relationship to `runRows` (lines vs one growing object). Show a short example mirroring the `runRows` example's shape. House style STRICT: `grep -n $'—\|–' docs/streaming.md` empty; no hype; no "manifest".

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/streaming.md
git commit -m "$(printf 'docs(site)+demo: partial typed streaming of a growing object\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: merge + publish + close

- [ ] **Step 1:** full suite `1 test suite(s) passed`.
- [ ] **Step 2:** merge via `superpowers:finishing-a-development-branch` (the user picks "merge to master locally"); pull first (master may have moved); suite on master; push; Pages `built`.
- [ ] **Step 3:** `bd close crucible-2ey --reason="Shipped (Option B): Crucible.Partial with closeJson (partial-JSON completion kernel) and runPartialWith/runPartial over Emit, decoding each growing buffer through a caller-supplied all-optional codec; per-delta typed partials for one growing object. Tests (closeJson matrix + scripted-delta end-to-end), live/scripted demo, streaming.md section. Generic all-optional derivation (Option C) remains a possible follow-up."`

---

## Self-Review

**1. Spec coverage:** closeJson (rules + single-object scope) -> Task 1 Step 2 + the pinned matrix. runPartialWith/runPartial mirroring Rows -> Step 1. Per-delta emit, blank emits nothing -> Step 1 (T.strip guard). Caller-supplied partial codec (Option B) -> the `JSONCodec p` parameter + test fixture. Demo + streaming.md replacement of the exclusion -> Task 2. Non-goals (Option C, Option A, arrays, debounce) absent. ✅

**2. Placeholder scan:** the demo wiring and the runPartial test's exact intermediate assertion are left to be pinned against chosen chunk boundaries (deterministic once chosen); the closeJson matrix is fully pinned and is the contract. The genericCodec-on-all-Maybe behaviour is flagged as a verify-and-report point (a real risk for Option B). No silent gaps. ✅

**3. Type consistency:** `closeJson :: Text -> Text`; `runPartialWith :: JSONCodec p -> (Either DecodeError p -> Eff es ()) -> Eff (Emit : es) r -> Eff es r` and `runPartial :: JSONCodec p -> Eff (Emit : es) r -> Eff es (r, [Either DecodeError p])` mirror `runRowsWith`/`runRows` exactly with `p` in place of the row type; `decodeLLM c (closeJson buf') :: Either DecodeError p`. ✅
