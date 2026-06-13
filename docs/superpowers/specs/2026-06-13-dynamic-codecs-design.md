# Dynamic Codecs Documentation Design Spec

**Date:** 2026-06-13
**Status:** Approved design, pending implementation
**Tracker:** `crucible-n0p`.
**Research basis:** `docs/superpowers/research/2026-06-11-baml-review.md` item 6 (dynamic codecs: document, do not build).
**Scope:** `docs/typed-functions.md` (one subsection); `test/Spec.hs` (one guard test). No library changes.

## Motivation

BAML needs a TypeBuilder to extend `@@dynamic` classes and enums at runtime
because its types are compiled. crucible codecs are ordinary runtime
values, so a schema that depends on runtime data needs no new machinery:
`enum (zip labels values)` over a list fetched at runtime (categories from
a database, say) already produces a `JSONCodec` whose injected schema lists
exactly those values. The gap is documentation, not code.

## Decision (autonomous)

This is the bead's own instruction ("document, do not build"), so there is
no design fork. The only choice is whether to add a guard test alongside
the docs; I add one small hermetic test so the documented claim (the
runtime schema follows the runtime list) cannot silently drift.

## Design

### Manual (`docs/typed-functions.md`)

A `### Dynamic codecs` subsection in "## Codecs" (after the `enum` example),
showing the category-from-database pattern: a list of labels fetched at
runtime is zipped into an `enum`, and the resulting codec's `schemaText`
lists exactly those labels, so the prompt the model sees follows the data.
Spell out that this needs no compile-time type and no TypeBuilder
equivalent because codecs are values. Example shape:

```haskell
-- categories known only at runtime (e.g. fetched from a database)
buildClassifier :: [Text] -> Skill Text Text
buildClassifier categories =
  skill "classify" str (enum (zip categories categories))
    (\s -> [text|Classify into one category: ${s}|])
```

The injected schema is a string-const enum of the runtime categories;
swap the list and the contract follows, no recompile.

### Guard test (`test/Spec.hs`)

One hermetic check: build `enum (zip cats cats)` from a runtime list,
assert `schemaText` contains each category, and assert `decodeLLM` accepts
a listed value and rejects an unlisted one.

## Non-goals

- Any TypeBuilder-style mutable-type machinery (the whole point: not
  needed).
- Dynamic addition of object fields at runtime (object codecs are built
  from field lists, which is the same value-level story; out of scope for
  this docs item, which targets the enum/category case the review names).

## House style

No emdashes, no hype, no manifest mentions.
