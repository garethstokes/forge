# Semantic Streaming of Partial Typed Values: DRAFT (needs a decision)

**Date:** 2026-06-13
**Status:** DRAFT, authored unattended. NOT approved, NOT planned, NOT implemented.
**Tracker:** `crucible-2ey`.
**Research basis:** `docs/superpowers/research/2026-06-11-baml-review.md` (semantic streaming); lifts the "incremental typed decoding of a single JSON object is out of scope" exclusion in `docs/streaming.md`.

**Why this is a draft and not the usual spec:** the bead says "decode
through a derived all-optional codec." Deriving an all-optional codec from
an arbitrary `JSONCodec a` is the central design fork, and it is genuinely
your call (it shapes the public API and pulls in real machinery). I would
not guess it unattended. This document researches the options and
recommends one; it is here for you to decide on, after which the normal
spec -> plan -> implement cycle runs.

## Goal

`runPartial`: reinterpret `Emit` so that, as deltas of a single growing
JSON object arrive, the caller receives progressively more complete
*typed partial values*. This is to one growing object what
`Crucible.Rows.runRows` is to JSONL lines. It lifts the streaming.md
exclusion.

## What is straightforward (no fork)

- **Buffering over Emit.** Mirror `Crucible.Rows`: reinterpret `Emit`,
  accumulate deltas in a buffer, and on each delta attempt a partial
  decode, handing results to a sink.
- **Closing unbalanced JSON.** `Crucible.Decode` already has the hard part:
  `scanBalanced` tracks bracket depth and string/escape state. A closer
  walks the buffer with that state and (1) if mid-string, closes the
  quote; (2) drops a trailing incomplete token (`{"a":` with no value, a
  dangling comma, a partial literal like `tr`); (3) appends the missing
  `]`/`}` in reverse nesting order. Fiddly but mechanical and pure;
  hermetically testable on hand-written buffers.

## The fork: how do partial values get a type?

A partial object is missing fields (not yet streamed). The decoded value
must therefore tolerate absent fields. autodocodec object codecs are built
from `requiredFieldWith'` applicatives over a fixed Haskell type `a`; the
codec is opaque and cannot be mechanically rewritten to relax requiredness,
and a partial `a` needs an all-`Maybe` shape, i.e. a *different type*. So
"a derived all-optional codec" is not a free transformation. Three ways to
deliver the feature:

### Option A: untyped partial `Value`s
`runPartial :: ... -> (Value -> m ()) -> Eff (Emit : es) a -> ...`. Close
the buffer, parse to an aeson `Value`, emit progressively complete
`Value`s. No codec, no type. Simplest by far; loses the "typed" promise
(the caller pattern-matches raw JSON). Good enough for a live UI preview;
weak as a typed-substrate feature.

### Option B: caller supplies the partial codec (recommended)
The caller writes the all-optional twin and its codec, exactly as the
dynamic-codecs insight prescribes (codecs are values; write the one you
need):

```haskell
data PersonP = PersonP { name :: Maybe Text, age :: Maybe Int }
runPartial :: Monad m => JSONCodec p -> (Either DecodeError p -> m ()) -> ...
```

`runPartial` closes the buffer and decodes through `codec @PersonP` on each
delta. No magic, honest types, reuses the whole codec stack. Cost: the
caller maintains a parallel partial type. This is the crucible-shaped
answer and mirrors BAML's `Partial<T>` without needing code generation.

### Option C: generic all-optional derivation
A `Partial` generic (or type family) that turns a record's fields into
their `Maybe` twins and derives the relaxed codec, so `runPartial (partial
@Person)` works from the original type. Closest to BAML's ergonomics, but
it is real machinery (Generics over `Crucible.Codec.Generic`, a new
type-level transformation) and a project of its own; it also interacts with
nested objects and lists (partial-deep vs partial-shallow).

## Recommendation

Option B for this cycle: it delivers genuinely typed partial streaming with
no new type-level machinery, reuses `Decode`'s scanner and the codec stack,
and stays honest about types. Option C is a worthwhile follow-up bead if
the parallel-type cost proves annoying in practice; Option A is too weak to
be the headline. But this is your call: B (pragmatic, some caller
boilerplate) vs C (ergonomic, heavier, its own cycle) vs A (cheap, untyped).

## Open questions for the decision

1. B, C, or A?
2. If B: does `runPartial` emit `Either DecodeError p` per delta (like
   `runRows`) or only emit on a successful partial decode (skip the noisy
   early buffers that close to nothing useful)?
3. Debounce: emit on every delta, or only when the closed-and-decoded
   value actually changed (avoid N near-identical partials)?
4. Scope: single top-level object only, or also a top-level array of
   objects (which overlaps `runRows`/JSONL)?

## Non-goals (regardless of option)

- Streaming fallback across providers (separate concern).
- Partial decoding of deeply nested structures beyond what the chosen
  option naturally supports.
- Replacing `runRows` (JSONL rows stay the supported path for datasets).

## Status / handoff

Awaiting your decision on the fork above. Once you pick an option, the
normal cycle (finalize spec -> plan -> subagent implementation -> merge)
runs. `crucible-2ey` is left claimed and in-progress with this note.
