# Semantic Streaming of Partial Typed Values Design Spec

**Date:** 2026-06-14
**Status:** Approved design, pending implementation
**Tracker:** `crucible-2ey`.
**Research basis:** `docs/superpowers/research/2026-06-11-baml-review.md` (semantic streaming); supersedes `2026-06-13-partial-streaming-DRAFT.md` (the all-optional-codec fork is resolved: Option B, caller-supplied partial codec).
**Scope:** new `src/Crucible/Partial.hs`; `test/Spec.hs`; `app/Main.hs`; `docs/streaming.md`.

## Motivation

`docs/streaming.md` excludes incremental typed decoding of a single
growing JSON object. `Crucible.Rows` covers JSONL (one object per line);
the gap is one object whose fields arrive token by token. This adds it:
as deltas arrive, the caller receives progressively more complete typed
partial values. It is to one growing object what `runRows` is to lines.

## Decision (the fork, resolved)

Option B: the caller supplies an all-optional partial type `p` and its
codec. crucible cannot generate a `Partial<T>` (no compile-time codegen),
and an arbitrary `JSONCodec a` cannot be mechanically relaxed to make
every field optional. Codecs are values, so the caller writes the partial
twin (the same insight as the dynamic-codecs docs). Sub-decisions: emit one
partial per non-blank delta (semantic streaming; no debounce, the caller
dedupes); `Either DecodeError p` per the Rows robustness idiom; single
top-level object only.

## Design (`Crucible.Partial`)

Mirrors `Crucible.Rows` (a pure kernel plus a sink interpreter plus a
collecting variant).

```haskell
-- | Close a partial JSON buffer into the longest valid JSON it can; the
-- pure kernel. Single top-level object expected. Rules, applied after a
-- single left-to-right scan that tracks the {/[ stack, string/escape
-- state, and whether the innermost object is in key or value position:
--   * mid VALUE string: close it with " (a partial string value shows
--     live); a trailing backslash (dangling escape) is dropped first.
--   * mid KEY string (object, before ':'): drop the incomplete key back
--     through its opening " and any preceding ',' (a key needs a value).
--   * trailing ':' (key, no value yet): drop the key/colon back to the
--     last complete member or the opening '{'.
--   * trailing ',': drop it.
--   * trailing partial literal/number (true|false|null prefix, "1." etc.):
--     drop it back to the last separator.
--   * then append, for each open bracket in the stack, its closer in
--     reverse nesting order.
-- A buffer whose first non-space char is not '{' is returned unchanged
-- (it will simply fail the partial decode, surfaced as a Left).
closeJson :: Text -> Text

-- | Interpret 'Emit' for one growing object: accumulate the whole buffer,
-- and on each delta close it and decode through the partial codec, handing
-- the 'Either DecodeError p' to the sink immediately. A blank buffer emits
-- nothing. Decode through a codec whose fields are all optional so partials
-- decode as fields arrive.
runPartialWith
  :: JSONCodec p
  -> (Either DecodeError p -> Eff es ())
  -> Eff (Emit : es) r
  -> Eff es r

-- | Like 'runPartialWith', but collect the partials alongside the result
-- (for tests and batch use).
runPartial :: JSONCodec p -> Eff (Emit : es) r -> Eff es (r, [Either DecodeError p])
```

`runPartialWith` keeps the accumulated buffer in `reinterpret (runState
T.empty)`; each `Emit t` appends, and if the new buffer is non-blank
`closeJson` + `decodeLLM p` produces one `Either DecodeError p` to the
sink (`raise . sink`, as `runRowsWith` does). No final flush is needed
(the last delta already produced the complete object's partial, which for
a well-formed final object equals the full value).

`closeJson` may reuse the scan discipline from `Crucible.Decode`
(`scanBalanced` tracks depth and string/escape) but needs the extra
key-vs-value tracking, so it is its own scanner in this module.

## Demo (`app/Main.hs`)

One live proof in the Anthropic-gated block: a partial type with all
`Maybe` fields, streamed through `Anthropic.streamChat`/`stream` and
`runPartialWith` printing each partial. Keep it small (a two or three
field object) and print the last few partials or a count, so the demo
shows fields filling in. If a live stream is awkward to thread here, a
scripted-delta demonstration (emit chunks directly) still proves the path;
the plan decides after wiring it.

## Manual (`docs/streaming.md`)

Replace the "out of scope" sentence in "Streaming and typed skills" with a
"Partial typed values" section: the caller writes an all-`Maybe` partial
type and its codec, `runPartialWith` streams `Either DecodeError p` as
fields arrive, `closeJson` is the kernel, one top-level object, and the
relationship to `runRows` (lines vs one growing object). House style: no
emdashes, no hype, no manifest mentions.

## Testing (hermetic; scripted Emit deltas)

`closeJson` (pure, the bulk):

- `"{\"name\":\"Ali"` -> `"{\"name\":\"Ali\"}"` (partial value string closed).
- `"{\"name\":\"Bob\",\"age\":3"` -> `"{\"name\":\"Bob\",\"age\":3}"`.
- `"{\"a\":1,"` -> `"{\"a\":1}"` (trailing comma dropped).
- `"{\"a\":"` -> `"{}"` (key with no value dropped).
- `"{\"na"` -> `"{}"` (incomplete key dropped).
- `"{\"a\":tr"` -> `"{}"` (partial literal dropped).
- `"{\"a\":1,\"b\":{\"c\":\"x"` -> `"{\"a\":1,\"b\":{\"c\":\"x\"}}"` (nested, value string closed, stack closed in order).
- `"{}"` -> `"{}"`; `""` -> `""`; `"  "` -> trimmed/unchanged.

`runPartial` end to end (scripted deltas via `emit`):

- Feeding `["{\"name\": \"Al", "ice\", \"age\": 3", "0}"]` with a partial
  codec `{ name :: Maybe Text, age :: Maybe Int }` yields a sequence of
  partials ending in `Right (PersonP (Just "Alice") (Just 30))`, with an
  intermediate partial showing `name = Just "Al..."` and `age = Nothing`.
- A blank leading delta emits nothing.
- `runPartialWith` hands each partial to a sink in order (collected and
  compared).

## Non-goals

- Generic all-optional derivation (Option C): a possible follow-up bead if
  writing the partial type by hand proves annoying.
- Untyped partial `Value`s (Option A): rejected; the typed partial is the
  point.
- Top-level arrays of objects: that is `runRows`/JSONL.
- Debounce/dedup of identical consecutive partials: the caller's choice.
- Streaming fallback across providers.
