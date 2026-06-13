# Assert and Check as Codec Refinements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `refine` (hard: fails decode so `call`'s retry loop feeds the violation back; message surfaced as the schema description) and `checked` (soft: a `Checked` wrapper with a per-check pass map), plus a `describe` helper.

**Architecture:** Spec at `docs/superpowers/specs/2026-06-13-assert-check-design.md` (tracker `crucible-mti`). Entirely within `Crucible.Codec`: `refine` builds on `bimapCodec` + `<?>`; `checked` on `dimapCodec`. No changes to the decode or retry machinery (they already consume a `DecodeError` from a failing codec).

**Tech Stack:** Haskell GHC 9.12.2, autodocodec. No -Werror. Build/test: `nix develop . --command timeout -s KILL 300 zinc build` (exit 0) / `... zinc test` ("1 test suite(s) passed"). Exit 137 = GHC iserv flake, retry once; second 137 = BLOCKED. Judge success by exit status or the pass line, never a pipeline tail. Ignore the "Git tree is dirty" warning.

---

## Background for the implementer

- Branch: create `feat/assert-check` from master; work in place, no worktrees.
- House style: DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot, prefix-free fields. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Read first: `src/Crucible/Codec.hs` (combinators, Autodocodec import, exports — currently pragmas are only `OverloadedStrings` + `TypeApplications`), `src/Crucible/Decode.hs` (`decodeLLM` turns a codec parse failure into a `DecodeError`), `src/Crucible/Skill.hs` `call` (its loop re-prompts with `err.message` on decode failure).
- Mechanism: a codec whose decode returns `Left msg` makes `decodeLLM` produce `DecodeError { message = "...msg..." }`; `call` feeds that back and retries. `refine` is just such a codec. `checked` never fails (always attaches results).
- The suite passes with 296 checks.
- API keys live in `.env` (gitignored). NEVER print, echo, or cat `.env` or any key value.

---

### Task 1: `refine`, `checked`, `Checked`, `describe` + tests

**Files:**
- Modify: `src/Crucible/Codec.hs`
- Modify: `test/Spec.hs`

- [ ] **Step 1: pragmas + imports.** In `src/Crucible/Codec.hs` add the record pragmas at the top (the module gains the `Checked` record):

```haskell
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
```

Add `(<?>)` to the `import Autodocodec (...)` list (next to `bimapCodec`, `dimapCodec`). Add `import qualified Data.Text as T` (needed for `T.unpack` in `refine`; check it is not already imported).

- [ ] **Step 2: exports.** Add to the module export list: `refine`, `checked`, `Checked (..)`, `allPassed`, `describe`.

- [ ] **Step 3: definitions.** Add after the existing combinators (e.g. after `optField`):

```haskell
-- | Attach a human description to a codec's schema (renders as the
-- JSON-schema "description"). Re-exports autodocodec's '<?>'.
describe :: JSONCodec a -> Text -> JSONCodec a
describe = (<?>)

-- | A hard refinement. Decoding fails when the predicate does not hold,
-- carrying @message@ so 'Crucible.Skill.call's retry loop feeds the
-- violation back to the model. The message is also surfaced as the schema
-- description, so the model sees the constraint upfront. The JSON type is
-- unchanged: a refinement is human guidance, not a wire-format change.
refine :: Text -> (a -> Bool) -> JSONCodec a -> JSONCodec a
refine msg ok c = bimapCodec check id c `describe` msg
  where check a = if ok a then Right a else Left (T.unpack msg)

-- | A value plus the result of each soft check, by name and in order.
data Checked a = Checked { value :: a, checks :: [(Text, Bool)] }
  deriving (Eq, Show)

-- | True when every check passed.
allPassed :: Checked a -> Bool
allPassed cv = all snd cv.checks

-- | A soft refinement. Decoding always succeeds; the value comes back
-- wrapped with each named check's pass/fail, so a caller branches on
-- quality without losing the data. The wire shape and schema are the inner
-- value's; 'Checked' is transparent on the wire.
checked :: [(Text, a -> Bool)] -> JSONCodec a -> JSONCodec (Checked a)
checked specs c = dimapCodec attach (.value) c
  where attach a = Checked a [(nm, p a) | (nm, p) <- specs]
```

If `(<?>)`'s type does not unify with `JSONCodec a -> Text -> JSONCodec a` directly (it is `ValueCodec i o -> Text -> ValueCodec i o`, and `JSONCodec a = ValueCodec a a`, so it should), adapt minimally and report. If GHC needs `Text` qualified differently, match the file.

- [ ] **Step 4: tests in `test/Spec.hs`.** Extend the `import Crucible.Codec (...)` line (currently `JSONCodec, schemaValue, schemaText`) with `refine, checked, Checked (..), allPassed, object, field, int, str`. Add `int`/`str`/`object`/`field` only if not already imported elsewhere; if they collide with another import, qualify or consolidate and report. Add these checks (place near the codec/decode checks):

```haskell
  -- crucible-mti: refine (hard) and checked (soft)
  , check "refine: a satisfying value decodes, a violating one fails with the message"
      (Right 5 :: Either DecodeError Int, True)
      ( decodeLLM (refine "must be positive" (> 0) int) "5"
      , case decodeLLM (refine "must be positive" (> 0) int) "-3" of
          Left e -> T.isInfixOf "must be positive" e.message
          Right (_ :: Int) -> False )
  , check "refine: the message is surfaced in the schema description"
      True
      (T.isInfixOf "must be positive" (schemaText (refine "must be positive" (> 0) int)))
  , check "refine: a field-level violation carries the constraint message"
      True
      (case decodeLLM (object (field "age" Prelude.id
              (refine "age must be 0..130" (\a -> a >= 0 && a <= 130) int))) "{\"age\": 200}" of
         Left e -> T.isInfixOf "age must be 0..130" e.message
         Right (_ :: Int) -> False)
  , check "refine: call retries on a violation then succeeds"
      (Right 42 :: Either DecodeError Int)
      (runPureEff (runLLMScripted ["{\"n\": -1}", "{\"n\": 42}"]
         (call (skill "s" str
                  (object (field "n" Prelude.id (refine "n must be positive" (> 0) int)))
                  (\x -> [text|give n for ${x}|]))
               ("in" :: Text))))
  , check "refine: with no retries a violation is returned"
      True
      (case runPureEff (runLLMScripted ["{\"n\": -1}"]
              (call (withRetries 0 (skill "s" str
                       (object (field "n" Prelude.id (refine "n must be positive" (> 0) int)))
                       (\x -> [text|give n for ${x}|])))
                    ("in" :: Text))) of
         Left e -> T.isInfixOf "n must be positive" e.message
         Right (_ :: Int) -> False)
  , check "checked: a passing value wraps with all checks true"
      (Checked ("hi" :: Text) [("nonempty", True), ("short", True)], True)
      (let cv = either (const (Checked "" [])) Prelude.id
                  (decodeLLM (checked [("nonempty", not . T.null), ("short", (< 10) . T.length)] str)
                     "\"hi\"")
       in (cv, allPassed cv))
  , check "checked: a failing value preserves the value and marks the failing check"
      (Checked ("" :: Text) [("nonempty", False), ("short", True)], False)
      (let cv = either (const (Checked "x" [])) Prelude.id
                  (decodeLLM (checked [("nonempty", not . T.null), ("short", (< 10) . T.length)] str)
                     "\"\"")
       in (cv, allPassed cv))
  , check "checked: the advertised schema is the inner codec's"
      True
      (schemaText (checked [("nonempty", not . T.null)] str) == schemaText str)
```

Notes: the `checked` value `"\"hi\""` is a JSON string literal (decodes to `Text` "hi"). `Prelude.id` avoids any `id` ambiguity. If `decodeLLM (checked ...) "\"hi\""` fails to find JSON (bare string has no bracket — `stripToJson` falls back to the trimmed input, and `A.eitherDecode "\"hi\""` parses a JSON string fine), it should still decode; if it does not, switch the inner codec to an object form and report. The `call`/`skill`/`withRetries`/`str` symbols come from the existing `Crucible.Skill`/`Crucible.Codec` imports. If a result differs, investigate the CODE; never weaken a check.

- [ ] **Step 5: build + suite.** Build exit 0; `1 test suite(s) passed`, 304 ok (296 + 8).

- [ ] **Step 6: commit.**

```bash
git add src/Crucible/Codec.hs test/Spec.hs
git commit -m "$(printf 'feat(codec): refine (hard) and checked (soft) output refinements\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: demo + live smoke + docs

**Files:**
- Modify: `app/Main.hs`
- Modify: `docs/typed-functions.md`

- [ ] **Step 1: demo.** Add `refine`, `object`, `field`, `int` to the `Crucible.Codec` import in `app/Main.hs` (extend the existing import line; add only what is missing). In the Anthropic-gated block, after the `typed fn:` classify demo (~line 98), add a `refine` skill whose schema description guides the model and whose retry loop would catch a violation:

```haskell
      let ageFn :: Skill T.Text Int
          ageFn = skill "extract-age" str
            (object (field "age" Prelude.id
               (refine "age must be between 0 and 130" (\a -> a >= 0 && a <= 130) int)))
            (\s -> [text|Extract the person's age from: ${s}|])
      ageRes <- runEff (Anthropic.run cfg (call ageFn "Maria is 34 years old."))
      TIO.putStrLn ("refine: extracted age " <> either (.message) (T.pack . show) ageRes)
```

(`skill`, `call`, `Skill`, `cfg`, `Anthropic`, `T`, `TIO`, `runEff` are already in scope. `either (.message) (T.pack . show) ageRes` renders Left's `DecodeError.message` or Right's Int.)

- [ ] **Step 2: build + live smoke.**

```bash
nix develop . --command timeout -s KILL 300 zinc build
nix develop . --command bash -c 'set -a; . ./.env; set +a; timeout -s KILL 420 .zinc/build/crucible-anthropic'
```

Expected: a `refine: extracted age 34` line (the model returns an in-range age, guided by the schema description); exit 0; the rest of the demo unchanged. If the model returns an out-of-range value, the retry loop re-prompts and it still resolves; REPORT the exact line.

- [ ] **Step 3: docs.** In `docs/typed-functions.md` "## Codecs" (read lines ~89-137 first): add `refine`, `checked`, and `describe` to the combinator table, and a short subsection after the `enum` example covering:
  - `refine :: Text -> (a -> Bool) -> JSONCodec a -> JSONCodec a` — a hard constraint; a violation fails decode, so `call` re-prompts with the message and the model retries (stronger than raising to the caller); the message is also surfaced in the schema description so the model sees it upfront. Show a one-line example.
  - `checked :: [(Text, a -> Bool)] -> JSONCodec a -> JSONCodec (Checked a)` — soft checks; decoding never fails, the value returns wrapped in `Checked { value, checks }` (a per-check pass list) so callers branch on quality with `allPassed`; transparent on the wire.
  - `describe :: JSONCodec a -> Text -> JSONCodec a` — attach a schema description to any codec.

  Table rows to add:

```markdown
| `refine`   | `Text -> (a -> Bool) -> JSONCodec a -> JSONCodec a` |
| `checked`  | `[(Text, a -> Bool)] -> JSONCodec a -> JSONCodec (Checked a)` |
| `describe` | `JSONCodec a -> Text -> JSONCodec a` |
```

  House style STRICT: `grep -n $'—\|–' docs/typed-functions.md` must stay empty; no hype words; never mention a project called "manifest".

- [ ] **Step 4: commit.**

```bash
git add app/Main.hs docs/typed-functions.md
git commit -m "$(printf 'docs(site)+demo: refine and checked codec refinements, proven live\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: merge + publish + close

**Files:** none.

- [ ] **Step 1: full suite.** `... zinc test` shows `1 test suite(s) passed`, 304 ok.
- [ ] **Step 2: merge + push.** Via `superpowers:finishing-a-development-branch`; after merge: suite on master, `git push`, Pages build reaches `built`.
- [ ] **Step 3: close the bead.**

```bash
bd close crucible-mti --reason="Shipped: refine (hard refinement, fails decode so call retries with the violation, message surfaced as schema description) and checked (soft, Checked { value, checks } per-check pass map, never fails, transparent on the wire) plus describe, in Crucible.Codec. 8 hermetic tests, live refine demo. Container-element removal, union-arm asserts, cross-field expressions remain non-goals."
```

---

## Self-Review

**1. Spec coverage:** `describe` re-exporting `<?>` -> Task 1 Step 3. `refine` via bimapCodec + describe (hard, fails decode, message in schema) -> Step 3 + tests (pass/fail, schema description, field-level, call-retry, retries=0). `Checked` + `allPassed` + `checked` via dimapCodec (soft, never fails, transparent) -> Step 3 + tests (passing, failing-preserves-value, schema-transparent). Demo refine through call -> Task 2. Docs table + subsection -> Task 2 Step 3. Non-goals (container removal, union arms, cross-field, class-level beyond whole-value) absent. ✅

**2. Placeholder scan:** none; the `checked` bare-string-JSON note and the `(<?>)` unification note are verify-against-reality instructions with concrete fallbacks, not gaps. ✅

**3. Type consistency:** `refine :: Text -> (a -> Bool) -> JSONCodec a -> JSONCodec a` matches every call site; `bimapCodec check id` where `check :: a -> Either String a` (decode) and `id` (encode); `checked :: [(Text, a -> Bool)] -> JSONCodec a -> JSONCodec (Checked a)` with `dimapCodec (a -> Checked a) (Checked a -> a)` via `(.value)`; `Checked { value, checks }` record-dot needs the three pragmas added in Step 1; `allPassed :: Checked a -> Bool`. Check counts: 296 + 8 = 304; the close message says 8 tests. ✅
