# Assert and Check as Codec Refinements Design Spec

**Date:** 2026-06-13
**Status:** Approved design, pending implementation
**Tracker:** `crucible-mti`.
**Research basis:** `docs/superpowers/research/2026-06-11-baml-review.md` item 3 (assert/check as codec-level refinements).
**Scope:** `src/Crucible/Codec.hs` (new combinators + `Checked` type); `test/Spec.hs`; `app/Main.hs`; `docs/typed-functions.md`.

## Motivation

BAML's `@assert` (hard) and `@check` (soft) constrain output types. crucible
already has the perfect consumer for hard asserts: `Crucible.Skill.call`'s
decode-retry loop. A refinement that fails decode feeds the violation back to
the model and retries, which is strictly better than BAML's raise-to-caller.
Soft checks are a separate wrapper carrying a per-check pass map, so callers
branch on quality without losing the data.

## Decisions taken during design

- `refine` surfaces its constraint message as the schema `description` (via
  autodocodec's `<?>`), so the model sees it upfront and usually satisfies
  it first try, AND still fails decode + retries on a violation. The JSON
  type is unchanged: the refinement is human guidance, not a wire-format
  change (the review's "honest contract").
- `Checked` carries `[(Text, Bool)]` (ordered assoc list): preserves check
  order, no new dependency, matches the house list idiom.
- Both live in `Crucible.Codec` (codec combinators). A small `describe`
  helper re-exports `<?>` for general use; `refine` builds on it.

## Design (`Crucible.Codec`)

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

New exports: `refine`, `checked`, `Checked (..)`, `allPassed`, `describe`.
The module already imports `bimapCodec` and `dimapCodec` from Autodocodec;
add `(<?>)`. `Crucible.Codec` gains `DuplicateRecordFields`,
`NoFieldSelectors`, `OverloadedRecordDot` if not present (for the `Checked`
record-dot `cv.checks` / `(.value)`), plus `OverloadedStrings` (already on).

### Behavior

- `refine` (hard): a violation makes `decodeLLM` return a `DecodeError`
  whose message is the refinement text; `call`'s loop re-prompts with it,
  giving the model a chance to fix the value. The schema description means
  it usually does not need to. A refinement nested in an object field
  attaches its description to that field and, on violation, aeson's parse
  path locates the field in the message.
- `checked` (soft): never fails; always returns `Checked { value, checks }`.
  The model returns the bare inner value, the advertised schema is the
  inner codec's, and callers inspect `cv.checks` or `allPassed cv`.

## Demo (`app/Main.hs`)

One live proof in the Anthropic-gated block: a `call` whose output codec
uses `refine` to enforce a constraint the model can satisfy once it sees
the description (and which the retry loop would catch otherwise), printing
the result; or a `checked` codec printing the per-check pass map. The plan
picks whichever provokes a clean, low-cost live demonstration.

## Manual (`docs/typed-functions.md`)

In the codecs material: document `refine` (hard, fails decode so `call`
retries with the violation, message surfaced as the schema description) and
`checked` (soft, returns a `Checked` wrapper with a per-check pass map,
never fails, transparent on the wire), with `describe` as the general
schema-description helper. House style: no emdashes, no hype, no manifest
mentions.

## Testing (hermetic)

- `refine` passes a satisfying value (`decodeLLM` Right) and fails a
  violating one (`decodeLLM` Left with the message in the error).
- `schemaText (refine msg ok c)` contains `msg` (surfaced as description).
- A field-level `refine` inside an object: a violating field yields a
  Left whose message names both the constraint and the field path.
- End-to-end via `runLLMScripted` + `call`: a first violating reply then a
  corrected reply retries to success; with retries = 0 the violation is
  returned as `Left`.
- `checked` over a passing value: `allPassed` True, every check True,
  `value` recovered.
- `checked` over a failing value: the failing check False, `value`
  preserved, decode never errors.
- `schemaText (checked specs c)` equals `schemaText c` (transparent).

## Non-goals

- Container-element removal: BAML drops failing elements from a list; a
  `refine` on a list codec fails the whole decode and retries instead.
- Union-arm asserts (no union codec surface to annotate).
- Cross-field or Jinja-style expressions referencing other results
  (`_.checks.$name`): a refinement sees only its own value.
- Class-level `@@assert` beyond a whole-value `refine` on the object codec
  (which already covers the whole-value case).
